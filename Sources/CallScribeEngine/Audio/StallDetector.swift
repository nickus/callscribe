import Foundation

/// Decides what to do when capture stops making progress — the watchdog's
/// brain, kept pure (fed durations, returns verdicts) so every rule is
/// unit-tested rather than hand-verified against real hardware.
///
/// Per-track escalation: a stalled track first gets its capture restarted
/// (bounded attempts with a grace period to come back up); a track whose
/// restarts are exhausted is declared lost, and the session carries on with
/// the other track — a mic-only transcript beats none. Only when BOTH tracks
/// are lost does the session end. Any byte of progress resets a track fully:
/// devices flap, and a recovered track deserves fresh restart credit.
struct StallDetector {
    enum Track: String, CaseIterable, Sendable { case mic, system }

    enum Event: Equatable, Sendable {
        /// The track stopped advancing — rebuild its capture.
        case restart(Track)
        /// Restarts exhausted; continue the session without this track.
        case trackLost(Track)
        /// Both tracks are lost; nothing is being recorded anymore.
        case endSession
    }

    struct Config: Sendable {
        /// Seconds without progress before a track counts as stalled.
        var stallSeconds = 5
        /// A track that has never produced audio gets this long to come up —
        /// a Bluetooth device's first buffer is legitimately slow.
        var startupGraceSeconds = 10
        /// Seconds a restart gets to show progress before the next escalation.
        var restartGraceSeconds = 10
        /// Restart attempts per stall episode (credit restored on progress).
        var maxRestarts = 3
    }

    private struct TrackState {
        var lastDuration = 0.0
        var everProgressed = false
        var idleSeconds = 0
        var restartsUsed = 0
        /// Seconds since the last restart; nil = no restart pending judgment.
        var sinceRestart: Int?
        var lost = false
        var lostReported = false
    }

    private let config: Config
    private var mic = TrackState()
    private var system = TrackState()
    private var ended = false

    init(config: Config = Config()) {
        self.config = config
    }

    /// Feed once a second with each track's written duration.
    mutating func tick(mic micDuration: TimeInterval, system systemDuration: TimeInterval) -> [Event] {
        guard !ended else { return [] }
        var events: [Event] = []
        events += advance(&mic, duration: micDuration, track: .mic)
        events += advance(&system, duration: systemDuration, track: .system)

        if mic.lost, system.lost {
            ended = true
            return [.endSession]
        }
        if mic.lost, !mic.lostReported {
            mic.lostReported = true
            events.append(.trackLost(.mic))
        }
        if system.lost, !system.lostReported {
            system.lostReported = true
            events.append(.trackLost(.system))
        }
        return events
    }

    private func advance(_ state: inout TrackState, duration: TimeInterval, track: Track) -> [Event] {
        if duration > state.lastDuration {
            state.lastDuration = duration
            state.everProgressed = true
            state.idleSeconds = 0
            state.sinceRestart = nil
            state.restartsUsed = 0
            state.lost = false
            state.lostReported = false
            return []
        }

        state.idleSeconds += 1
        guard !state.lost else { return [] }

        if let waited = state.sinceRestart {
            state.sinceRestart = waited + 1
            guard waited + 1 >= config.restartGraceSeconds else { return [] }
            return escalate(&state, track: track)
        }

        let threshold = state.everProgressed ? config.stallSeconds : config.startupGraceSeconds
        guard state.idleSeconds >= threshold else { return [] }
        return escalate(&state, track: track)
    }

    /// Next restart if credit remains, else mark the track lost (reported by
    /// `tick`, which knows whether the other track is lost too).
    private func escalate(_ state: inout TrackState, track: Track) -> [Event] {
        if state.restartsUsed < config.maxRestarts {
            state.restartsUsed += 1
            state.sinceRestart = 0
            return [.restart(track)]
        }
        state.lost = true
        return []
    }
}
