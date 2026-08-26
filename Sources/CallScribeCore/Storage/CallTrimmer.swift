import Foundation

/// Shortens a recorded call to a time range and invalidates everything derived
/// from the old audio, so the normal pipeline re-runs from scratch. The user's
/// own corrections (title, speaker names, expected speaker count) survive.
public enum CallTrimmer {
    /// Trim both tracks to `[start, end)` and drop every derived artifact.
    /// Returns the new duration. Destructive: the discarded audio is gone.
    @discardableResult
    public static func trim(
        _ folder: CallFolder,
        from start: TimeInterval,
        to end: TimeInterval
    ) throws -> TimeInterval {
        let fileManager = FileManager.default
        var duration: TimeInterval = 0
        // Either track may be absent (mic-only or system-only recordings).
        for wav in [folder.micWAV, folder.systemWAV] where fileManager.fileExists(atPath: wav.path) {
            duration = max(duration, try WAVTrim.trim(wav, from: start, to: end))
        }

        // Everything below describes audio that no longer exists. A stale
        // summary left behind by a failed re-run would be worse than none.
        try? fileManager.removeItem(at: folder.cacheDir)
        try? fileManager.removeItem(at: folder.transcriptMD)
        try? fileManager.removeItem(at: folder.summaryMD)

        var meta = try folder.loadMeta()
        meta.pipeline = CallMeta.PipelineState()
        meta.durationSec = duration
        meta.endedAt = meta.startedAt.addingTimeInterval(duration)
        // LLM speaker corrections are keyed by timecode; the trim just shifted
        // every timestamp, so they'd match the wrong turns (or none).
        meta.speakerCorrections = nil
        // Deliberately kept: title, speakerNames, expectedSpeakers, language —
        // the user set those, and a trim shouldn't undo their work.
        try folder.saveMeta(meta)

        return duration
    }
}
