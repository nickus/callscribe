import FluidAudio
import Foundation
import Testing
@testable import CallScribeCore
@testable import CallScribeEngine

@Suite struct STTEngineTests {
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "stt-engine-tests-\(UUID().uuidString)")!
    }

    @Test func defaultsToWhisperWhenNothingPersisted() {
        #expect(STTEngine.current(from: scratchDefaults()) == .whisper)
    }

    @Test func persistedChoiceRoundTrips() {
        let defaults = scratchDefaults()
        STTEngine.parakeet.persist(to: defaults)
        #expect(STTEngine.current(from: defaults) == .parakeet)
        STTEngine.whisper.persist(to: defaults)
        #expect(STTEngine.current(from: defaults) == .whisper)
    }

    @Test func garbageInDefaultsFallsBackToWhisper() {
        let defaults = scratchDefaults()
        defaults.set("nemoton", forKey: STTEngine.defaultsKey)
        #expect(STTEngine.current(from: defaults) == .whisper)
    }

    @Test func modelNamesMatchTheEngines() {
        #expect(STTEngine.whisper.modelName == WhisperTranscriber.defaultModel)
        #expect(STTEngine.parakeet.modelName == ParakeetTranscriber.defaultModel)
    }
}

/// The token→word mapping is the piece of ParakeetTranscriber the merge
/// depends on; exercised with synthetic timings, no model needed. Sub-word
/// grouping itself is FluidAudio's — these tests pin OUR wrapper: trimming,
/// empty-input behavior, and that times survive the mapping.
@Suite struct ParakeetWordMappingTests {
    private func token(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 0.9)
    }

    @Test func emptyTimingsYieldNoWords() {
        #expect(ParakeetTranscriber.words(from: []).isEmpty)
    }

    @Test func subWordTokensGroupIntoTimedWords() {
        // Leading space is the word-boundary marker (▁ is pre-normalized to a
        // space by FluidAudio before timings reach us).
        let words = ParakeetTranscriber.words(from: [
            token(" при", 1.0, 1.2),
            token("вет", 1.2, 1.4),
            token(" мир", 2.0, 2.3),
        ])
        #expect(words.map(\.text) == ["привет", "мир"])
        #expect(words.map(\.start) == [1.0, 2.0])
        #expect(words.map(\.end) == [1.4, 2.3])
    }

    @Test func wordsCarryFullProbability() {
        // Parakeet word timings carry no usable per-word confidence; 1.0 keeps
        // them clear of any minWordProbability filtering in the merge.
        let words = ParakeetTranscriber.words(from: [token(" hey", 0.1, 0.3)])
        #expect(words.map(\.probability) == [1.0])
    }
}
