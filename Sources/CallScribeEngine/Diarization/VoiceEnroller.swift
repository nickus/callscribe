import CallScribeCore
import FluidAudio
import Foundation

/// Learns a voice "fingerprint" for one speaker in a processed call, so future
/// calls can recognise them. Sources the sample from that speaker's own
/// utterances (from turns.json) cut out of the system track, then runs
/// FluidAudio's embedding model — the same one diarization already uses.
public enum VoiceEnroller {
    public enum EnrollError: Error, LocalizedError {
        case noSpeechForSpeaker
        case noAudio

        public var errorDescription: String? {
            switch self {
            case .noSpeechForSpeaker: "Not enough of this speaker's audio to learn their voice."
            case .noAudio: "The call's system audio is missing."
            }
        }
    }

    /// Up to 10 s (the embedding model's window) sampled from the speaker's
    /// longest utterances (cleanest, most single-speaker).
    private static let maxSamples = 160_000   // 10 s @ 16 kHz
    private static let minSamples = 16_000    // need at least 1 s

    /// `speakerLabel` is the canonical label as it appears in `turns.json`
    /// ("Speaker 2", "Me" — though "Me" is never enrolled). Returns the
    /// fingerprint plus the audio clip it was computed from — the clip becomes
    /// the person's sample on the People screen.
    public static func learn(
        speakerLabel: String,
        in folder: CallFolder,
        modelDirectory: URL
    ) async throws -> (embedding: [Float], sample: [Int16]) {
        let data = try Data(contentsOf: folder.turnsJSON)
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)
        let ranges = transcript.utterances
            .filter { $0.speaker.label == speakerLabel }
            .map { (start: $0.start, end: $0.end) }
            .sorted { ($0.end - $0.start) > ($1.end - $1.start) }   // longest first
        guard !ranges.isEmpty else { throw EnrollError.noSpeechForSpeaker }

        let samples = try AudioFileLoader.loadMono16k(folder.systemWAV)
        guard !samples.isEmpty else { throw EnrollError.noAudio }

        var clip: [Float] = []
        for range in ranges {
            let lo = max(0, Int(range.start * 16000))
            let hi = min(samples.count, Int(range.end * 16000))
            if hi > lo { clip.append(contentsOf: samples[lo..<hi]) }
            if clip.count >= maxSamples { break }
        }
        if clip.count > maxSamples { clip = Array(clip[0..<maxSamples]) }
        guard clip.count >= minSamples else { throw EnrollError.noSpeechForSpeaker }

        let models = try await DiarizerModels.downloadIfNeeded(to: modelDirectory)
        let manager = DiarizerManager()
        manager.initialize(models: models)
        let embedding = try manager.extractSpeakerEmbedding(from: clip)
        return (embedding, pcm16(clip))
    }

    /// Float [-1, 1] → Int16 PCM for the WAV sample.
    static func pcm16(_ clip: [Float]) -> [Int16] {
        clip.map { Int16(max(-1, min(1, $0)) * 32767) }
    }
}
