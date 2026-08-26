import Foundation

/// Turns a transcript into a Markdown summary. Implementation #1 shells out to
/// `claude -p`; the protocol lets an Ollama backend slot in later. Summarization
/// never blocks the transcript — a failure here still leaves transcript.md.
public protocol Summarizer: Sendable {
    func summarize(transcript: String) async throws -> SummaryResult
}

public struct SummaryResult: Sendable, Equatable {
    /// Full summary Markdown (summary / agreements / "my tasks" checklist).
    public let markdown: String
    /// Inferred label → real name ("Speaker 1" → "Misha").
    public let speakerNames: [String: String]
    /// Short title for the call (like an auto-named chat), if produced.
    public let title: String?
    /// Turns whose speaker the LLM judged misattributed from context.
    public let corrections: [SpeakerCorrection]

    public init(
        markdown: String,
        speakerNames: [String: String],
        title: String? = nil,
        corrections: [SpeakerCorrection] = []
    ) {
        self.markdown = markdown
        self.speakerNames = speakerNames
        self.title = title
        self.corrections = corrections
    }
}
