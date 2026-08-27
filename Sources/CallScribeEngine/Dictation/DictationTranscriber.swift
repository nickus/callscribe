import Foundation

/// One Whisper model, kept loaded between dictations. This is the whole reason
/// dictation feels instant.
///
/// The pipeline builds a `WhisperTranscriber` per run and throws it away, which
/// is right for a call: the 5–10 s model load disappears against minutes of
/// work. For dictation it *is* the work, so the instance is held instead.
///
/// It is a second instance, independent of the pipeline's, on purpose: sharing
/// one would park a two-second dictation behind an hour-long call
/// transcription. The cost is both models resident while a call is processing,
/// which `releaseIfIdle(after:)` keeps from becoming the steady state.
///
/// Being an `actor` also gives serialization for free — two dictations can never
/// decode at once.
public actor DictationTranscriber {
    public static let shared = DictationTranscriber()

    private let model: String
    private var transcriber: SpeechTranscriber?
    private var loadedEngine: STTEngine?
    private var lastUsed: Date?
    private var idleRelease: Task<Void, Never>?
    /// Decodes currently inside `transcribeText` — an engine swap must never
    /// unload the model out from under one (actors interleave at awaits).
    private var decodesInFlight = 0
    /// The one in-flight load; reentrant `prepare`s join it instead of racing
    /// it and clobbering each other's instance. The generation counter tells
    /// a joiner whether the slot still holds the task it awaited (Task is a
    /// struct — no identity to compare).
    private var loadTask: Task<SpeechTranscriber, Error>?
    private var loadTaskEngine: STTEngine?
    private var loadGeneration = 0

    public init(model: String = WhisperTranscriber.defaultModel) {
        self.model = model
    }

    /// Whether the model is loaded right now — lets the UI say "loading the
    /// model" instead of "transcribing" when the next call will pay for a load.
    public var isWarm: Bool { transcriber != nil }

    /// Load the engine's model if it isn't already. Idempotent, and worth
    /// calling the moment recording *starts* rather than when it ends: the
    /// first load then overlaps the seconds the user spends speaking instead
    /// of following them. Switching engines in the tray swaps the warm
    /// instance on the next dictation.
    public func prepare(modelsDir: URL, engine: STTEngine = .whisper) async throws {
        _ = try await obtainTranscriber(modelsDir: modelsDir, engine: engine)
    }

    /// Transcribe one utterance to plain text, with the language it turned out to
    /// be in. `text` is "" if the clip held no speech. `language` nil = auto-detect,
    /// in which case the returned one is what the engine decided (nil from
    /// Parakeet, which doesn't report a language).
    public func transcribe(
        wav url: URL,
        language: String?,
        modelsDir: URL,
        engine: STTEngine = .whisper
    ) async throws -> (text: String, language: String?) {
        guard let transcriber = try await obtainTranscriber(modelsDir: modelsDir, engine: engine)
        else { return ("", nil) }
        decodesInFlight += 1
        defer { decodesInFlight -= 1 }
        let result = try await transcriber.transcribeText(wav: url, language: language)
        lastUsed = Date()
        guard Self.containsSpeech(result.text) else { return ("", result.language) }
        return (result.text, result.language)
    }

    /// The warm instance for `engine`, loading — or joining an in-flight
    /// load — as needed. Returns the instance DIRECTLY rather than reading
    /// the shared slot afterwards: a concurrent different-engine prepare can
    /// swap the slot between our load finishing and us resuming, and a
    /// dictation must not lose the model its own load just produced.
    private func obtainTranscriber(
        modelsDir: URL, engine: STTEngine
    ) async throws -> SpeechTranscriber? {
        while let task = loadTask {
            let generation = loadGeneration
            let taskEngine = loadTaskEngine
            let joined = try? await task.value
            if loadGeneration == generation {
                loadTask = nil
                loadTaskEngine = nil
            }
            if taskEngine == engine, let joined { return joined }
        }
        if let current = transcriber {
            if loadedEngine == engine { return current }
            // A different engine while an utterance is still decoding: keep
            // the warm model for this one; the switch applies on the next.
            if decodesInFlight > 0 { return current }
        }

        let previous = transcriber
        transcriber = nil
        let task = Task { [model] () -> SpeechTranscriber in
            if let previous { await previous.unload() }
            // Surfaces `ModelProvisioner.Failure` when the model isn't downloaded,
            // so the caller can say "still downloading" instead of appearing to hang.
            try await ModelProvisioner.shared.ensureReady(
                modelsDir: modelsDir, engine: engine, model: model)
            let started = Date()
            let loaded: SpeechTranscriber = switch engine {
            case .whisper: try await WhisperTranscriber(model: model, modelFolder: modelsDir)
            case .parakeet: try await ParakeetTranscriber(modelsDir: modelsDir)
            }
            self.transcriber = loaded
            self.loadedEngine = engine
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            Log.shared.info("dictation: \(engine.rawValue) model loaded in \(elapsed) s")
            return loaded
        }
        loadGeneration += 1
        loadTask = task
        loadTaskEngine = engine
        let generation = loadGeneration
        defer {
            if loadGeneration == generation {
                loadTask = nil
                loadTaskEngine = nil
            }
        }
        return try await task.value
    }

    /// Whisper renders silence as punctuation — a bare "." or "…" — so a hold with
    /// nothing spoken into it comes back non-empty and would paste a stray period
    /// into the user's document. Anything with no letter or digit in it is nothing.
    static func containsSpeech(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Drop the model once it has gone unused for `interval`. Rescheduled by each
    /// call, so a burst of dictations keeps it warm and a quiet spell hands the
    /// memory back.
    public func releaseIfIdle(after interval: TimeInterval) {
        idleRelease?.cancel()
        idleRelease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await self?.releaseIfUnused(for: interval)
        }
    }

    private func releaseIfUnused(for interval: TimeInterval) async {
        guard let transcriber,
              let lastUsed,
              // Re-checked rather than trusted: the sleep says the timer elapsed,
              // not that nothing used the model in the meantime. lastUsed alone
              // can't see a decode still in flight (it's stamped on completion),
              // so an idle release must never yank a model mid-decode.
              decodesInFlight == 0,
              Date().timeIntervalSince(lastUsed) >= interval
        else { return }
        self.transcriber = nil
        await transcriber.unload()
        Log.shared.info("dictation: released the warm model after \(Int(interval)) s idle")
    }
}
