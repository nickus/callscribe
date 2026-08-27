import Foundation

/// Prompt template for the summarizer and a tolerant parser for its response.
public enum SummaryPrompt {
    public static func build(transcript: String, projectContext: String? = nil) -> String {
        let context = projectContext.map { context in
            """

            Project context — glossary, people, and terminology for this call. \
            Use these canonical spellings everywhere you write. Where the \
            transcript clearly misrecognized a term from the context, also add \
            a "replacements" array to the JSON block: \
            [{"from": "<text exactly as it appears in the transcript>", \
            "to": "<canonical term>"}]. Copy "from" verbatim (it is applied as \
            a literal text replacement), fix only terms you are confident \
            about, and never rewrite ordinary speech.

            Context:
            ---
            \(context)
            ---

            """
        } ?? ""
        return """
        You are given a transcript of a call. Speakers are labeled "Me" and \
        "Speaker 1", "Speaker 2", etc. Produce a concise Markdown summary in the \
        same language as the transcript, with these sections:

        ## Summary
        A short paragraph of what the call was about.

        ## Topics
        One `### [HH:MM:SS] Topic name` subsection per distinct topic discussed, \
        in the order they came up. Copy the timecode verbatim from the transcript \
        line where that topic starts; name the topic in 2–5 words. Under each \
        heading write a short paragraph conveying the substance of that \
        discussion — the main ideas, arguments and conclusions, in your own \
        words. Do not replay individual remarks speaker by speaker and do not \
        attribute lines.

        ## Agreements
        Bullet list of decisions and agreements reached.

        ## My tasks
        A checklist (`- [ ]`) of concrete action items assigned to "Me".

        Keep those four `##` headings exactly as written above, in English; write \
        all of the content under them in the transcript's language.

        REQUIRED: end your reply with a fenced ```json block (and nothing after \
        it) containing a "title" — 3–6 words naming the call, in the \
        transcript's language — and a "speakers" object mapping labels to any \
        real names you can confidently infer (use {} if none). Always include \
        the "title".

        If a line is clearly attributed to the wrong speaker given the \
        conversational context (an answer credited to the person who asked the \
        question, a line that must belong to the other party mid-dialogue), \
        also include a "corrections" array. Each item is \
        {"time": "HH:MM:SS", "from": "<label shown>", "to": "<label it should be>"} \
        with the timecode copied verbatim from that line. Only reassign \
        between remote speakers ("Speaker N" or named) — never to or from \
        "Me" — and only when you are confident; omit the array when in doubt. \
        Example:

        ```json
        {"title": "Launch planning sync", "speakers": {"Speaker 1": "Misha"}, \
        "corrections": [{"time": "00:04:12", "from": "Speaker 1", "to": "Speaker 2"}]}
        ```
        \(context)
        Transcript:
        ---
        \(transcript)
        ---
        """
    }

    /// Extract the fenced JSON block (title + speaker names), tolerating
    /// surrounding prose, multi-line JSON, a missing block, or malformed JSON.
    /// The block is stripped from the returned Markdown.
    public static func parse(_ response: String) -> SummaryResult {
        guard let block = fencedJSON(in: response) else {
            return SummaryResult(
                markdown: response.trimmingCharacters(in: .whitespacesAndNewlines),
                speakerNames: [:]
            )
        }

        var names: [String: String] = [:]
        var title: String?
        var corrections: [SpeakerCorrection] = []
        var replacements: [TextReplacement] = []
        if let data = block.json.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let speakers = root["speakers"] as? [String: Any] {
                names = speakers.compactMapValues { $0 as? String }
            }
            if let t = (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                title = t
            }
            if let list = root["corrections"] as? [[String: Any]] {
                corrections = list.compactMap { item in
                    guard let time = item["time"] as? String,
                          let from = item["from"] as? String,
                          let to = item["to"] as? String
                    else { return nil }
                    return SpeakerCorrection(time: time, from: from, to: to)
                }
            }
            if let list = root["replacements"] as? [[String: Any]] {
                replacements = list.compactMap { item in
                    guard let from = item["from"] as? String, !from.isEmpty,
                          let to = item["to"] as? String
                    else { return nil }
                    return TextReplacement(from: from, to: to)
                }
            }
        }

        var markdown = response
        markdown.removeSubrange(block.range)
        return SummaryResult(
            markdown: markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            speakerNames: names,
            title: title,
            corrections: corrections,
            replacements: replacements
        )
    }

    /// Locate a ```json … ``` fenced block; returns its inner text and the
    /// range of the whole block (fences included) so it can be stripped.
    private static func fencedJSON(in text: String) -> (json: String, range: Range<String.Index>)? {
        guard let open = text.range(of: "```json", options: .caseInsensitive),
              let close = text.range(of: "```", range: open.upperBound..<text.endIndex)
        else { return nil }
        let json = String(text[open.upperBound..<close.lowerBound])
        return (json, open.lowerBound..<close.upperBound)
    }
}
