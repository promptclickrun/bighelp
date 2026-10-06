import SwiftUI

@MainActor
struct HermesWorkspacePickerView: View {
    let store: HermesWorkspaceStore
    let agentID: String
    let sessionID: String?
    let onSelected: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(
        store: HermesWorkspaceStore,
        agentID: String,
        sessionID: String? = nil,
        onSelected: (() -> Void)? = nil
    ) {
        self.store = store
        self.agentID = agentID
        self.sessionID = sessionID
        self.onSelected = onSelected
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                HermesWorkspaceManagerContent(
                    store: store,
                    agentID: agentID,
                    sessionID: sessionID
                ) {
                    onSelected?()
                    dismiss()
                }
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.vertical, BighelpTokens.space16)
            }
            .scrollIndicators(.hidden)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: "\(agentID)|\(sessionID ?? "none")") {
            await store.load(agentID: agentID, sessionID: sessionID)
        }
        .accessibilityIdentifier("hermes-workspaces.screen")
    }

    @BighelpThemeReader private var theme: BighelpTheme

}

@MainActor
struct HermesWorkspaceManagerContent: View {
    let store: HermesWorkspaceStore
    let agentID: String
    let sessionID: String?
    let onSelected: () -> Void

    @State private var isCreatePresented = false
    @State private var workspacePendingArchive: HermesWorkspaceSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(spacing: BighelpTokens.space8) {
                Text("Manage Workspaces")
                    .bighelpFont(.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: BighelpTokens.space8)
                BighelpHeaderActionButton(
                    systemImage: "plus",
                    accessibilityLabel: "New Workspace"
                ) {
                    isCreatePresented = true
                }
                .accessibilityIdentifier("hermes-workspaces.create")
            }

            HermesWorkspaceRows(
                store: store,
                agentID: agentID,
                sessionID: sessionID,
                onSelected: onSelected,
                onArchive: { workspacePendingArchive = $0 }
            )
        }
        .bighelpSheet(isPresented: $isCreatePresented) {
            HermesWorkspaceCreateView(store: store, agentID: agentID)
        }
        .confirmationDialog(
            workspacePendingArchive.map { "Archive \($0.name)?" } ?? "Archive Workspace?",
            isPresented: Binding(
                get: { workspacePendingArchive != nil },
                set: { if !$0 { workspacePendingArchive = nil } }
            ),
            titleVisibility: .visible,
            presenting: workspacePendingArchive
        ) { workspace in
            Button("Archive Workspace", role: .destructive) {
                workspacePendingArchive = nil
                Task { await store.archive(id: workspace.id, agentID: agentID) }
            }
            Button("Cancel", role: .cancel) {
                workspacePendingArchive = nil
            }
        } message: { _ in
            Text("This archives the Workspace registration. Its remote folders and files are not deleted.")
        }
    }

    @BighelpThemeReader private var theme: BighelpTheme

}

@MainActor
struct HermesWorkspaceRows: View {
    let store: HermesWorkspaceStore
    let agentID: String
    let sessionID: String?
    let onSelected: () -> Void
    let onArchive: (HermesWorkspaceSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if store.isLoading, store.catalog == nil {
                BighelpThinkingOrb(
                    scenario: .searching,
                    visibleLabel: "Loading Workspaces"
                )
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if let catalog = store.catalog, catalog.workspaces.isEmpty {
                ContentUnavailableView(
                    "No Workspaces",
                    systemImage: "square.stack.3d.up",
                    description: Text("Create a Workspace on your Hermes host, then try again.")
                )
            } else if let catalog = store.catalog {
                ForEach(catalog.workspaces) { workspace in
                    let isSelected = HermesWorkspaceSelectionPresentation.isSelected(
                        workspace,
                        store: store,
                        sessionID: sessionID
                    )
                    HStack(spacing: BighelpTokens.space4) {
                        Button {
                            Task {
                                if await store.select(
                                    id: workspace.id,
                                    agentID: agentID,
                                    sessionID: sessionID
                                ) {
                                    onSelected()
                                }
                            }
                        } label: {
                            workspaceRow(workspace)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.selectingID != nil || store.archivingID != nil)
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                        .accessibilityIdentifier("hermes-workspace.\(workspace.id)")

                        Button {
                            onArchive(workspace)
                        } label: {
                            if store.archivingID == workspace.id {
                                BighelpThinkingOrb(scenario: .working, scale: .inline)
                                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                            } else {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(theme.secondaryText)
                                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(store.selectingID != nil || store.archivingID != nil || store.isCreating)
                        .accessibilityLabel("Archive \(workspace.name)")
                        .accessibilityIdentifier("hermes-workspace.archive.\(workspace.id)")
                    }
                    .padding(.trailing, BighelpTokens.space4)
                    .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
                    .overlay {
                        RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                            .stroke(
                                isSelected ? theme.action : theme.border,
                                lineWidth: isSelected ? 1.5 : BighelpTokens.hairline
                            )
                    }
                }
            } else {
                ContentUnavailableView(
                    "Workspaces unavailable",
                    systemImage: "square.stack.3d.up",
                    description: Text(store.errorMessage ?? "Connect to the selected Hermes host and try again.")
                )
            }

            if let message = store.errorMessage {
                Text(message)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    Task {
                        await store.load(agentID: agentID, sessionID: sessionID)
                    }
                }
                    .bighelpActionStyle()
                    .tint(theme.action)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hermes-workspaces.content")
    }

    private func workspaceRow(_ workspace: HermesWorkspaceSummary) -> some View {
        let isSelected = HermesWorkspaceSelectionPresentation.isSelected(
            workspace,
            store: store,
            sessionID: sessionID
        )
        return HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: isSelected
                ? "square.stack.3d.up.fill"
                : "square.stack.3d.up")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isSelected ? theme.action : theme.primaryText)
                .frame(width: 36, height: 36)
                .background(theme.raisedSurface, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.name)
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(theme.primaryText)
                if !workspace.description.isEmpty {
                    Text(workspace.description)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(workspace.folderCount) \(workspace.folderCount == 1 ? "folder" : "folders")")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
            }
            Spacer(minLength: BighelpTokens.space8)
            if store.selectingID == workspace.id {
                BighelpThinkingOrb(scenario: .working, scale: .inline)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.action)
            }
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme: BighelpTheme

}

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
