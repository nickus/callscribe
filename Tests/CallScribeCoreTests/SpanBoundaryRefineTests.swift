import Foundation
import Testing
@testable import CallScribeCore

@Suite struct SpanBoundaryRefineTests {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> Word {
        Word(text: text, start: start, end: end)
    }

    @Test func boundarySnapsToNearestInterWordSilence() {
        // Diarizer put the A/B boundary at 5.8; the only nearby silence between
        // words is 5.4–5.5, so the boundary moves to its midpoint 5.45.
        let spans = [
            SpeakerSpan(speakerID: "a", start: 0, end: 5.8),
            SpeakerSpan(speakerID: "b", start: 5.8, end: 10),
        ]
        let words = [word("hello", 0.0, 4.9), word("yes", 5.0, 5.4), word("sure", 5.5, 6.0)]
        let refined = TranscriptMerger.refineSpanBoundaries(spans, systemWords: words, config: MergeConfig())
        #expect(refined[0].end == 5.45)
        #expect(refined[1].start == 5.45)
    }

    @Test func boundaryWithNoSilenceInReachStaysPut() {
        let spans = [
            SpeakerSpan(speakerID: "a", start: 0, end: 5.0),
            SpeakerSpan(speakerID: "b", start: 5.0, end: 10),
        ]
        // The only silence midpoint (1.5) is far beyond the 1 s tolerance.
        let words = [word("hi", 0.0, 1.0), word("there", 2.0, 9.0)]
        let refined = TranscriptMerger.refineSpanBoundaries(spans, systemWords: words, config: MergeConfig())
        #expect(refined == spans)
    }

    @Test func sameSpeakerBoundaryIsUntouched() {
        let spans = [
            SpeakerSpan(speakerID: "a", start: 0, end: 5.0),
            SpeakerSpan(speakerID: "a", start: 5.0, end: 10),
        ]
        let words = [word("hi", 0.0, 4.8), word("there", 5.2, 9.0)]
        let refined = TranscriptMerger.refineSpanBoundaries(spans, systemWords: words, config: MergeConfig())
        #expect(refined == spans)
    }

    @Test func zeroToleranceDisablesRefinement() {
        let spans = [
            SpeakerSpan(speakerID: "a", start: 0, end: 5.8),
            SpeakerSpan(speakerID: "b", start: 5.8, end: 10),
        ]
        let words = [word("hello", 0.0, 4.9), word("yes", 5.0, 5.4), word("sure", 5.5, 6.0)]
        var config = MergeConfig()
        config.spanBoundaryRefineTolerance = 0
        let refined = TranscriptMerger.refineSpanBoundaries(spans, systemWords: words, config: config)
        #expect(refined == spans)
    }

    @Test func cutThatWouldInvertASpanIsSkipped() {
        // Nearest silence midpoint (4.9) lies before span "a" even starts.
        let spans = [
            SpeakerSpan(speakerID: "a", start: 5.0, end: 5.2),
            SpeakerSpan(speakerID: "b", start: 5.2, end: 9),
        ]
        let words = [word("hi", 0.0, 4.8), word("there", 5.0, 9.0)]
        let refined = TranscriptMerger.refineSpanBoundaries(spans, systemWords: words, config: MergeConfig())
        #expect(refined == spans)
    }

    @Test func enrolledNameSurvivesRefinement() {
        let spans = [
            SpeakerSpan(speakerID: "a", start: 0, end: 5.8, name: "Misha"),
            SpeakerSpan(speakerID: "b", start: 5.8, end: 10),
        ]
        let words = [word("hello", 0.0, 4.9), word("yes", 5.0, 5.4), word("sure", 5.5, 6.0)]
        let refined = TranscriptMerger.refineSpanBoundaries(spans, systemWords: words, config: MergeConfig())
        #expect(refined[0].name == "Misha")
        #expect(refined[0].end == 5.45)
    }

    @Test func mergeStopsStealingTheReplysFirstWord() {
        // "yes" (5.0–6.0) lies mostly inside speaker a's late-ending span, so by
        // raw overlap it would go to a. Refinement moves the boundary into the
        // 4.9–5.0 silence and the word lands with speaker b, where it belongs.
        let spans = [
            SpeakerSpan(speakerID: "a", start: 0, end: 5.7),
            SpeakerSpan(speakerID: "b", start: 5.7, end: 10),
        ]
        let words = [word("hello", 0.0, 4.9), word("yes", 5.0, 6.0)]
        var config = MergeConfig()
        config.phantomSpeakerMinDuration = 0   // 1 s of "b" isn't a phantom here

        let transcript = TranscriptMerger.merge(
            micWords: [], systemWords: words, spans: spans, config: config)
        #expect(transcript.utterances.map(\.speaker.label) == ["Speaker 1", "Speaker 2"])
        #expect(transcript.utterances.map(\.text) == ["hello", "yes"])

        config.spanBoundaryRefineTolerance = 0   // without refinement: stolen
        let unrefined = TranscriptMerger.merge(
            micWords: [], systemWords: words, spans: spans, config: config)
        #expect(unrefined.utterances.map(\.text) == ["hello yes"])
    }
}
