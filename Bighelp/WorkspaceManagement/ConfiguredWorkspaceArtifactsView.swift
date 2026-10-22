import SwiftUI

/// Whose configured workspace Files reads, on which connection: a selected agent's own folder, or
/// (no agent) the folder of the agent serving the bighelp plugin, as Nerd Mode's Artifacts shows it.
struct WorkspaceFilesTarget: Hashable {
    let owner: WorkspaceOwner
    let agentID: String?
}

/// A target's folder as the host proved it, and what reads inside it.
struct ConfiguredWorkspace: Identifiable {
    struct ID: Hashable {
        let target: WorkspaceFilesTarget
        let root: String
    }

    let target: WorkspaceFilesTarget
    let scope: DirectHermesWorkspaceFileScope
    let performer: any WorkspaceOperationPerforming
    let validateScope: WorkspaceArtifactsStore.ScopeValidator

    var id: ID { ID(target: target, root: scope.root) }
}

/// Where Files finds an agent's folder: the bighelp plugin on the selected host, or the demo's.
@MainActor
protocol ConfiguredWorkspaceSource {
    /// `currentOwner` turns nil once the target leaves the screen, so a late reply never lands.
    func open(_ target: WorkspaceFilesTarget,
              currentOwner: @escaping @MainActor () -> WorkspaceOwner?) async throws -> ConfiguredWorkspace
    /// Saves a chosen folder for the agent `open` reads, never another one; nil when that agent isn't known.
    func folderChooser(for target: WorkspaceFilesTarget) -> WorkspaceFolderChooser?
}

/// The bighelp plugin's workspace-files routes on the selected host. Another agent's folder needs
/// plugin 3.20.0; the serving agent never names itself, so older plugins keep working for it.
struct HostConfiguredWorkspace: ConfiguredWorkspaceSource {
    let http: any DirectHermesNativeHTTP & DirectHermesAuthenticatedHTTP
    let workspace: any WorkspaceOperationPerforming

    func open(_ target: WorkspaceFilesTarget,
              currentOwner: @escaping @MainActor () -> WorkspaceOwner?) async throws -> ConfiguredWorkspace {
        let files = DirectHermesManagedFilesClient(http: http, owner: target.owner, agentID: target.agentID,
                                                   currentOwner: currentOwner)
        let scope = try await files.workspaceScope()
        let artifacts = DirectHermesArtifactClient(http: http, owner: target.owner, fallback: workspace,
                                                   agentID: target.agentID, currentOwner: currentOwner)
        return .init(target: target, scope: scope, performer: artifacts,
                     validateScope: { try await files.workspaceScope() })
    }

    func folderChooser(for target: WorkspaceFilesTarget) -> WorkspaceFolderChooser? {
        guard let client = workspace as? DirectHermesWorkspaceClient,
              let profile = target.agentID ?? client.nativeContext?.servingProfileID else { return nil }
        return .live(client: client, owner: target.owner, profileID: profile)
    }
}

/// Discovers only the target agent's configured workspace before mounting the
/// existing confined artifact browser. No default or user-authored root is used.
@MainActor
struct ConfiguredWorkspaceArtifactsView: View {
    let hostName: String
    let target: WorkspaceFilesTarget
    let source: any ConfiguredWorkspaceSource
    /// The target on screen now. Another agent or connection makes this one's late replies drop.
    let currentTarget: @MainActor () -> WorkspaceFilesTarget?
    var isEmbedded = false
    /// What was found, and for which target: nothing, or anything kept for another one, reads as loading.
    @State private var shown: (target: WorkspaceFilesTarget, phase: Phase)?
    @State private var isChoosingFolder = false
    @State private var presentedChooser: WorkspaceFolderChooser?

    private enum Phase {
        case opened(ConfiguredWorkspace)
        /// The chooser is offered when Hermes can't find the agent's folder.
        case failed(String, folderChooser: WorkspaceFolderChooser?)
    }

    var body: some View {
        Group {
            switch shown?.target == target && currentTarget() == target ? shown?.phase : nil {
            case .opened(let workspace)?:
                WorkspaceArtifactsView(hostName: hostName, owner: target.owner, scope: workspace.scope,
                    performer: workspace.performer, scopeValidator: workspace.validateScope,
                    isCurrent: { currentTarget() == target }, isEmbedded: isEmbedded)
                    .id(workspace.id)
            case .failed(let message, let folderChooser)?:
                ContentUnavailableView {
                    Label("Workspace unavailable", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(message)
                } actions: {
                    if let folderChooser {
                        Button("Choose Workspace Folder") {
                            presentedChooser = folderChooser
                            isChoosingFolder = true
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("workspace.choose-folder")
                    }
                    Button("Try Again") { Task { await loadScope() } }
                }
            case nil:
                ProgressView("Finding the workspace…")
            }
        }
        .bighelpSheet(isPresented: $isChoosingFolder) {
            if let presentedChooser {
                WorkspaceFolderPicker(chooser: presentedChooser) { Task { await loadScope() } }
                    .bighelpSheetSize(.standard)
            }
        }
        .navigationTitle(isEmbedded ? "" : "Artifacts")
        .task(id: target) { await loadScope() }
    }

    /// Says why, so an old plugin reads as "update it" instead of a dead end.
    static func message(for error: Error) -> String {
        switch error as? WorkspaceClientError {
        case .unavailable(.unsupportedOperation)?, .unavailable(.pluginRequired)?:
            "This host's bighelp plugin doesn't share workspace files yet. Update it in Settings, under this "
                + "computer's Plugin version, then try again."
        case .rejected(let code, _)? where WorkspaceClientError.workspaceFilesMessage(code) != nil:
            WorkspaceClientError.workspaceFilesMessage(code) ?? ""
        case let known?:
            known.localizedDescription + " No other folder was opened."
        case nil:
            (error as? DirectHermesManagedFilesError)?.localizedDescription
                ?? "The host could not confirm access to its configured workspace. No other folder was opened."
        }
    }

    /// Opens the target's folder. Nil when another agent or connection took its place meanwhile,
    /// so a late reply for one agent never fills the next one's Files.
    static func open(_ target: WorkspaceFilesTarget, from source: any ConfiguredWorkspaceSource,
                     currentTarget: @escaping @MainActor () -> WorkspaceFilesTarget?) async throws -> ConfiguredWorkspace? {
        let workspace = try await source.open(target, currentOwner: {
            currentTarget() == target ? target.owner : nil
        })
        try Task.checkCancellation()
        guard currentTarget() == target, workspace.target == target, workspace.scope.owner == target.owner else {
            return nil
        }
        return workspace
    }

    private func loadScope() async {
        guard currentTarget() == target else { return }
        shown = nil
        do {
            guard let workspace = try await Self.open(target, from: source, currentTarget: currentTarget) else { return }
            shown = (target, .opened(workspace))
        } catch is CancellationError {
        } catch {
            guard currentTarget() == target else { return }
            shown = (target, .failed(Self.message(for: error),
                folderChooser: WorkspaceFolderChooser.canFix(error) ? source.folderChooser(for: target) : nil))
        }
    }
}
