import Foundation

/// Renders a merged transcript to Markdown. A separate pure stage so that
/// "apply inferred speaker names" can re-render without re-merging.
public enum TranscriptMarkdownRenderer {
    /// `names` maps display labels to real names ("Speaker 1" → "Misha");
    /// `replacements` fix terms the STT misheard (from the project context).
    /// Both apply at render time only — the underlying words stay untouched.
    public static func render(
        _ transcript: Transcript,
        names: [String: String] = [:],
        replacements: [TextReplacement] = []
    ) -> String {
        let lines = transcript.utterances.map { utterance in
            let label = names[utterance.speaker.label] ?? utterance.speaker.label
            let text = TextReplacement.apply(replacements, to: utterance.text)
            return "**[\(timecode(utterance.start))] \(label):** \(text)"
        }
        return lines.joined(separator: "\n\n") + (lines.isEmpty ? "" : "\n")
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
