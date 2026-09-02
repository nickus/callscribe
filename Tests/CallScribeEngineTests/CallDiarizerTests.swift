import Foundation
import SpeakerKit
import Testing
@testable import CallScribeCore
@testable import CallScribeEngine

/// The SpeakerKit → SpeakerSpan mapping is the seam the whole pipeline sits
/// on; exercised with synthetic segments, no models needed.
@Suite struct CallDiarizerTests {
    private func segment(_ speaker: SpeakerInfo, _ start: Float, _ end: Float) -> SpeakerSegment {
        SpeakerSegment(speaker: speaker, startTime: start, endTime: end, frameRate: 100)
    }

    @Test func speakerIdsBecomeClusters() {
        let spans = CallDiarizer.spans(from: [
            segment(.speakerId(1), 0, 5),
            segment(.speakerId(2), 5, 9),
            segment(.speakerId(1), 9, 12),
        ])
        #expect(spans.map(\.speakerID) == ["S1", "S2", "S1"])
        #expect(spans.map(\.start) == [0, 5, 9])
        #expect(spans.map(\.end) == [5, 9, 12])
        #expect(spans.allSatisfy { $0.name == nil })
    }

    @Test func noMatchSegmentsAreDropped() {
        let spans = CallDiarizer.spans(from: [
            segment(.noMatch, 0, 3),
            segment(.speakerId(1), 3, 6),
        ])
        #expect(spans.map(\.speakerID) == ["S1"])
    }

    @Test func emptyAndInvertedSegmentsAreDropped() {
        let spans = CallDiarizer.spans(from: [
            segment(.speakerId(1), 5, 5),
            segment(.speakerId(1), 7, 6),
        ])
        #expect(spans.isEmpty)
    }

    @Test func spansComeBackTimeOrdered() {
        let spans = CallDiarizer.spans(from: [
            segment(.speakerId(2), 8, 10),
            segment(.speakerId(1), 0, 4),
        ])
        #expect(spans.map(\.start) == [0, 8])
    }
}
