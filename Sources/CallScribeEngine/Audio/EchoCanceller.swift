import CSpeexDSP
import CallScribeCore
import Foundation

/// Offline acoustic echo cancellation. The mic (near-end) contains the user's
/// voice plus the remote voice bleeding in through the speakers; the system
/// track is the clean far-end reference. SpeexDSP's adaptive filter subtracts
/// the echo, leaving (mostly) just the local voice — without the muffling of
/// Apple's real-time voice processing. Assumes the tracks are already
/// time-aligned (see RecordingSession lead-in silence).
public enum EchoCanceller {
    private static let frame = 160          // 10 ms at 16 kHz
    private static let filterLength = 4800  // 300 ms tail for the room, post-alignment
    /// How far the echo may trail the reference: Bluetooth speakers, AirPlay
    /// and TVs add up to ~1.5 s between the digitally-tapped reference and
    /// the sound actually leaving the device.
    private static let maxDelayFrames = 150
    /// Below this the delay already fits inside the adaptive tail — shifting
    /// would only risk misalignment from an imprecise estimate.
    private static let minCompensatedFrames = 10   // 100 ms

    /// Write `outWAV` = mic with the system echo removed. Returns false (and
    /// writes nothing) if inputs are missing/empty or the canceller is
    /// unavailable — callers then fall back to the raw mic.
    @discardableResult
    public static func process(micWAV: URL, systemWAV: URL, outWAV: URL) -> Bool {
        guard let micF = try? AudioFileLoader.loadMono16k(micWAV), !micF.isEmpty,
              let sysRaw = try? AudioFileLoader.loadMono16k(systemWAV), !sysRaw.isEmpty
        else { return false }

        // Bulk-delay compensation: the reference is captured at the tap BEFORE
        // the output device's buffer, so on a Bluetooth/AirPlay route the mic
        // hears the echo hundreds of ms later — beyond any reasonable adaptive
        // tail. Align the reference first; the filter then only models the room.
        let sysF: [Float]
        let delaySamples = estimateBulkDelay(mic: micF, reference: sysRaw)
        if delaySamples > 0 {
            var shifted = [Float](repeating: 0, count: delaySamples)
            shifted.append(contentsOf: sysRaw.prefix(max(0, sysRaw.count - delaySamples)))
            sysF = shifted
            Log.shared.info("echocancel: compensating \(delaySamples * 1000 / 16000) ms output-device delay")
        } else {
            sysF = sysRaw
        }

        guard let state = speex_echo_state_init(Int32(frame), Int32(filterLength)) else { return false }
        defer { speex_echo_state_destroy(state) }
        var rate: Int32 = 16000
        _ = speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)

        // SpeexDSP works on 16-bit PCM frames. Pad both to a common frame
        // multiple so the last frame is whole.
        let count = max(micF.count, sysF.count)
        let padded = ((count + frame - 1) / frame) * frame
        let mic = toInt16(micF, count: padded)
        let sys = toInt16(sysF, count: padded)
        var out = [Int16](repeating: 0, count: padded)

        mic.withUnsafeBufferPointer { m in
            sys.withUnsafeBufferPointer { s in
                out.withUnsafeMutableBufferPointer { o in
                    var i = 0
                    while i < padded {
                        speex_echo_cancellation(
                            state,
                            m.baseAddress! + i,   // near-end (mic)
                            s.baseAddress! + i,   // far-end reference (system)
                            o.baseAddress! + i
                        )
                        i += frame
                    }
                }
            }
        }

        let trimmed = Array(out.prefix(micF.count))
        do {
            let writer = try WAVWriter(url: outWAV)
            try writer.append(trimmed)
            try writer.finalize()
            return true
        } catch {
            return false
        }
    }

    /// Dominant mic-behind-reference delay in samples, 0 when nothing decisive:
    /// normalized cross-correlation of mean-centered 10 ms RMS envelopes over
    /// the whole call. Envelope-level (not sample-level) keeps it cheap and
    /// robust to the speaker's acoustic coloring of the echo.
    static func estimateBulkDelay(mic: [Float], reference: [Float]) -> Int {
        let frames = min(mic.count, reference.count) / frame
        guard frames > maxDelayFrames * 2 else { return 0 }

        var micEnv = [Float](repeating: 0, count: frames)
        var refEnv = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sm: Float = 0
            var sr: Float = 0
            for i in (f * frame)..<((f + 1) * frame) {
                sm += mic[i] * mic[i]
                sr += reference[i] * reference[i]
            }
            micEnv[f] = sm.squareRoot()
            refEnv[f] = sr.squareRoot()
        }
        let micMean = micEnv.reduce(0, +) / Float(frames)
        let refMean = refEnv.reduce(0, +) / Float(frames)
        for f in 0..<frames {
            micEnv[f] -= micMean
            refEnv[f] -= refMean
        }
        let micNorm = micEnv.reduce(0) { $0 + $1 * $1 }.squareRoot()

        var best = (lag: 0, r: Float(0))
        for lag in 0...maxDelayFrames {
            var dot: Float = 0
            var refPower: Float = 0
            for f in 0..<(frames - lag) {
                dot += micEnv[f + lag] * refEnv[f]
                refPower += refEnv[f] * refEnv[f]
            }
            let r = dot / (micNorm * refPower.squareRoot() + 1e-9)
            if r > best.r { best = (lag, r) }
        }
        guard best.r > 0.3, best.lag >= minCompensatedFrames else { return 0 }
        return best.lag * frame
    }

    private static func toInt16(_ samples: [Float], count: Int) -> [Int16] {
        var result = [Int16](repeating: 0, count: count)
        for i in 0..<min(samples.count, count) {
            let v = (samples[i] * 32767).rounded()
            result[i] = Int16(max(-32768, min(32767, v)))
        }
        return result
    }
}
