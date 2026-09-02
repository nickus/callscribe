import CallScribeCore
import FluidAudio
import Foundation

/// The voice-library embedding space: FluidAudio's speaker-embedding model,
/// shared by cluster naming, per-utterance relabeling, and enrollment. The
/// library's profiles live in THIS space — diarization itself may come from a
/// different pipeline (SpeakerKit), but every stored or compared fingerprint
/// goes through here so old profiles stay valid.
enum VoiceEmbedding {
    /// The embedding model wants 1–10 s of audio.
    static let sampleRate = 16000
    static let minSamples = 16_000
    static let maxSamples = 160_000

    static func makeManager(modelDirectory: URL) async throws -> DiarizerManager {
        let models = try await DiarizerModels.downloadIfNeeded(to: modelDirectory)
        let manager = DiarizerManager()
        manager.initialize(models: models)
        return manager
    }

    /// Embedding of `[start, end]`, padded to the model's 1 s minimum evenly
    /// around the range — spilling to the other side at a file edge — and
    /// capped at its 10 s window. nil only when the whole file is too short.
    static func embed(
        from start: TimeInterval,
        to end: TimeInterval,
        in samples: [Float],
        manager: DiarizerManager
    ) -> [Float]? {
        var lo = max(0, Int(start * Double(sampleRate)))
        var hi = min(samples.count, Int(end * Double(sampleRate)))
        guard hi > lo else { return nil }
        if hi - lo < minSamples {
            let missing = minSamples - (hi - lo)
            let leftRoom = lo
            let rightRoom = samples.count - hi
            var left = min(missing / 2, leftRoom)
            let right = min(missing - left, rightRoom)
            left = min(leftRoom, missing - right)   // spill what the right lacked
            lo -= left
            hi += right
        }
        if hi - lo > maxSamples { hi = lo + maxSamples }
        guard hi - lo >= minSamples else { return nil }
        return try? manager.extractSpeakerEmbedding(from: Array(samples[lo..<hi]))
    }

    /// Duration-weighted centroid per cluster over spans ≥ the model minimum.
    static func clusterCentroids(
        spans: [SpeakerSpan],
        samples: [Float],
        manager: DiarizerManager
    ) -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        for span in spans where span.end - span.start >= 1.0 {
            guard let embedding = embed(from: span.start, to: span.end, in: samples, manager: manager)
            else { continue }
            let weight = Float(span.end - span.start)
            var sum = sums[span.speakerID] ?? [Float](repeating: 0, count: embedding.count)
            for i in embedding.indices where i < sum.count { sum[i] += embedding[i] * weight }
            sums[span.speakerID] = sum
        }
        return sums
    }
}
