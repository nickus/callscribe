import Foundation

/// The one implementation of embedding arithmetic every voice feature shares —
/// matching, relabeling, profile blending. Three private copies drifted apart
/// once already; distances must mean the same thing everywhere.
public enum VoiceMath {
    public static func normalize(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// 1 − cosine similarity for two L2-normalised vectors (0 = identical).
    /// Mismatched dimensions return 2 — farther than any real pair, so
    /// embeddings from a different model can never match.
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 2 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return 1 - dot
    }
}
