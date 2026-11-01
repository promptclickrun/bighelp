import SwiftUI

@MainActor
struct WorkspaceProjectsSection: View {
    @Bindable var store: WorkspaceManagementStore
    let projects: [WorkspaceProject]

    private var rows: [WorkspaceProject] {
        projects.filter { $0.isArchived == store.showsArchived && store.matches($0.name, $0.summary) }
    }

    var body: some View {
        Section {
            Toggle("Show archived projects", isOn: $store.showsArchived)
            if rows.isEmpty {
                Text(store.search.isEmpty ? "No projects in this view." : "No matching projects.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(rows.prefix(store.visibleLimit))) { project in
                NavigationLink {
                    WorkspaceProjectDetailView(store: store, projectID: project.id)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(project.name)
                            if !project.summary.isEmpty {
                                Text(project.summary).font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: project.isArchived ? "archivebox" : "folder")
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
                .accessibilityIdentifier("workspace.project.\(project.id)")
            }
            if rows.count > store.visibleLimit {
                Button("Show more projects") { store.loadMore() }.frame(minHeight: BighelpTokens.hitTarget)
            }
        } header: { Text("Projects") } footer: {
            Text("Projects are registered folders, not copies on this device. Archiving never deletes their files.")
        }
    }
}

@MainActor
struct WorkspaceProjectDetailView: View {
    let store: WorkspaceManagementStore
    let projectID: String
    @State private var name = ""

    private var project: WorkspaceProject? {
        guard store.ownsScope, case .projects(let rows) = store.content else { return nil }
        return rows.first { $0.id == projectID }
    }

    var body: some View {
        List {
            WorkspaceManagementStatusSection(store: store)
            if let project {
                Section("Overview") {
                    LabeledContent("Project", value: project.name)
                    LabeledContent("Registration", value: project.isArchived ? "Archived" : "Active")
                    if !project.summary.isEmpty { Text(project.summary) }
                }
                Section("Registered folders") {
                    ForEach(project.folders) { folder in
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(folder.label ?? (folder.isPrimary ? "Primary folder" : "Folder"))
                            Text(folder.path).font(.bighelp(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if store.canEdit {
                    Section("Display name") {
                        TextField("Project name", text: $name)
                            .textInputAutocapitalization(.sentences)
                            .accessibilityIdentifier("workspace.project.name")
                        Button("Review rename") { store.review = .renameProject(id: project.id, name: name) }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || name == project.name || name.utf8.count > 200)
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    Section("Project status") {
                        Button(project.isArchived ? "Restore project" : "Archive project") {
                            store.review = .archiveProject(id: project.id, restore: project.isArchived)
                        }
                        .frame(minHeight: BighelpTokens.hitTarget)
                    }
                }
            } else {
                Text("This project is no longer available in the selected workspace.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(project?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = project?.name ?? "" }
    }
}

@MainActor
struct WorkspaceModelsSection: View {
    let store: WorkspaceManagementStore
    let catalog: WorkspaceModelCatalog
    let onOpenProfiles: (() -> Void)?

    private var hasMatches: Bool {
        catalog.providers.contains { provider in
            store.matches(provider.name) || provider.models.contains { store.matches($0) }
        }
    }

    var body: some View {
        Section("Profile default") {
            LabeledContent("Provider", value: catalog.currentProvider.isEmpty ? "Not configured" : catalog.currentProvider)
            LabeledContent("Model", value: catalog.currentModel.isEmpty ? "Not configured" : catalog.currentModel)
            if let onOpenProfiles {
                Button("Edit agent runtime defaults", action: onOpenProfiles)
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            Text("Individual sessions can use a different model. Provider requests and credentials remain managed by Hermes.")
                .font(.bighelp(.footnote)).foregroundStyle(.secondary)
        }
        ForEach(catalog.providers) { provider in
            let models = provider.models.filter { store.matches($0, provider.name) }
            if !models.isEmpty || store.matches(provider.name) {
                Section(provider.name) {
                    if let authenticated = provider.isAuthenticated {
                        LabeledContent("Credential", value: authenticated ? "Configured" : "Not configured")
                    }
                    ForEach(Array(models.prefix(store.visibleLimit)), id: \.self) { model in
                        HStack {
                            Text(model)
                            if provider.id == catalog.currentProvider && model == catalog.currentModel {
                                Image(systemName: "checkmark").accessibilityLabel("Profile default")
                            }
                        }
                        if !hasMatches {
                            Section {
                                Text(store.search.isEmpty ? "No configured providers were reported." : "No matching models or providers.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if models.isEmpty { Text("No models listed.").foregroundStyle(.secondary) }
                    if models.count > store.visibleLimit {
                        Button("Show more models") { store.loadMore() }.frame(minHeight: BighelpTokens.hitTarget)
                    }
                }
            }
        }
    }
}

@MainActor
struct WorkspaceConfigurationSection: View {
    let store: WorkspaceManagementStore
    let configuration: WorkspaceReasoningConfiguration

    var body: some View {
        Section {
            LabeledContent("Default effort", value: configuration.effort.title)
            LabeledContent("Show reasoning on Hermes", value: configuration.showsReasoning ? "Yes" : "No")
            if store.canEdit {
                Menu("Change default effort") {
                    ForEach(WorkspaceReasoningConfiguration.Effort.allCases) { effort in
                        Button(effort.title) { store.review = .reasoning(effort) }
                            .disabled(effort == configuration.effort)
                    }
                }
                .frame(minHeight: BighelpTokens.hitTarget)
            }
        } header: {
            Text("Profile reasoning")
        } footer: {
            Text("This changes only the selected profile's default. Session overrides remain separate. Other host configuration and approval policy stay in their dedicated Hermes controls; raw configuration is never displayed.")
        }
    }
}

@MainActor
struct WorkspaceFilesSection: View {
    let store: WorkspaceManagementStore
    let listing: WorkspaceFileListing

    @State private var options = FileExplorerOptions()

    private var rows: [WorkspaceFileListing.Entry] {
        options.apply(listing.entries.filter { store.matches($0.name) })
    }

    var body: some View {
        Section {
            FileExplorerControls(options: $options, showsSearch: false)
            LabeledContent(listing.rootLabel == nil ? "Permitted root" : "Granted folder", value: listing.rootLabel ?? listing.root)
            Text(listing.path.isEmpty ? "Root folder" : listing.path).font(.bighelp(.footnote)).textSelection(.enabled)
            if listing.rootLabel != nil {
                Button("All granted folders", systemImage: "folder.badge.gearshape") {
                    Task { await store.load(.files) }
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .disabled(store.isLoading)
            }
            if let parent = listing.parent {
                Button("Parent folder", systemImage: "arrow.up") {
                    Task { await store.load(.files, path: parent, root: listing.root) }
                }
                .frame(minHeight: BighelpTokens.hitTarget)
            }
            if rows.isEmpty { Text("No files in this view.").foregroundStyle(.secondary) }
            ForEach(Array(rows.prefix(store.visibleLimit))) { entry in
                Button {
                    Task {
                        if entry.isDirectory {
                            await store.load(.files, path: entry.path, root: listing.root)
                        } else {
                            await store.preview(entry, root: listing.root)
                        }
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(entry.name)
                            if let size = entry.size {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
                .disabled(store.isLoading || store.isPreviewing)
            }
            if rows.count > store.visibleLimit {
                Button("Show more files") { store.loadMore() }.frame(minHeight: BighelpTokens.hitTarget)
            } else if listing.nextPage != nil {
                Button("Load next directory page") { Task { await store.loadMoreFiles() } }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .disabled(store.isLoading)
            }
        } header: { Text("Folder") } footer: {
            Text("Read-only browsing within the root confirmed by Hermes. Search filters loaded directory pages. Text previews are limited to 256 KB. No arbitrary path entry, file deletion or host terminal is exposed.")
        }
    }
}
