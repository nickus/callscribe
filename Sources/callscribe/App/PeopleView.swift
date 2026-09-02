import AVFoundation
import CallScribeCore
import SwiftUI

/// The voice library: everyone the app can recognize, with an audible sample
/// of each voice. Voices land here from "Apply names" in a transcript or the
/// per-speaker "Remember voice" — one global library shared by all projects.
struct PeopleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [VoiceProfile] = []
    @State private var player: AVAudioPlayer?
    @State private var playingName: String?

    private let store = VoiceStore()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                Label("People", systemImage: "person.2").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            if profiles.isEmpty {
                Text("""
                    No voices learned yet. Open a call's transcript, click a \
                    speaker label to name a few turns, and apply — the voices \
                    land here and future calls get named automatically.
                    """)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            } else {
                ScrollView {
                    VStack(spacing: Spacing.sm) {
                        ForEach(profiles) { profile in
                            row(profile)
                        }
                    }
                }
            }
        }
        .padding(Spacing.xl)
        .frame(minWidth: 440, minHeight: 260)
        .onAppear { profiles = store.load() }
        .onDisappear { player?.stop() }
    }

    private func row(_ profile: VoiceProfile) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.body.weight(.medium))
                Text("learned \(profile.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.hasSample(forName: profile.name) {
                Button {
                    toggleSample(profile.name)
                } label: {
                    Label(
                        playingName == profile.name ? "Stop" : "Play",
                        systemImage: playingName == profile.name ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(SoftButtonStyle())
                .pointerCursor()
            } else {
                Text("no sample").font(.caption).foregroundStyle(.tertiary)
            }
            Button(role: .destructive) {
                forget(profile.name)
            } label: {
                Label("Forget", systemImage: "trash")
            }
            .buttonStyle(SoftButtonStyle())
            .help("Future calls stop recognizing this voice; existing transcripts keep the name")
            .pointerCursor()
        }
        .padding(Spacing.md)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func toggleSample(_ name: String) {
        if playingName == name {
            player?.stop()
            playingName = nil
            return
        }
        player?.stop()
        guard let sample = try? AVAudioPlayer(contentsOf: store.sampleURL(forName: name)) else { return }
        player = sample
        playingName = name
        sample.play()
    }

    private func forget(_ name: String) {
        _ = try? store.removeVoice(named: name)
        profiles = store.load()
        if playingName == name {
            player?.stop()
            playingName = nil
        }
    }
}
