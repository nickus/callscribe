import Foundation

/// Storage is plain folders: one folder per call under the root, named by
/// start time. In-app history is just a listing of this directory.
public struct CallStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL
            ?? FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/CallNotes")
    }

    public func createCallFolder(startedAt: Date) throws -> CallFolder {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let base = formatter.string(from: startedAt)

        var candidate = rootURL.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return CallFolder(url: candidate)
    }

    /// Call folders, newest first. Only directories that actually hold a call
    /// (they contain `meta.json`) are returned, so pointing a project at a
    /// folder with unrelated subfolders never lists them as calls.
    public func listCalls() throws -> [CallFolder] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let hasMeta = FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("meta.json").path)
                return isDir && hasMeta
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(CallFolder.init(url:))
    }

    /// Delete a call's entire folder — audio, transcript, summary, meta.json and
    /// the hidden `.cache/` — recursively, leaving nothing behind.
    public func delete(_ folder: CallFolder) throws {
        try FileManager.default.removeItem(at: folder.url)
    }

    /// Move a call's folder into another store (= another project), keeping
    /// its name; a name collision in the destination gets the same numeric
    /// suffix a colliding recording would. Everything the call owns travels
    /// with the folder — audio, transcript, meta.json, `.cache/`.
    @discardableResult
    public func move(_ folder: CallFolder, to destination: CallStore) throws -> CallFolder {
        try FileManager.default.createDirectory(
            at: destination.rootURL, withIntermediateDirectories: true)
        let base = folder.url.lastPathComponent
        var candidate = destination.rootURL.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = destination.rootURL.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        try FileManager.default.moveItem(at: folder.url, to: candidate)
        return CallFolder(url: candidate)
    }
}
