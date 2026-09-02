import CallScribeCore
import Foundation
import Testing
@testable import CallScribeEngine

@Suite struct EchoCancellerTests {
    /// Feed a far-end reference and a mic that is ONLY the delayed, attenuated
    /// echo of it. After the adaptive filter converges the residual should be
    /// far quieter than the input echo (high ERLE).
    @Test func cancelsEchoOfTheReference() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rate = 16000
        let seconds = 6
        let n = rate * seconds
        let delay = 80          // 5 ms speaker→mic delay
        let echoGain: Float = 0.5

        // Deterministic pseudo-random far-end (good filter excitation).
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
        }
        var ref = [Float](repeating: 0, count: n)
        for i in 0..<n { ref[i] = next() * 0.3 }

        // mic = echo only (no near-end talk) → ideal ERLE measurement.
        var mic = [Float](repeating: 0, count: n)
        for i in delay..<n { mic[i] = echoGain * ref[i - delay] }

        let refURL = dir.appendingPathComponent("system.wav")
        let micURL = dir.appendingPathComponent("mic.wav")
        let outURL = dir.appendingPathComponent("mic-clean.wav")
        try writeWAV(ref, to: refURL)
        try writeWAV(mic, to: micURL)

        #expect(EchoCanceller.process(micWAV: micURL, systemWAV: refURL, outWAV: outURL))

        let cleaned = try AudioFileLoader.loadMono16k(outURL)
        // Measure over the last 2 s (post-convergence).
        let start = rate * (seconds - 2)
        let echoPower = power(mic, from: start)
        let residual = power(cleaned, from: min(start, cleaned.count))
        let erleDB = 10 * log10(echoPower / max(residual, 1e-12))
        #expect(erleDB >= 10, "expected ≥10 dB echo reduction, got \(erleDB) dB")
    }

    /// Today's Bluetooth-speaker case: the echo trails the tapped reference by
    /// ~440 ms — more than the adaptive tail. Bulk-delay compensation must
    /// align first; without it this echo is untouchable (measured −1 dB on a
    /// real call).
    @Test func cancelsEchoDelayedBeyondTheFilterTail() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aec-far-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rate = 16000
        let seconds = 40   // envelope correlation wants > 2×maxDelay of signal
        let n = rate * seconds
        let delay = 7104   // 444 ms
        let echoGain: Float = 0.5

        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
        }
        // Bursty far-end (speech-like on/off) — envelopes need structure.
        var ref = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let talking = (i / (rate * 2)) % 3 != 2   // 4 s on, 2 s off
            ref[i] = talking ? next() * 0.3 : 0
        }
        var mic = [Float](repeating: 0, count: n)
        for i in delay..<n { mic[i] = echoGain * ref[i - delay] }

        let refURL = dir.appendingPathComponent("system.wav")
        let micURL = dir.appendingPathComponent("mic.wav")
        let outURL = dir.appendingPathComponent("mic-clean.wav")
        try writeWAV(ref, to: refURL)
        try writeWAV(mic, to: micURL)

        #expect(EchoCanceller.process(micWAV: micURL, systemWAV: refURL, outWAV: outURL))

        let cleaned = try AudioFileLoader.loadMono16k(outURL)
        let start = rate * (seconds - 8)
        let echoPower = power(mic, from: start)
        let residual = power(cleaned, from: min(start, cleaned.count))
        let erleDB = 10 * log10(echoPower / max(residual, 1e-12))
        #expect(erleDB >= 10, "expected ≥10 dB reduction of far-delayed echo, got \(erleDB) dB")
    }

    @Test func delayEstimateFindsTheBulkDelay() {
        let rate = 16000
        let n = rate * 40
        let delay = 7100
        var seed: UInt64 = 42
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
        }
        var ref = [Float](repeating: 0, count: n)
        for i in 0..<n where (i / (rate * 2)) % 3 != 2 { ref[i] = next() * 0.3 }
        var mic = [Float](repeating: 0, count: n)
        for i in delay..<n { mic[i] = 0.5 * ref[i - delay] }

        let estimated = EchoCanceller.estimateBulkDelay(mic: mic, reference: ref)
        // Envelope resolution is 10 ms (160 samples) — one frame of slack.
        #expect(abs(estimated - delay) <= 160, "estimated \(estimated), true \(delay)")
    }

    @Test func nearFieldEchoIsNotCompensated() {
        // A 5 ms speaker→mic delay sits comfortably inside the adaptive tail;
        // shifting the reference for it would only risk misalignment.
        let rate = 16000
        let n = rate * 40
        var seed: UInt64 = 7
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
        }
        var ref = [Float](repeating: 0, count: n)
        for i in 0..<n where (i / (rate * 2)) % 3 != 2 { ref[i] = next() * 0.3 }
        var mic = [Float](repeating: 0, count: n)
        for i in 80..<n { mic[i] = 0.5 * ref[i - 80] }

        #expect(EchoCanceller.estimateBulkDelay(mic: mic, reference: ref) == 0)
    }

    private func power(_ x: [Float], from: Int) -> Double {
        guard from < x.count else { return 0 }
        var sum = 0.0
        for i in from..<x.count { sum += Double(x[i]) * Double(x[i]) }
        return sum / Double(x.count - from)
    }
}

/// Minimal 16 kHz mono Int16 WAV writer for tests (reuses the app's WAVWriter).
func writeWAV(_ samples: [Float], to url: URL) throws {
    let writer = try WAVWriter(url: url)
    try writer.append(samples.map { Int16(max(-32768, min(32767, ($0 * 32767).rounded()))) })
    try writer.finalize()
}
