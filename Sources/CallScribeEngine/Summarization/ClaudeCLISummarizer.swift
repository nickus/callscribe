import CallScribeCore
import Foundation

/// Summarizer #1: shells out to the locally installed `claude -p` CLI. Sends
/// the transcript on stdin, reads Markdown on stdout. A missing binary, a
/// non-zero exit, or a timeout raises a typed error — the caller keeps the
/// transcript and offers a retry; summarization never blocks the pipeline.
/// Somewhere for a background reader to hand its bytes back.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}

public struct ClaudeCLISummarizer: Summarizer {
    public enum Failure: LocalizedError {
        case binaryNotFound
        case timedOut
        case nonZeroExit(Int32, String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                "The `claude` CLI was not found. Install it or set CALLSCRIBE_CLAUDE_PATH."
            case .timedOut:
                "The summarizer timed out."
            case .nonZeroExit(let code, let stderr):
                "claude exited with code \(code): \(stderr)"
            }
        }
    }

    private let binaryURL: URL
    private let timeout: TimeInterval
    private let workingDirectory: URL?
    private let log: Log

    /// Default timeout sized for hour-plus calls: a ~60-minute transcript
    /// (~95 KB) with a project glossary legitimately takes `claude -p` well
    /// over the old 3 minutes to read and summarize.
    public init?(workingDirectory: URL? = nil, timeout: TimeInterval = 600, log: Log = .shared) {
        guard let binary = Self.resolveBinary() else { return nil }
        self.binaryURL = binary
        self.timeout = timeout
        self.workingDirectory = workingDirectory
        self.log = log
    }

    /// CALLSCRIBE_CLAUDE_PATH → common install locations. GUI apps don't inherit
    /// the shell PATH, so probe explicit paths rather than relying on `which`.
    public static func resolveBinary() -> URL? {
        if let override = ProcessInfo.processInfo.environment["CALLSCRIBE_CLAUDE_PATH"] {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func summarize(transcript: String, projectContext: String?) async throws -> SummaryResult {
        let prompt = SummaryPrompt.build(transcript: transcript, projectContext: projectContext)
        // Size, not content: when this times out, the log should say whether
        // the input was huge without anyone digging through call folders.
        log.info("summarizer: prompt \(prompt.count) chars, timeout \(Int(timeout))s")
        let output = try runClaude(prompt: prompt)
        return SummaryPrompt.parse(output)
    }

    private func runClaude(prompt: String) throws -> String {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["-p"]

        // Run in the project's working directory (chosen by the user) so the
        // `claude` agent's file access is intentional and scoped there. Falls
        // back to a throwaway temp dir so it never scans the user's real
        // folders (Desktop/Documents/…) by accident.
        if let workingDirectory {
            try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            process.currentDirectoryURL = workingDirectory
        } else {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("callscribe-claude", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            process.currentDirectoryURL = scratch
        }

        // An app started by LaunchServices gets a stripped environment, and
        // `claude` looks its keychain credentials up by the account name in USER —
        // without it, it prints "Not logged in · Please run /login" and exits 1.
        // Supply the essentials instead of inheriting whatever we were given.
        var environment = ProcessInfo.processInfo.environment
        if environment["USER"]?.isEmpty ?? true { environment["USER"] = NSUserName() }
        if environment["HOME"]?.isEmpty ?? true {
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        if environment["PATH"]?.isEmpty ?? true {
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        // Read both pipes concurrently, and put the deadline on the *reads*.
        // `readDataToEndOfFile()` blocks until the child exits, so a deadline
        // checked after it can never fire — a hung `claude` would hang the app.
        // Reading them one after the other also deadlocks if the second pipe
        // fills its buffer while we're blocked on the first.
        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async(group: group) { outBox.set(stdout.fileHandleForReading.readDataToEndOfFile()) }
        queue.async(group: group) { errBox.set(stderr.fileHandleForReading.readDataToEndOfFile()) }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 5)   // terminate closes the pipes → reads return
            log.error("summarizer timed out after \(Int(timeout))s — terminated")
            throw Failure.timedOut
        }
        process.waitUntilExit()
        let outData = outBox.get(), errData = errBox.get()

        guard process.terminationStatus == 0 else {
            // `claude -p` reports its own failures on stdout ("Not logged in",
            // usage limits) and leaves stderr empty, so fall back to stdout —
            // otherwise the user gets a bare exit code and nothing to act on.
            // Lossy decoding on purpose: one truncated multibyte character must
            // not erase a whole error message (or, below, a whole summary).
            // swiftlint:disable:next optional_data_string_conversion
            let err = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // swiftlint:disable:next optional_data_string_conversion
            let out = String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = err.isEmpty ? out : err
            log.error("""
                summarizer exit=\(process.terminationStatus) \
                channel=\(err.isEmpty ? "stdout" : "stderr"): \(Log.truncated(message))
                """)
            throw Failure.nonZeroExit(process.terminationStatus, message)
        }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: outData, as: UTF8.self)
    }
}
