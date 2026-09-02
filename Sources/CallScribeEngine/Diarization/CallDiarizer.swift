import CallScribeCore
import Foundation
import SpeakerKit

/// Diarizes the system track with pyannote community-1 (Argmax SpeakerKit,
/// fully on-device CoreML): powerset segmentation → WeSpeaker embeddings →
/// VBx clustering — the best open cascaded pipeline per our 2026 research
/// (DER 20.2% on DIHARD III), replacing the previous-generation FluidAudio
/// models that merged quiet participants into the dominant cluster. The
/// exact-count hint constrains the clustering itself, so "8 people were on
/// this call" finally means something.
///
/// Voice-library matching stays in the FluidAudio embedding space the library
/// was built in (see VoiceEmbedding): cluster centroids are re-embedded per
/// call, so existing profiles keep working unchanged.
///
/// Diarization must never take down the pipeline: any failure is reported as
/// an empty span list so the merge falls back to `Participant`.
public enum CallDiarizer {
    /// Diarize a 16 kHz mono WAV. Returns time-ranged speaker clusters, or an
    /// empty array if diarization could not run.
    public static func diarize(
        wav url: URL,
        modelDirectory: URL,
        knownVoices: [VoiceProfile] = [],
        expectedSpeakers: Int? = nil
    ) async -> [SpeakerSpan] {
        do {
            let samples = try AudioFileLoader.loadMono16k(url)
            guard samples.count >= 16000 else { return [] }

            // No verbose/logLevel here: only SpeakerKit.init would apply them
            // to the shared logger, and this path never constructs it — the
            // logger's own default is silent, which is what we want.
            let config = PyannoteConfig(downloadBase: modelDirectory.path)
            let manager = SpeakerKitDiarizer.pyannote(config: config)
            try await manager.ensureModelsLoaded()

            let options = PyannoteDiarizationOptions(
                numberOfSpeakers: (expectedSpeakers ?? 0) > 0 ? expectedSpeakers : nil
            )
            let result = try await manager.diarize(
                audioArray: samples, options: options, progressCallback: nil)

            let clusters = spans(from: result.segments)
            return await labeled(
                clusters, samples: samples,
                voices: knownVoices, modelDirectory: modelDirectory)
        } catch {
            Log.shared.warn("diarize: SpeakerKit failed: \(Log.truncated(error.localizedDescription))")
            return []
        }
    }

    /// SpeakerKit segments → engine-agnostic spans. Only concrete speaker ids
    /// become clusters. The pipeline we run (exclusive reconciliation on)
    /// emits `.speakerId` exclusively; the `.noMatch`/`.multiple` drops are a
    /// backstop for other SpeakerKit flows, not an overlap-handling decision.
    static func spans(from segments: [SpeakerSegment]) -> [SpeakerSpan] {
        segments.compactMap { segment in
            guard case .speakerId(let id) = segment.speaker else { return nil }
            let start = TimeInterval(segment.startTime)
            let end = TimeInterval(segment.endTime)
            guard end > start else { return nil }
            return SpeakerSpan(speakerID: "S\(id)", start: start, end: end)
        }
        .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Label clusters from the voice library: duration-weighted FluidAudio
    /// centroid per cluster → strict close-and-unambiguous matching.
    private static func labeled(
        _ spans: [SpeakerSpan],
        samples: [Float],
        voices: [VoiceProfile],
        modelDirectory: URL
    ) async -> [SpeakerSpan] {
        guard !voices.isEmpty, !spans.isEmpty else { return spans }
        guard let manager = try? await VoiceEmbedding.makeManager(modelDirectory: modelDirectory)
        else { return spans }
        let centroids = VoiceEmbedding.clusterCentroids(
            spans: spans, samples: samples, manager: manager)
        let names = VoiceMatcher.assign(centroids: centroids, voices: voices)
        guard !names.isEmpty else { return spans }
        return spans.map { span in
            guard let name = names[span.speakerID] else { return span }
            return SpeakerSpan(speakerID: span.speakerID, start: span.start, end: span.end, name: name)
        }
    }
}
