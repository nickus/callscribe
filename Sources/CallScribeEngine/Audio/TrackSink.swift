import AVFAudio
import CallScribeCore
import Foundation

/// Serializes one track's hot path: captured buffers (any format) are
/// resampled to 16 kHz mono and appended to the WAV file, all on a private
/// serial queue. The resampler follows the buffers' format: a device or route
/// change mid-call (AirPods flipping A2DP↔HFP) changes the stream's rate or
/// channel count, and converting new buffers with the old converter is exactly
/// how a track ends up written at the wrong speed.
///
/// Alignment: the file position is kept matching the wall clock. Given a
/// shared session-start host time, the first buffer's own host time tells us
/// how late this track began, and that much silence is prepended; a hole in
/// the middle (capture died and was rebuilt) is padded the same way, so the
/// tracks stay sample-aligned for the echo canceller and the merge. A lone
/// track has nothing to line up with and passes `nil` instead — it zero-bases
/// on its own first sample, but mid-stream holes are still padded.
final class TrackSink: @unchecked Sendable {
    private static let sampleRate = 16000
    /// Below this, a buffer's timeline lead over the file is clock jitter and
    /// resampler lag; above it, a real capture hole that must be padded.
    private static let gapPadThreshold: TimeInterval = 0.5
    /// A "hole" bigger than this means a broken host-time source, not a gap.
    private static let gapPadSanityMax: TimeInterval = 3600

    /// IOProc-style producers can be scheduled directly on this queue and call
    /// `processInline` synchronously (zero-copy); everyone else uses `enqueue`.
    let queue: DispatchQueue

    private let writer: WAVWriter
    private let sessionStartHostTime: UInt64?
    private var timelineZeroHostTime: UInt64?
    private var resampler: AudioResampler?
    private var resamplerFormat: AVAudioFormat?
    private var accepting = true
    private var firstError: Error?
    private var prependedLeadIn = false
    private(set) var startOffsetSec: TimeInterval = 0

    /// Mirrors of `writer.duration` / `firstError` readable WITHOUT hopping
    /// onto `queue`: the watchdog polls them, and `queue.sync` from the
    /// watchdog would block behind the very wedged file write it's supposed
    /// to detect.
    private let mirrorLock = NSLock()
    private var mirroredDuration: TimeInterval = 0
    private var mirroredError: String?

    /// - Parameter sessionStartHostTime: the shared clock zero for a multi-track
    ///   session, or `nil` to zero-base on this track's own first sample. `nil`
    ///   is what a single-track recording wants: the device takes a couple of
    ///   hundred milliseconds to deliver its first buffer, and padding that gap
    ///   would only prepend silence and overstate `duration`.
    init(url: URL, label: String, sessionStartHostTime: UInt64?) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.writer = try WAVWriter(url: url)
        self.sessionStartHostTime = sessionStartHostTime
        self.queue = DispatchQueue(label: "callscribe.sink.\(label)")
    }

    /// Hand a buffer over from an arbitrary thread. The caller must not touch
    /// the buffer afterwards — ownership transfers to the sink queue.
    func enqueue(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let boxed = UncheckedSendable(value: buffer)
        queue.async { self.processInline(boxed.value, hostTime: hostTime) }
    }

    /// Convert + write synchronously. Must run on `queue`.
    func processInline(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard accepting, firstError == nil else { return }
        do {
            if resamplerFormat != buffer.format {
                // Route change: drain the old converter's tail BEFORE any gap
                // padding — it is pre-gap audio and belongs before the silence.
                // Feeding the old converter the new format would either throw
                // or (worse) resample at the stale rate — the half-speed bug.
                if let old = resampler {
                    let tail = try old.flush()
                    if !tail.isEmpty { try writer.append(tail) }
                }
                resampler = try AudioResampler(inputFormat: buffer.format)
                resamplerFormat = buffer.format
            }
            try padTimelineGap(before: hostTime)
            try writer.append(resampler!.convert(buffer))
            mirror()
        } catch {
            firstError = error
            mirrorLock.withLock { mirroredError = error.localizedDescription }
        }
    }

    /// Keep the file position matching the wall clock. First buffer: prepend
    /// the lead-in back to the shared session start. Later buffers: pad any
    /// real hole (capture died and came back) with silence.
    private func padTimelineGap(before hostTime: UInt64) throws {
        if !prependedLeadIn {
            prependedLeadIn = true
            if let sessionStartHostTime {
                timelineZeroHostTime = sessionStartHostTime
                if hostTime > sessionStartHostTime {
                    let seconds = Self.hostTicksToSeconds(hostTime - sessionStartHostTime)
                    // Same sanity bound as mid-stream gaps. A tighter clamp here
                    // would place a late first buffer (capture that only came up
                    // after watchdog restarts) at position 0 — misaligned audio
                    // AND the huge pad on the next buffer anyway.
                    if seconds > 0, seconds < Self.gapPadSanityMax {
                        startOffsetSec = seconds
                        try writer.append(silence(seconds: seconds))
                        mirror()
                    }
                }
            } else {
                timelineZeroHostTime = hostTime
            }
            return
        }
        guard let zero = timelineZeroHostTime, hostTime > zero else { return }
        let expected = Self.hostTicksToSeconds(hostTime - zero)
        let gap = expected - writer.duration
        guard gap > Self.gapPadThreshold, gap < Self.gapPadSanityMax else { return }
        try writer.append(silence(seconds: gap))
        mirror()
    }

    private func silence(seconds: TimeInterval) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * Double(Self.sampleRate)))
    }

    private func mirror() {
        let duration = writer.duration
        mirrorLock.withLock { mirroredDuration = duration }
    }

    /// Stop accepting, drain the resampler, finalize the WAV header, and
    /// surface the first error the hot path swallowed (if any).
    func finish() throws {
        var result: Result<Void, Error> = .success(())
        queue.sync {
            accepting = false
            do {
                if let tail = try resampler?.flush(), !tail.isEmpty {
                    try writer.append(tail)
                }
                try writer.finalize()
            } catch {
                result = .failure(error)
            }
            if let error = firstError {
                result = .failure(error)
            }
        }
        try result.get()
    }

    var duration: TimeInterval {
        queue.sync { writer.duration }
    }

    // MARK: - Watchdog mirrors (safe from any thread, never touch `queue`)

    var currentDuration: TimeInterval {
        mirrorLock.withLock { mirroredDuration }
    }

    /// The write-path error the hot path latched, if any — lets the watchdog
    /// tell "no audio arriving" apart from "audio arriving, writes failing".
    var latchedErrorDescription: String? {
        mirrorLock.withLock { mirroredError }
    }

    // MARK: - Host time

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func hostTicksToSeconds(_ ticks: UInt64) -> TimeInterval {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func secondsToHostTicks(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }
}
