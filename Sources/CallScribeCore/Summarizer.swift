import Foundation

/// Turns a transcript into a Markdown summary. Implementation #1 shells out to
/// `claude -p`; the protocol lets an Ollama backend slot in later. Summarization
/// never blocks the transcript — a failure here still leaves transcript.md.
public protocol Summarizer: Sendable {
    /// `projectContext` is the project's glossary/notes (context.md), used for
    /// canonical term spellings and transcript corrections; nil when absent.
    func summarize(transcript: String, projectContext: String?) async throws -> SummaryResult
}

extension Summarizer {
    public func summarize(transcript: String) async throws -> SummaryResult {
        try await summarize(transcript: transcript, projectContext: nil)
    }
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
    /// Misheard terms → canonical spellings from the project context.
    public let replacements: [TextReplacement]

    public init(
        markdown: String,
        speakerNames: [String: String],
        title: String? = nil,
        corrections: [SpeakerCorrection] = [],
        replacements: [TextReplacement] = []
    ) {
        self.markdown = markdown
        self.speakerNames = speakerNames
        self.title = title
        self.corrections = corrections
        self.replacements = replacements
    }
}
