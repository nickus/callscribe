import AVFAudio
import Foundation
import Testing
@testable import CallScribeEngine

/// TrackSink is where the two capture-loss bugs were fixed: the resampler must
/// follow mid-stream format changes (the half-speed system track), and holes
/// in the timeline after a capture restart must be padded with silence so the
/// two tracks stay aligned. Both are pure enough to test with synthetic
/// buffers and host times.
@Suite struct TrackSinkTests {
    private func tempWAV() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tracksink-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("track.wav")
    }

    private func buffer(seconds: Double, sampleRate: Double, value: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) { channel[i] = value }
        }
        return buffer
    }

    private func ticks(_ seconds: Double, after base: UInt64) -> UInt64 {
        base + TrackSink.secondsToHostTicks(seconds)
    }

    @Test func leadInAndDurationMatchTheSharedClock() throws {
        let base = mach_absolute_time()
        let sink = try TrackSink(url: tempWAV(), label: "t", sessionStartHostTime: base)
        sink.processInline(buffer(seconds: 0.5, sampleRate: 48000), hostTime: ticks(0.2, after: base))
        try sink.finish()
        #expect(abs(sink.startOffsetSec - 0.2) < 0.01)
        #expect(abs(sink.duration - 0.7) < 0.05)
    }

    @Test func captureHoleIsPaddedWithSilence() throws {
        // A buffer arrives, capture dies, a rebuilt capture resumes 4.3 s
        // later: the file must span the full wall-clock time, not glue the
        // two chunks together (that's what desynced the echo canceller).
        let base = mach_absolute_time()
        let sink = try TrackSink(url: tempWAV(), label: "t", sessionStartHostTime: base)
        sink.processInline(buffer(seconds: 0.5, sampleRate: 48000), hostTime: ticks(0.2, after: base))
        sink.processInline(buffer(seconds: 0.5, sampleRate: 48000), hostTime: ticks(5.0, after: base))
        try sink.finish()
        #expect(abs(sink.duration - 5.5) < 0.05)
    }

    @Test func subThresholdJitterIsNotPadded() throws {
        // Normal cadence: the next buffer starts where the last one ended,
        // give or take clock jitter — nothing must be inserted.
        let base = mach_absolute_time()
        let sink = try TrackSink(url: tempWAV(), label: "t", sessionStartHostTime: base)
        sink.processInline(buffer(seconds: 0.5, sampleRate: 48000), hostTime: ticks(0.0, after: base))
        sink.processInline(buffer(seconds: 0.5, sampleRate: 48000), hostTime: ticks(0.6, after: base))
        try sink.finish()
        #expect(abs(sink.duration - 1.0) < 0.05)
    }

    @Test func formatChangeMidStreamKeepsRealtimeDuration() throws {
        // The half-speed regression: the route flips and buffers start
        // arriving at a different sample rate. One second of 48 kHz plus one
        // second of 24 kHz is two seconds of audio — the old sink kept the
        // 48 kHz converter and died (or mis-rated the tail).
        let base = mach_absolute_time()
        let sink = try TrackSink(url: tempWAV(), label: "t", sessionStartHostTime: base)
        sink.processInline(buffer(seconds: 1.0, sampleRate: 48000), hostTime: ticks(0.0, after: base))
        sink.processInline(buffer(seconds: 1.0, sampleRate: 24000), hostTime: ticks(1.0, after: base))
        try sink.finish()
        #expect(abs(sink.duration - 2.0) < 0.05)
        #expect(sink.latchedErrorDescription == nil)
    }

    @Test func channelCountChangeMidStreamSurvivesToo() throws {
        let stereo = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let stereoBuffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 48000)!
        stereoBuffer.frameLength = 48000

        let base = mach_absolute_time()
        let sink = try TrackSink(url: tempWAV(), label: "t", sessionStartHostTime: base)
        sink.processInline(stereoBuffer, hostTime: ticks(0.0, after: base))
        sink.processInline(buffer(seconds: 1.0, sampleRate: 48000), hostTime: ticks(1.0, after: base))
        try sink.finish()
        #expect(abs(sink.duration - 2.0) < 0.05)
        #expect(sink.latchedErrorDescription == nil)
    }

    @Test func loneTrackZeroBasesOnItsFirstBufferButStillPadsHoles() throws {
        // Dictation-style single track: no lead-in (nothing to align with),
        // but a mid-stream capture hole must still be padded.
        let base = mach_absolute_time()
        let sink = try TrackSink(url: tempWAV(), label: "t", sessionStartHostTime: nil)
        sink.processInline(buffer(seconds: 0.5, sampleRate: 48000), hostTime: ticks(0.3, after: base))
        sink.processInline(buffer(seconds: 0.5, sampleRate: 48000), hostTime: ticks(3.3, after: base))
        try sink.finish()
        #expect(sink.startOffsetSec == 0)
        // Zero-based at 0.3: second buffer sits at 3.0 on the track's own
        // timeline, so 2.5 s of silence fill the hole.
        #expect(abs(sink.duration - 3.5) < 0.05)
    }

    @Test func simultaneousFormatChangeAndHoleKeepsWallClockDuration() throws {
        // A route change usually comes WITH a capture hole: the old converter's
        // tail must land before the padded silence, and the total must still
        // match the wall clock.
        let base = mach_absolute_time()
        let sink = try TrackSink(url: tempWAV(), label: "t", sessionStartHostTime: base)
        sink.processInline(buffer(seconds: 1.0, sampleRate: 48000), hostTime: ticks(0.0, after: base))
        sink.processInline(buffer(seconds: 1.0, sampleRate: 24000), hostTime: ticks(3.0, after: base))
        try sink.finish()
        #expect(abs(sink.duration - 4.0) < 0.05)
        #expect(sink.latchedErrorDescription == nil)
    }

    @Test func veryLateFirstBufferIsPlacedAtItsWallClockPosition() throws {
        // Capture that only came up after watchdog restarts: the first buffer
        // can arrive well past 30 s. It must land at its real position with
        // the lead-in padded — not at position 0 with the hole appearing
        // after it (the old clamp did exactly that).
        let base = mach_absolute_time()
        let sink = try TrackSink(url: tempWAV(), label: "t", sessionStartHostTime: base)
        sink.processInline(buffer(seconds: 0.5, sampleRate: 48000), hostTime: ticks(31.0, after: base))
        try sink.finish()
        #expect(abs(sink.startOffsetSec - 31.0) < 0.01)
        #expect(abs(sink.duration - 31.5) < 0.05)
    }

    @Test func currentDurationMirrorsWithoutTouchingTheQueue() throws {
        let base = mach_absolute_time()
        let sink = try TrackSink(url: tempWAV(), label: "t", sessionStartHostTime: base)
        sink.processInline(buffer(seconds: 1.0, sampleRate: 16000), hostTime: ticks(0.0, after: base))
        // The mirror is what the watchdog polls; it must match the real thing.
        #expect(abs(sink.currentDuration - sink.duration) < 0.001)
        try sink.finish()
    }
}
