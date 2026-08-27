import AppKit
import CallScribeCore
import Foundation

/// Owns a live recording: creates the call folder, checks disk space, starts
/// both tracks on one shared clock, watches for capture stalls, and writes
/// meta.json on stop. Audio is written continuously — a crash keeps whatever
/// reached disk.
public final class RecordingSession: @unchecked Sendable {
    public enum Failure: LocalizedError {
        case insufficientDiskSpace(availableBytes: Int64)

        public var errorDescription: String? {
            switch self {
            case .insufficientDiskSpace(let bytes):
                "Not enough free disk space to record (\(bytes / 1_000_000) MB available)."
            }
        }
    }

    public let folder: CallFolder
    private let appVersion: String
    private let language: String?

    private let micSink: TrackSink
    private let systemSink: TrackSink
    private let micRecorder: MicRecorder
    private let systemRecorder: SystemAudioTapRecorder

    private var meta: CallMeta
    private var stopped = false
    private let onStall: (@Sendable (String) -> Void)?
    private let log: Log
    private var watchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "callscribe.watchdog")

    public init(
        store: CallStore,
        startedAt: Date,
        appVersion: String,
        language: String? = nil,
        log: Log = .shared,
        onStall: (@Sendable (String) -> Void)? = nil
    ) throws {
        let available = try DiskSpace.availableBytes(at: store.rootURL.deletingLastPathComponent())
        guard available >= DiskSpace.minimumBytesForRecording else {
            throw Failure.insufficientDiskSpace(availableBytes: available)
        }

        self.folder = try store.createCallFolder(startedAt: startedAt)
        self.appVersion = appVersion
        self.language = language
        self.log = log
        self.onStall = onStall
        // Shared clock zero for both tracks (see TrackSink lead-in silence).
        let sessionStart = mach_absolute_time()
        self.micSink = try TrackSink(url: folder.micWAV, label: "mic", sessionStartHostTime: sessionStart)
        self.systemSink = try TrackSink(url: folder.systemWAV, label: "system", sessionStartHostTime: sessionStart)
        self.micRecorder = MicRecorder(sink: micSink)
        self.systemRecorder = SystemAudioTapRecorder(sink: systemSink)

        self.meta = CallMeta(startedAt: startedAt, appVersion: appVersion)
        self.meta.language = language
        try folder.saveMeta(meta)
    }

    public func start() throws {
        try systemRecorder.start()
        do {
            try micRecorder.start()
        } catch {
            systemRecorder.stop()
            throw error
        }
        startWatchdog()
    }

    @discardableResult
    public func stop() throws -> CallFolder {
        guard !stopped else { return folder }
        stopped = true
        watchdog?.cancel()
        watchdog = nil

        micRecorder.stop()
        systemRecorder.stop()
        // Finish BOTH sinks even when the first throws — the second file would
        // otherwise be left with an unfinalized header and a leaked handle.
        let micResult = Result { try micSink.finish() }
        let systemResult = Result { try systemSink.finish() }

        meta.endedAt = Date()
        meta.durationSec = max(micSink.duration, systemSink.duration)
        meta.micStartOffsetSec = micSink.startOffsetSec
        meta.systemStartOffsetSec = systemSink.startOffsetSec
        try folder.saveMeta(meta)
        try micResult.get()
        try systemResult.get()
        return folder
    }

    /// Watch both tracks for stalls (StallDetector holds the tested rules): a
    /// stalled track gets its capture rebuilt; a track that stays dead is
    /// abandoned and the session continues on the other; only both-dead fires
    /// `onStall`. Durations are read via lock-free mirrors — `queue.sync`
    /// here could block behind the wedged write the watchdog must detect.
    /// The disk files are always preserved.
    private func startWatchdog() {
        var detector = StallDetector()
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for event in detector.tick(mic: micSink.currentDuration, system: systemSink.currentDuration) {
                switch event {
                case .restart(let track):
                    log.warn("recording: \(track.rawValue) track stalled — rebuilding its capture")
                    restart(track)
                case .trackLost(let track):
                    let sink = track == .mic ? micSink : systemSink
                    let detail = sink.latchedErrorDescription.map { " (write error: \($0))" } ?? ""
                    log.error("""
                        recording: \(track.rawValue) track is not coming back\(detail) — \
                        continuing with the other track only
                        """)
                case .endSession:
                    self.onStall?(self.stallDiagnosis())
                    timer.cancel()
                }
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func restart(_ track: StallDetector.Track) {
        switch track {
        case .mic: micRecorder.restart()
        case .system: systemRecorder.restart()
        }
    }

    /// Tell "no audio arriving" apart from "audio arriving, writes failing":
    /// a latched sink error (disk trouble) used to be reported as a capture
    /// stall, sending whoever read the log to debug the wrong subsystem.
    private func stallDiagnosis() -> String {
        let sinkErrors = [
            micSink.latchedErrorDescription.map { "mic: \($0)" },
            systemSink.latchedErrorDescription.map { "system: \($0)" },
        ].compactMap { $0 }
        return sinkErrors.isEmpty
            ? "no audio arriving on either track"
            : "track writes failing (disk?): \(sinkErrors.joined(separator: "; "))"
    }
}
