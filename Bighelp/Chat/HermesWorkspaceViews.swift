import SwiftUI

@MainActor
/// A new Hermes project: a name, a folder chats will work in and, from the
/// Projects screen, a short description.
struct HermesWorkspaceCreateView: View {
    private enum Field: Hashable {
        case name
        case summary
        case folderPath
    }

    let store: HermesWorkspaceStore
    let agentID: String
    /// "Workspace" in a chat's folder picker, "Project" on the Projects screen.
    var noun = "Workspace"
    var onCreated: (() -> Void)? = nil

    @State private var name = ""
    @State private var summary = ""
    @State private var folderPath = ""
    /// The folder last opened from the list, whose subfolders are shown
    /// (rather than siblings matching its name).
    @State private var openedPath: String?
    /// The name follows the chosen folder until it's typed by hand.
    @State private var nameFollowsFolder = true
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled

    @BighelpThemeReader private var theme: BighelpTheme

    private var trimmedPath: String { folderPath.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// What the list shows: an opened folder's children, else matches for the typed name.
    private var listedPath: String { openedPath == folderPath ? folderPath + "/" : folderPath }
    private var secondaryStyle: AnyShapeStyle {
        uiV2Enabled ? AnyShapeStyle(theme.secondaryText) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Focusing writes back the same text; only a real edit stops auto-naming.
                    TextField("Name", text: Binding(get: { name }, set: { if $0 != name { name = $0; nameFollowsFolder = false } }),
                              prompt: Text("Name").bighelpFieldHint(theme))
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .name)
                        .accessibilityIdentifier("hermes-workspaces.create.name")
                    if noun == "Project" {
                        TextField("What it's for (optional)", text: $summary,
                                  prompt: Text("What it's for (optional)").bighelpFieldHint(theme), axis: .vertical)
                            .lineLimit(1...3)
                            .focused($focusedField, equals: .summary)
                            .accessibilityIdentifier("hermes-workspaces.create.summary")
                    }
                    TextField("Folder, like ~/projects/app", text: $folderPath,
                              prompt: Text("Folder, like ~/projects/app").bighelpFieldHint(theme))
                        .font(.bighelp(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .folderPath)
                        .accessibilityIdentifier("hermes-workspaces.create.path")
                } header: {
                    Text(noun)
                } footer: {
                    if trimmedPath.hasPrefix("~"), let full = HermesFolderPath.expanded(trimmedPath, home: store.homePath) {
                        Text("Full path: \(full)")
                    } else if !trimmedPath.isEmpty, !HermesFolderPath.isAccepted(trimmedPath) {
                        Text("Start with / for a full path, or ~/ for your home folder.")
                    }
                }
                .listRowBackground(uiV2Enabled ? theme.surface : nil)

                Section {
                    folderRows
                } header: {
                    if let page = store.folderSuggestions {
                        Text("Folders in \(HermesFolderPath.abbreviated(page.parentPath, home: store.homePath))")
                    } else {
                        Text("Remote folders")
                    }
                } footer: {
                    Text("Tap a folder to open it, or keep typing to narrow the list. The \(noun.lowercased()) uses the folder in the path above.")
                }
                .listRowBackground(uiV2Enabled ? theme.surface : nil)

                if uiV2Enabled {
                    if store.isCreating {
                        Section {
                            ProgressView("Creating \(noun.lowercased())…")
                                .accessibilityIdentifier("hermes-workspaces.create.progress")
                        }
                        .listRowBackground(theme.surface)
                    }
                    if let message = store.errorMessage {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme.danger)
                                .accessibilityIdentifier("hermes-workspaces.create.error")
                        }
                        .listRowBackground(theme.surface)
                    }
                }
            }
            .modifier(CapabilitySheetAppearance(theme: theme))
            .navigationTitle("New \(noun)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            if await store.create(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                folderPath: trimmedPath,
                                description: summary,
                                agentID: agentID
                            ) {
                                onCreated?()
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !HermesFolderPath.isAccepted(trimmedPath)
                            || store.isCreating
                    )
                    .accessibilityIdentifier("hermes-workspaces.create.submit")
                }
            }
        }
        .task(id: listedPath) {
            do {
                try await Task.sleep(for: .milliseconds(openedPath == folderPath ? 0 : 250))
                try Task.checkCancellation()
                await store.loadFolderSuggestions(typedPath: listedPath, agentID: agentID)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        .task {
            await Task.yield()
            focusedField = .name
        }
    }

    @ViewBuilder
    private var folderRows: some View {
        let page = store.folderSuggestions
        if let page, let above = HermesFolderPath.parent(of: page.parentPath) {
            Button {
                open(above)
            } label: {
                Label {
                    Text("Up to \(HermesFolderPath.abbreviated(above, home: store.homePath))")
                        .lineLimit(1).truncationMode(.head)
                } icon: {
                    Image(systemName: "arrow.turn.left.up")
                }
            }
            .accessibilityIdentifier("hermes-workspaces.folder-up")
        }
        if store.isLoadingFolderSuggestions && page == nil {
            BighelpThinkingOrb(scenario: .searching, scale: .inline, visibleLabel: "Looking for folders")
        } else if let message = store.folderSuggestionErrorMessage {
            Text(message).foregroundStyle(secondaryStyle)
        } else if let page, page.folders.isEmpty {
            Text(HermesFolderPath.query(for: listedPath)?.prefix.isEmpty == false
                 ? "No folders match that name here."
                 : "No folders inside \(HermesFolderPath.abbreviated(page.parentPath, home: store.homePath)).")
                .foregroundStyle(secondaryStyle)
        } else if let page {
            ForEach(Array(page.folders.enumerated()), id: \.element.id) { index, folder in
                Button {
                    open(folder.path)
                } label: {
                    HStack(spacing: BighelpTokens.space12) {
                        Image(systemName: "folder")
                            .foregroundStyle(uiV2Enabled ? AnyShapeStyle(theme.action) : AnyShapeStyle(.tint))
                        Text(folder.name)
                            .foregroundStyle(uiV2Enabled ? AnyShapeStyle(theme.primaryText) : AnyShapeStyle(.primary))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.bighelp(.footnote).weight(.semibold))
                            .foregroundStyle(secondaryStyle)
                    }
                    .contentShape(.rect)
                }
                .accessibilityLabel(folder.name)
                .accessibilityHint("Opens \(HermesFolderPath.abbreviated(folder.path, home: store.homePath))")
                .accessibilityIdentifier("hermes-workspaces.folder-suggestion.\(index)")
            }
            if page.nextOffset != nil {
                Text("More folders here. Keep typing to narrow the list.").foregroundStyle(secondaryStyle)
            }
        }
    }

    /// Puts the folder in the path (keeping "~/" when that's how it's being
    /// typed), lists what's inside it, and names the workspace after it.
    private func open(_ fullPath: String) {
        let path = trimmedPath.hasPrefix("/") ? fullPath : HermesFolderPath.abbreviated(fullPath, home: store.homePath)
        openedPath = path
        folderPath = path
        if nameFollowsFolder, fullPath != "/" {
            name = (fullPath as NSString).lastPathComponent
        }
    }
}
