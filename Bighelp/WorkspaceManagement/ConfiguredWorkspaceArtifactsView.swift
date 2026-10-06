import SwiftUI

/// Discovers only the selected host's configured workspace before mounting the
/// existing confined artifact browser. No default or user-authored root is used.
@MainActor
struct ConfiguredWorkspaceArtifactsView: View {
    let hostName: String
    let owner: WorkspaceOwner
    let http: any DirectHermesNativeHTTP & DirectHermesAuthenticatedHTTP
    let performer: any WorkspaceOperationPerforming
    let currentOwner: @MainActor () -> WorkspaceOwner?
    var isEmbedded = false
    /// Offered when Hermes can't find the agent's folder.
    var folderChooser: WorkspaceFolderChooser?
    @State private var scope: DirectHermesWorkspaceFileScope?
    @State private var canChooseFolder = false
    @State private var isChoosingFolder = false
    @State private var scopeClient: DirectHermesManagedFilesClient?
    @State private var artifactClient: DirectHermesArtifactClient?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let scope, let scopeClient, let artifactClient, scope.owner == owner, currentOwner() == owner {
                WorkspaceArtifactsView(hostName: hostName, owner: owner, scope: scope,
                    performer: artifactClient, scopeValidator: { try await scopeClient.workspaceScope() },
                    isCurrent: { currentOwner() == owner }, isEmbedded: isEmbedded)
                    .id(Data(scope.root.utf8))
            } else if isLoading {
                ProgressView("Finding the workspace…")
            } else {
                ContentUnavailableView {
                    Label("Workspace unavailable", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(errorMessage ?? "The host has not confirmed its configured workspace.")
                } actions: {
                    if canChooseFolder, folderChooser != nil {
                        Button("Choose Workspace Folder") { isChoosingFolder = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("workspace.choose-folder")
                    }
                    Button("Try Again") { Task { await loadScope() } }
                }
            }
        }
        .bighelpSheet(isPresented: $isChoosingFolder) {
            if let folderChooser {
                WorkspaceFolderPicker(chooser: folderChooser) { Task { await loadScope() } }
                    .bighelpSheetSize(.standard)
            }
        }
        .navigationTitle(isEmbedded ? "" : "Artifacts")
        .task(id: owner) { await loadScope() }
    }

    /// Says why, so an old plugin reads as "update it" instead of a dead end.
    static func message(for error: Error) -> String {
        switch error as? WorkspaceClientError {
        case .unavailable(.unsupportedOperation)?, .unavailable(.pluginRequired)?:
            "This host's bighelp plugin doesn't share workspace files yet. Update it in Settings, under this "
                + "computer's Plugin version, then try again."
        case .rejected(let code)? where WorkspaceClientError.workspaceFilesMessage(code) != nil:
            WorkspaceClientError.workspaceFilesMessage(code) ?? ""
        case let known?:
            known.localizedDescription + " No other folder was opened."
        case nil:
            (error as? DirectHermesManagedFilesError)?.localizedDescription
                ?? "The host could not confirm access to its configured workspace. No other folder was opened."
        }
    }

    private func loadScope() async {
        guard currentOwner() == owner else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let client = DirectHermesManagedFilesClient(http: http, owner: owner, currentOwner: currentOwner)
            let verified = try await client.workspaceScope()
            try Task.checkCancellation()
            guard currentOwner() == owner, verified.owner == owner else { return }
            scopeClient = client
            artifactClient = DirectHermesArtifactClient(http: http, owner: owner,
                fallback: performer, currentOwner: currentOwner)
            scope = verified
        } catch is CancellationError {
        } catch {
            guard currentOwner() == owner else { return }
            scope = nil
            scopeClient = nil
            artifactClient = nil
            errorMessage = Self.message(for: error)
            canChooseFolder = WorkspaceFolderChooser.canFix(error)
        }
    }
}
