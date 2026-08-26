import Foundation

/// One turn-level speaker reassignment inferred by the summarizer from
/// conversational context ("this reply clearly belongs to the question-asker").
/// Keyed by the turn's rendered timecode plus the label it currently shows, so
/// the fix can be re-applied every time the transcript is re-rendered from the
/// cached pipeline artifacts — and silently skipped if a re-diarization made it
/// no longer match.
public struct SpeakerCorrection: Codable, Sendable, Equatable {
    /// The turn's timecode exactly as rendered in transcript.md ("HH:MM:SS").
    public var time: String
    /// The label the turn shows now, as the LLM saw it ("Speaker 2" or a name).
    public var from: String
    /// The label of the speaker the turn actually belongs to.
    public var to: String

    public init(time: String, from: String, to: String) {
        self.time = time
        self.from = from
        self.to = to
    }
}
