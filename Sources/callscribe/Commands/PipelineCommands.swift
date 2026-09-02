import ArgumentParser
import CallScribeCore
import CallScribeEngine
import Foundation

/// Shared helpers for the folder-oriented pipeline subcommands.
private func callFolder(_ path: String) -> CallFolder {
    CallFolder(url: URL(fileURLWithPath: path))
}

private func makeRunner(
    _ folder: CallFolder, withSummarizer: Bool, engine: STTEngine = .whisper
) throws -> PipelineRunner {
    let modelsDir = try AppPaths.ensureModelsDirectory()
    let summarizer: Summarizer? = withSummarizer ? ClaudeCLISummarizer() : nil
    if withSummarizer && summarizer == nil {
        FileHandle.standardError.write(Data("note: `claude` CLI not found; summary will be skipped\n".utf8))
    }
    return PipelineRunner(folder: folder, modelsDir: modelsDir, summarizer: summarizer, engine: engine)
}

private func parseEngine(_ raw: String) throws -> STTEngine {
    guard let engine = STTEngine(rawValue: raw.lowercased()) else {
        throw ValidationError("Unknown engine '\(raw)' — use whisper or parakeet.")
    }
    return engine
}

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Download and prewarm the transcription model (one-time, several minutes)."
    )
    @Option(help: "STT engine to fetch: whisper or parakeet.") var engine: String = "whisper"

    func run() async throws {
        let engine = try parseEngine(engine)
        let dir = try AppPaths.ensureModelsDirectory()
        print("Downloading + prewarming \(engine.modelName) into \(dir.path)…")
        try await ModelProvisioner.shared.ensureReady(
            modelsDir: dir,
            engine: engine,
            onProgress: { fraction in
                print(fraction.map { String(format: "  %.0f%%", $0 * 100) } ?? "  starting…")
            })
        switch engine {
        case .whisper: _ = try await WhisperTranscriber(modelFolder: dir, prewarm: true)
        case .parakeet: _ = try await ParakeetTranscriber(modelsDir: dir)
        }
        print("Model ready.")
    }
}

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe both tracks of a call folder (writes .cache/whisper-*.json)."
    )
    @Argument(help: "Path to the call folder.") var folder: String
    @Flag(help: "Re-transcribe even if cached.") var force = false
    @Option(help: "STT engine: whisper or parakeet.") var engine: String = "whisper"

    func run() async throws {
        let runner = try makeRunner(
            callFolder(folder), withSummarizer: false, engine: parseEngine(engine))
        _ = try await runner.runStage(.transcribe, force: force)
        print("Transcribed.")
    }
}

struct DiarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diarize",
        abstract: "Diarize the system track of a call folder (writes .cache/diarization.json)."
    )
    @Argument(help: "Path to the call folder.") var folder: String
    @Flag(help: "Re-diarize even if cached.") var force = false
    @Option(help: "Force this many remote speakers (persisted; omit for auto).") var speakers: Int?

    func run() async throws {
        let f = callFolder(folder)
        if let speakers {
            var meta = try f.loadMeta()
            meta.expectedSpeakers = speakers
            try f.saveMeta(meta)
        }
        let runner = try makeRunner(f, withSummarizer: false)
        _ = try await runner.runStage(.diarize, force: force)
        print("Diarized.")
    }
}

struct EchoCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "echocancel",
        abstract: "Remove speaker echo from the mic track (writes .cache/mic-clean.wav)."
    )
    @Argument(help: "Path to the call folder.") var folder: String

    func run() async throws {
        let runner = try makeRunner(callFolder(folder), withSummarizer: false)
        _ = try await runner.runStage(.echoCancel, force: true)
        print("Echo-cancelled → .cache/mic-clean.wav")
    }
}

struct EnrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enroll",
        abstract: "Learn a speaker's voice from a call, then re-diarize + re-merge."
    )
    @Argument(help: "Path to the call folder.") var folder: String
    @Argument(help: #"Canonical speaker label, e.g. "Speaker 2"."#) var speaker: String
    @Argument(help: "The person's name.") var name: String

    func run() async throws {
        let f = callFolder(folder)
        let modelsDir = try AppPaths.ensureModelsDirectory()
        let learned = try await VoiceEnroller.learn(
            speakerLabel: speaker, in: f, modelDirectory: modelsDir)
        let store = VoiceStore()
        let voices = try store.upsert(VoiceProfile(name: name, embedding: learned.embedding))
        try? store.saveSample(learned.sample, forName: name)
        print("Learned \(name) (\(learned.embedding.count)-dim). Library now has \(voices.count) voice(s).")
        let runner = PipelineRunner(folder: f, modelsDir: modelsDir, summarizer: nil)
        _ = try await runner.runStage(.diarize, force: true)
        _ = try await runner.runStage(.merge, force: true)
        print("Re-diarized + re-merged \(f.url.lastPathComponent).")
    }
}

struct MergeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge transcription + diarization into transcript.md."
    )
    @Argument(help: "Path to the call folder.") var folder: String

    func run() async throws {
        let runner = try makeRunner(callFolder(folder), withSummarizer: false)
        _ = try await runner.runStage(.merge, force: true)
        print("Wrote transcript.md")
    }
}

struct SummarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "Summarize transcript.md via `claude -p` into summary.md."
    )
    @Argument(help: "Path to the call folder.") var folder: String

    func run() async throws {
        let runner = try makeRunner(callFolder(folder), withSummarizer: true)
        _ = try await runner.runStage(.summarize, force: true)
        print("Wrote summary.md")
    }
}

struct PipelineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pipeline",
        abstract: "Run the full post-recording pipeline (resumable)."
    )
    @Argument(help: "Path to the call folder.") var folder: String
    @Flag(help: "Re-run every stage.") var force = false
    @Option(help: "STT engine: whisper or parakeet.") var engine: String = "whisper"

    func run() async throws {
        let f = callFolder(folder)
        let runner = try makeRunner(f, withSummarizer: true, engine: parseEngine(engine))
        let meta = try await runner.run(force: force) { stage in
            print("… \(stage.rawValue)")
        }
        print("Done. transcript.md\(meta.pipeline.summarized ? " + summary.md" : " (summary skipped)")")
        print("  \(f.url.path)")
    }
}
