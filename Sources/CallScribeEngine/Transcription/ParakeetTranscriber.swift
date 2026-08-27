import CallScribeCore
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B v3 (FluidAudio's CoreML port) as an STT engine:
/// multilingual (25 languages incl. Russian), several-fold faster than Whisper
/// at a third of the footprint, and it doesn't hallucinate text on silence.
/// Token timings come back per ~80 ms encoder frame with the whole-file
/// timeline already stitched across chunks, and FluidAudio's own aggregator
/// groups them into words — plenty of resolution for the merge, whose gaps and
/// spans are all hundreds of milliseconds.
///
/// Unlike Whisper it does not report a detected language, so
/// `detectedLanguage` comes back nil and downstream treats the language as
/// unknown. The optional `language` is a script-filter hint (keeps Latin
/// hallucinations out of Cyrillic audio), not a language switch.
public final class ParakeetTranscriber: SpeechTranscriber, @unchecked Sendable {
    public static let defaultModel = "parakeet-tdt-0.6b-v3"

    private let manager: AsrManager

    /// Where the model lives under `modelsDir`. FluidAudio resolves the model
    /// at `<parent-of-what-you-pass>/<repo folder name>`, so the last path
    /// component must BE the repo folder name for everything to stay in our
    /// models directory.
    public static func modelURL(modelsDir: URL) -> URL {
        modelsDir.appendingPathComponent(defaultModel, isDirectory: true)
    }

    public init(modelsDir: URL) async throws {
        // melChunkContext is an English-only blank fix that pulls the decoder
        // toward its English prior at chunk seams on multilingual audio
        // (FluidAudio #594) — off for our ru/en calls.
        let config = ASRConfig(melChunkContext: false)
        // Offline-first, like WhisperTranscriber: an already-provisioned app
        // must load from disk even when Hugging Face is unreachable.
        let dir = Self.modelURL(modelsDir: modelsDir)
        let models: AsrModels
        if AsrModels.modelsExist(at: dir) {
            models = try await AsrModels.load(from: dir)
        } else {
            models = try await AsrModels.downloadAndLoad(to: dir)
        }
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)
        self.manager = manager
    }

    public func transcribe(wav url: URL, language: String?) async throws -> TrackTranscription {
        guard let result = try await run(url: url, language: language) else {
            return TrackTranscription(words: [], detectedLanguage: nil)
        }
        return TrackTranscription(
            words: Self.words(from: result.tokenTimings ?? []),
            detectedLanguage: nil
        )
    }

    public func transcribeText(
        wav url: URL,
        language: String?
    ) async throws -> (text: String, language: String?) {
        guard let result = try await run(url: url, language: language) else { return ("", nil) }
        return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    public func unload() async {
        await manager.cleanup()
    }

    /// nil = the clip is shorter than the model's 300 ms minimum (a minimal
    /// dictation hold can produce one) — no speech, not an error.
    private func run(url: URL, language: String?) async throws -> ASRResult? {
        var state = TdtDecoderState.make()
        let hint = language.flatMap(Language.init(rawValue:))
        do {
            return try await manager.transcribe(url, decoderState: &state, language: hint)
        } catch let error as ASRError {
            if case .invalidAudioData = error { return nil }
            throw error
        }
    }

    /// FluidAudio token timings → merge-ready words. Empty in, empty out —
    /// timings are legitimately absent on decoder edge cases, and a track of
    /// pure silence yields no tokens at all.
    static func words(from timings: [TokenTiming]) -> [Word] {
        buildWordTimings(from: timings).compactMap { timing in
            let text = timing.word.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return Word(text: text, start: timing.startTime, end: timing.endTime)
        }
    }
}
