import AVFoundation
import CallScribeCore
import Foundation
import Observation

/// Plays a call's two tracks (mic = "Me", system = "Others") through one synced
/// AVPlayer. A track selector controls which is audible: "Both" mixes them
/// (echoes if recorded on speakers), "Them" plays only the clean system track.
@MainActor
@Observable
final class CallAudioPlayer {
    enum TrackMode: String, CaseIterable, Identifiable {
        case both = "Both", me = "Me", them = "Them"
        var id: String { rawValue }
    }

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isReady = false
    private(set) var hasBothTracks = false

    var mode: TrackMode = .both { didSet { applyMix() } }

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var micTrack: AVMutableCompositionTrack?
    private var systemTrack: AVMutableCompositionTrack?
    private var observer: Any?

    /// (Re)build the player for a call folder. No-op-safe if neither WAV exists.
    func load(_ folder: CallFolder) {
        teardown()
        Task { await build(folder) }
    }

    private func build(_ folder: CallFolder) async {
        let composition = AVMutableComposition()
        var maxDuration = CMTime.zero

        // Prefer the echo-cancelled mic ("Me") when it exists.
        let micURL = FileManager.default.fileExists(atPath: folder.micCleanWAV.path)
            ? folder.micCleanWAV : folder.micWAV
        for (wav, isMic) in [(micURL, true), (folder.systemWAV, false)] {
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }
            let asset = AVURLAsset(url: wav)
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let assetDuration = try? await asset.load(.duration),
                  let track = composition.addMutableTrack(
                      withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try? track.insertTimeRange(
                CMTimeRange(start: .zero, duration: assetDuration), of: sourceTrack, at: .zero)
            if isMic { micTrack = track } else { systemTrack = track }
            if assetDuration > maxDuration { maxDuration = assetDuration }
        }

        guard maxDuration > .zero else { return }
        duration = maxDuration.seconds
        hasBothTracks = micTrack != nil && systemTrack != nil

        let item = AVPlayerItem(asset: composition)
        playerItem = item
        let player = AVPlayer(playerItem: item)
        self.player = player
        applyMix()
        isReady = true

        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                if self.isPlaying, time.seconds >= self.duration - 0.05 {
                    self.pause()
                    self.seek(to: 0)
                }
            }
        }
    }

    /// Mute tracks per the selected mode via an audio mix (no re-decode).
    private func applyMix() {
        guard let playerItem else { return }
        var params: [AVMutableAudioMixInputParameters] = []
        if let micTrack {
            let p = AVMutableAudioMixInputParameters(track: micTrack)
            p.setVolume(mode == .them ? 0 : 1, at: .zero)   // mic carries "Me"
            params.append(p)
        }
        if let systemTrack {
            let p = AVMutableAudioMixInputParameters(track: systemTrack)
            p.setVolume(mode == .me ? 0 : 1, at: .zero)     // system carries "Them"
            params.append(p)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        playerItem.audioMix = mix
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let player else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        currentTime = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func teardown() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        playerItem = nil
        micTrack = nil
        systemTrack = nil
        isPlaying = false
        isReady = false
        hasBothTracks = false
        currentTime = 0
        duration = 0
    }

    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let t = Int(seconds)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
