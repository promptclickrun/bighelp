import SwiftUI

/// When Hermes can't tell which folder is an agent's workspace (no working folder of its own, or
/// a missing one), the person picks one on the computer. It's saved as the agent's working folder
/// (`terminal.cwd`, Hermes' own setting), so the agent and Files agree on it.
@MainActor
struct WorkspaceFolderChooser {
    /// One folder's subfolders on the host ("~" for home).
    let list: @MainActor (String) async throws -> HermesWorkspaceFolderPage
    /// Saves the full path as the working folder.
    let save: @MainActor (String) async throws -> Void

    /// Problems a chosen folder fixes. Containers, SSH and Windows aren't one of them.
    static func canFix(_ error: any Error) -> Bool {
        guard case .rejected(let code)? = error as? WorkspaceClientError else { return false }
        return ["workspace_not_configured", "workspace_unavailable", "workspace_hermes_folder"].contains(code)
    }

    /// Hermes' folder listing and config, through the selected host's workspace client.
    static func live(client: DirectHermesWorkspaceClient, owner: WorkspaceOwner, profileID: String) -> Self {
        Self(
            list: { path in
                let response = try await client.listFolder(path: path, owner: owner)
                return try HermesFolderListing.page(response, requestedPath: path, prefix: "", offset: 0, limit: 500)
            },
            save: { path in
                let result = try await client.perform(.configSet, payload: [
                    "profile": .string(profileID), "key": .string("terminal.cwd"), "value": .string(path),
                ], owner: owner)
                guard result["key"]?.string == "terminal.cwd" else { throw WorkspaceClientError.invalidResponse }
            }
        )
    }
}

/// Browse the host's folders from home, open one to look inside, and use the one showing.
struct WorkspaceFolderPicker: View {
    let chooser: WorkspaceFolderChooser
    let onChosen: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = "~"
    @State private var page: HermesWorkspaceFolderPage?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(page?.parentPath ?? path, systemImage: "folder")
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .lineLimit(2)
                        .accessibilityIdentifier("workspace.chooser.current")
                    if let parent = HermesFolderPath.parent(of: page?.parentPath ?? path) {
                        Button { open(parent) } label: { Label("Up", systemImage: "arrow.up") }
                            .accessibilityIdentifier("workspace.chooser.up")
                    }
                } footer: {
                    Text("Pick the folder your agent keeps its files in. It becomes the agent's working folder, so new chats start there too.")
                }
                Section("Folders") {
                    if isLoading {
                        ProgressView()
                    } else if let folders = page?.folders, !folders.isEmpty {
                        ForEach(folders) { folder in
                            Button { open(folder.path) } label: {
                                Label(folder.name, systemImage: "folder")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("workspace.chooser.folder.\(folder.name)")
                        }
                    } else {
                        Text("No folders here.").foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Workspace folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                        #endif
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This Folder") { use() }
                        .disabled(page == nil || isSaving)
                        .accessibilityIdentifier("workspace.chooser.use")
                }
            }
            .task { await load(path) }
        }
    }

    private func open(_ next: String) {
        Task { await load(next) }
    }

    private func load(_ next: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            page = try await chooser.list(next)
            path = page?.parentPath ?? next
            message = nil
        } catch {
            message = "That folder couldn't be opened."
        }
    }

    private func use() {
        guard let folder = page?.parentPath else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await chooser.save(folder)
                onChosen()
                dismiss()
            } catch {
                message = "Hermes couldn't use that folder. Pick another one."
            }
        }
    }
}
