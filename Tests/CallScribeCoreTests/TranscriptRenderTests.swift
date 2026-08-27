import Foundation
import Testing
@testable import CallScribeCore

@Suite struct TranscriptRenderTests {
    private func transcript(_ texts: [(Speaker, String)]) -> Transcript {
        Transcript(utterances: texts.enumerated().map { i, entry in
            Utterance(
                speaker: entry.0,
                words: [Word(text: entry.1, start: TimeInterval(i), end: TimeInterval(i) + 0.5)]
            )
        })
    }

    @Test func replacementsFixTermsInTheRenderedText() {
        let markdown = TranscriptMarkdownRenderer.render(
            transcript([(.me, "смотрим аль лупа логи"), (.remote(1), "да, аль лупа")]),
            replacements: [TextReplacement(from: "аль лупа", to: "AI-лупа")]
        )
        #expect(markdown.contains("смотрим AI-лупа логи"))
        #expect(markdown.contains("да, AI-лупа"))
        #expect(!markdown.contains("аль лупа"))
    }

    @Test func replacementsComposeWithSpeakerNames() {
        let markdown = TranscriptMarkdownRenderer.render(
            transcript([(.remote(1), "сан бокс готов")]),
            names: ["Speaker 1": "Саша"],
            replacements: [TextReplacement(from: "сан бокс", to: "Sandbox")]
        )
        #expect(markdown.contains("Саша:** Sandbox готов"))
    }

    @Test func emptyFromNeverMatches() {
        // Defense in depth: parse() drops these, but the renderer must not
        // explode or corrupt text if one ever reaches it.
        let markdown = TranscriptMarkdownRenderer.render(
            transcript([(.me, "привет")]),
            replacements: [TextReplacement(from: "", to: "x")]
        )
        #expect(markdown.contains("привет"))
        #expect(!markdown.contains("xпxрxиxвxеxтx"))
    }
}
