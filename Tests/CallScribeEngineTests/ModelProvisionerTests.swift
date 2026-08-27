import Foundation
import Testing
@testable import CallScribeEngine

@Suite struct ModelProvisionerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("provisioner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    @Test func nothingOnDiskIsNotReady() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ModelProvisioner.isWhisperReady(modelsDir: dir) == false)
    }

    /// The interrupted-first-run case: WhisperKit fetches the tokenizer separately
    /// from the model snapshot, so the encoder can be on disk while the model still
    /// can't load offline. Reporting "ready" here would put a silent network fetch
    /// inside the first transcription.
    @Test func downloadedButNeverLoadedIsNotReady() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let variant = ModelProvisioner.whisperModelURL(modelsDir: dir)
        try touch(variant.appendingPathComponent("AudioEncoder.mlmodelc"))

        #expect(ModelProvisioner.isWhisperReady(modelsDir: dir) == false)
    }

    @Test func markerMakesItReady() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let variant = ModelProvisioner.whisperModelURL(modelsDir: dir)
        try touch(variant.appendingPathComponent("AudioEncoder.mlmodelc"))
        try touch(variant.appendingPathComponent(".callscribe-provisioned"))

        #expect(ModelProvisioner.isWhisperReady(modelsDir: dir) == true)
    }

    @Test func parakeetNothingOnDiskIsNotReady() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ModelProvisioner.isParakeetReady(modelsDir: dir) == false)
        #expect(ModelProvisioner.isReady(engine: .parakeet, modelsDir: dir) == false)
    }

    @Test func parakeetMarkerMakesItReady() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch(
            ParakeetTranscriber.modelURL(modelsDir: dir)
                .appendingPathComponent(".callscribe-provisioned"))

        #expect(ModelProvisioner.isParakeetReady(modelsDir: dir) == true)
        #expect(ModelProvisioner.isReady(engine: .parakeet, modelsDir: dir) == true)
        // Engines are provisioned independently — a ready Parakeet says
        // nothing about Whisper.
        #expect(ModelProvisioner.isReady(engine: .whisper, modelsDir: dir) == false)
    }

    /// Same no-network guarantee as Whisper's: a marker on disk means
    /// `ensureReady` returns without downloading, loading, or firing onStart.
    @Test func parakeetEnsureReadyIsANoOpOnceProvisioned() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch(
            ParakeetTranscriber.modelURL(modelsDir: dir)
                .appendingPathComponent(".callscribe-provisioned"))

        let started = Mutex(false)
        try await ModelProvisioner().ensureReady(
            modelsDir: dir,
            engine: .parakeet,
            onStart: { started.set(true) })

        #expect(started.get() == false)
    }

    /// The ready path must not touch the network or load anything — this test would
    /// hang or throw if `ensureReady` tried, and `onStart` must stay silent so no
    /// caller reports "waiting for the model" when nothing is waiting.
    @Test func ensureReadyIsANoOpOnceProvisioned() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let variant = ModelProvisioner.whisperModelURL(modelsDir: dir)
        try touch(variant.appendingPathComponent(".callscribe-provisioned"))

        let started = Mutex(false)
        try await ModelProvisioner().ensureReady(
            modelsDir: dir,
            onStart: { started.set(true) })

        #expect(started.get() == false)
    }

    /// Minimal Sendable box so the `@Sendable` callbacks can report back.
    private final class Mutex<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.withLock { value } }
        func set(_ newValue: T) { lock.withLock { value = newValue } }
    }
}
