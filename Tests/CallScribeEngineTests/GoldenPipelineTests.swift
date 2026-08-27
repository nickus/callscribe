import Foundation
import Testing
@testable import CallScribeCore
@testable import CallScribeEngine

/// End-to-end pipeline regression on a committed two-track ru+en fixture.
///
/// Opt-in: needs the Whisper + diarization models downloaded (`callscribe
/// setup`) and is slow, so it only runs when CALLSCRIBE_GOLDEN=1. Assertions
/// are deliberately fuzzy — Whisper output drifts across model versions, so we
/// check structural properties, not exact strings.
///
/// The committed fixture is SYNTHETIC (macOS `say`: ru+en mic, two TTS voices
/// on the system track). It proves the pipeline runs end-to-end on real ML —
/// but note two limits it exposes: FluidAudio does not reliably separate the
/// two TTS voices (they cluster as one speaker — TTS voices sit too close in
/// embedding space), and Whisper renders the English mic intro as Russian
/// (the ru+en code-switching limitation). For genuine multi-speaker validation,
/// replace the fixture with a REAL recording made via `callscribe record`
/// (see scripts/smoke.md) — hence the assertions below are structural, not
/// speaker-count-based.
private struct MockSummarizer: Summarizer {
    let result: SummaryResult
    func summarize(transcript: String, projectContext: String?) async throws -> SummaryResult { result }
}

/// Runs the full pipeline on a throwaway copy of the fixture and asserts the
/// engine-independent structural properties. Shared by the Whisper and
/// Parakeet golden suites.
private func runGoldenPipeline(engine: STTEngine) async throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/golden-call")
    try #require(
        FileManager.default.fileExists(atPath: fixture.appendingPathComponent("system.wav").path),
        "record the golden fixture first (see scripts/smoke.md)"
    )

    // Work on a throwaway copy so the fixture stays clean.
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("golden-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    for name in ["mic.wav", "system.wav"] {
        try FileManager.default.copyItem(
            at: fixture.appendingPathComponent(name),
            to: work.appendingPathComponent(name)
        )
    }
    let folder = CallFolder(url: work)
    var meta = CallMeta(startedAt: Date(timeIntervalSince1970: 0), appVersion: "test")
    try folder.saveMeta(meta)

    let runner = PipelineRunner(
        folder: folder,
        modelsDir: try AppPaths.ensureModelsDirectory(),
        summarizer: MockSummarizer(result: SummaryResult(markdown: "## Summary\nmock", speakerNames: [:])),
        engine: engine
    )
    try await runner.run()

    let transcript = try String(contentsOf: folder.transcriptMD, encoding: .utf8)
    #expect(!transcript.isEmpty)
    #expect(transcript.contains("Me:"), "mic track should be attributed to Me")
    #expect(transcript.contains("Speaker") || transcript.contains("Participant"),
            "system track should be attributed to a remote speaker")

    // Utterances must be time-ordered.
    let times = transcript
        .split(separator: "\n")
        .compactMap { line -> Int? in
            guard let m = line.firstMatch(of: /\[(\d\d):(\d\d):(\d\d)\]/) else { return nil }
            return Int(m.1)! * 3600 + Int(m.2)! * 60 + Int(m.3)!
        }
    #expect(times == times.sorted(), "timecodes should be non-decreasing")

    meta = try folder.loadMeta()
    #expect(meta.pipeline.transcribed && meta.pipeline.merged)
    #expect(meta.whisperModel == engine.modelName)
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CALLSCRIBE_GOLDEN"] == "1"))
struct GoldenPipelineTests {
    @Test func pipelineProducesInterleavedSpeakerTranscript() async throws {
        try await runGoldenPipeline(engine: .whisper)
    }
}

/// Separate gate: needs the Parakeet models (`callscribe setup --engine
/// parakeet`), which CALLSCRIBE_GOLDEN alone doesn't promise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CALLSCRIBE_GOLDEN_PARAKEET"] == "1"))
struct GoldenParakeetPipelineTests {
    @Test func parakeetPipelineProducesInterleavedSpeakerTranscript() async throws {
        try await runGoldenPipeline(engine: .parakeet)
    }
}
