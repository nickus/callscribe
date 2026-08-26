import Foundation

/// Contents of `meta.json` in a call folder: call metadata, the speaker-label →
/// real-name mapping, and pipeline stage flags that make processing resumable.
public struct CallMeta: Codable, Sendable, Equatable {
    public struct PipelineState: Codable, Sendable, Equatable {
        public var echoCanceled = false
        public var transcribed = false
        public var diarized = false
        public var merged = false
        public var summarized = false

        public init() {}

        // Tolerant decode: missing flags (e.g. `echoCanceled` in meta.json
        // written by an older build) default to false rather than throwing.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            echoCanceled = try c.decodeIfPresent(Bool.self, forKey: .echoCanceled) ?? false
            transcribed = try c.decodeIfPresent(Bool.self, forKey: .transcribed) ?? false
            diarized = try c.decodeIfPresent(Bool.self, forKey: .diarized) ?? false
            merged = try c.decodeIfPresent(Bool.self, forKey: .merged) ?? false
            summarized = try c.decodeIfPresent(Bool.self, forKey: .summarized) ?? false
        }
    }

    public var startedAt: Date
    public var endedAt: Date?
    public var durationSec: Double?
    /// Short LLM-generated title (from the summarizer); nil until summarized.
    public var title: String?
    /// Whisper language override ("ru"/"en"); nil = auto-detect.
    public var language: String?
    /// How many remote participants to split the system track into; nil = auto.
    /// The mic/"Me" track is separate and never diarized, so this counts others.
    public var expectedSpeakers: Int?
    /// Detected language of the call, filled in after transcription.
    public var detectedLanguage: String?
    /// Debug: gap between session start and each track's first audio buffer
    /// (that much silence is prepended to keep both tracks on one timeline).
    public var micStartOffsetSec: Double?
    public var systemStartOffsetSec: Double?
    /// "Speaker 1" → "Misha"; inferred by the Summarizer or set manually.
    public var speakerNames: [String: String]
    /// Turn-level speaker fixes inferred by the Summarizer; re-applied on every
    /// transcript re-render. Dropped on trim (their timecodes shift).
    public var speakerCorrections: [SpeakerCorrection]?
    public var pipeline: PipelineState
    public var appVersion: String
    public var whisperModel: String?

    public init(startedAt: Date, appVersion: String) {
        self.startedAt = startedAt
        self.speakerNames = [:]
        self.pipeline = PipelineState()
        self.appVersion = appVersion
    }

    public static func load(from url: URL) throws -> CallMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CallMeta.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
