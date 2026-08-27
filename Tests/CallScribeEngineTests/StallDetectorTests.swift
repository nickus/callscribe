import Foundation
import Testing
@testable import CallScribeEngine

/// Defaults under test: stall after 5 idle s, startup grace 10 s, restart
/// grace 10 s, 3 restarts per episode. The helpers below advance one track
/// while holding the other, so each rule is exercised in isolation.
@Suite struct StallDetectorTests {
    /// Ticks `detector` n times with `mic`/`system` advancing (+0.1 s each
    /// tick) or frozen, collecting every event.
    private func run(
        _ detector: inout StallDetector,
        ticks: Int,
        micAdvances: Bool,
        systemAdvances: Bool,
        micStart: Double = 1.0,
        systemStart: Double = 1.0
    ) -> [StallDetector.Event] {
        var events: [StallDetector.Event] = []
        var mic = micStart
        var system = systemStart
        for _ in 0..<ticks {
            if micAdvances { mic += 0.1 }
            if systemAdvances { system += 0.1 }
            events += detector.tick(mic: mic, system: system)
        }
        return events
    }

    @Test func healthyTracksProduceNoEvents() {
        var detector = StallDetector()
        let events = run(&detector, ticks: 120, micAdvances: true, systemAdvances: true)
        #expect(events.isEmpty)
    }

    @Test func stalledTrackGetsRestartAfterFiveSeconds() {
        var detector = StallDetector()
        _ = run(&detector, ticks: 3, micAdvances: true, systemAdvances: true)
        let events = run(&detector, ticks: 5, micAdvances: true, systemAdvances: false)
        #expect(events == [.restart(.system)])
    }

    @Test func restartsEscalateThenTrackIsLostAndSessionContinues() {
        var detector = StallDetector()
        _ = run(&detector, ticks: 3, micAdvances: true, systemAdvances: true)
        // 5 idle → restart #1; +10 → #2; +10 → #3; +10 → lost. Mic stays alive,
        // so the session must NOT end.
        let events = run(&detector, ticks: 60, micAdvances: true, systemAdvances: false)
        #expect(events == [
            .restart(.system), .restart(.system), .restart(.system), .trackLost(.system),
        ])
    }

    @Test func progressAfterRestartResetsEverything() {
        var detector = StallDetector()
        _ = run(&detector, ticks: 3, micAdvances: true, systemAdvances: true)
        _ = run(&detector, ticks: 5, micAdvances: true, systemAdvances: false)   // restart #1
        // The restart worked: system advances again...
        _ = run(&detector, ticks: 10, micAdvances: true, systemAdvances: true, micStart: 10, systemStart: 10)
        // ...and a later stall gets a full fresh escalation, not a leftover one.
        let events = run(&detector, ticks: 60, micAdvances: true, systemAdvances: false, micStart: 20, systemStart: 20)
        #expect(events == [
            .restart(.system), .restart(.system), .restart(.system), .trackLost(.system),
        ])
    }

    @Test func trackThatNeverStartedGetsStartupGrace() {
        var detector = StallDetector()
        // System never produces a byte; mic is fine. First verdict must wait
        // for the 10 s startup grace, not the 5 s stall threshold.
        let atNine = run(&detector, ticks: 9, micAdvances: true, systemAdvances: false, systemStart: 0)
        #expect(atNine.isEmpty)
        let atTen = run(&detector, ticks: 1, micAdvances: true, systemAdvances: false, systemStart: 0)
        #expect(atTen == [.restart(.system)])
    }

    @Test func bothTracksDeadEndsTheSession() {
        var detector = StallDetector()
        _ = run(&detector, ticks: 3, micAdvances: true, systemAdvances: true)
        let events = run(&detector, ticks: 60, micAdvances: false, systemAdvances: false)
        // Both escalate in lockstep; the session ends exactly once, with no
        // per-track "lost" noise — endSession supersedes it.
        #expect(events.filter { $0 == .endSession }.count == 1)
        #expect(!events.contains(.trackLost(.mic)))
        #expect(!events.contains(.trackLost(.system)))
        #expect(events.last == .endSession)
    }

    @Test func nothingAfterSessionEnd() {
        var detector = StallDetector()
        _ = run(&detector, ticks: 3, micAdvances: true, systemAdvances: true)
        _ = run(&detector, ticks: 60, micAdvances: false, systemAdvances: false)
        let after = run(&detector, ticks: 30, micAdvances: false, systemAdvances: false)
        #expect(after.isEmpty)
    }

    @Test func secondTrackDyingLaterStillEndsTheSession() {
        var detector = StallDetector()
        _ = run(&detector, ticks: 3, micAdvances: true, systemAdvances: true)
        // System dies first and is reported lost while mic still records.
        let first = run(&detector, ticks: 60, micAdvances: true, systemAdvances: false)
        #expect(first.last == .trackLost(.system))
        // Then the mic dies too — the session must end.
        let second = run(&detector, ticks: 60, micAdvances: false, systemAdvances: false)
        #expect(second.last == .endSession)
    }

    @Test func lostTrackThatRecoversRejoinsTheSession() {
        var detector = StallDetector()
        _ = run(&detector, ticks: 3, micAdvances: true, systemAdvances: true)
        _ = run(&detector, ticks: 60, micAdvances: true, systemAdvances: false)   // system lost
        // Device came back on its own (e.g. AirPods reconnected much later).
        _ = run(&detector, ticks: 5, micAdvances: true, systemAdvances: true, micStart: 30, systemStart: 30)
        // Now the mic dies alone — system is healthy again, so the session
        // must survive: restarts for mic, then trackLost, but no endSession.
        let events = run(&detector, ticks: 60, micAdvances: false, systemAdvances: true, micStart: 40, systemStart: 40)
        #expect(events.last == .trackLost(.mic))
        #expect(!events.contains(.endSession))
    }
}
