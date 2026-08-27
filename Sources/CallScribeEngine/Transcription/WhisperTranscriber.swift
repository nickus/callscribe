import CallScribeCore
import Foundation
import WhisperKit

/// Word-timestamped Whisper output for one track, engine-agnostic.
public struct TrackTranscription: Codable, Sendable {
    public let words: [Word]
    public let detectedLanguage: String?
}

/// Wraps WhisperKit for batch transcription of a WAV file. Reuses one loaded
/// model across both tracks (they run serially to bound peak memory).
///
/// `@unchecked Sendable` so a long-lived instance can be held as actor state
/// (dictation keeps one warm). It adds no mutable state of its own — just an
/// immutable handle to a `WhisperKit`, which is not itself Sendable — so
/// *serializing* calls remains the caller's job. Both callers do: the pipeline
/// transcribes its two tracks one after the other, and `DictationTranscriber`
/// is an actor.
public final class WhisperTranscriber: SpeechTranscriber, @unchecked Sendable {
    public static let defaultModel = "openai_whisper-large-v3-v20240930_turbo"

    private let whisperKit: WhisperKit

    public init(
        model: String = defaultModel,
        modelFolder: URL,
        prewarm: Bool = false
    ) async throws {
        // If the model is already downloaded, load it straight from disk with no
        // network — transcription is meant to be fully offline, and a Hugging
        // Face hiccup (e.g. a 504) must not break an already-provisioned app.
        // The tokenizer resolves locally too via downloadBase. Fall back to
        // downloading only when the model isn't present yet (first run).
        let localModel = ModelProvisioner.whisperModelURL(modelsDir: modelFolder, model: model)
        let isCached = FileManager.default.fileExists(
            atPath: localModel.appendingPathComponent("AudioEncoder.mlmodelc").path)

        let config: WhisperKitConfig
        if isCached {
            config = WhisperKitConfig(
                downloadBase: modelFolder,
                modelFolder: localModel.path,
                verbose: false,
                logLevel: .error,
                prewarm: prewarm,
                load: true,
                download: false
            )
        } else {
            config = WhisperKitConfig(
                model: model,
                downloadBase: modelFolder,
                verbose: false,
                logLevel: .error,
                prewarm: prewarm,
                load: true,
                download: true
            )
        }
        self.whisperKit = try await WhisperKit(config)
    }

    /// Transcribe a WAV file. `language` nil = auto-detect.
    public func transcribe(wav url: URL, language: String?) async throws -> TrackTranscription {
        let options = DecodingOptions(
            verbose: false,
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: true
        )
        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)

        var words: [Word] = []
        for segment in results.flatMap(\.segments) {
            for timing in segment.words ?? [] {
                let text = timing.word.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                words.append(Word(
                    text: timing.word,
                    start: TimeInterval(timing.start),
                    end: TimeInterval(timing.end),
                    probability: timing.probability
                ))
            }
        }
        return TrackTranscription(words: words, detectedLanguage: results.first?.language)
    }

    /// Transcribe a WAV file to plain text. `language` nil = auto-detect.
    ///
    /// Word timestamps are the *merge* algorithm's requirement, not
    /// transcription's — dictation has no use for them and asking for them isn't
    /// free, so this is a second entry point rather than a flag on the one above.
    public func transcribeText(
        wav url: URL,
        language: String?
    ) async throws -> (text: String, language: String?) {
        let options = DecodingOptions(
            verbose: false,
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: false
        )
        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
        // Trim each window before joining: their texts carry leading spaces, and
        // concatenating raw would leave doubled ones mid-sentence.
        let text = results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (text, results.first?.language)
    }

    /// Release the CoreML models now. Only a long-lived instance needs this —
    /// the pipeline builds one per run and simply drops it, whereas dictation
    /// holds one warm between uses and wants the ~1.5 GB back on a timer.
    public func unload() async {
        await whisperKit.unloadModels()
    }
}
