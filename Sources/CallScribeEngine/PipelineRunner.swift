import CallScribeCore
import Foundation

/// Runs the post-recording pipeline: transcribe both tracks → diarize the
/// system track → merge → summarize. Resumable via meta.json stage flags and
/// the `.cache` artifacts, so a crash or a missing `claude` never forces
/// starting over — and never loses the transcript.
public actor PipelineRunner {
    public enum Stage: String, Sendable {
        case echoCancel, waitingForModel, transcribe, diarize, merge, summarize
    }

    private let folder: CallFolder
    private let modelsDir: URL
    private let summarizer: Summarizer?
    private let engine: STTEngine
    private let whisperModel: String
    private let log: Log
    private let project: String
    /// Last stage entered, so a thrown error can say where it happened.
    private var currentStage: Stage?

    public init(
        folder: CallFolder,
        modelsDir: URL,
        summarizer: Summarizer?,
        engine: STTEngine = .whisper,
        whisperModel: String = WhisperTranscriber.defaultModel,
        log: Log = .shared,
        project: String? = nil
    ) {
        self.folder = folder
        self.modelsDir = modelsDir
        self.summarizer = summarizer
        self.engine = engine
        self.whisperModel = whisperModel
        self.log = log
        // The display name when the caller knows it (the app), else the
        // containing directory — the CLI has no notion of projects.
        self.project = project ?? folder.url.deletingLastPathComponent().lastPathComponent
    }

    /// Every line carries the project and the call folder: the folder name is only
    /// a timestamp, and two projects can hold calls from the same minute.
    private func note(_ text: String) -> String { "pipeline [\(project)] \(folder.name) \(text)" }

    /// Run every stage that hasn't completed yet.
    /// `onStage` reports progress for the UI.
    @discardableResult
    public func run(
        force: Bool = false,
        onStage: (@Sendable (Stage) -> Void)? = nil
    ) async throws -> CallMeta {
        do {
            let meta = try await runStages(force: force, onStage: onStage)
            log.info(note("done"))
            return meta
        } catch {
            // Which stage it died in is the part a bare error text never says.
            log.error(note("""
                stage=\(currentStage?.rawValue ?? "start") failed: \
                \(Log.truncated(error.localizedDescription))
                """))
            throw error
        }
    }

    /// Report a stage to the UI, the log, and `currentStage` in one move, so a
    /// failure can name where it happened.
    private func mark(_ stage: Stage, _ onStage: (@Sendable (Stage) -> Void)?) {
        currentStage = stage
        onStage?(stage)
        log.info(note("stage=\(stage.rawValue)"))
    }

    private func runStages(
        force: Bool,
        onStage: (@Sendable (Stage) -> Void)?
    ) async throws -> CallMeta {
        try FileManager.default.createDirectory(at: folder.cacheDir, withIntermediateDirectories: true)
        var meta = try folder.loadMeta()

        // 0. Cancel speaker echo from the mic track (best-effort; never fatal).
        if force || !meta.pipeline.echoCanceled {
            mark(.echoCancel, onStage)
            runEchoCancellation()
            meta.pipeline.echoCanceled = true
            try folder.saveMeta(meta)
        }

        // 1. Transcribe both tracks (serially, one model instance).
        if force || !meta.pipeline.transcribed {
            // Before claiming to transcribe: on a fresh machine this waits on a
            // ~1.5 GB download, and saying "Transcribing…" through it is the lie
            // this reports instead. `onStart` fires only when we really wait.
            // Attribute a provisioning failure to this stage even though the UI
            // only hears about it when we genuinely have to wait. The callback
            // runs inside the provisioner's actor, so it touches no state here.
            currentStage = .waitingForModel
            try await ModelProvisioner.shared.ensureReady(
                modelsDir: modelsDir,
                engine: engine,
                model: whisperModel,
                onStart: { [log, project, name = folder.name] in
                    onStage?(.waitingForModel)
                    log.info("pipeline [\(project)] \(name) stage=waitingForModel")
                }
            )
            mark(.transcribe, onStage)
            let transcriber = try await makeTranscriber()
            let mic = try await transcriber.transcribe(wav: micSource(), language: meta.language)
            let system = try await transcriber.transcribe(wav: folder.systemWAV, language: meta.language)
            try write(mic, to: folder.whisperMicJSON)
            try write(system, to: folder.whisperSystemJSON)
            meta.detectedLanguage = mic.detectedLanguage ?? system.detectedLanguage
            meta.whisperModel = sttModelName
            meta.pipeline.transcribed = true
            try folder.saveMeta(meta)
        }

        // 2. Diarize the system track (failure → empty spans, never fatal).
        //    Enrolled voices let matched speakers come back labeled by name.
        if force || !meta.pipeline.diarized {
            mark(.diarize, onStage)
            let spans = await runDiarization(expectedSpeakers: meta.expectedSpeakers)
            try write(spans, to: folder.diarizationJSON)
            // Old LLM corrections are keyed against the spans this just replaced;
            // left in place they could flip a now-correct turn that happens to
            // share a timecode. The summarize ahead infers fresh ones.
            meta.speakerCorrections = nil
            meta.pipeline.diarized = true
            try folder.saveMeta(meta)
        }

        // 3. Merge into transcript.md.
        if force || !meta.pipeline.merged {
            mark(.merge, onStage)
            try renderTranscript(names: meta.speakerNames)
            meta.pipeline.merged = true
            try folder.saveMeta(meta)
        }

        // 4. Summarize (optional; failure leaves transcript intact).
        if let summarizer, force || !meta.pipeline.summarized {
            mark(.summarize, onStage)
            let transcript = try String(contentsOf: folder.transcriptMD, encoding: .utf8)
            let result = try await summarizer.summarize(
                transcript: transcript, projectContext: projectContext())
            try result.markdown.write(to: folder.summaryMD, atomically: true, encoding: .utf8)
            if let title = result.title { meta.title = title }
            appendCorrections(result, to: &meta)
            appendReplacements(result, to: &meta)
            if !result.speakerNames.isEmpty {
                meta.speakerNames.merge(result.speakerNames) { _, new in new }
            }
            // Persist names + fixes before re-rendering (renderTranscript reads
            // them back from meta.json), but mark the stage done only after the
            // render — a failed render re-runs summarize instead of stranding
            // transcript.md without the fixes.
            try folder.saveMeta(meta)
            if !result.speakerNames.isEmpty || !result.corrections.isEmpty
                || !result.replacements.isEmpty {
                try renderTranscript(names: meta.speakerNames)
            }
            meta.pipeline.summarized = true
            try folder.saveMeta(meta)
        }

        return meta
    }

    /// Run a single stage in isolation (used by the per-stage CLI subcommands).
    /// Stages depend on their predecessors' `.cache` artifacts existing.
    @discardableResult
    public func runStage(_ stage: Stage, force: Bool) async throws -> CallMeta {
        // Same record as `run()` — this is the CLI's path and has no stage channel
        // to the UI at all, so without this a `callscribe summarize` failure leaves
        // nothing behind but the terminal it was printed to.
        log.info(note("stage=\(stage.rawValue) (single)"))
        do {
            let meta = try await runOneStage(stage, force: force)
            log.info(note("stage=\(stage.rawValue) ok"))
            return meta
        } catch {
            log.error(note("stage=\(stage.rawValue) failed: \(Log.truncated(error.localizedDescription))"))
            throw error
        }
    }

    private func runOneStage(_ stage: Stage, force: Bool) async throws -> CallMeta {
        try FileManager.default.createDirectory(at: folder.cacheDir, withIntermediateDirectories: true)
        var meta = try folder.loadMeta()
        switch stage {
        case .waitingForModel:
            return meta   // a reported status, not a runnable stage
        case .echoCancel:
            runEchoCancellation()
            meta.pipeline.echoCanceled = true
        case .transcribe:
            // No stage channel here (CLI subcommands) — still share the one
            // coalesced download rather than starting a second one.
            try await ModelProvisioner.shared.ensureReady(
                modelsDir: modelsDir, engine: engine, model: whisperModel)
            let transcriber = try await makeTranscriber()
            let mic = try await transcriber.transcribe(wav: micSource(), language: meta.language)
            let system = try await transcriber.transcribe(wav: folder.systemWAV, language: meta.language)
            try write(mic, to: folder.whisperMicJSON)
            try write(system, to: folder.whisperSystemJSON)
            meta.detectedLanguage = mic.detectedLanguage ?? system.detectedLanguage
            meta.whisperModel = sttModelName
            meta.pipeline.transcribed = true
        case .diarize:
            let spans = await runDiarization(expectedSpeakers: meta.expectedSpeakers)
            try write(spans, to: folder.diarizationJSON)
            // Keyed against the spans this just replaced — see runStages.
            meta.speakerCorrections = nil
            meta.pipeline.diarized = true
        case .merge:
            try renderTranscript(names: meta.speakerNames)
            meta.pipeline.merged = true
        case .summarize:
            guard let summarizer else {
                // "Regenerate summary" with no `claude` on disk does nothing at
                // all; without this the next line would claim the stage was ok.
                log.warn(note("stage=summarize skipped — no summarizer (claude CLI not found)"))
                return meta
            }
            let transcript = try String(contentsOf: folder.transcriptMD, encoding: .utf8)
            let result = try await summarizer.summarize(
                transcript: transcript, projectContext: projectContext())
            try result.markdown.write(to: folder.summaryMD, atomically: true, encoding: .utf8)
            if let title = result.title { meta.title = title }
            appendCorrections(result, to: &meta)
            appendReplacements(result, to: &meta)
            if !result.speakerNames.isEmpty {
                meta.speakerNames.merge(result.speakerNames) { _, new in new }
            }
            // Save first (renderTranscript reads the fixes from meta.json);
            // the summarized flag lands with the final save below.
            try folder.saveMeta(meta)
            if !result.speakerNames.isEmpty || !result.corrections.isEmpty
                || !result.replacements.isEmpty {
                try renderTranscript(names: meta.speakerNames)
            }
            meta.pipeline.summarized = true
        }
        try folder.saveMeta(meta)
        return meta
    }

    /// Accumulate LLM turn corrections in meta. Must run BEFORE this round's
    /// inferred names are merged into meta: canonicalization needs the map the
    /// LLM's transcript was rendered with — extended with the names it
    /// inferred this round, which it may already be using in `corrections`.
    private func appendCorrections(_ result: SummaryResult, to meta: inout CallMeta) {
        guard !result.corrections.isEmpty else { return }
        let merged = SpeakerCorrections.appending(
            result.corrections,
            to: meta.speakerCorrections ?? [],
            names: meta.speakerNames.merging(result.speakerNames) { _, new in new }
        )
        meta.speakerCorrections = merged.isEmpty ? nil : merged
    }

    /// Accumulate glossary-driven term fixes; exact duplicates from a
    /// re-summarize are skipped (replacing the same text twice is a no-op,
    /// but the list shouldn't grow unboundedly).
    private func appendReplacements(_ result: SummaryResult, to meta: inout CallMeta) {
        guard !result.replacements.isEmpty else { return }
        var existing = meta.textReplacements ?? []
        for replacement in result.replacements where !existing.contains(replacement) {
            existing.append(replacement)
        }
        meta.textReplacements = existing
    }

    /// The project's glossary/notes — context.md beside the call folders,
    /// nil when absent or empty.
    private func projectContext() -> String? {
        let url = folder.url.deletingLastPathComponent().appendingPathComponent("context.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Re-render transcript.md from cached data with a (possibly updated) name
    /// map — used by "apply inferred names" and manual rename, no re-merge.
    public func renderTranscript(names: [String: String]) throws {
        let mic: TrackTranscription = try read(folder.whisperMicJSON)
        let system: TrackTranscription = try read(folder.whisperSystemJSON)
        let spans: [SpeakerSpan] = (try? read(folder.diarizationJSON)) ?? []
        let meta = try? folder.loadMeta()
        // When the user fixed the speaker count, trust it — don't fold a forced
        // cluster away as a phantom.
        var config = MergeConfig()
        if meta?.expectedSpeakers != nil { config.phantomSpeakerMinDuration = 0 }
        var transcript = TranscriptMerger.merge(
            micWords: mic.words,
            systemWords: system.words,
            spans: spans,
            config: config,
            detectedLanguage: mic.detectedLanguage ?? system.detectedLanguage
        )
        // Turn-level fixes the summarizer inferred from context survive every
        // re-render; ones a re-diarization invalidated just stop matching.
        if let corrections = meta?.speakerCorrections {
            transcript = SpeakerCorrections.apply(corrections, to: transcript, names: names)
        }
        let markdown = TranscriptMarkdownRenderer.render(
            transcript, names: names, replacements: meta?.textReplacements ?? [])
        try markdown.write(to: folder.transcriptMD, atomically: true, encoding: .utf8)
        // Structured sidecar with real per-utterance times for the UI highlight.
        // Name-independent (canonical speaker labels); names are applied on display.
        try write(transcript, to: folder.turnsJSON)
    }

    /// Echo cancellation, with its result recorded instead of dropped. Both entry
    /// points mark the stage done either way, so a skip is otherwise invisible —
    /// and `micSource()` then transcribes the raw mic, speaker echo included.
    private func runEchoCancellation() {
        let cancelled = EchoCanceller.process(
            micWAV: folder.micWAV, systemWAV: folder.systemWAV, outWAV: folder.micCleanWAV)
        if cancelled {
            log.info(note("stage=echoCancel ok"))
        } else {
            log.warn(note("stage=echoCancel skipped — transcribing the raw mic (echo included)"))
        }
    }

    /// Diarization, which returns empty spans rather than throwing. Empty means
    /// every remote participant collapses into one speaker in the transcript.
    private func runDiarization(expectedSpeakers: Int?) async -> [SpeakerSpan] {
        let spans = await CallDiarizer.diarize(
            wav: folder.systemWAV, modelDirectory: modelsDir,
            knownVoices: VoiceStore().load(), expectedSpeakers: expectedSpeakers)
        if spans.isEmpty {
            log.warn(note("stage=diarize produced no spans — remote speakers will merge into one"))
        } else {
            log.info(note("stage=diarize spans=\(spans.count)"))
        }
        return spans
    }

    /// The engine's transcriber, loading its model from disk (both engines
    /// fall back to downloading only on a first run `ensureReady` missed).
    private func makeTranscriber() async throws -> SpeechTranscriber {
        switch engine {
        case .whisper: try await WhisperTranscriber(model: whisperModel, modelFolder: modelsDir)
        case .parakeet: try await ParakeetTranscriber(modelsDir: modelsDir)
        }
    }

    /// The model identifier recorded in meta.json for this run's engine.
    private var sttModelName: String {
        engine == .whisper ? whisperModel : engine.modelName
    }

    /// The mic signal to transcribe: the echo-cancelled track when present,
    /// else the raw mic.
    private func micSource() -> URL {
        FileManager.default.fileExists(atPath: folder.micCleanWAV.path)
            ? folder.micCleanWAV : folder.micWAV
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
