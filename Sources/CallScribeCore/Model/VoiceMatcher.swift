import Foundation

/// Names diarized clusters from the voice library. Cross-call matching needs
/// BOTH closeness and unambiguity: measured on real calls (2026-09-02), the
/// same person lands ≈0.4–0.6 from their profile in another call while a
/// different person can come as close as ≈0.4 — absolute distance alone
/// cannot separate them. So a cluster takes a name only when its nearest
/// profile is within the threshold AND clear of the runner-up by the margin,
/// and assignment is greedy one-to-one — a false name is worse than a miss.
public enum VoiceMatcher {
    public static let matchThreshold: Float = 0.55
    public static let matchMargin: Float = 0.1

    /// `centroids`: cluster id → duration-weighted embedding (any scale —
    /// normalized here). Returns cluster id → profile name.
    public static func assign(
        centroids: [String: [Float]],
        voices: [VoiceProfile]
    ) -> [String: String] {
        guard !voices.isEmpty else { return [:] }

        var candidates: [(distance: Float, cluster: String, name: String)] = []
        for (cluster, sum) in centroids {
            let centroid = VoiceMath.normalize(sum)
            let ranked = voices
                .map { voice in
                    (name: voice.name,
                     distance: VoiceMath.cosineDistance(centroid, VoiceMath.normalize(voice.embedding)))
                }
                .sorted { $0.distance < $1.distance }
            guard let best = ranked.first, best.distance <= matchThreshold else { continue }
            if ranked.count > 1, ranked[1].distance - best.distance < matchMargin { continue }
            candidates.append((best.distance, cluster, best.name))
        }
        candidates.sort { $0.distance < $1.distance }

        // Greedy one-to-one: a voice claims at most one cluster and vice versa,
        // so two people can never both be labeled with the same profile.
        var result: [String: String] = [:]
        var usedNames = Set<String>()
        for candidate in candidates {
            guard result[candidate.cluster] == nil, !usedNames.contains(candidate.name) else { continue }
            result[candidate.cluster] = candidate.name
            usedNames.insert(candidate.name)
        }
        return result
    }
}
