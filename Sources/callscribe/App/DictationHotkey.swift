import AppKit
import CallScribeCore
import CallScribeEngine
import Carbon.HIToolbox
import CoreGraphics

/// Watches for the Right Shift hold and reports what it means.
///
/// Deliberately thin: every decision lives in `DictationGesture`, which is pure
/// and tested. This file is only the polling and the clock, neither of which can
/// be unit-tested.
///
/// **Why polling and not `NSEvent.addGlobalMonitorForEvents`.** The obvious
/// implementation — a global monitor for `.flagsChanged`/`.keyDown` — breaks the
/// app. On macOS 26, installing one stops this process receiving its **own mouse
/// events**: clicks on our windows are delivered elsewhere, the tray menu won't
/// open, and no window ever becomes key, all while the app renders correctly and
/// its main thread sits idle. It looks exactly like a frozen UI and took a long
/// time to pin down. Measured: with the global monitor installed, a local mouse
/// monitor logged 0 clicks; with dictation disabled, 6 in as many seconds.
///
/// So this reads key state directly instead, via `CGEventSource`, which needs no
/// event tap and no Accessibility grant:
///
/// - `flagsState(_:)` — Right Shift down *specifically*, from the
///   device-dependent bits. `NSEvent`'s `.shift` is device-independent and can't
///   tell the two shift keys apart, and `keyState(_:key:)` is no help either: for
///   modifier keys it reports the press under the *left* key code whichever
///   physical key you use. Same call also answers "is a chord modifier held?".
/// - `secondsSinceLastEventType(_:eventType:)` — did the user type a key during
///   the hold? That's the "you were shifting, not dictating" abort, recovered
///   without seeing the keystroke itself.
///
/// Posting the paste still needs Accessibility; observing no longer does.
@MainActor
final class DictationHotkey {
    /// 50 ms: fine enough that the 350 ms threshold lands well within tolerance
    /// and a typed key is caught in the same window it happened, cheap enough to
    /// run continuously (three integer-ish queries, 20 times a second).
    private static let pollInterval: TimeInterval = 0.05

    private var gesture = DictationGesture()
    private var poller: Timer?
    private var wasDown = false
    private let onAction: (DictationGesture.Action) -> Void

    init(onAction: @escaping (DictationGesture.Action) -> Void) {
        self.onAction = onAction
    }

    var isRunning: Bool { poller != nil }

    func start() {
        guard poller == nil else { return }
        wasDown = Self.isRightShiftDown   // don't fire on a key already held
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // `.common` so polling survives a menu tracking loop or a window drag —
        // otherwise a hold begun with a menu open would never be noticed.
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
    }

    func stop() {
        poller?.invalidate()
        poller = nil
        // Abandon a gesture in flight, so re-enabling starts from a clean slate.
        if gesture.isRecording { onAction(.abortRecording) }
        gesture = DictationGesture()
        wasDown = false
    }

    // MARK: - Polling

    private func poll() {
        let now = Self.now

        // Checked before the transition below: a key typed during the hold means
        // the user was shift-typing. Modifier presses don't count — those arrive
        // as flagsChanged, not keyDown, so Right Shift itself can't trip this
        // (measured: `sinceKeyDown` stays large through a whole hold).
        if gesture.isPending, Self.typedSinceLastPoll {
            feed(.otherKeyDown(at: now))
        }

        let down = Self.isRightShiftDown
        if down != wasDown {
            wasDown = down
            if down {
                feed(.rightShiftDown(at: now, otherModifiers: Self.otherModifiersHeld))
            } else {
                feed(.rightShiftUp(at: now))
            }
        }

        // Unconditional: this is what promotes a long-enough hold into a
        // recording and what enforces the safety cap.
        feed(.tick(at: now))
    }

    private func feed(_ input: DictationGesture.Input) {
        let action = gesture.handle(input)
        if action != .none { onAction(action) }
    }

    // MARK: - Key state

    /// `NX_DEVICERSHIFTKEYMASK` — the device-dependent bit for *right* shift
    /// specifically (left shift is `0x02`).
    private static let rightShiftDeviceMask: UInt64 = 0x04

    /// Right Shift, via the device-dependent bits of the global flag state.
    ///
    /// Not `keyState(_:key:)`: for modifier keys that reports the press under the
    /// *left* key code whichever physical key you use, so
    /// `keyState(kVK_RightShift)` is false even while Right Shift is held —
    /// measured. `flagsState` carries the device-dependent bits and does tell the
    /// two apart. Neither call needs an event tap.
    private static var isRightShiftDown: Bool {
        CGEventSource.flagsState(.combinedSessionState).rawValue & rightShiftDeviceMask != 0
    }

    /// A chord — ⌘⇧, ⌥⇧, ⌃⇧ — is somebody's shortcut, not a dictation.
    private static var otherModifiersHeld: Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return !flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl])
    }

    /// Whether a key went down within the last poll window. The 1.5× slack covers
    /// timer jitter without reaching back far enough to catch an older keystroke.
    private static var typedSinceLastPoll: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            < pollInterval * 1.5
    }

    // MARK: - Clock

    /// Seconds since boot, which does not advance while the machine sleeps.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
