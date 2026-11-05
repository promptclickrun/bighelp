import SwiftUI

/// A bot's Active Project (its profile › Active Project): the projects on its computer and the one Hermes
/// starts its new chats in. Choosing one makes it current for this bot only; its chats keep their own
/// projects (a chat moves with ⋯ › Move to Project…).
@MainActor
struct BotActiveProjectView: View {
    let store: HermesWorkspaceStore
    let agentID: String
    let botName: String
    var onChange: () -> Void = {}

    @BighelpThemeReader private var theme

    var body: some View {
        Form {
            if let catalog = store.catalog, store.catalogAgentID == agentID {
                if catalog.workspaces.isEmpty {
                    Section {
                        Text("No projects yet. Make one in Projects, then choose it here.")
                            .foregroundStyle(theme.secondaryText)
                    }
                    .listRowBackground(theme.surface)
                } else {
                    Section {
                        ForEach(catalog.workspaces) { project in
                            row(project, isCurrent: project.id == catalog.activeWorkspaceID)
                        }
                    } footer: {
                        Text("\(botName)'s new chats start in this project's folder. Chats you already have stay in their own project.")
                    }
                    .listRowBackground(theme.surface)
                }
                if let message = store.errorMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(theme.danger)
                    }
                    .listRowBackground(theme.surface)
                }
            } else if let message = store.errorMessage {
                Section {
                    Text(message)
                        .foregroundStyle(theme.secondaryText)
                    Button(String(localized: "Try again")) { Task { await store.load(agentID: agentID) } }
                }
                .listRowBackground(theme.surface)
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
                    .listRowBackground(theme.surface)
            }
        }
        .bighelpFormSurface()
        .navigationTitle(String(localized: "Active Project"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load(agentID: agentID) }
        .accessibilityIdentifier("bot-project.screen")
    }

    private func row(_ project: HermesWorkspaceSummary, isCurrent: Bool) -> some View {
        Button {
            Task { if await store.select(id: project.id, agentID: agentID) { onChange() } }
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: "folder")
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.bighelp(.body, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    if !project.description.isEmpty {
                        Text(project.description)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: BighelpTokens.space8)
                if store.selectingID == project.id {
                    ProgressView()
                } else if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.bighelp(.body).weight(.semibold))
                        .foregroundStyle(theme.action)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(store.selectingID != nil)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("bot-project.\(project.id)")
    }
}
