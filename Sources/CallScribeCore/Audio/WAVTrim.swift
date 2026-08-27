import Foundation

public enum WAVTrimError: Error, Equatable {
    /// Not a RIFF/WAVE file, or its chunk table is truncated.
    case notAWAVFile(String)
    /// Only the 16-bit mono PCM our recorder writes can be trimmed byte-wise.
    case unsupportedFormat(String)
    /// The requested range keeps no audio at all.
    case emptyRange
}

/// Trims a 16 kHz mono Int16 WAV to a time range by copying the raw sample
/// bytes — no decode, no float round-trip, no whole-file load. Our recordings
/// always come from `WAVWriter`, so the kept audio is bit-identical to the
/// original; anything else is rejected rather than silently mangled.
public enum WAVTrim {
    /// Rewrite `url` in place, keeping only `[start, end)` seconds. Returns the
    /// resulting duration. `end` past the recording is clamped, and a range that
    /// already covers the whole file leaves it untouched.
    @discardableResult
    public static func trim(_ url: URL, from start: TimeInterval, to end: TimeInterval) throws -> TimeInterval {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let layout = try Self.layout(of: handle, path: url.path)
        let bytesPerFrame = 2                        // mono, 16-bit
        let bytesPerSecond = Double(layout.sampleRate * UInt32(bytesPerFrame))

        /// Seconds → an offset inside the data chunk, snapped to a frame
        /// boundary and clamped to the audio actually present.
        func offset(_ seconds: TimeInterval) -> Int {
            let raw = Int((max(0, seconds) * bytesPerSecond).rounded(.down))
            return min(raw - raw % bytesPerFrame, layout.dataSize)
        }

        let from = offset(start)
        let to = max(from, offset(end))
        let keptBytes = to - from
        guard keptBytes >= bytesPerFrame else { throw WAVTrimError.emptyRange }

        // Nothing to cut — don't rewrite the file for a no-op.
        guard keptBytes < layout.dataSize else {
            return TimeInterval(layout.dataSize) / bytesPerSecond
        }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).trim-\(UUID().uuidString)")
        try Data(WAVWriter.header(sampleRate: layout.sampleRate, dataBytes: UInt32(keptBytes)))
            .write(to: temp, options: .atomic)

        let out = try FileHandle(forWritingTo: temp)
        try out.seekToEnd()
        try handle.seek(toOffset: UInt64(layout.dataOffset + from))
        var remaining = keptBytes
        while remaining > 0 {
            let chunk = min(remaining, 1 << 20)      // 1 MB at a time
            guard let data = try handle.read(upToCount: chunk), !data.isEmpty else { break }
            try out.write(contentsOf: data)
            remaining -= data.count
        }
        try out.close()

        // Atomic swap, so an interrupted trim can never leave a half-written WAV.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        return TimeInterval(keptBytes) / bytesPerSecond
    }

    /// Duration of a WAV in seconds, from its header (0 if unreadable).
    public static func duration(of url: URL) -> TimeInterval {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let layout = try? Self.layout(of: handle, path: url.path) else { return 0 }
        return TimeInterval(layout.dataSize) / TimeInterval(layout.sampleRate * 2)
    }

    // MARK: - RIFF parsing

    private struct Layout {
        let sampleRate: UInt32
        let dataOffset: Int
        let dataSize: Int
    }

    /// Walk the chunk table for `fmt ` (validating the format) and `data`.
    /// Chunk sizes are honoured rather than assuming the canonical 44-byte
    /// header, so files carrying extra chunks still parse.
    private static func layout(of handle: FileHandle, path: String) throws -> Layout {
        guard let riff = try handle.read(upToCount: 12), riff.count == 12,
              riff.prefix(4).elementsEqual(Array("RIFF".utf8)),
              riff.suffix(4).elementsEqual(Array("WAVE".utf8))
        else { throw WAVTrimError.notAWAVFile(path) }

        var sampleRate: UInt32?
        while let header = try handle.read(upToCount: 8), header.count == 8 {
            let id = String(bytes: header.prefix(4), encoding: .utf8) ?? ""
            let size = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
            let bodyStart = try handle.offset()

            switch id {
            case "fmt ":
                guard let fmt = try handle.read(upToCount: min(size, 16)), fmt.count >= 16 else {
                    throw WAVTrimError.notAWAVFile(path)
                }
                let format = fmt.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
                let channels = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self) }
                let rate = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
                let bits = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: UInt16.self) }
                guard format == 1, channels == 1, bits == 16 else {
                    throw WAVTrimError.unsupportedFormat(
                        "expected 16-bit mono PCM, got format \(format), \(channels)ch, \(bits)-bit")
                }
                sampleRate = rate

            case "data":
                guard let rate = sampleRate else { throw WAVTrimError.notAWAVFile(path) }
                // Clamp the declared size to what's actually on disk, so a
                // truncated file can't make us read past EOF.
                let onDisk = Int(try handle.seekToEnd()) - Int(bodyStart)
                return Layout(sampleRate: rate, dataOffset: Int(bodyStart), dataSize: max(0, min(size, onDisk)))

            default:
                break
            }

            // Chunks are word-aligned: an odd size is followed by a pad byte.
            try handle.seek(toOffset: UInt64(Int(bodyStart) + size + (size % 2)))
        }
        throw WAVTrimError.notAWAVFile(path)
    }
}
