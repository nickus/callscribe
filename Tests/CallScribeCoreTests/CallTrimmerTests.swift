import Foundation
import Testing
@testable import CallScribeCore

/// A call folder with both tracks, a populated cache, rendered markdown, and a
/// fully-processed meta carrying the user's own edits.
private func makeProcessedCall(seconds: Int = 4) throws -> CallFolder {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("calltrimmer-test-\(UUID().uuidString)")
    let folder = CallFolder(url: root)
    try fileManager.createDirectory(at: folder.cacheDir, withIntermediateDirectories: true)

    for wav in [folder.micWAV, folder.systemWAV] {
        let writer = try WAVWriter(url: wav, sampleRate: 16000)
        try writer.append([Int16](repeating: 1234, count: 16000 * seconds))
        try writer.finalize()
    }
    try Data("transcript".utf8).write(to: folder.transcriptMD)
    try Data("summary".utf8).write(to: folder.summaryMD)
    for artifact in [
        folder.micCleanWAV, folder.whisperMicJSON, folder.whisperSystemJSON,
        folder.diarizationJSON, folder.turnsJSON,
    ] {
        try Data("stale".utf8).write(to: artifact)
    }

    var meta = CallMeta(startedAt: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "test")
    meta.durationSec = Double(seconds)
    meta.title = "Launch planning sync"
    meta.speakerNames = ["Speaker 1": "Misha"]
    meta.expectedSpeakers = 2
    meta.language = "ru"
    meta.pipeline.echoCanceled = true
    meta.pipeline.transcribed = true
    meta.pipeline.diarized = true
    meta.pipeline.merged = true
    meta.pipeline.summarized = true
    try folder.saveMeta(meta)
    return folder
}

@Test func trimShortensBothTracks() throws {
    let folder = try makeProcessedCall()
    defer { try? FileManager.default.removeItem(at: folder.url) }

    let duration = try CallTrimmer.trim(folder, from: 0, to: 2.5)
    #expect(abs(duration - 2.5) < 0.001)
    #expect(WAVTrim.duration(of: folder.micWAV) == 2.5)
    #expect(WAVTrim.duration(of: folder.systemWAV) == 2.5)
}

@Test func trimDropsEverythingDerivedFromTheOldAudio() throws {
    let folder = try makeProcessedCall()
    defer { try? FileManager.default.removeItem(at: folder.url) }

    try CallTrimmer.trim(folder, from: 1, to: 3)

    let fileManager = FileManager.default
    #expect(!fileManager.fileExists(atPath: folder.cacheDir.path))
    #expect(!fileManager.fileExists(atPath: folder.transcriptMD.path))
    #expect(!fileManager.fileExists(atPath: folder.summaryMD.path))

    let meta = try folder.loadMeta()
    #expect(meta.pipeline == CallMeta.PipelineState())   // every flag back to false
}

@Test func trimUpdatesDurationAndEnd() throws {
    let folder = try makeProcessedCall()
    defer { try? FileManager.default.removeItem(at: folder.url) }

    try CallTrimmer.trim(folder, from: 0.5, to: 2.5)
    let meta = try folder.loadMeta()
    #expect(meta.durationSec == 2.0)
    #expect(meta.endedAt == meta.startedAt.addingTimeInterval(2.0))
}

@Test func trimKeepsTheUsersOwnEdits() throws {
    let folder = try makeProcessedCall()
    defer { try? FileManager.default.removeItem(at: folder.url) }

    try CallTrimmer.trim(folder, from: 0, to: 2)
    let meta = try folder.loadMeta()
    #expect(meta.title == "Launch planning sync")
    #expect(meta.speakerNames == ["Speaker 1": "Misha"])
    #expect(meta.expectedSpeakers == 2)
    #expect(meta.language == "ru")
}

@Test func trimWorksWithOnlyOneTrackPresent() throws {
    let folder = try makeProcessedCall()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    try FileManager.default.removeItem(at: folder.systemWAV)

    let duration = try CallTrimmer.trim(folder, from: 0, to: 1.5)
    #expect(abs(duration - 1.5) < 0.001)
    #expect(WAVTrim.duration(of: folder.micWAV) == 1.5)
}
