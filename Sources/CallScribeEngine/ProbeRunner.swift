import Foundation

/// M1 verification harness: records N seconds from both tracks (microphone +
/// system audio) to a scratch folder. Exercises the full permission and
/// capture path without any of the later pipeline stages.
public enum ProbeRunner {
    public struct ProbeResult: Sendable {
        public let micURL: URL
        public let systemURL: URL
        public let micSeconds: Double
        public let systemSeconds: Double
    }

    public static func run(seconds: UInt, outputDir: URL? = nil) async throws -> ProbeResult {
        guard await PermissionsProbe.requestMicrophoneAccess() else {
            throw AudioCaptureError.microphoneAccessDenied
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = outputDir
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("callscribe-probe-\(stamp)")

        let sessionStart = mach_absolute_time()
        let micSink = try TrackSink(
            url: dir.appendingPathComponent("mic.wav"), label: "mic",
            sessionStartHostTime: sessionStart)
        let systemSink = try TrackSink(
            url: dir.appendingPathComponent("system.wav"), label: "system",
            sessionStartHostTime: sessionStart)

        // System tap first: it owns the riskier TCC prompt.
        let systemRecorder = SystemAudioTapRecorder(sink: systemSink)
        try systemRecorder.start()

        let micRecorder = MicRecorder(sink: micSink)
        do {
            try micRecorder.start()
        } catch {
            systemRecorder.stop()
            throw error
        }

        try? await Task.sleep(for: .seconds(Double(seconds)))

        micRecorder.stop()
        systemRecorder.stop()
        try micSink.finish()
        try systemSink.finish()

        return ProbeResult(
            micURL: dir.appendingPathComponent("mic.wav"),
            systemURL: dir.appendingPathComponent("system.wav"),
            micSeconds: micSink.duration,
            systemSeconds: systemSink.duration
        )
    }
}
