import CallScribeCore
import CallScribeEngine
import Foundation
import Observation

/// Hold Right Shift, speak, release — the text lands where the cursor is.
///
/// Wires the four independent pieces together: the hotkey monitor decides *when*
/// (`DictationHotkey` over the pure `DictationGesture`), `DictationRecorder`
/// captures, `DictationTranscriber` keeps a warm model to decode with, and
/// `TextInserter` puts the result in the frontmost app.
///
/// Deliberately separate from `AppState`: dictation touches no project, call or
/// processing queue, and the two share nothing but the microphone.
@MainActor
@Observable
final class DictationController {
    /// Below this, a hold can't have held speech — a fumbled key, not a sentence.
    private static let minDuration: TimeInterval = 0.4
    /// Hand the ~1.5 GB back after this long unused.
    private static let idleRelease: TimeInterval = 600

    private static let enabledKey = "dictation.enabled"
    private static let promptedKey = "dictation.didPromptForAccessibility"

    /// Whether the Right Shift watcher is running.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            apply()
        }
    }

    /// Set by the app to veto dictation while a call is recording — a second tap
    /// on the same microphone is not worth the risk to the call.
    var isBlocked: () -> Bool = { false }

    /// Dictation will transcribe but can't *paste*: detecting the hold needs no
    /// permission, while posting ⌘V does. The result lands on the clipboard
    /// instead, and the tray offers a way to fix it.
    var needsAccessibility: Bool {
        isEnabled && !PermissionsProbe.isAccessibilityTrusted
    }

    /// Past dictations, for the Dictations window. Owned here because this is
    /// what appends to the log and so the only thing that knows when it changed.
    let history = DictationHistory()

    private let hud = DictationHUD()
    private let dictationLog = DictationLog()
    /// Built on first use. `@ObservationIgnored` because it is plumbing, not state
    /// any view reads — and `lazy` is unavailable inside an `@Observable`.
    @ObservationIgnored private var dictationsWindow: DictationsWindow?
    private var hotkey: DictationHotkey?
    private var recorder: DictationRecorder?
    private var recordingURL: URL?

    init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        apply()
        promptForAccessibilityOnce()
    }

    // MARK: - Enable / disable

    private func apply() {
        if isEnabled {
            let hotkey = hotkey ?? DictationHotkey { [weak self] action in
                self?.perform(action)
            }
            self.hotkey = hotkey
            hotkey.start()
            Log.shared.info("dictation: enabled (right shift)")
        } else {
            hotkey?.stop()
            hud.hide()
            Log.shared.info("dictation: disabled")
        }
    }

    /// Show the system Accessibility prompt exactly once, on the first launch
    /// after dictation exists. Prompting on every untrusted launch would be a
    /// dialog the user has already said no to; never prompting would leave a
    /// feature that is on and silently does nothing.
    private func promptForAccessibilityOnce() {
        guard isEnabled, !PermissionsProbe.isAccessibilityTrusted else { return }
        guard !UserDefaults.standard.bool(forKey: Self.promptedKey) else {
            Log.shared.warn("dictation: enabled but not trusted for Accessibility")
            return
        }
        UserDefaults.standard.set(true, forKey: Self.promptedKey)
        PermissionsProbe.requestAccessibilityAccess()
    }

    /// Menu action for when the one-time prompt is spent.
    func openAccessibilitySettings() {
        PermissionsProbe.openAccessibilitySettings()
    }

    /// Open the window listing past dictations. Routed through here rather than
    /// `openWindow(id:)` because the window is AppKit, not a SwiftUI scene.
    func showDictations() {
        let window = dictationsWindow ?? DictationsWindow(history: history)
        dictationsWindow = window
        window.show()
    }

    // MARK: - Gesture

    private func perform(_ action: DictationGesture.Action) {
        switch action {
        case .none: break
        case .beginRecording: begin()
        case .finishRecording: finish()
        case .abortRecording: abort()
        }
    }

    private func begin() {
        guard recorder == nil else { return }

        if isBlocked() {
            hud.flash(.failure("Recording a call — dictation is paused."))
            return
        }
        // Checked synchronously: awaiting the TCC round-trip here would swallow
        // the first syllables. Requesting in the background makes the *next*
        // attempt work, which is the best that can be done from a key-press.
        guard PermissionsProbe.hasMicrophoneAccess else {
            hud.flash(.failure("Microphone access is off. Grant it in System Settings."))
            Task { _ = await PermissionsProbe.requestMicrophoneAccess() }
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callscribe-dictation-\(UUID().uuidString).wav")
        do {
            let recorder = try DictationRecorder(url: url) { [weak self] level in
                Task { @MainActor in self?.hud.model.report(rms: level) }
            }
            try recorder.start()
            self.recorder = recorder
            self.recordingURL = url
            hud.show(.listening)
        } catch {
            try? FileManager.default.removeItem(at: url)
            hud.flash(.failure(error.localizedDescription))
            Log.shared.error("dictation: capture failed to start: \(Log.truncated(error.localizedDescription))")
            return
        }

        // The reason dictation feels quick: the first model load (5–10 s) runs
        // while the user is still talking rather than after they stop. Errors are
        // ignored here — `transcribe` re-runs `prepare` and reports them properly.
        Task {
            try? await DictationTranscriber.shared.prepare(
                modelsDir: AppPaths.modelsDirectory, engine: STTEngine.current())
        }
    }

    private func finish() {
        guard let recorder, let url = recordingURL else { return }
        self.recorder = nil
        self.recordingURL = nil

        let duration: TimeInterval
        do {
            duration = try recorder.stop()
        } catch {
            try? FileManager.default.removeItem(at: url)
            hud.flash(.failure(error.localizedDescription))
            Log.shared.error("dictation: capture failed to stop: \(Log.truncated(error.localizedDescription))")
            return
        }

        guard duration >= Self.minDuration else {
            try? FileManager.default.removeItem(at: url)
            hud.flash(.note("Too short."), for: 1.2)
            return
        }

        Task { await transcribeAndInsert(url, duration: duration) }
    }

    private func abort() {
        guard let recorder else { return }
        self.recorder = nil
        _ = try? recorder.stop()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        // No message: the user was typing a capital, and an overlay flashing at
        // them for it would be pure noise.
        hud.hide()
    }

    // MARK: - Transcribe → insert

    private func transcribeAndInsert(_ url: URL, duration: TimeInterval) async {
        defer { try? FileManager.default.removeItem(at: url) }

        // Distinguishes the 5–10 s first load from the ~1 s steady state, so a
        // cold start doesn't look like a hang.
        let warm = await DictationTranscriber.shared.isWarm
        hud.show(warm ? .transcribing : .loadingModel)

        let text: String
        let language: String?
        do {
            (text, language) = try await DictationTranscriber.shared.transcribe(
                wav: url,
                language: nil,          // auto-detect, as the call pipeline does
                modelsDir: try AppPaths.ensureModelsDirectory(),
                engine: STTEngine.current()   // the tray picker's choice
            )
        } catch {
            hud.flash(.failure(error.localizedDescription), for: 4)
            Log.shared.error("dictation: transcription failed: \(Log.truncated(error.localizedDescription))")
            return
        }
        await DictationTranscriber.shared.releaseIfIdle(after: Self.idleRelease)

        guard !text.isEmpty else {
            hud.flash(.note("Nothing heard."), for: 1.5)
            Log.shared.info("dictation: \(String(format: "%.1f", duration)) s produced no text")
            return
        }

        dictationLog.append(text, language: language)
        // The Dictations window may be open behind whatever app is being dictated
        // into, so nothing else would tell it a new entry exists — this app has no
        // file watching, by convention.
        history.reload()

        switch await TextInserter.insert(text) {
        case .pasted:
            hud.hide()
            // Metadata only — the dictated text belongs in dictations.md, and
            // ~/Library/Logs is swept up by sysdiagnose.
            Log.shared.info("dictation: \(String(format: "%.1f", duration)) s → \(text.count) chars pasted")
        case .copiedOnly(let reason):
            hud.flash(.failure(reason), for: 4)
            Log.shared.warn("""
                dictation: \(String(format: "%.1f", duration)) s → \
                \(text.count) chars copied only: \(reason)
                """)
        }
    }
}
