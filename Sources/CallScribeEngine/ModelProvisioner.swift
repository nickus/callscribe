import FluidAudio
import Foundation
import WhisperKit

/// Gets an STT model onto disk and *loadable*, once, in the background.
///
/// "Downloaded" is not the same as "usable": `WhisperKit.loadModels` resolves the
/// tokenizer separately from the model snapshot, so an interrupted first run can
/// leave `AudioEncoder.mlmodelc` in place with no tokenizer — and a file-existence
/// check would then claim readiness and hit the network again mid-transcription.
/// Provisioning is therefore download + one successful load (which caches the
/// tokenizer), recorded by a marker file inside the variant folder.
public actor ModelProvisioner {
    public static let shared = ModelProvisioner()

    /// Every provisioning failure — offline, disk, a failed load, an unexpected
    /// download location — surfaces as this one type, so callers can tell "the
    /// model isn't ready yet" apart from a real pipeline error and keep the
    /// recording queued instead of dropping it.
    public enum Failure: LocalizedError {
        case notProvisioned(String)
        case unexpectedModelLocation(downloaded: String, expected: String)

        public var errorDescription: String? {
            switch self {
            case .notProvisioned(let reason):
                "The transcription model isn't ready yet: \(reason)"
            case .unexpectedModelLocation(let downloaded, let expected):
                "WhisperKit downloaded the model to \(downloaded) but it is loaded from \(expected)."
            }
        }
    }

    private static let markerName = ".callscribe-provisioned"

    /// Where WhisperKit's Hub layout puts `model` under `modelsDir`. The one
    /// definition of that path — `WhisperTranscriber` loads from here too.
    public static func whisperModelURL(
        modelsDir: URL,
        model: String = WhisperTranscriber.defaultModel
    ) -> URL {
        modelsDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)")
    }

    /// Downloaded *and* loaded at least once. Static and free of actor state so
    /// the UI can seed itself synchronously at launch without an `await`.
    public static func isWhisperReady(
        modelsDir: URL,
        model: String = WhisperTranscriber.defaultModel
    ) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(modelsDir: modelsDir, model: model).path)
    }

    /// Same marker semantics for the Parakeet install (FluidAudio's download
    /// and ANE compile both precede the marker write).
    public static func isParakeetReady(modelsDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: parakeetMarkerURL(modelsDir: modelsDir).path)
    }

    /// Readiness of whichever engine the user selected.
    public static func isReady(engine: STTEngine, modelsDir: URL) -> Bool {
        switch engine {
        case .whisper: isWhisperReady(modelsDir: modelsDir)
        case .parakeet: isParakeetReady(modelsDir: modelsDir)
        }
    }

    private static func markerURL(modelsDir: URL, model: String) -> URL {
        whisperModelURL(modelsDir: modelsDir, model: model).appendingPathComponent(markerName)
    }

    private static func parakeetMarkerURL(modelsDir: URL) -> URL {
        ParakeetTranscriber.modelURL(modelsDir: modelsDir).appendingPathComponent(markerName)
    }

    /// The model files themselves, tokenizer aside — the "does it still need
    /// downloading at all" precondition.
    private static func isDownloaded(modelsDir: URL, model: String) -> Bool {
        FileManager.default.fileExists(
            atPath: whisperModelURL(modelsDir: modelsDir, model: model)
                .appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    /// One in-flight attempt AND one progress sink per model, so a Whisper
    /// caller never coalesces onto a Parakeet download (or vice versa) and two
    /// concurrent downloads can't interleave fractions into one progress bar.
    private var inFlight: [String: Task<Void, Error>] = [:]
    private var progressSinks: [String: @Sendable (Double?) -> Void] = [:]

    /// Make the engine's model usable, downloading it if needed. Idempotent —
    /// concurrent callers join the in-flight attempt rather than starting
    /// their own.
    ///
    /// - Parameters:
    ///   - model: overrides the Whisper variant; ignored for Parakeet.
    ///   - onStart: fired once, from inside the actor, only when this call has to
    ///     wait on a download. Lets a caller report "waiting" without a
    ///     check-then-act race against the readiness test.
    ///   - onProgress: 0…1, `nil` while the transfer hasn't reported anything yet.
    ///     A single sink, claimed by the first caller that supplies one (the UI);
    ///     everyone else passes nil and just awaits. Fanning out to several
    ///     consumers would only split one download's progress between them.
    public func ensureReady(
        modelsDir: URL,
        engine: STTEngine = .whisper,
        model: String = WhisperTranscriber.defaultModel,
        onStart: (@Sendable () -> Void)? = nil,
        onProgress: (@Sendable (Double?) -> Void)? = nil
    ) async throws {
        let ready = switch engine {
        case .whisper: Self.isWhisperReady(modelsDir: modelsDir, model: model)
        case .parakeet: Self.isParakeetReady(modelsDir: modelsDir)
        }
        if ready { return }
        let key = engine == .whisper ? model : ParakeetTranscriber.defaultModel
        if progressSinks[key] == nil, let onProgress { progressSinks[key] = onProgress }
        onStart?()
        let task = inFlight[key] ?? Task {
            switch engine {
            case .whisper: try await self.provision(modelsDir: modelsDir, model: model)
            case .parakeet: try await self.provisionParakeet(modelsDir: modelsDir)
            }
        }
        inFlight[key] = task
        try await task.value
    }

    /// Download (when missing) → load once → write the marker. The whole body is
    /// wrapped so callers see `Failure` and nothing else.
    private func provision(modelsDir: URL, model: String) async throws {
        // Runs on the actor: clearing here means a retry starts a fresh attempt
        // instead of re-awaiting this task's outcome. Nothing can create a
        // replacement before this runs, since a new task is only made when
        // the model's `inFlight` slot is nil.
        defer {
            inFlight[model] = nil
            progressSinks[model] = nil
        }

        let expected = Self.whisperModelURL(modelsDir: modelsDir, model: model)
        do {
            if !Self.isDownloaded(modelsDir: modelsDir, model: model) {
                let sink = progressSinks[model]
                sink?(nil)
                Log.shared.info("provisioning \(model): downloading into \(modelsDir.path)")
                let downloaded = try await WhisperKit.download(
                    variant: model,
                    downloadBase: modelsDir,
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        sink?(fraction > 0 ? fraction : nil)
                    }
                )
                // `download` resolves the variant folder itself (globbing the repo
                // listing), so trust its answer over a recomputed path: a marker
                // written beside a folder the loader never consults would mean
                // re-downloading 1.5 GB on every launch.
                guard downloaded.standardizedFileURL == expected.standardizedFileURL else {
                    throw Failure.unexpectedModelLocation(
                        downloaded: downloaded.path, expected: expected.path)
                }
            }
            // The second half of provisioning: this resolves and caches the
            // tokenizer, so later loads are genuinely offline.
            _ = try await WhisperTranscriber(model: model, modelFolder: modelsDir)
            try Data().write(to: Self.markerURL(modelsDir: modelsDir, model: model))
            progressSinks[model]?(1)
            Log.shared.info("provisioning \(model): ready")
        } catch let failure as Failure {
            Log.shared.error("provisioning \(model) failed: \(Log.truncated(failure.localizedDescription))")
            throw failure
        } catch {
            Log.shared.error("provisioning \(model) failed: \(Log.truncated(error.localizedDescription))")
            throw Failure.notProvisioned(error.localizedDescription)
        }
    }

    /// Parakeet's provisioning: FluidAudio's downloadAndLoad both fetches the
    /// repo and does the first (ANE-compiling) load, so one call earns the
    /// marker. Wrapped the same way — callers see `Failure` and nothing else.
    private func provisionParakeet(modelsDir: URL) async throws {
        let model = ParakeetTranscriber.defaultModel
        defer {
            inFlight[model] = nil
            progressSinks[model] = nil
        }
        do {
            let sink = progressSinks[model]
            sink?(nil)
            Log.shared.info("provisioning \(model): downloading into \(modelsDir.path)")
            _ = try await AsrModels.downloadAndLoad(
                to: ParakeetTranscriber.modelURL(modelsDir: modelsDir),
                progressHandler: { progress in
                    let fraction = progress.fractionCompleted
                    sink?(fraction > 0 ? fraction : nil)
                }
            )
            try Data().write(to: Self.parakeetMarkerURL(modelsDir: modelsDir))
            progressSinks[model]?(1)
            Log.shared.info("provisioning \(model): ready")
        } catch {
            Log.shared.error("provisioning \(model) failed: \(Log.truncated(error.localizedDescription))")
            throw Failure.notProvisioned(error.localizedDescription)
        }
    }
}
