import ArgumentParser
import CallScribeCore
import CallScribeEngine
import Foundation

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record a call to a new folder in ~/Documents/CallNotes."
    )

    @Option(name: .shortAndLong, help: "Stop automatically after N seconds (default: until Ctrl-C).")
    var duration: Double?

    @Option(name: .shortAndLong, help: "Language override: ru or en (default: auto-detect).")
    var language: String?

    func run() async throws {
        guard await PermissionsProbe.requestMicrophoneAccess() else {
            throw AudioCaptureError.microphoneAccessDenied
        }

        // One stop channel with three producers: Ctrl-C, the --duration timer,
        // and unrecoverable capture (which used to print "stopping" while the
        // CLI happily kept recording two dead tracks).
        let (stopped, stop) = AsyncStream.makeStream(of: Void.self)

        let session = try RecordingSession(
            store: CallStore(),
            startedAt: Date(),
            appVersion: AppInfo.version,
            language: language,
            onStall: { reason in
                print("\n⚠️  capture unrecoverable (\(reason)) — stopping; recording so far is kept")
                stop.yield()
            }
        )
        try session.start()
        print("● Recording to \(session.folder.url.path)")
        print("  play the call audio; press Ctrl-C to stop.")

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigint.setEventHandler { stop.yield() }
        sigint.resume()
        if let duration {
            DispatchQueue.global().asyncAfter(deadline: .now() + duration) { stop.yield() }
        }
        for await _ in stopped { break }
        sigint.cancel()

        let folder = try session.stop()
        let meta = try folder.loadMeta()
        print("■ Stopped. \(String(format: "%.1f", meta.durationSec ?? 0)) s recorded.")
        print("  Next: callscribe pipeline \(folder.url.path)")
    }
}
