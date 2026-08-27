import Foundation
import Testing
@testable import CallScribeCore

private func tempWAV() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("wavwriter-test-\(UUID().uuidString).wav")
}

private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
}

@Test func finalizedFileHasCorrectHeader() throws {
    let url = tempWAV()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try WAVWriter(url: url, sampleRate: 16000)
    let samples = [Int16](repeating: 1000, count: 1600)  // 0.1 s
    try writer.append(samples)
    try writer.finalize()

    let data = try Data(contentsOf: url)
    #expect(data.count == 44 + 3200)
    #expect(String(bytes: data.prefix(4), encoding: .utf8) == "RIFF")
    #expect(String(bytes: data.subdata(in: 8..<12), encoding: .utf8) == "WAVE")
    #expect(readUInt32LE(data, at: 4) == 36 + 3200)   // RIFF chunk size
    #expect(readUInt32LE(data, at: 24) == 16000)       // sample rate
    #expect(readUInt32LE(data, at: 40) == 3200)        // data chunk size
}

@Test func headerIsPatchedPeriodicallyWithoutFinalize() throws {
    // Simulates a crash: never call finalize(); the periodic patch must still
    // have produced a header covering (almost) all written audio.
    let url = tempWAV()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try WAVWriter(url: url, sampleRate: 16000)
    // 6 s of audio in 0.5 s chunks crosses the 5 s patch threshold.
    for _ in 0..<12 {
        try writer.append([Int16](repeating: 42, count: 8000))
    }
    // No finalize — abandon the writer (handle stays open; data is on disk).

    let data = try Data(contentsOf: url)
    let declared = readUInt32LE(data, at: 40)
    #expect(declared >= 16000 * 2 * 5, "header should cover at least the first 5 s")
    #expect(data.count == 44 + 12 * 16000)
}

@Test func durationTracksWrittenSamples() throws {
    let url = tempWAV()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try WAVWriter(url: url, sampleRate: 16000)
    try writer.append([Int16](repeating: 0, count: 16000))
    #expect(abs(writer.duration - 1.0) < 0.001)
    try writer.finalize()
}
