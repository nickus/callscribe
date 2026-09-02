import CallScribeCore
import SwiftUI

/// One utterance ready to render: real `[start, end]` times (so playback
/// highlight can track overlapping speech), a canonical speaker label
/// ("Me"/"Speaker 1"), and the text.
struct Turn: Identifiable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let label: String
    let text: String
}

/// The transcript rendered as chat bubbles: "Me" on the right (accent tint),
/// other speakers on the left, each speaker color-coded. Every timecode is
/// clickable and seeks the audio player; a turn is highlighted whenever the
/// playhead is within its real time range — so a long monologue stays lit for
/// its whole duration and a short interjection nested inside it lights only when
/// it actually occurs (both can be lit at once during overlap).
///
/// Speaker labels on remote turns are clickable: naming a few turns and
/// applying teaches the app these voices and relabels the whole call — the
/// per-turn marks are ground truth, everything else follows by voice.
struct TranscriptView: View {
    let turns: [Turn]
    let names: [String: String]
    let player: CallAudioPlayer
    /// Pending "this turn is <name>" marks (turn.id → name), owned by the
    /// detail view; empty when annotation isn't available (no callback).
    var pendingNames: [Int: String] = [:]
    /// Known names to offer as one-click choices.
    var suggestions: [String] = []
    /// Present = labels are clickable; called with the turn and the typed name.
    var onAnnotate: ((Turn, String) -> Void)?

    @State private var editingTurnID: Int?
    @State private var draftName = ""

    /// Colors for non-"Me" speakers, assigned in first-appearance order.
    private static let palette: [Color] = [.teal, .orange, .pink, .green, .brown, .cyan, .mint]

    var body: some View {
        if turns.isEmpty {
            Text("No transcript.").foregroundStyle(.secondary)
        } else {
            let colors = colorMap(turns)
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(turns) { turn in
                    let active = player.isPlaying
                        && player.currentTime >= turn.start
                        && player.currentTime <= turn.end
                    bubble(turn, color: colors[turn.label] ?? .gray, isMe: turn.label == "Me", active: active)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The speaker name over a bubble. For remote turns (when annotation is
    /// available) it's a button: click → name this piece of voice. A pending
    /// mark shows the chosen name with a pencil until it's applied.
    @ViewBuilder
    private func speakerLabel(_ turn: Turn, color: Color, isMe: Bool) -> some View {
        let display = pendingNames[turn.id] ?? names[turn.label] ?? turn.label
        if !isMe, onAnnotate != nil {
            Button {
                draftName = pendingNames[turn.id] ?? ""
                editingTurnID = turn.id
            } label: {
                HStack(spacing: 3) {
                    Text(display).font(.caption.weight(.semibold))
                    Image(systemName: pendingNames[turn.id] == nil ? "person.crop.circle.badge.questionmark" : "pencil")
                        .font(.system(size: 9))
                }
                .foregroundStyle(color)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Who is speaking here? Name a few turns, then Apply")
            .popover(isPresented: Binding(
                get: { editingTurnID == turn.id },
                // Guarded: a late dismissal write from THIS row must not
                // cancel a popover another row has just opened.
                set: { if !$0, editingTurnID == turn.id { editingTurnID = nil } }
            )) {
                namingPopover(turn)
            }
        } else {
            Text(display).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
    }

    private func namingPopover(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Who is speaking here?").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { commitName(turn) }
            if !suggestions.isEmpty {
                // One-click picks from names the app already knows.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 90), spacing: 6)],
                    alignment: .leading, spacing: 6
                ) {
                    ForEach(suggestions, id: \.self) { name in
                        Button(name) {
                            draftName = name
                            commitName(turn)
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
                .frame(width: 200)
            }
            HStack {
                if pendingNames[turn.id] != nil {
                    Button("Remove mark") {
                        onAnnotate?(turn, "")
                        editingTurnID = nil
                    }
                }
                Spacer()
                Button("Mark") { commitName(turn) }
                    .buttonStyle(SoftButtonStyle(tint: .brand))
                    .disabled({
                        let name = draftName.trimmingCharacters(in: .whitespaces)
                        return name.isEmpty || Self.isReserved(name)
                    }())
            }
        }
        .padding(Spacing.md)
    }

    private func commitName(_ turn: Turn) {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !Self.isReserved(name) else { return }
        onAnnotate?(turn, name)
        editingTurnID = nil
    }

    /// Canonical labels can't be people's names — "Me" would flip the bubble
    /// to the mic side and teach a remote voice as the user's own.
    static func isReserved(_ name: String) -> Bool {
        name == "Me" || name == "Participant" || name.wholeMatch(of: /Speaker \d+/) != nil
    }

    private func colorMap(_ turns: [Turn]) -> [String: Color] {
        var map: [String: Color] = [:]
        var others = 0
        for turn in turns where map[turn.label] == nil {
            if turn.label == "Me" {
                map[turn.label] = .brand
            } else {
                map[turn.label] = Self.palette[others % Self.palette.count]
                others += 1
            }
        }
        return map
    }

    @ViewBuilder
    private func bubble(_ turn: Turn, color: Color, isMe: Bool, active: Bool) -> some View {
        HStack(spacing: 0) {
            if isMe { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TimecodeButton(start: turn.start, color: color, player: player)
                    speakerLabel(turn, color: color, isMe: isMe)
                }
                Text(turn.text)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(active ? 0.28 : 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color.opacity(active ? 0.9 : 0), lineWidth: 1.5)
            )
            .frame(maxWidth: 480, alignment: isMe ? .trailing : .leading)
            if !isMe { Spacer(minLength: 40) }
        }
    }
}
