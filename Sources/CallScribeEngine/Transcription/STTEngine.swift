import Foundation

/// One speech-to-text engine: word-timestamped transcription for the call
/// pipeline, plain text for dictation, and unload for warm instances.
public protocol SpeechTranscriber: Sendable {
    func transcribe(wav url: URL, language: String?) async throws -> TrackTranscription
    func transcribeText(wav url: URL, language: String?) async throws -> (text: String, language: String?)
    func unload() async
}

/// The user-selectable STT engine, persisted in UserDefaults so the tray
/// picker, the pipeline, and dictation all agree. Whisper is the accuracy
/// default; Parakeet trades some accuracy (notably on mixed-language speech)
/// for several-fold speed and a third of the disk and memory.
public enum STTEngine: String, CaseIterable, Sendable, Identifiable {
    case whisper
    case parakeet

    public var id: String { rawValue }

    /// The model identifier recorded in meta.json and used for provisioning.
    public var modelName: String {
        switch self {
        case .whisper: WhisperTranscriber.defaultModel
        case .parakeet: ParakeetTranscriber.defaultModel
        }
    }

    public var displayName: String {
        switch self {
        case .whisper: "Whisper large-v3 turbo — accurate, 1.5 GB"
        case .parakeet: "Parakeet TDT v3 — fast, 0.5 GB"
        }
    }

    public static let defaultsKey = "stt.engine"

    /// The engine the user picked, `.whisper` until they pick one.
    public static func current(from defaults: UserDefaults = .standard) -> STTEngine {
        defaults.string(forKey: defaultsKey).flatMap(STTEngine.init(rawValue:)) ?? .whisper
    }

    public func persist(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
