import Foundation
import Testing
@testable import CallScribeCore

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("callstore-test-\(UUID().uuidString)")
}

@Test func createCallFolderNamesByStartTime() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CallStore(rootURL: root)

    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let folder = try store.createCallFolder(startedAt: date)
    #expect(FileManager.default.fileExists(atPath: folder.url.path))
    // Exact name depends on local timezone; the shape must hold.
    #expect(folder.name.wholeMatch(of: /\d{4}-\d{2}-\d{2}_\d{2}-\d{2}/) != nil)

    // Same start minute → deduplicated with a suffix.
    let second = try store.createCallFolder(startedAt: date)
    #expect(second.name == "\(folder.name)-2")
}

@Test func listCallsReturnsNewestFirst() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CallStore(rootURL: root)

    for name in ["2026-07-10_09-00", "2026-07-14_15-30", "2026-01-02_08-15"] {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("meta.json"))
    }
    // Stray files and non-call folders are ignored.
    try Data().write(to: root.appendingPathComponent(".DS_Store"))
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("unrelated-folder"), withIntermediateDirectories: true)

    let calls = try store.listCalls()
    #expect(calls.map(\.name) == ["2026-07-14_15-30", "2026-07-10_09-00", "2026-01-02_08-15"])
}

@Test func listCallsOnMissingRootIsEmpty() throws {
    let store = CallStore(rootURL: tempRoot())
    #expect(try store.listCalls().isEmpty)
}

@Test func deleteRemovesTheWholeFolderIncludingCache() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CallStore(rootURL: root)
    let folder = try store.createCallFolder(startedAt: Date(timeIntervalSince1970: 1_790_000_000))

    // Populate like a finished call: top-level files + hidden .cache subfolder.
    try Data("audio".utf8).write(to: folder.micWAV)
    try Data("audio".utf8).write(to: folder.systemWAV)
    try Data("# t".utf8).write(to: folder.transcriptMD)
    try FileManager.default.createDirectory(at: folder.cacheDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: folder.whisperMicJSON)

    try store.delete(folder)

    #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    #expect(try store.listCalls().isEmpty)
}

@Test func moveCarriesTheWholeFolderToTheOtherStore() throws {
    let sourceRoot = tempRoot(), targetRoot = tempRoot()
    defer {
        try? FileManager.default.removeItem(at: sourceRoot)
        try? FileManager.default.removeItem(at: targetRoot)
    }
    let source = CallStore(rootURL: sourceRoot)
    let target = CallStore(rootURL: targetRoot)   // root doesn't exist yet — move creates it
    let folder = try source.createCallFolder(startedAt: Date(timeIntervalSince1970: 1_790_000_000))
    try Data("{}".utf8).write(to: folder.url.appendingPathComponent("meta.json"))
    try Data("audio".utf8).write(to: folder.micWAV)
    try FileManager.default.createDirectory(at: folder.cacheDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: folder.whisperMicJSON)

    let moved = try source.move(folder, to: target)

    #expect(moved.name == folder.name)
    #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    #expect(FileManager.default.fileExists(atPath: moved.micWAV.path))
    #expect(FileManager.default.fileExists(atPath: moved.whisperMicJSON.path))
    #expect(try source.listCalls().isEmpty)
    #expect(try target.listCalls().map(\.name) == [moved.name])
}

@Test func moveIntoANameCollisionGetsASuffix() throws {
    let sourceRoot = tempRoot(), targetRoot = tempRoot()
    defer {
        try? FileManager.default.removeItem(at: sourceRoot)
        try? FileManager.default.removeItem(at: targetRoot)
    }
    let source = CallStore(rootURL: sourceRoot)
    let target = CallStore(rootURL: targetRoot)
    let folder = try source.createCallFolder(startedAt: Date(timeIntervalSince1970: 1_790_000_000))
    try Data("{}".utf8).write(to: folder.url.appendingPathComponent("meta.json"))
    // The same minute already exists in the target project.
    try FileManager.default.createDirectory(
        at: targetRoot.appendingPathComponent(folder.name), withIntermediateDirectories: true)

    let moved = try source.move(folder, to: target)
    #expect(moved.name == "\(folder.name)-2")
}

@Test func metaRoundTrip() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CallStore(rootURL: root)
    let folder = try store.createCallFolder(startedAt: Date(timeIntervalSince1970: 1_790_000_000))

    var meta = CallMeta(startedAt: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "0.1.0")
    meta.endedAt = Date(timeIntervalSince1970: 1_790_000_600)
    meta.durationSec = 600
    meta.speakerNames = ["Speaker 1": "Misha"]
    meta.pipeline.transcribed = true
    try folder.saveMeta(meta)

    let loaded = try folder.loadMeta()
    #expect(loaded == meta)
}
