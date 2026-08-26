import Foundation
import Testing
@testable import CallScribeCore

@Suite struct SpeakerCorrectionsTests {
    /// One word per utterance is enough — apply() never looks inside words.
    private func utterance(_ speaker: Speaker, at start: TimeInterval, _ text: String = "x") -> Utterance {
        Utterance(speaker: speaker, words: [Word(text: text, start: start, end: start + 0.5)])
    }

    @Test func reassignsMatchingTurn() {
        let transcript = Transcript(utterances: [
            utterance(.remote(1), at: 10),
            utterance(.remote(2), at: 20),
        ])
        let fixed = SpeakerCorrections.apply(
            [SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 2")],
            to: transcript
        )
        #expect(fixed.utterances.map(\.speaker) == [.remote(2), .remote(2)])
    }

    @Test func timecodeMismatchLeavesTurnAlone() {
        let transcript = Transcript(utterances: [
            utterance(.remote(1), at: 10),
            utterance(.remote(2), at: 20),
        ])
        let fixed = SpeakerCorrections.apply(
            [SpeakerCorrection(time: "00:00:11", from: "Speaker 1", to: "Speaker 2")],
            to: transcript
        )
        #expect(fixed.utterances.map(\.speaker) == [.remote(1), .remote(2)])
    }

    @Test func labelMismatchLeavesTurnAlone() {
        // Right time, but the turn belongs to someone else than "from" claims.
        let transcript = Transcript(utterances: [
            utterance(.remote(1), at: 10),
            utterance(.remote(2), at: 20),
        ])
        let fixed = SpeakerCorrections.apply(
            [SpeakerCorrection(time: "00:00:10", from: "Speaker 2", to: "Speaker 1")],
            to: transcript
        )
        #expect(fixed.utterances.map(\.speaker) == [.remote(1), .remote(2)])
    }

    @Test func neverMovesToOrFromMe() {
        let transcript = Transcript(utterances: [
            utterance(.me, at: 10),
            utterance(.remote(1), at: 20),
        ])
        let fixed = SpeakerCorrections.apply(
            [
                SpeakerCorrection(time: "00:00:10", from: "Me", to: "Speaker 1"),
                SpeakerCorrection(time: "00:00:20", from: "Speaker 1", to: "Me"),
            ],
            to: transcript
        )
        #expect(fixed.utterances.map(\.speaker) == [.me, .remote(1)])
    }

    @Test func unknownTargetSpeakerIsSkipped() {
        // "Speaker 3" exists nowhere in the transcript — no invented speakers.
        let transcript = Transcript(utterances: [utterance(.remote(1), at: 10)])
        let fixed = SpeakerCorrections.apply(
            [SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 3")],
            to: transcript
        )
        #expect(fixed.utterances.map(\.speaker) == [.remote(1)])
    }

    @Test func resolvesDisplayNamesViaNameMap() {
        // The LLM saw "Misha"/"Anna" (names already applied); canonical labels
        // underneath are still "Speaker N".
        let transcript = Transcript(utterances: [
            utterance(.remote(1), at: 10),
            utterance(.remote(2), at: 20),
        ])
        let fixed = SpeakerCorrections.apply(
            [SpeakerCorrection(time: "00:00:10", from: "Misha", to: "Anna")],
            to: transcript,
            names: ["Speaker 1": "Misha", "Speaker 2": "Anna"]
        )
        #expect(fixed.utterances.map(\.speaker) == [.remote(2), .remote(2)])
    }

    @Test func correctionsApplyInOrderAgainstEvolvingState() {
        // The second correction refers to the state the first one produced.
        let transcript = Transcript(utterances: [
            utterance(.remote(1), at: 10),
            utterance(.remote(2), at: 20),
        ])
        let fixed = SpeakerCorrections.apply(
            [
                SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 2"),
                SpeakerCorrection(time: "00:00:10", from: "Speaker 2", to: "Speaker 1"),
            ],
            to: transcript
        )
        #expect(fixed.utterances.map(\.speaker) == [.remote(1), .remote(2)])
    }

    // MARK: - appending (accumulation in meta.json)

    @Test func appendingCanonicalizesDisplayNames() {
        // Stored corrections must say "Speaker N": a later rename of Misha
        // would otherwise strand a correction stored as "Misha".
        let stored = SpeakerCorrections.appending(
            [SpeakerCorrection(time: "00:00:10", from: "Misha", to: "Anna")],
            to: [],
            names: ["Speaker 1": "Misha", "Speaker 2": "Anna"]
        )
        #expect(stored == [SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 2")])
    }

    @Test func appendingCollapsesChains() {
        // S1→S2 then S2→S3 must become S1→S3: every stored entry maps a turn
        // from its original merge-time speaker.
        let stored = SpeakerCorrections.appending(
            [SpeakerCorrection(time: "00:00:10", from: "Speaker 2", to: "Speaker 3")],
            to: [SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 2")],
            names: [:]
        )
        #expect(stored == [SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 3")])
    }

    @Test func appendingCancelsExactRevert() {
        let stored = SpeakerCorrections.appending(
            [SpeakerCorrection(time: "00:00:10", from: "Speaker 2", to: "Speaker 1")],
            to: [SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 2")],
            names: [:]
        )
        #expect(stored.isEmpty)
    }

    @Test func reassertionAfterRevertIsNotSwallowed() {
        // Correct → revert → correct again across three summarize runs must
        // end corrected; a naive exact-duplicate dedup absorbs run 3 forever.
        var stored: [SpeakerCorrection] = []
        stored = SpeakerCorrections.appending(
            [SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 2")],
            to: stored, names: [:])
        stored = SpeakerCorrections.appending(
            [SpeakerCorrection(time: "00:00:10", from: "Speaker 2", to: "Speaker 1")],
            to: stored, names: [:])
        stored = SpeakerCorrections.appending(
            [SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 2")],
            to: stored, names: [:])
        #expect(stored == [SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 2")])
    }

    @Test func appendingSkipsExactDuplicatesAndSelfMoves() {
        let existing = [SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 2")]
        let stored = SpeakerCorrections.appending(
            [
                SpeakerCorrection(time: "00:00:10", from: "Speaker 1", to: "Speaker 2"),
                // Canonicalizes to Speaker 1 → Speaker 1: a no-op, dropped.
                SpeakerCorrection(time: "00:00:20", from: "Misha", to: "Speaker 1"),
            ],
            to: existing,
            names: ["Speaker 1": "Misha"]
        )
        #expect(stored == existing)
    }

    @Test func canonicalizedCorrectionsSurviveARename() {
        // End-to-end across the rename flow: corrections captured against a
        // named transcript, then the user renames the speaker — the stored
        // canonical labels still resolve and the turn stays corrected.
        let transcript = Transcript(utterances: [
            utterance(.remote(1), at: 10),
            utterance(.remote(2), at: 20),
        ])
        let stored = SpeakerCorrections.appending(
            [SpeakerCorrection(time: "00:00:10", from: "Misha", to: "Anna")],
            to: [],
            names: ["Speaker 1": "Misha", "Speaker 2": "Anna"]
        )
        let renamed = ["Speaker 1": "Mike", "Speaker 2": "Anna"]   // Misha → Mike
        let fixed = SpeakerCorrections.apply(stored, to: transcript, names: renamed)
        #expect(fixed.utterances.map(\.speaker) == [.remote(2), .remote(2)])
    }

    @Test func namedSpeakersAreRemoteAndCorrectable() {
        let transcript = Transcript(utterances: [
            utterance(.named("Misha"), at: 10),
            utterance(.remote(1), at: 20),
        ])
        let fixed = SpeakerCorrections.apply(
            [SpeakerCorrection(time: "00:00:10", from: "Misha", to: "Speaker 1")],
            to: transcript
        )
        #expect(fixed.utterances.map(\.speaker) == [.remote(1), .remote(1)])
    }
}
