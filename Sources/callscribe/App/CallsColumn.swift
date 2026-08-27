import SwiftUI

/// Middle column: the selected project's calls, with the record button pinned
/// on top and calls grouped into day sections.
struct CallsColumn: View {
    @Bindable var state: AppState
    @Binding var selection: String?

    @State private var pendingDelete: AppState.CallSummary?
    @State private var confirmingCancel = false

    var body: some View {
        VStack(spacing: 0) {
            recordHeader
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(daySections) { section in
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.md)
                            .padding(.top, Spacing.md)
                            .padding(.bottom, Spacing.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(section.calls) { call in
                            callRow(call)
                        }
                    }
                }
                .padding(Spacing.sm)
            }
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { call in
            Button("Delete recording and all its files", role: .destructive) {
                if selection == call.id { selection = nil }
                state.delete(call.folder)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text(
                "This permanently removes the whole folder — audio, transcript, "
                    + "summary and everything else for this call.")
        }
    }

    /// Prominent recording control pinned above the call list.
    private var recordHeader: some View {
        VStack(spacing: Spacing.sm) {
            RecordButton(state: state)
                .buttonStyle(BrandButtonStyle(
                    fill: state.isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(LinearGradient.brand),
                    glow: state.isRecording ? .red : .brand))
                .frame(maxWidth: .infinity)
                .keyboardShortcut("r")

            if case .idle = state.phase {} else {
                RecordStatusChip(phase: state.phase)
            }

            if state.modelState != .ready {
                ModelStatusChip(state: state)
            }

            if state.isRecording {
                Button("Cancel Recording") { confirmingCancel = true }
                    .buttonStyle(SoftButtonStyle(tint: .red))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(Spacing.lg)
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $confirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Discard recording", role: .destructive) { state.cancelRecording() }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("This stops recording and deletes it without transcribing.")
        }
    }

    /// One call row with a soft brand-tinted highlight when selected (instead of
    /// the heavy full-saturation List selection bar).
    private func callRow(_ call: AppState.CallSummary) -> some View {
        let isSelected = selection == call.id
        let sub = CallFormatting.subtitle(call)
        return Button {
            selection = call.id
        } label: {
            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.title ?? CallFormatting.time(call))
                        .font(.body.weight(.medium))
                        .foregroundStyle(isSelected ? Color.brand : Color.primary)
                        .lineLimit(2)
                    if let job = state.statusJob(for: call.folder) {
                        Text(CallFormatting.stageLabel(job.stage)).font(.caption).foregroundStyle(.secondary)
                    } else if !sub.isEmpty {
                        Text(sub).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if state.isProcessing(call.folder) {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.sm)
            .padding(.horizontal, Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.brand.opacity(0.15) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .contextMenu {
            Button("Delete", role: .destructive) { pendingDelete = call }
        }
    }

    /// Calls grouped into day sections (newest first), preserving order.
    private var daySections: [DaySection] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [AppState.CallSummary]] = [:]
        for call in state.calls {
            let day = call.startedAt.map { calendar.startOfDay(for: $0) } ?? .distantPast
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(call)
        }
        return order.map { day in
            DaySection(id: "\(day.timeIntervalSince1970)", title: CallFormatting.dayTitle(day), calls: byDay[day] ?? [])
        }
    }

    struct DaySection: Identifiable {
        let id: String
        let title: String
        let calls: [AppState.CallSummary]
    }
}
