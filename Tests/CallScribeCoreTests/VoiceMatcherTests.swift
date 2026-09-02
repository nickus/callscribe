import Foundation
import Testing
@testable import CallScribeCore

/// Orthogonal unit vectors are maximally distant (cosine distance 1),
/// identical are 0 — enough to exercise threshold, margin, and one-to-one.
@Suite struct VoiceMatcherTests {
    private func voice(_ axis: Int, dim: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[axis] = 1
        return v
    }

    private func profile(_ name: String, _ embedding: [Float]) -> VoiceProfile {
        VoiceProfile(name: name, embedding: embedding)
    }

    @Test func closeAndUnambiguousClusterGetsTheName() {
        let names = VoiceMatcher.assign(
            centroids: ["a": voice(0)],
            voices: [profile("Ilia", voice(0)), profile("Alina", voice(1))]
        )
        #expect(names == ["a": "Ilia"])
    }

    @Test func distantClusterStaysAnonymous() {
        // Orthogonal = distance 1.0, over the 0.55 threshold.
        let names = VoiceMatcher.assign(
            centroids: ["a": voice(2)],
            voices: [profile("Ilia", voice(0))]
        )
        #expect(names.isEmpty)
    }

    @Test func ambiguousMatchIsRejected() {
        // Two profiles nearly equidistant from the cluster: without a clear
        // 0.1 margin, naming would be a coin flip — so no name at all.
        var nearIlia = voice(0)
        nearIlia[1] = 0.3
        let centroid = VoiceMath.normalize(nearIlia)
        var nearAlina = voice(1)
        nearAlina[0] = 0.3
        let names = VoiceMatcher.assign(
            centroids: ["a": centroid],
            voices: [
                profile("Ilia", centroid),                              // distance 0
                profile("Alina", VoiceMath.normalize(nearAlina.map { $0 * 0.99 + 0.01 })),
            ]
        )
        // Ilia at distance 0, Alina far — unambiguous, matches.
        #expect(names["a"] == "Ilia")

        // Now make both profiles the SAME vector: margin = 0 → rejected.
        let tied = VoiceMatcher.assign(
            centroids: ["a": centroid],
            voices: [profile("Ilia", centroid), profile("Alina", centroid)]
        )
        #expect(tied.isEmpty)
    }

    @Test func oneToOneAssignmentNeverReusesAName() {
        // Two clusters both closest to Ilia; only the closer one gets him.
        var slightlyOff = voice(0)
        slightlyOff[1] = 0.2
        let names = VoiceMatcher.assign(
            centroids: [
                "exact": voice(0),
                "close": VoiceMath.normalize(slightlyOff),
            ],
            voices: [profile("Ilia", voice(0))]
        )
        #expect(names["exact"] == "Ilia")
        #expect(names["close"] == nil)
    }

    @Test func mismatchedDimensionsNeverMatch() {
        // A profile learned by a different embedding model (other dimension)
        // must be invisible, not erroneously близкий.
        let names = VoiceMatcher.assign(
            centroids: ["a": voice(0, dim: 8)],
            voices: [profile("Legacy", voice(0, dim: 4))]
        )
        #expect(names.isEmpty)
    }
}
