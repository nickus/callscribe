import Foundation
import Testing
@testable import CallScribeCore

private func w(_ text: String, _ start: Double, _ end: Double, p: Float = 1.0) -> Word {
    Word(text: text, start: start, end: end, probability: p)
}

private func span(_ id: String, _ start: Double, _ end: Double) -> SpeakerSpan {
    SpeakerSpan(speakerID: id, start: start, end: end)
}

@Suite struct TranscriptMergerTests {
    @Test func emptyInputsProduceEmptyTranscript() {
        let t = TranscriptMerger.merge(micWords: [], systemWords: [], spans: [])
        #expect(t.utterances.isEmpty)
    }

    @Test func micOnlyIsAllMe() {
        let t = TranscriptMerger.merge(
            micWords: [w("privet", 0, 0.5), w("kak", 0.6, 0.9), w("dela", 1.0, 1.4)],
            systemWords: [],
            spans: []
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].speaker == .me)
        #expect(t.utterances[0].text == "privet kak dela")
    }

    @Test func micSplitsOnLongSilence() {
        let t = TranscriptMerger.merge(
            micWords: [w("one", 0, 0.5), w("two", 5.0, 5.5)],  // 4.5 s gap
            systemWords: [],
            spans: []
        )
        #expect(t.utterances.count == 2)
        #expect(t.utterances.allSatisfy { $0.speaker == .me })
    }

    @Test func systemWordsAttributedBySpanOverlap() {
        let t = TranscriptMerger.merge(
            micWords: [],
            systemWords: [w("hello", 0.2, 0.6), w("world", 3.1, 3.6)],
            spans: [span("A", 0, 2), span("B", 3, 5)]
        )
        #expect(t.utterances.count == 2)
        #expect(t.utterances[0].speaker == .remote(1))
        #expect(t.utterances[1].speaker == .remote(2))
    }

    @Test func emptySpansFallBackToParticipant() {
        let t = TranscriptMerger.merge(
            micWords: [],
            systemWords: [w("hi", 0, 0.4), w("there", 0.5, 0.9)],
            spans: []
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].speaker == .participant)
    }

    @Test func wordStraddlingTwoSpansPicksMaxOverlap() {
        // Word [1.8, 2.6]: overlaps span A by 0.2 and span B by 0.6 → B.
        let attributed = TranscriptMerger.attribute(
            systemWords: [w("border", 1.8, 2.6)],
            spans: [span("A", 0, 2), span("B", 2, 4)],
            config: MergeConfig()
        )
        #expect(attributed[0].speaker == .remote(2))
    }

    @Test func wordInGapSnapsToNearestSpanWithinTolerance() {
        // Word [2.2, 2.5] sits in the gap; nearest span is A (distance 0.2 vs 0.5).
        let attributed = TranscriptMerger.attribute(
            systemWords: [w("gap", 2.2, 2.5)],
            spans: [span("A", 0, 2), span("B", 3, 5)],
            config: MergeConfig()
        )
        #expect(attributed[0].speaker == .remote(1))
    }

    @Test func wordFarFromAnySpanSticksWithPreviousSpeaker() {
        var config = MergeConfig()
        config.spanSnapTolerance = 1.0
        let attributed = TranscriptMerger.attribute(
            systemWords: [w("in-b", 3.2, 3.6), w("orphan", 10.0, 10.4)],
            spans: [span("A", 0, 2), span("B", 3, 5)],
            config: config
        )
        #expect(attributed[0].speaker == .remote(2))
        #expect(attributed[1].speaker == .remote(2), "orphan inherits previous word's speaker")
    }

    @Test func speakerChangeMidStreamSplitsUtterance() {
        let t = TranscriptMerger.merge(
            micWords: [],
            systemWords: [w("first", 0.1, 0.5), w("second", 0.6, 1.0), w("reply", 2.2, 2.6)],
            spans: [span("A", 0, 2), span("B", 2, 4)]
        )
        #expect(t.utterances.count == 2)
        #expect(t.utterances[0].speaker == .remote(1))
        #expect(t.utterances[0].text == "first second")
        #expect(t.utterances[1].speaker == .remote(2))
    }

    @Test func longMonologueStaysOneUtterance() {
        let words = (0..<20).map { i in w("w\(i)", Double(i) * 0.5, Double(i) * 0.5 + 0.4) }
        let t = TranscriptMerger.merge(
            micWords: [],
            systemWords: words,
            spans: [span("A", 0, 100)]
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].words.count == 20)
    }

    @Test func micOnTopOfSystemSpeechIsDroppedAsEcho() {
        // Mic speech that sits on top of remote speech is echo (the remote
        // picked up through the speakers), not genuine cross-talk — dropped.
        let t = TranscriptMerger.merge(
            micWords: [w("me-a", 1.0, 1.4), w("me-b", 1.5, 1.9)],
            systemWords: [w("them-a", 1.0, 1.4), w("them-b", 1.5, 1.9)],
            spans: [span("A", 0, 3)]
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].speaker == .remote(1))
    }

    @Test func unsortedInputIsHandled() {
        let t = TranscriptMerger.merge(
            micWords: [w("later", 1.0, 1.4), w("first", 0.0, 0.4)],
            systemWords: [],
            spans: []
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].text == "first later")
    }

    @Test func lowProbabilityWordsAreFiltered() {
        var config = MergeConfig()
        config.minWordProbability = 0.5
        let t = TranscriptMerger.merge(
            micWords: [w("real", 0, 0.4, p: 0.9), w("ghost", 0.5, 0.9, p: 0.2)],
            systemWords: [],
            spans: [],
            config: config
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].text == "real")
    }

    @Test func invalidWordsAreDropped() {
        let t = TranscriptMerger.merge(
            micWords: [w("ok", 0, 0.4), w("zero", 1.0, 1.0), w("negative", 3.0, 2.0)],
            systemWords: [],
            spans: []
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].text == "ok")
    }

    @Test func speakerNumberingFollowsFirstAppearanceInTime() {
        // Diarizer IDs are opaque and arrive unordered; numbering must follow
        // first appearance on the timeline, not ID sort order.
        let t = TranscriptMerger.merge(
            micWords: [],
            systemWords: [w("early", 0.1, 0.5), w("late", 5.1, 5.5)],
            spans: [span("zzz", 0, 2), span("aaa", 5, 7)]
        )
        #expect(t.utterances[0].speaker == .remote(1), "zzz spoke first → Speaker 1")
        #expect(t.utterances[1].speaker == .remote(2))
    }

    @Test func adjacentSameSpeakerUtterancesCoalesce() {
        // Interleaving can split a monologue around a short interjection
        // window; same-speaker pieces within coalesceGap merge back.
        let pieces = [
            Utterance(speaker: .me, words: [w("a", 0, 0.4)]),
            Utterance(speaker: .me, words: [w("b", 0.5, 0.9)]),
            Utterance(speaker: .remote(1), words: [w("c", 3.0, 3.4)]),
        ]
        let merged = TranscriptMerger.coalesce(pieces, config: MergeConfig())
        #expect(merged.count == 2)
        #expect(merged[0].text == "a b")
    }

    @Test func whisperTokenLeadingSpacesAreNormalized() {
        let u = Utterance(speaker: .me, words: [w(" Hello", 0, 0.3), w(" world", 0.4, 0.7)])
        #expect(u.text == "Hello world")
    }

    @Test func echoBleedIsRemovedFromMe() {
        // Speaker bleed: the remote line is captured on the system track AND
        // (via the speakers) on the mic at the same time. The mic copy is dropped.
        let line = [w("Friday", 2.0, 2.4), w("works", 2.5, 2.9), w("for", 3.0, 3.2), w("launch", 3.3, 3.7)]
        let t = TranscriptMerger.merge(
            micWords: line,                 // bleed
            systemWords: line,              // real remote
            spans: [span("A", 1.8, 4.0)]
        )
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].speaker == .remote(1))
    }

    @Test func realMeSpeechIsKeptWhenNotOnSystemTrack() {
        // The user's own words never play through the speakers, so they don't
        // appear on the system track and must be kept.
        let t = TranscriptMerger.merge(
            micWords: [w("my", 0.0, 0.3), w("own", 0.4, 0.7), w("point", 0.8, 1.1)],
            systemWords: [w("their", 3.0, 3.3), w("reply", 3.4, 3.8)],
            spans: [span("A", 2.9, 4.0)]
        )
        #expect(t.utterances.contains { $0.speaker == .me && $0.text == "my own point" })
        #expect(t.utterances.contains { $0.speaker == .remote(1) })
    }

    @Test func nonOverlappingSimilarTextIsNotTreatedAsEcho() {
        // Same words but at a different time → the user genuinely repeating,
        // not bleed. Kept.
        let t = TranscriptMerger.merge(
            micWords: [w("okay", 10.0, 10.4), w("sounds", 10.5, 10.9), w("good", 11.0, 11.3)],
            systemWords: [w("okay", 0.0, 0.4), w("sounds", 0.5, 0.9), w("good", 1.0, 1.3)],
            spans: [span("A", 0.0, 1.5)]
        )
        #expect(t.utterances.contains { $0.speaker == .me })
    }

    @Test func echoDedupDisabledKeepsBothTracks() {
        var config = MergeConfig()
        config.echoDedup = false
        let line = [w("Friday", 2.0, 2.4), w("works", 2.5, 2.9)]
        let t = TranscriptMerger.merge(
            micWords: line, systemWords: line, spans: [span("A", 1.8, 3.5)], config: config
        )
        #expect(t.utterances.contains { $0.speaker == .me })
        #expect(t.utterances.contains { $0.speaker == .remote(1) })
    }

    @Test func partialEchoDropsOnlyTheOverlappingWords() {
        // A mic utterance that starts as echo (overlaps the remote) but continues
        // after the remote falls silent: only the echoed prefix is dropped, the
        // genuine tail survives. (The old whole-utterance filter kept all of it.)
        let system = [
            w("это", 2260, 2262), w("же", 2262, 2264), w("ничего", 2264, 2266),
            w("не", 2266, 2268), w("меняет", 2268, 2293),
        ]
        let micEchoPrefix = [w("это", 2261, 2263), w("меняет", 2270, 2272)]        // overlaps system
        let micGenuine = [w("я", 2300, 2300.4), w("решил", 2300.5, 2301), w("вынести", 2301, 2301.6)]
        let t = TranscriptMerger.merge(
            micWords: micEchoPrefix + micGenuine,
            systemWords: system,
            spans: [span("A", 2260, 2293)]
        )
        let me = t.utterances.filter { $0.speaker == .me }
        #expect(me.count == 1)
        #expect(me[0].text == "я решил вынести", "echo prefix dropped, genuine tail kept")
    }

    @Test func shortEchoResidueIsDroppedButSilenceBackchannelKept() {
        // A 1-word mic blip that Whisper timed just outside a remote word is echo
        // residue → dropped. A 1-word backchannel in real silence is kept.
        let t = TranscriptMerger.merge(
            micWords: [
                w("ага", 10.3, 10.6),   // right after remote speech → residue
                w("да", 30.0, 30.4),    // in silence → genuine
            ],
            systemWords: [w("бесконечная", 5.0, 10.0)],
            spans: [span("A", 5, 10)]
        )
        let me = t.utterances.filter { $0.speaker == .me }
        #expect(me.count == 1)
        #expect(me[0].text == "да")
    }

    @Test func garbledLaggingEchoFragmentIsRemoved() {
        // A garbled mic fragment sitting on top of a long system utterance is
        // echo. Text-matching can't catch garble, but the time overlap does.
        let system = [
            w("то", 0, 0.9), w("есть", 1, 1.9), w("крупное", 2, 2.9),
            w("агентство", 3, 3.9), w("которым", 4, 4.9), w("доверие", 5, 5.9),
            w("оффер", 6, 6.9), w("подключать", 7, 7.9), w("проверенных", 8, 8.9),
            w("партнеров", 9, 9.9), w("этап", 10, 10.9), w("тестирования", 11, 11.9),
        ]
        // Lags the source; 4/5 words echo the system, one ("трафик") is garble.
        let micEcho = [
            w("крупное", 3.0, 3.4), w("агентство", 3.5, 3.9), w("доверие", 4.0, 4.4),
            w("оффер", 4.5, 4.9), w("трафик", 5.0, 5.4),
        ]
        let t = TranscriptMerger.merge(micWords: micEcho, systemWords: system, spans: [span("A", 0, 12)])
        #expect(!t.utterances.contains { $0.speaker == .me }, "echo fragment dropped from Me")
        #expect(t.utterances.contains { $0.speaker == .remote(1) })
    }

    @Test func phantomRemoteSpeakerIsFoldedIntoNeighbour() {
        // Speaker A talks a lot; a 0.5 s "Speaker B" blip is clustering noise.
        let aFirst = (0..<8).map { w("a\($0)", Double($0) * 1.2, Double($0) * 1.2 + 0.4) }   // 0–8.8 s
        let bBlip = [w("blip", 10.5, 11.0)]
        let aLast = (0..<6).map { w("z\($0)", 12 + Double($0) * 1.2, 12 + Double($0) * 1.2 + 0.4) }
        let t = TranscriptMerger.merge(
            micWords: [],
            systemWords: aFirst + bBlip + aLast,
            spans: [span("A", 0, 9), span("B", 10.4, 11.1), span("A2", 11.9, 20)]
        )
        // "A" and "A2" are different diarizer IDs but the blip (B, ~0.5 s) is the
        // only phantom; it folds into a neighbour, and labels stay contiguous.
        #expect(!t.utterances.contains { $0.speaker == .remote(3) }, "no phantom third speaker")
        #expect(t.utterances.allSatisfy { if case .remote = $0.speaker { true } else { false } })
    }

    @Test func renumberRemoteMakesLabelsContiguous() {
        let us = [
            Utterance(speaker: .remote(1), words: [w("a", 0, 0.4)]),
            Utterance(speaker: .remote(4), words: [w("b", 1, 1.4)]),
            Utterance(speaker: .remote(4), words: [w("c", 2, 2.4)]),
            Utterance(speaker: .remote(7), words: [w("d", 3, 3.4)]),
        ]
        let r = TranscriptMerger.renumberRemote(us)
        #expect(r.map(\.speaker) == [.remote(1), .remote(2), .remote(2), .remote(3)])
    }

    @Test func foldNeverRemovesTheLastRemoteSpeaker() {
        // Every remote speaker is tiny (short call). Nothing is folded away.
        let us = [
            Utterance(speaker: .remote(1), words: [w("a", 0, 0.5)]),
            Utterance(speaker: .remote(2), words: [w("b", 1, 1.5)]),
        ]
        let folded = TranscriptMerger.foldPhantomSpeakers(us, config: MergeConfig())
        #expect(folded.map(\.speaker) == [.remote(1), .remote(2)])
    }

    @Test func enrolledSpanBecomesNamedSpeakerAndOthersNumbered() {
        let t = TranscriptMerger.merge(
            micWords: [],
            systemWords: [w("привет", 0.1, 0.5), w("здарова", 5.1, 5.5)],
            spans: [
                SpeakerSpan(speakerID: "leha", start: 0, end: 2, name: "Лёха"),   // enrolled
                SpeakerSpan(speakerID: "zzz", start: 5, end: 7),                    // unknown
            ]
        )
        #expect(t.utterances.count == 2)
        #expect(t.utterances[0].speaker == .named("Лёха"))
        #expect(t.utterances[0].speaker.label == "Лёха")
        #expect(t.utterances[1].speaker == .remote(1), "first unnamed speaker numbers from 1")
    }

    @Test func namedSpeakersAreNeverFoldedOrRenumbered() {
        // A named speaker with tiny talk-time is identified, not a phantom.
        let us = [
            Utterance(speaker: .remote(1), words: [w("a", 0, 5)]),
            Utterance(speaker: .named("Лёха"), words: [w("b", 6, 6.4)]),   // 0.4s but named
            Utterance(speaker: .remote(1), words: [w("c", 8, 13)]),
        ]
        let folded = TranscriptMerger.foldPhantomSpeakers(us, config: MergeConfig())
        #expect(folded.contains { $0.speaker == .named("Лёха") })
        let renumbered = TranscriptMerger.renumberRemote(folded)
        #expect(renumbered.contains { $0.speaker == .named("Лёха") })
    }
}

