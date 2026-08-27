import AppKit
import CallScribeEngine
import SwiftUI

struct MenuBarView: View {
    @Bindable var state: AppState
    @Bindable var dictation: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ControlBar(state: state)
        Divider()
        Toggle("Dictation — hold Right Shift", isOn: $dictation.isEnabled)
        // Renders as a submenu. Applies to new calls and dictations; switching
        // to a not-yet-downloaded engine starts its download immediately.
        Picker("Transcription engine", selection: $state.sttEngine) {
            ForEach(STTEngine.allCases) { engine in
                Text(engine.displayName).tag(engine)
            }
        }
        // Only while dictation can hear you but not paste — the text goes to the
        // clipboard instead, and this is the way out of that.
        if dictation.needsAccessibility {
            Button("Grant Accessibility Access…") { dictation.openAccessibilitySettings() }
        }
        Button("Dictations…") { dictation.showDictations() }
        Divider()
        Button("Open Window") { openWindow(id: "main") }
        Button("Quit CallScribe") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
