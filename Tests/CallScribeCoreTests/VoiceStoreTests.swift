import Foundation
import Testing
@testable import CallScribeCore

@Suite struct VoiceReinforceTests {
    private func store() -> VoiceStore {
        VoiceStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(UUID().uuidString)/voices.json"))
    }

    @Test func firstObservationCreatesTheProfile() throws {
        let s = store()
        let voices = try s.reinforce(name: "Ilia", embedding: [1, 0, 0])
        #expect(voices.count == 1)
        #expect(voices[0].name == "Ilia")
    }

    @Test func laterObservationsBlendInsteadOfReplacing() throws {
        let s = store()
        _ = try s.reinforce(name: "Ilia", embedding: [1, 0, 0])
        let voices = try s.reinforce(name: "Ilia", embedding: [0, 1, 0])
        #expect(voices.count == 1)
        // Equal blend of the two normalized observations — both calls count.
        let e = voices[0].embedding
        #expect(abs(e[0] - 0.5) < 0.001)
        #expect(abs(e[1] - 0.5) < 0.001)
        // Identity (id/createdAt) survives the blend.
    }

    @Test func mismatchedDimensionsFallBackToReplace() throws {
        let s = store()
        _ = try s.reinforce(name: "Ilia", embedding: [1, 0, 0])
        let voices = try s.reinforce(name: "Ilia", embedding: [0, 1])
        #expect(voices.count == 1)
        #expect(voices[0].embedding == [0, 1])
    }
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("voices-\(UUID().uuidString).json")
}

@Suite struct VoiceStoreTests {
    @Test func emptyWhenMissing() {
        let store = VoiceStore(fileURL: tempFile())
        #expect(store.load().isEmpty)
    }

    @Test func roundTripsProfiles() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VoiceStore(fileURL: url)
        let voice = VoiceProfile(name: "Лёха", embedding: [0.1, 0.2, 0.3])
        try store.save([voice])

        let loaded = VoiceStore(fileURL: url).load()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "Лёха")
        #expect(loaded[0].embedding == [0.1, 0.2, 0.3])
    }

    @Test func upsertReplacesByNameCaseInsensitively() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VoiceStore(fileURL: url)
        try store.upsert(VoiceProfile(name: "Лёха", embedding: [1]))
        try store.upsert(VoiceProfile(name: "лёха", embedding: [2, 2]))   // same person, new fingerprint

        let voices = store.load()
        #expect(voices.count == 1)
        #expect(voices[0].embedding == [2, 2])
    }

    @Test func removeByName() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VoiceStore(fileURL: url)
        try store.upsert(VoiceProfile(name: "A", embedding: [1]))
        try store.upsert(VoiceProfile(name: "B", embedding: [2]))
        try store.removeVoice(named: "a")   // case-insensitive

        #expect(store.load().map(\.name) == ["B"])
    }
}
