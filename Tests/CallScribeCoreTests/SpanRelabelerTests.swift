import Foundation
import Testing
@testable import CallScribeCore

/// Synthetic voices: orthogonal unit vectors are maximally distant (cosine
/// distance 1), identical vectors are distance 0 — enough to exercise every
/// assignment rule without a real embedding model.
@Suite struct SpanRelabelerTests {
    private func voice(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[axis] = 1
        return v
    }

    private func span(_ cluster: String, _ start: Double, _ end: Double, name: String? = nil) -> SpeakerSpan {
        SpeakerSpan(speakerID: cluster, start: start, end: end, name: name)
    }

    @Test func annotatedSpanAlwaysGetsItsName() {
        // Even when the embedding says otherwise — the user is ground truth.
        let spans = [span("a", 0, 5), span("b", 5, 10)]
        let result = SpanRelabeler.relabel(
            spans: spans,
            embeddings: [voice(0), voice(0)],
            assignments: [.init(spanIndex: 0, name: "Ilia")]
        )
        #expect(result[0].name == "Ilia")
    }

    @Test func singleNameSpreadsAcrossItsWholeCluster() {
        // The diarizer vouched these spans are one voice; one mark names them all.
        let spans = [span("a", 0, 5), span("a", 10, 15), span("a", 20, 25)]
        let result = SpanRelabeler.relabel(
            spans: spans,
            embeddings: [voice(0), voice(0), nil],
            assignments: [.init(spanIndex: 0, name: "Ilia")]
        )
        #expect(result.map(\.name) == ["Ilia", "Ilia", "Ilia"])
    }

    @Test func impureClusterSplitsByVoice() {
        // The diarizer merged two people into cluster "a"; the user marked one
        // span as each. The unannotated span follows its own embedding.
        let spans = [span("a", 0, 5), span("a", 10, 15), span("a", 20, 25)]
        let result = SpanRelabeler.relabel(
            spans: spans,
            embeddings: [voice(0), voice(1), voice(1)],
            assignments: [
                .init(spanIndex: 0, name: "Ilia"),
                .init(spanIndex: 1, name: "Alina"),
            ]
        )
        #expect(result.map(\.name) == ["Ilia", "Alina", "Alina"])
    }

    @Test func impureClusterFallsBackToNearestMarkInTime() {
        // No embedding for the middle span — it takes the name of the closest
        // annotated span by time (10-15 is nearer to 20-25 than to 0-5).
        let spans = [span("a", 0, 5), span("a", 12, 15), span("a", 16, 20)]
        let result = SpanRelabeler.relabel(
            spans: spans,
            embeddings: [voice(0), nil, voice(1)],
            assignments: [
                .init(spanIndex: 0, name: "Ilia"),
                .init(spanIndex: 2, name: "Alina"),
            ]
        )
        #expect(result[1].name == "Alina")
    }

    @Test func matchingUnannotatedClusterInheritsTheName() {
        // Cluster "b" was never marked, but it sounds exactly like Ilia —
        // a split cluster gets reunited under one name.
        let spans = [span("a", 0, 5), span("b", 10, 15)]
        let result = SpanRelabeler.relabel(
            spans: spans,
            embeddings: [voice(0), voice(0)],
            assignments: [.init(spanIndex: 0, name: "Ilia")]
        )
        #expect(result[1].name == "Ilia")
    }

    @Test func distantUnannotatedClusterKeepsItsExistingLabel() {
        // Cluster "b" sounds nothing like Ilia (orthogonal = distance 1.0,
        // far over the threshold): no name is invented, the old one stays.
        let spans = [span("a", 0, 5), span("b", 10, 15, name: "Misha")]
        let result = SpanRelabeler.relabel(
            spans: spans,
            embeddings: [voice(0), voice(1)],
            assignments: [.init(spanIndex: 0, name: "Ilia")]
        )
        #expect(result[1].name == "Misha")
        #expect(result[1].speakerID == "b")
    }

    @Test func noAssignmentsChangesNothing() {
        let spans = [span("a", 0, 5, name: "Old")]
        let result = SpanRelabeler.relabel(spans: spans, embeddings: [voice(0)], assignments: [])
        #expect(result == spans)
    }

    @Test func outOfRangeAssignmentIsIgnored() {
        let spans = [span("a", 0, 5)]
        let result = SpanRelabeler.relabel(
            spans: spans,
            embeddings: [voice(0)],
            assignments: [.init(spanIndex: 7, name: "Ilia")]
        )
        #expect(result == spans)
    }

    // MARK: - resolve (marks → spans, with conflict splitting)

    @Test func resolveMapsAMarkToItsBestOverlapSpan() {
        let spans = [span("a", 0, 5), span("b", 5, 10)]
        let (outSpans, assignments) = SpanRelabeler.resolve(
            spans: spans,
            marks: [.init(start: 6, end: 8, name: "Ilia")]
        )
        #expect(outSpans == spans)
        #expect(assignments == [.init(spanIndex: 1, name: "Ilia")])
    }

    @Test func resolveDropsAMarkOutsideEverySpan() {
        let spans = [span("a", 0, 5)]
        let (outSpans, assignments) = SpanRelabeler.resolve(
            spans: spans,
            marks: [.init(start: 50, end: 55, name: "Ilia")]
        )
        #expect(outSpans == spans)
        #expect(assignments.isEmpty)
    }

    @Test func conflictingMarksOnOneSpanSplitItAndBothSurvive() {
        // The diarizer missed a speaker change inside one span: two turns,
        // two different names, one span. Both ground truths must survive.
        let spans = [span("a", 0, 20)]
        let (outSpans, assignments) = SpanRelabeler.resolve(
            spans: spans,
            marks: [
                .init(start: 1, end: 8, name: "Ilia"),
                .init(start: 12, end: 19, name: "Alina"),
            ]
        )
        #expect(outSpans.count > 1)
        #expect(outSpans.allSatisfy { $0.speakerID == "a" })
        // Continuous coverage of the original span, in order.
        #expect(outSpans.first?.start == 0)
        #expect(outSpans.last?.end == 20)
        let named = assignments.map(\.name).sorted()
        #expect(named == ["Alina", "Ilia"])
        // The assignments point at pieces covering their marks.
        for assignment in assignments {
            let piece = outSpans[assignment.spanIndex]
            #expect(piece.end - piece.start > 0)
        }
    }

    @Test func sameNameTwiceOnOneSpanDoesNotSplit() {
        let spans = [span("a", 0, 20)]
        let (outSpans, assignments) = SpanRelabeler.resolve(
            spans: spans,
            marks: [
                .init(start: 1, end: 8, name: "Ilia"),
                .init(start: 12, end: 19, name: "Ilia"),
            ]
        )
        #expect(outSpans == spans)
        #expect(assignments == [.init(spanIndex: 0, name: "Ilia")])
    }

    @Test func conflictingMarksOnDifferentSpansOfOneClusterBothHold() {
        // Both marked spans keep exactly what the user said, even though they
        // share a cluster — source of truth is per-span.
        let spans = [span("a", 0, 5), span("a", 10, 15)]
        let result = SpanRelabeler.relabel(
            spans: spans,
            embeddings: [voice(0), voice(1)],
            assignments: [
                .init(spanIndex: 0, name: "Ilia"),
                .init(spanIndex: 1, name: "Alina"),
            ]
        )
        #expect(result[0].name == "Ilia")
        #expect(result[1].name == "Alina")
    }
}
