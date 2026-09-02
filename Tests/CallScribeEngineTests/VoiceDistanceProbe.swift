import CallScribeCore
import FluidAudio
import Foundation
import Testing
@testable import CallScribeEngine

/// Throwaway diagnostic (opt-in): prints voice-embedding distances between
/// the diarized clusters of a real call, to pick propagation thresholds from
/// evidence instead of folklore. CALLSCRIBE_VOICE_PROBE=<call folder path>.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CALLSCRIBE_VOICE_PROBE"] != nil))
struct VoiceDistanceProbe {
    @Test func printClusterDistances() async throws {
        let path = ProcessInfo.processInfo.environment["CALLSCRIBE_VOICE_PROBE"]!
        let folder = CallFolder(url: URL(fileURLWithPath: path))
        let spans = try JSONDecoder().decode(
            [SpeakerSpan].self, from: Data(contentsOf: folder.diarizationJSON))
        let samples = try AudioFileLoader.loadMono16k(folder.systemWAV)
        let models = try await DiarizerModels.downloadIfNeeded(to: AppPaths.modelsDirectory)
        let manager = DiarizerManager()
        manager.initialize(models: models)

        // Group spans by display identity (name if set, else cluster id).
        var groups: [String: [(SpeakerSpan, [Float])]] = [:]
        for span in spans where span.end - span.start >= 1.0 {
            let lo = max(0, Int(span.start * 16000))
            let hi = min(samples.count, min(lo + 160_000, Int(span.end * 16000)))
            guard hi - lo >= 16000,
                  let e = try? manager.extractSpeakerEmbedding(from: Array(samples[lo..<hi]))
            else { continue }
            groups[span.name ?? span.speakerID, default: []].append((span, e))
        }

        func norm(_ v: [Float]) -> [Float] {
            let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return n > 0 ? v.map { $0 / n } : v
        }
        func dist(_ a: [Float], _ b: [Float]) -> Float {
            1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        func centroid(_ items: [(SpeakerSpan, [Float])]) -> [Float] {
            var sum = [Float](repeating: 0, count: items[0].1.count)
            for (span, e) in items {
                let w = Float(span.end - span.start)
                for i in e.indices { sum[i] += e[i] * w }
            }
            return norm(sum)
        }

        let names = groups.keys.sorted()
        print("=== groups: \(names.map { "\($0) (\(groups[$0]!.count) spans)" })")
        let centroids = names.map { centroid(groups[$0]!) }
        print("=== pairwise centroid distances:")
        for i in names.indices {
            for j in names.indices where j > i {
                print(String(format: "  %-22@ vs %-22@  %.3f",
                             names[i] as NSString, names[j] as NSString,
                             dist(centroids[i], centroids[j])))
            }
        }
        print("=== within-group span→own-centroid distances (spread):")
        for (i, name) in names.enumerated() {
            let ds = groups[name]!.map { dist(norm($0.1), centroids[i]) }.sorted()
            let mid = ds[ds.count / 2]
            print(String(format: "  %-22@  median %.3f  max %.3f  n=%d",
                         name as NSString, mid, ds.last!, ds.count))
        }
        print("=== library profiles vs groups:")
        for profile in VoiceStore().load() {
            let p = norm(profile.embedding)
            for (i, name) in names.enumerated() {
                print(String(format: "  %-16@ vs %-22@  %.3f",
                             profile.name as NSString, name as NSString, dist(p, centroids[i])))
            }
        }
    }
}
