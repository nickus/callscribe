import CallScribeCore
import FluidAudio
import Foundation

/// Applies the user's per-utterance name annotations to a processed call:
/// embeds every diarization span once, resolves each annotation to the span
/// under it, lets `SpanRelabeler` reassign every span (annotations are ground
/// truth), writes the renamed spans back to diarization.json, and upserts the
/// voice library so FUTURE calls recognize these people automatically. The
/// caller re-merges afterwards — named spans flow into the transcript as
/// `.named` speakers.
public enum VoiceRelabeler {
    /// One "this utterance is `name`" mark from the transcript view.
    public struct Annotation: Sendable, Equatable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let name: String

        public init(start: TimeInterval, end: TimeInterval, name: String) {
            self.start = start
            self.end = end
            self.name = name
        }
    }

    public enum RelabelError: Error, LocalizedError {
        case noDiarization
        case noAudio
        case annotationsNotFound

        public var errorDescription: String? {
            switch self {
            case .noDiarization: "This call has no speaker data to relabel — run speaker detection first."
            case .noAudio: "The call's system audio is missing."
            case .annotationsNotFound: "None of the labeled turns matched a detected speaker segment."
            }
        }
    }

    /// The embedding model wants 1–10 s of audio; short spans are padded
    /// around their center from the surrounding recording.
    private static let sampleRate = 16000
    private static let minSamples = 16_000
    private static let maxSamples = 160_000

    public static func apply(
        annotations: [Annotation],
        in folder: CallFolder,
        modelDirectory: URL
    ) async throws {
        guard !annotations.isEmpty else { return }
        guard let data = try? Data(contentsOf: folder.diarizationJSON),
              let spans = try? JSONDecoder().decode([SpeakerSpan].self, from: data),
              !spans.isEmpty
        else { throw RelabelError.noDiarization }

        let samples = try AudioFileLoader.loadMono16k(folder.systemWAV)
        guard !samples.isEmpty else { throw RelabelError.noAudio }

        let models = try await DiarizerModels.downloadIfNeeded(to: modelDirectory)
        let manager = DiarizerManager()
        manager.initialize(models: models)

        // The turns the user annotated were rendered from REFINED boundaries
        // (word-gap snapping in the merge); resolving against raw spans would
        // let a short reply near a boundary ground-truth-name the wrong
        // cluster. Refine the same way, then resolve — splitting any span
        // that got two different names (a speaker change the diarizer missed).
        let refined = refinedSpans(spans, folder: folder)
        let (workSpans, assignments) = SpanRelabeler.resolve(
            spans: refined,
            marks: annotations.map { .init(start: $0.start, end: $0.end, name: $0.name) }
        )
        guard !assignments.isEmpty else { throw RelabelError.annotationsNotFound }
        if assignments.count < annotations.count {
            Log.shared.warn(
                "relabel: \(annotations.count - assignments.count) mark(s) matched no speaker segment")
        }

        // Every span embedded once — both the annotated ones (the evidence)
        // and the rest (what the evidence is compared against).
        let embeddings: [[Float]?] = workSpans.map { span in
            embedding(of: span.start, to: span.end, in: samples, manager: manager)
        }

        let relabeled = SpanRelabeler.relabel(
            spans: workSpans, embeddings: embeddings, assignments: assignments)
        try JSONEncoder().encode(relabeled).write(to: folder.diarizationJSON, options: .atomic)

        // The relabel itself succeeded; failing to persist voices for FUTURE
        // calls shouldn't abort it.
        var learned: Set<String> = []
        do {
            learned = try learnVoices(
                assignments: assignments, spans: workSpans, embeddings: embeddings, audio: samples)
        } catch {
            Log.shared.warn("relabel: voices not saved: \(Log.truncated(error.localizedDescription))")
        }
        let unlearned = Set(assignments.map(\.name)).subtracting(learned)
        if !unlearned.isEmpty {
            Log.shared.warn("""
                relabel: could not learn \(unlearned.count) voice(s) — \
                the marked audio was too short to fingerprint
                """)
        }
        Log.shared.info("""
            relabel: \(annotations.count) mark(s) applied, \(learned.count) voice(s) learned, \
            \(workSpans.count) span(s) relabeled
            """)
    }

    /// The same boundary refinement the merge applies before rendering turns.
    private static func refinedSpans(_ spans: [SpeakerSpan], folder: CallFolder) -> [SpeakerSpan] {
        guard let data = try? Data(contentsOf: folder.whisperSystemJSON),
              let track = try? JSONDecoder().decode(TrackTranscription.self, from: data)
        else { return spans }
        let words = track.words
            .filter { $0.end > $0.start }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        return TranscriptMerger.refineSpanBoundaries(spans, systemWords: words, config: MergeConfig())
    }

    /// Remember each voice for future calls from ONLY the spans the user
    /// marked — never from propagated labels. The user's annotations are
    /// training data; automatic inferences are not, so a wrong inheritance
    /// can never poison a profile. A single call contributes few spans, but
    /// every Apply BLENDS into the existing profile (VoiceStore.reinforce),
    /// so recognition converges across calls from manual marks alone.
    /// The longest marked span becomes the audible sample on the People screen.
    @discardableResult
    private static func learnVoices(
        assignments: [SpanRelabeler.Assignment],
        spans: [SpeakerSpan],
        embeddings: [[Float]?],
        audio: [Float]
    ) throws -> Set<String> {
        var sums: [String: [Float]] = [:]
        var longestSpan: [String: SpeakerSpan] = [:]
        for assignment in assignments {
            let span = spans[assignment.spanIndex]
            let name = assignment.name
            if let best = longestSpan[name] {
                if span.end - span.start > best.end - best.start {
                    longestSpan[name] = span
                }
            } else {
                longestSpan[name] = span
            }
            guard let embedding = embeddings[assignment.spanIndex] else { continue }
            let weight = Float(max(span.end - span.start, 0.001))
            var sum = sums[name] ?? [Float](repeating: 0, count: embedding.count)
            for i in embedding.indices where i < sum.count { sum[i] += embedding[i] * weight }
            sums[name] = sum
        }
        let store = VoiceStore()
        for (name, sum) in sums {
            _ = try store.reinforce(name: name, embedding: sum)
            if let span = longestSpan[name] {
                let lo = max(0, Int(span.start * Double(sampleRate)))
                let hi = min(audio.count, min(lo + maxSamples, Int(span.end * Double(sampleRate))))
                if hi > lo {
                    try? store.saveSample(VoiceEnroller.pcm16(Array(audio[lo..<hi])), forName: name)
                }
            }
        }
        return Set(sums.keys)
    }

    /// Embedding of `[start, end]`, padded to the model's 1 s minimum evenly
    /// around the range — spilling to the other side at a file edge — and
    /// capped at its 10 s window. nil only when the whole file is too short.
    private static func embedding(
        of start: TimeInterval,
        to end: TimeInterval,
        in samples: [Float],
        manager: DiarizerManager
    ) -> [Float]? {
        var lo = max(0, Int(start * Double(Self.sampleRate)))
        var hi = min(samples.count, Int(end * Double(Self.sampleRate)))
        guard hi > lo else { return nil }
        if hi - lo < minSamples {
            let missing = minSamples - (hi - lo)
            let leftRoom = lo
            let rightRoom = samples.count - hi
            var left = min(missing / 2, leftRoom)
            let right = min(missing - left, rightRoom)
            left = min(leftRoom, missing - right)   // spill what the right lacked
            lo -= left
            hi += right
        }
        if hi - lo > maxSamples { hi = lo + maxSamples }
        guard hi - lo >= minSamples else { return nil }
        return try? manager.extractSpeakerEmbedding(from: Array(samples[lo..<hi]))
    }
}
