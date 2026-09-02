import Foundation

/// Reassigns diarization spans to user-named voices. The user's per-utterance
/// annotations are ground truth: an annotated span gets its name no matter
/// what; the rest follow by voice similarity, most cautiously the further
/// they are from the evidence:
///
///   1. a span the user annotated → that name, always;
///   2. an unannotated span whose CLUSTER was annotated with one name → that
///      name (the diarizer already vouched these spans are the same voice);
///   3. a cluster annotated with SEVERAL names (the diarizer merged people) →
///      each span goes to the nearest of those names by its own embedding;
///   4. a cluster with no annotations at all → the nearest name centroid, but
///      only within the strict threshold — a false name is worse than a miss.
public enum SpanRelabeler {
    /// "Span #i is `name`" — resolved by the caller from an annotated
    /// utterance's time range.
    public struct Assignment: Sendable, Equatable {
        public let spanIndex: Int
        public let name: String

        public init(spanIndex: Int, name: String) {
            self.spanIndex = spanIndex
            self.name = name
        }
    }

    /// A raw user mark: "this time range is `name`".
    public struct Mark: Sendable, Equatable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let name: String

        public init(start: TimeInterval, end: TimeInterval, name: String) {
            self.start = start
            self.end = end
            self.name = name
        }
    }

    /// Resolve marks to spans, SPLITTING any span that received different
    /// names — the diarizer missed a speaker change inside it, and collapsing
    /// to one name would silently drop the user's other mark. Each conflicting
    /// mark gets a dedicated sub-span (same cluster) covering its range, so
    /// the multi-name cluster rules can then separate the voices. Marks that
    /// overlap no span are dropped.
    public static func resolve(
        spans: [SpeakerSpan],
        marks: [Mark]
    ) -> (spans: [SpeakerSpan], assignments: [Assignment]) {
        var marksBySpan: [Int: [Mark]] = [:]
        for mark in marks {
            let best = spans.indices
                .map { ($0, overlap(spans[$0], mark)) }
                .max { $0.1 < $1.1 }
            guard let best, best.1 > 0 else { continue }
            marksBySpan[best.0, default: []].append(mark)
        }

        var outSpans: [SpeakerSpan] = []
        var assignments: [Assignment] = []
        for (index, span) in spans.enumerated() {
            guard let spanMarks = marksBySpan[index] else {
                outSpans.append(span)
                continue
            }
            if Set(spanMarks.map(\.name)).count == 1 {
                assignments.append(Assignment(spanIndex: outSpans.count, name: spanMarks[0].name))
                outSpans.append(span)
                continue
            }
            let pieces = split(span, at: spanMarks)
            for mark in spanMarks {
                let best = pieces.indices
                    .map { ($0, overlap(pieces[$0], mark)) }
                    .max { $0.1 < $1.1 }
                guard let best, best.1 > 0 else { continue }
                assignments.append(Assignment(spanIndex: outSpans.count + best.0, name: mark.name))
            }
            outSpans.append(contentsOf: pieces)
        }
        return (outSpans, assignments)
    }

    /// Cut a span at the boundaries of its (conflicting) marks. Sub-second
    /// slivers are merged away by the 10 ms floor.
    private static func split(_ span: SpeakerSpan, at marks: [Mark]) -> [SpeakerSpan] {
        var cuts: Set<TimeInterval> = []
        for mark in marks {
            let lo = min(max(mark.start, span.start), span.end)
            let hi = min(max(mark.end, span.start), span.end)
            if lo > span.start { cuts.insert(lo) }
            if hi < span.end { cuts.insert(hi) }
        }
        let bounds = ([span.start, span.end] + cuts).sorted()
        return zip(bounds, bounds.dropFirst()).compactMap { lo, hi in
            hi - lo > 0.01
                ? SpeakerSpan(speakerID: span.speakerID, start: lo, end: hi, name: span.name)
                : nil
        }
    }

    private static func overlap(_ span: SpeakerSpan, _ mark: Mark) -> TimeInterval {
        max(0, min(span.end, mark.end) - max(span.start, mark.start))
    }

    /// Same bar as enrolled-voice matching in FluidDiarizer.
    public static let propagationThreshold: Float = 0.35

    /// `embeddings` runs parallel to `spans`; nil where a span was too short
    /// to embed. Spans keep their existing name when nothing new applies.
    public static func relabel(
        spans: [SpeakerSpan],
        embeddings: [[Float]?],
        assignments: [Assignment]
    ) -> [SpeakerSpan] {
        guard !assignments.isEmpty, spans.count == embeddings.count else { return spans }

        var nameBySpan: [Int: String] = [:]
        for assignment in assignments where spans.indices.contains(assignment.spanIndex) {
            nameBySpan[assignment.spanIndex] = assignment.name
        }
        guard !nameBySpan.isEmpty else { return spans }

        // Duration-weighted voice centroid per annotated name.
        var centroids: [String: [Float]] = [:]
        for (index, name) in nameBySpan {
            guard let embedding = embeddings[index] else { continue }
            let weight = Float(max(spans[index].end - spans[index].start, 0.001))
            var sum = centroids[name] ?? [Float](repeating: 0, count: embedding.count)
            for i in embedding.indices where i < sum.count { sum[i] += embedding[i] * weight }
            centroids[name] = sum
        }
        let nameCentroids = centroids.mapValues(normalize)

        // Which names each cluster was annotated with, and where.
        var clusterVotes: [String: Set<String>] = [:]
        var clusterMarks: [String: [(mid: TimeInterval, name: String)]] = [:]
        for (index, name) in nameBySpan {
            let span = spans[index]
            clusterVotes[span.speakerID, default: []].insert(name)
            clusterMarks[span.speakerID, default: []].append(((span.start + span.end) / 2, name))
        }

        // One decision per fully-unannotated cluster, from its weighted centroid.
        let unannotatedClusterName = unannotatedClusterNames(
            spans: spans, embeddings: embeddings,
            annotatedClusters: Set(clusterVotes.keys), nameCentroids: nameCentroids)

        return spans.enumerated().map { index, span in
            let name: String?
            if let annotated = nameBySpan[index] {
                name = annotated
            } else if let votes = clusterVotes[span.speakerID] {
                if votes.count == 1 {
                    name = votes.first
                } else {
                    name = splitClusterName(
                        embedding: embeddings[index],
                        spanMid: (span.start + span.end) / 2,
                        votes: votes,
                        nameCentroids: nameCentroids,
                        marks: clusterMarks[span.speakerID] ?? [])
                }
            } else {
                name = unannotatedClusterName[span.speakerID]
            }
            guard let name else { return span }
            return SpeakerSpan(speakerID: span.speakerID, start: span.start, end: span.end, name: name)
        }
    }

    /// A cluster the diarizer wrongly merged: pick among the voted names by
    /// this span's own voice, falling back to the nearest annotated span in
    /// time when the span was too short to embed.
    private static func splitClusterName(
        embedding: [Float]?,
        spanMid: TimeInterval,
        votes: Set<String>,
        nameCentroids: [String: [Float]],
        marks: [(mid: TimeInterval, name: String)]
    ) -> String? {
        if let embedding {
            let normalized = normalize(embedding)
            let best = votes
                .compactMap { name in nameCentroids[name].map { (name, cosineDistance(normalized, $0)) } }
                .min { $0.1 < $1.1 }
            if let best { return best.0 }
        }
        return marks.min { abs($0.mid - spanMid) < abs($1.mid - spanMid) }?.name
    }

    /// Nearest name centroid per unannotated cluster — strictly thresholded.
    private static func unannotatedClusterNames(
        spans: [SpeakerSpan],
        embeddings: [[Float]?],
        annotatedClusters: Set<String>,
        nameCentroids: [String: [Float]]
    ) -> [String: String] {
        var sums: [String: [Float]] = [:]
        for (index, span) in spans.enumerated() where !annotatedClusters.contains(span.speakerID) {
            guard let embedding = embeddings[index] else { continue }
            let weight = Float(max(span.end - span.start, 0.001))
            var sum = sums[span.speakerID] ?? [Float](repeating: 0, count: embedding.count)
            for i in embedding.indices where i < sum.count { sum[i] += embedding[i] * weight }
            sums[span.speakerID] = sum
        }
        var result: [String: String] = [:]
        for (cluster, sum) in sums {
            let centroid = normalize(sum)
            let best = nameCentroids
                .map { ($0.key, cosineDistance(centroid, $0.value)) }
                .min { $0.1 < $1.1 }
            if let best, best.1 <= propagationThreshold {
                result[cluster] = best.0
            }
        }
        return result
    }

    private static func normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// 1 − cosine similarity for two L2-normalised vectors (0 = identical).
    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 2 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return 1 - dot
    }
}
