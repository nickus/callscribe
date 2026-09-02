import Foundation

/// Persists learned voices (`VoiceProfile`) in a small JSON file under
/// Application Support. One global library shared across projects — enroll a
/// person once and every future call can recognise them.
public final class VoiceStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("CallScribe/voices.json")
        }
    }

    public func load() -> [VoiceProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let voices = try? decoder.decode([VoiceProfile].self, from: data)
        else { return [] }
        return voices
    }

    public func save(_ voices: [VoiceProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(voices).write(to: fileURL, options: .atomic)
    }

    /// Add or replace a voice, matching by case-insensitive name (re-enrolling a
    /// person updates their fingerprint rather than duplicating them).
    @discardableResult
    public func upsert(_ voice: VoiceProfile) throws -> [VoiceProfile] {
        var voices = load()
        if let i = voices.firstIndex(where: { $0.name.caseInsensitiveCompare(voice.name) == .orderedSame }) {
            voices[i] = voice
        } else {
            voices.append(voice)
        }
        try save(voices)
        return voices
    }

    /// Blend a fresh voice observation into the existing profile (or create
    /// one): an equal-weight blend of L2-normalized embeddings. Every marked
    /// call refines the fingerprint toward how the person sounds ACROSS
    /// calls and channels — replacing outright made profiles channel-specific,
    /// which is why recognition across calls kept missing.
    @discardableResult
    public func reinforce(name: String, embedding: [Float]) throws -> [VoiceProfile] {
        let voices = load()
        guard let existing = voices.first(
            where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
            existing.embedding.count == embedding.count
        else {
            return try upsert(VoiceProfile(name: name, embedding: embedding))
        }
        let blended = zip(Self.normalize(existing.embedding), Self.normalize(embedding))
            .map { ($0 + $1) / 2 }
        return try upsert(VoiceProfile(
            id: existing.id, name: existing.name, embedding: blended, createdAt: existing.createdAt))
    }

    static func normalize(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Remove the voice with this name (case-insensitive), sample included.
    @discardableResult
    public func removeVoice(named name: String) throws -> [VoiceProfile] {
        var voices = load()
        voices.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        try save(voices)
        try? FileManager.default.removeItem(at: sampleURL(forName: name))
        return voices
    }

    // MARK: - Voice samples (for the People screen)

    /// A short WAV of this person's voice, saved when their voice is learned.
    /// Keyed by name slug — re-learning replaces the sample, like the profile.
    public func sampleURL(forName name: String) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("voice-samples/\(Project.folderSlug(name)).wav")
    }

    public func hasSample(forName name: String) -> Bool {
        FileManager.default.fileExists(atPath: sampleURL(forName: name).path)
    }

    /// Save a 16 kHz mono sample for this voice, replacing any older one.
    public func saveSample(_ samples: [Int16], forName name: String) throws {
        let url = sampleURL(forName: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let writer = try WAVWriter(url: url)
        try writer.append(samples)
        try writer.finalize()
    }
}