@Suite struct RendererTests {
    @Test func rendersTimecodesAndLabels() {
        let t = Transcript(utterances: [
            Utterance(speaker: .me, words: [w("hi", 754, 754.4)]),
            Utterance(speaker: .remote(2), words: [w("hey", 3725, 3725.5)]),
        ])
        let md = TranscriptMarkdownRenderer.render(t)
        #expect(md.contains("**[00:12:34] Me:** hi"))
        #expect(md.contains("**[01:02:05] Speaker 2:** hey"))
    }

    @Test func nameSubstitutionAppliesAndIsIdempotent() {
        let t = Transcript(utterances: [
            Utterance(speaker: .remote(1), words: [w("hello", 0, 0.5)])
        ])
        let names = ["Speaker 1": "Misha"]
        let md = TranscriptMarkdownRenderer.render(t, names: names)
        #expect(md.contains("**[00:00:00] Misha:** hello"))
        // Re-rendering with the same map yields the same output (renders from
        // the model, not from previously rendered text).
        #expect(TranscriptMarkdownRenderer.render(t, names: names) == md)
    }

    @Test func emptyTranscriptRendersEmpty() {
        #expect(TranscriptMarkdownRenderer.render(Transcript(utterances: [])).isEmpty)
    }
}

@Suite struct TranscriptSidecarTests {
    private func w(_ text: String, _ start: Double, _ end: Double) -> Word {
        Word(text: text, start: start, end: end, probability: 1)
    }

    @Test func transcriptRoundTripsThroughJSON() throws {
        // The UI highlight relies on the turns.json sidecar preserving each
        // utterance's real start/end/speaker/text.
        let original = Transcript(utterances: [
            Utterance(speaker: .me, words: [w("привет", 2202, 2203)]),
            Utterance(speaker: .remote(1), words: [w("такое", 2197, 2200), w("бывает", 2200, 2270)]),
            Utterance(speaker: .named("Лёха"), words: [w("ага", 2300, 2301)]),
        ], detectedLanguage: "ru")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)

        #expect(decoded == original)
        #expect(decoded.utterances[2].speaker == .named("Лёха"))
        #expect(decoded.utterances[1].speaker.label == "Speaker 1")
        #expect(decoded.utterances[1].start == 2197)
        #expect(decoded.utterances[1].end == 2270)   // real end, not the next turn's start
        #expect(decoded.utterances[0].text == "привет")
    }
}
