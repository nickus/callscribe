import Foundation

/// One transcript text fix inferred by the summarizer from the project
/// context ("аль лупа" → "AI-лупа"): STT mishears domain terms, and the
/// glossary knows their canonical spellings. Content-keyed — applied as a
/// plain occurrence replacement at render time — so it survives re-renders,
/// re-diarization, and even a re-transcription that repeats the same mistake.
public struct TextReplacement: Codable, Sendable, Equatable {
    /// The misrecognized text exactly as it appears in the transcript.
    public var from: String
    /// The canonical spelling from the project context.
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    /// Apply a list in order as literal occurrence replacements — the ONE
    /// implementation used by every surface that shows transcript text, so
    /// transcript.md and the in-app view can never disagree.
    public static func apply(_ replacements: [TextReplacement], to text: String) -> String {
        var result = text
        for replacement in replacements where !replacement.from.isEmpty {
            result = result.replacingOccurrences(of: replacement.from, with: replacement.to)
        }
        return result
    }
}
