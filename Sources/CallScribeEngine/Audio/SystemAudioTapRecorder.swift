import AVFAudio
import CoreAudio
import Foundation

/// Records everything other processes play (the remote-participants track)
/// via a Core Audio process tap — the AudioCap pattern:
///
///   1. a global tap that excludes our own process,
///   2. wrapped in a private aggregate device clocked by the default output,
///   3. read through an IOProc block scheduled on the sink's serial queue,
///      so buffers are converted and written synchronously with zero copies.
///
/// Two things change under us mid-call and are handled here rather than by
/// dying quietly:
///   - the TAP FORMAT follows the tapped route (AirPods flipping A2DP↔HFP
///     change the rate/channel count) — wrapping IOProc bytes with a stale
///     format mislabels every buffer and the track gets written at the wrong
///     speed, so the current format lives in a lock-protected holder kept
///     fresh by a property listener;
///   - the DEFAULT OUTPUT DEVICE can be switched or torn down (AirPods
///     auto-switch away), killing the aggregate — a listener rebuilds the
///     whole capture on the new route, and the TrackSink pads the hole.
///
/// Requires the Audio Recording TCC grant (`NSAudioCaptureUsageDescription`);
/// creating the tap triggers the system prompt on first use.
final class SystemAudioTapRecorder: @unchecked Sendable {
    private let sink: TrackSink
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// Serializes build/restart/stop and runs both property listeners.
    private let control = DispatchQueue(label: "callscribe.tap.control")
    private var stopped = false
    private let format = CurrentFormat()
    private var tapFormatListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?

    init(sink: TrackSink) {
        self.sink = sink
    }

    func start() throws {
        try control.sync { try buildCapture() }
        installDefaultOutputListener()
    }

    /// Tear down and rebuild the tap + aggregate on the current default
    /// output. Never throws — mid-transition the new route may not be ready;
    /// the session watchdog retries until audio flows again.
    func restart() {
        control.async { [self] in
            guard !stopped else { return }
            teardownCapture()
            try? buildCapture()
        }
    }

    func stop() {
        removeDefaultOutputListener()
        control.sync {
            stopped = true
            teardownCapture()
        }
    }

    /// Must run on `control`.
    private func buildCapture() throws {
        let ownProcess = try CoreAudioSupport.translatePIDToProcessObject(getpid())

        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [ownProcess]
        )
        description.name = "CallScribe System Audio Tap"
        description.isPrivate = true
        // muteBehavior defaults to CATapUnmuted — the user keeps hearing the call.

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try checkOSStatus(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")
        self.tapID = tapID

        do {
            var asbd = try CoreAudioSupport.tapStreamDescription(tapID)
            guard let initialFormat = AVAudioFormat(streamDescription: &asbd) else {
                throw AudioCaptureError.formatUnsupported("tap stream description not representable")
            }
            format.set(initialFormat)
            installTapFormatListener(on: tapID)

            let outputUID = try CoreAudioSupport.deviceUID(CoreAudioSupport.defaultOutputDevice())
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "CallScribe Tap Aggregate",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ],
                ],
            ]
            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            try checkOSStatus(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                "create aggregate device"
            )
            self.aggregateID = aggregateID

            // Scheduling the IOProc on the sink queue lets us consume the
            // buffer list synchronously (pointers are only valid inside the
            // block), so no copy is needed. The format is re-read per callback:
            // it changes mid-stream when the tapped route reconfigures. In the
            // window before the format listener lands, a byte-size mismatch
            // makes the buffer constructor return nil — the guard below drops
            // those frames on purpose rather than mislabeling them.
            let sink = self.sink
            let format = self.format
            var procID: AudioDeviceIOProcID?
            try checkOSStatus(
                AudioDeviceCreateIOProcIDWithBlock(
                    &procID, aggregateID, sink.queue
                ) { _, inInputData, inInputTime, _, _ in
                    guard let current = format.get(),
                          let buffer = AVAudioPCMBuffer(
                              pcmFormat: current,
                              bufferListNoCopy: inInputData,
                              deallocator: nil
                          ), buffer.frameLength > 0 else { return }
                    sink.processInline(buffer, hostTime: inInputTime.pointee.mHostTime)
                },
                "create IOProc"
            )
            self.ioProcID = procID

            try checkOSStatus(AudioDeviceStart(aggregateID, procID), "start aggregate device")
        } catch {
            teardownCapture()
            throw error
        }
    }

    /// Must run on `control`.
    private func teardownCapture() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            removeTapFormatListener(from: tapID)
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Property listeners

    // Listener registration matches addresses by VALUE, so each call builds
    // its own copy — no shared mutable statics.

    private static func makeAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Must run on `control` (called from buildCapture).
    private func installTapFormatListener(on tapID: AudioObjectID) {
        let format = self.format
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            var asbd = (try? CoreAudioSupport.tapStreamDescription(tapID)) ?? AudioStreamBasicDescription()
            guard asbd.mSampleRate > 0, let fresh = AVAudioFormat(streamDescription: &asbd) else { return }
            format.set(fresh)
        }
        var address = Self.makeAddress(kAudioTapPropertyFormat)
        AudioObjectAddPropertyListenerBlock(tapID, &address, control, block)
        tapFormatListener = block
    }

    /// Must run on `control`.
    private func removeTapFormatListener(from tapID: AudioObjectID) {
        guard let block = tapFormatListener else { return }
        var address = Self.makeAddress(kAudioTapPropertyFormat)
        AudioObjectRemovePropertyListenerBlock(tapID, &address, control, block)
        tapFormatListener = nil
    }

    private func installDefaultOutputListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.restart()
        }
        var address = Self.makeAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, block)
        defaultOutputListener = block
    }

    private func removeDefaultOutputListener() {
        guard let block = defaultOutputListener else { return }
        var address = Self.makeAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, block)
        defaultOutputListener = nil
    }
}

/// The tap's current stream format, shared between the IOProc (reads every
/// callback) and the format-change listener (writes). A plain lock: both
/// sides touch it briefly and never while holding anything else.
private final class CurrentFormat: @unchecked Sendable {
    private let lock = NSLock()
    private var format: AVAudioFormat?

    func get() -> AVAudioFormat? { lock.withLock { format } }
    func set(_ new: AVAudioFormat) { lock.withLock { format = new } }
}
