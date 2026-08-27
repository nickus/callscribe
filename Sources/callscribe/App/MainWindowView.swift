import AppKit
import CallScribeCore
import SwiftUI

/// The primary window. A plain two-pane layout (a collapsible calls list and the
/// call detail) with a single, undivided window toolbar — so the project header
/// stays pinned to the window's left regardless of the calls pane.
struct MainWindowView: View {
    @Bindable var state: AppState
    /// Only for the Dictations toolbar button — no property of it is read in the
    /// body, so this adds no observation dependency.
    let dictation: DictationController

    @State private var selectedCallID: String?
    @State private var showNewProject = false
    @State private var showHistory = true

    private var selectedCall: AppState.CallSummary? {
        state.calls.first { $0.id == selectedCallID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if case .failed(let message) = state.phase {
                    ErrorBanner(message: message) { state.clearError() }
                        .padding([.horizontal, .top], 10)
                }
                if let processingError = state.processingError {
                    ErrorBanner(message: processingError) { state.clearProcessingError() }
                        .padding([.horizontal, .top], 10)
                }
                HStack(spacing: 0) {
                    if showHistory {
                        CallsColumn(state: state, selection: $selectedCallID)
                            .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                        Divider()
                    }
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 900, minHeight: 520)
            .navigationTitle(selectedCall.map(CallFormatting.title) ?? "")
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        showHistory.toggle()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Show or hide the calls list")
                    .pointerCursor()

                    ForEach(state.projects) { project in
                        projectButton(project)
                    }

                    Button {
                        showNewProject = true
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .help("Create a new project")
                    .pointerCursor()

                    Button {
                        state.openProjectContext()
                    } label: {
                        Label("Context", systemImage: "text.book.closed")
                    }
                    .help("Edit this project's glossary — the summarizer uses it to fix and name terms")
                    .pointerCursor()

                    // Its own window — dictations aren't scoped to the project
                    // these buttons select.
                    Button {
                        dictation.showDictations()
                    } label: {
                        Label("Dictations", systemImage: "text.quote")
                    }
                    .help("Browse everything you've dictated")
                    .pointerCursor()
                }
            }
        }
        // Open to the newest call; keep the current one if it's still in the
        // list, otherwise (launch, project switch, delete) select the first.
        .onChange(of: state.calls.map(\.id), initial: true) { _, ids in
            if let sel = selectedCallID, ids.contains(sel) { return }
            selectedCallID = ids.first
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet { name, parent in
                state.addProject(name: name, parentURL: parent)
            }
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let call = selectedCall {
            CallDetailView(state: state, call: call) { selectedCallID = nil }
                .id(call.id)
        } else {
            ContentUnavailableView("No call selected", systemImage: "waveform")
        }
    }

    @ViewBuilder
    private func projectButton(_ project: Project) -> some View {
        let isSelected = project.id == state.selectedProjectID
        let button = Button {
            state.selectedProjectID = project.id
        } label: {
            Text(project.name)
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
            }
            if state.projects.count > 1 {
                Button("Remove from CallScribe", role: .destructive) {
                    state.removeProject(project.id)
                }
            }
        }
        .pointerCursor()

        // Selected = filled accent (white label); others = a normal bordered
        // button with the default (visible) label color.
        if isSelected {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
