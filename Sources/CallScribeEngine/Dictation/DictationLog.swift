import CallScribeCore
import Foundation

/// A running record of what you've dictated, in
/// `~/Library/Application Support/CallScribe/dictations.md`.
///
/// Unlike `Log`, this file holds **content** — the dictated text itself. That's
/// the point of it, and the reason it lives in Application Support beside
/// `projects.json` rather than in `~/Library/Logs`, which `sysdiagnose`
/// collects. `Log` stays metadata-only.
///
/// This type is only the file I/O. The format itself lives in
/// `DictationLogFormat` over in CallScribeCore, so reading and writing can't
/// drift apart — which matters because `remove` rewrites the whole file, and
/// this file is the only record of what was said.
public struct DictationLog: Sendable {
    private let fileURL: URL

    public init(fileURL: URL = AppPaths.dictationLogURL) {
        self.fileURL = fileURL
    }

    /// Append one dictation. Best-effort: a dictation that reached the cursor has
    /// already done its job, so a failure here is logged, not thrown.
    public func append(_ text: String, at date: Date = Date(), language: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try appendThrowing(DictationLogFormat.render(trimmed, at: date, language: language))
        } catch {
            Log.shared.warn("""
                dictation: could not append to the dictation log: \
                \(Log.truncated(error.localizedDescription))
                """)
        }
    }

    /// Every entry, oldest first. Non-throwing and empty on any failure — a
    /// missing file just means nothing has been dictated yet, which is the same
    /// convention `ProjectStore.load` follows.
    public func entries() -> [DictationLogFormat.Entry] {
        guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return DictationLogFormat.parse(markdown)
    }

    /// Delete one entry, addressed by its ordinal in the file (`Entry.index`).
    ///
    /// A whole-file rewrite, so unlike `append` it goes through `.atomic` — as
    /// every other writer in the app does. An out-of-range index rewrites the
    /// file unchanged rather than throwing.
    public func remove(index: Int) throws {
        let markdown = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        guard !markdown.isEmpty else { return }
        let updated = DictationLogFormat.remove(markdown, index: index)
        guard updated != markdown else { return }
        try Data(updated.utf8).write(to: fileURL, options: .atomic)
    }

    private func appendThrowing(_ entry: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = entry.data(using: .utf8) else { return }

        if !manager.fileExists(atPath: fileURL.path) {
            try Data(DictationLogFormat.preamble.utf8 + data).write(to: fileURL)
            return
        }
        // Opened and closed per entry rather than held: dictations are seconds
        // apart at best, and a retained handle would be one more thing to get
        // right across app quit.
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
