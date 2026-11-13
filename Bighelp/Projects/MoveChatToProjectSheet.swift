import SwiftUI

/// Move to Project…, from a chat's ⋯ menu and from Chats. Nil wherever the computer can't move
/// chats. `onMoved` shows the confirmed project in the chat list and an open chat.
@MainActor
struct ChatProjectMove {
    let store: HermesWorkspaceStore
    let onMoved: @MainActor (HermesWorkspaceSummary, _ sessionID: String) -> Void
}

/// The chat ⋯ menu's Move to Project… row: the chat's project now, and what opens the sheet.
struct ChatProjectMenuItem {
    let projectName: String?
    let open: () -> Void
}

/// Lists the agent's projects on this computer. A tap moves the chat, and the sheet closes
/// only once Hermes confirms it; otherwise it stays open and says why.
struct MoveChatToProjectSheet: View {
    let move: ChatProjectMove
    let chatTitle: String
    let agentID: String
    let sessionID: String
    let currentProjectID: String?

    private struct MoveRequest: Equatable {
        let projectID: String
        let attempt = UUID()
    }

    @Environment(\.dismiss) private var dismiss
    @State private var projects: [HermesWorkspaceSummary]?
    @State private var loadFailed = false
    @State private var loadAttempt = 0
    @State private var request: MoveRequest?
    @State private var moveError: String?

    var body: some View {
        NavigationStack {
            content
                .background(theme.canvas.ignoresSafeArea())
                .navigationTitle("Move to Project")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("chat.move-project.cancel")
                    }
                }
        }
        .task(id: loadAttempt) { await load() }
        .task(id: request) {
            guard let request else { return }
            await perform(request)
        }
        .presentationDetents([.medium, .large])
        .bighelpSheetSize(.compact)
    }

    @ViewBuilder
    private var content: some View {
        if let projects, projects.isEmpty {
            ContentUnavailableView {
                Label("No projects yet", systemImage: "folder")
            } description: {
                Text("Make a project on the Projects screen, then move this chat into it.")
            }
        } else if let projects {
            List {
                Section {
                    ForEach(Self.ordered(projects, currentProjectID: currentProjectID)) { row($0) }
                } header: {
                    Text(chatTitle)
                } footer: {
                    if let moveError {
                        Text(moveError)
                            .foregroundStyle(theme.danger)
                            .accessibilityIdentifier("chat.move-project.error")
                    } else {
                        Text("The chat keeps its messages. The bot works in the project you pick.")
                    }
                }
                .listRowBackground(theme.surface)
            }
            .scrollContentBackground(.hidden)
        } else if loadFailed {
            ContentUnavailableView {
                Label("Projects didn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check that this chat's computer is on and connected, then try again.")
            } actions: {
                Button("Try Again") { loadAttempt += 1 }
                    .accessibilityIdentifier("chat.move-project.retry")
            }
        } else {
            ProgressView("Loading projects")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The chat's own project first, then the rest by name, so the row worth seeing is
    /// never the one to hunt for.
    static func ordered(
        _ projects: [HermesWorkspaceSummary],
        currentProjectID: String?
    ) -> [HermesWorkspaceSummary] {
        projects.sorted { lhs, rhs in
            let leftIsCurrent = lhs.id == currentProjectID
            let rightIsCurrent = rhs.id == currentProjectID
            if leftIsCurrent != rightIsCurrent { return leftIsCurrent }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// Picking the chat's own project just closes the sheet.
    private func row(_ project: HermesWorkspaceSummary) -> some View {
        let isCurrent = project.id == currentProjectID
        let isMoving = request?.projectID == project.id
        return Button {
            if isCurrent { dismiss() } else { request = MoveRequest(projectID: project.id) }
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: "folder")
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
                Text(project.name)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: BighelpTokens.space8)
                if isMoving {
                    Text("Moving…")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                } else if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.bighelp(.body).weight(.semibold))
                        .foregroundStyle(theme.action)
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        #if targetEnvironment(macCatalyst)
        .bighelpPointerButtonStyle(.borderless)
        #endif
        .disabled(request != nil)
        .accessibilityValue(isCurrent ? Text("This chat is here") : Text(""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("chat.move-project.\(project.id)")
    }

    private func load() async {
        loadFailed = false
        do {
            projects = try await move.store.projects(agentID: agentID)
        } catch is CancellationError {
        } catch {
            loadFailed = projects == nil
        }
    }

    private func perform(_ request: MoveRequest) async {
        moveError = nil
        do {
            let project = try await move.store.moveSession(sessionID, agentID: agentID, to: request.projectID)
            move.onMoved(project, sessionID)
            dismiss()
        } catch is CancellationError {
        } catch {
            moveError = (error as? WorkspaceClientError)?.errorDescription
                ?? String(localized: "The chat didn't move. Try again.")
            self.request = nil
        }
    }

    @BighelpThemeReader private var theme
}
