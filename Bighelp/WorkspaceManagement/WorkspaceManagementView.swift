import SwiftUI

@MainActor
struct WorkspaceManagementView: View {
    @Bindable var store: WorkspaceManagementStore
    let destination: WorkspaceDestination
    var onOpenExisting: ((WorkspaceDestination) -> Void)?


    @BighelpThemeReader private var theme

    private var isHostWide: Bool {
        if [.system, .memory, .logs, .webhooks].contains(destination) { return true }
        if case .files(let listing) = store.content { return listing.rootLabel == nil }
        return false
    }

    var body: some View {
        Group {
            if store.ownsScope {
                content
            } else {
                WorkspaceUnavailableView(destination: destination, hostName: store.hostName,
                    reason: "This workspace is no longer selected. Return to Workspace to open the current host.")
            }
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.action)
        .task(id: destination) { await store.load(destination) }
        .bighelpSheet(item: $store.review) { mutation in
            WorkspaceMutationReviewView(store: store, mutation: mutation)
                .bighelpSheetSize(.standard)
        }
        .bighelpSheet(isPresented: Binding(
            get: { store.filePreview != nil },
            set: { if !$0 { store.closePreview() } }
        )) {
            if store.ownsScope, let preview = store.filePreview {
                NavigationStack {
                    WorkspaceTextReader(title: preview.name, text: preview.text)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { store.closePreview() }.keyboardShortcut(.cancelAction)
                            }
                        }
                }
                .bighelpSheetSize(.large)
            }
        }
        .accessibilityIdentifier("workspace.management.\(destination.rawValue)")
        .onChange(of: store.ownsScope) { _, current in
            if !current { store.retire() }
        }
    }

    private var content: some View {
        List {
            Section("Workspace") {
                LabeledContent("Host", value: store.hostName)
                if isHostWide {
                    Text("Host-wide information, not restricted to one agent profile.")
                        .font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
                } else {
                    LabeledContent("Profile", value: store.profileName)
                }
            }
            WorkspaceManagementStatusSection(store: store)
            if let value = store.content {
                loadedContent(value)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .searchable(text: $store.search, prompt: "Search \(destination.title.lowercased())")
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").bighelpToolbarIcon()
                }
                .bighelpHelp("Refresh")
                .disabled(store.isLoading || store.isSaving)
            }
        }
    }

    @ViewBuilder
    private func loadedContent(_ content: WorkspaceManagementContent) -> some View {
        switch content {
        case .projects(let projects):
            WorkspaceProjectsSection(store: store, projects: projects)
        case .models(let catalog):
            WorkspaceModelsSection(store: store, catalog: catalog, onOpenProfiles: onOpenExisting.map { action in
                { action(.profiles) }
            })
        case .inventory(let items):
            if destination == .system {
                ForEach(items) { item in
                    Section(item.title) {
                        if let status = item.status { LabeledContent("Status", value: status) }
                        ForEach(item.details.filter { store.matches($0.label, $0.value) }) { detail in
                            LabeledContent(detail.label, value: detail.value)
                        }
                    }
                }
            } else {
                inventory(items)
            }
        case .fileRoots(let roots):
            Section("Host-granted folders") {
                Text("A host operator grants these folders. Signing in alone does not grant filesystem access.")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                ForEach(roots.filter { store.matches($0.label) }) { root in
                    Button {
                        Task { await store.load(.files, path: "", root: root.id) }
                    } label: {
                        Label(root.label, systemImage: "folder")
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .disabled(store.isLoading)
                }
                if roots.isEmpty {
                    Text("No folders have been granted on this host. Ask the host operator to grant an appropriate project folder.")
                        .foregroundStyle(.secondary)
                }
            }
        case .credentials(let keys):
            WorkspaceCredentialsSection(store: store, credentials: keys)
        case .webhooks(let webhooks, let enabled):
            Section("Status") {
                LabeledContent("Webhook platform", value: enabled ? "Enabled" : "Disabled")
                Text("These are the serving profile's existing webhooks. Global enablement, secrets, scripts and delivery configuration remain on Hermes.")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
            let rows = webhooks.filter { store.matches($0.id, $0.description) }
            Section("Webhooks") {
                ForEach(Array(rows.prefix(store.visibleLimit))) { webhook in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        Text(webhook.id).font(.bighelp(.headline))
                        Text(webhook.description).foregroundStyle(.secondary)
                        LabeledContent("Incoming events", value: webhook.isEnabled ? "Enabled" : "Disabled")
                        LabeledContent("Secret", value: webhook.hasSecret ? "Configured" : "Not set")
                        Text(webhook.events.joined(separator: ", ")).font(.bighelp(.footnote))
                        if store.canEdit {
                            Button(webhook.isEnabled ? "Disable" : "Enable") {
                                store.review = .setWebhookEnabled(name: webhook.id, enabled: !webhook.isEnabled)
                            }
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .disabled(!enabled && !webhook.isEnabled)
                        }
                    }
                }
                pagination(count: rows.count)
            }
        case .configuration(let configuration):
            WorkspaceConfigurationSection(store: store, configuration: configuration)
        case .files(let listing):
            WorkspaceFilesSection(store: store, listing: listing)
        case .logs(let lines):
            Section("Recent log severity") {
                Text("Only severity is shown. Log messages are withheld because they may contain prompts, file paths or credentials. Inspect detailed logs on the host.")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                let counts = Dictionary(grouping: lines) { String($0.prefix(while: { $0 != " " })) }
                ForEach(["CRITICAL", "ERROR", "WARNING", "WARN", "INFO", "DEBUG", "LOG"], id: \.self) { level in
                    if let entries = counts[level], store.matches(level) {
                        LabeledContent(level.capitalized, value: entries.count.formatted())
                    }
                }
                if lines.isEmpty {
                    Text("No recent log lines were reported.").foregroundStyle(.secondary)
                }
                Text("\(lines.count) lines returned by the host. This is a bounded tail, not a complete log history.")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
        }
    }

    private func inventory(_ items: [WorkspaceInventoryItem]) -> some View {
        let rows = items.filter { store.matches($0.title, $0.summary, $0.status ?? "") }
        return Section("Results") {
            ForEach(Array(rows.prefix(store.visibleLimit))) { item in
                NavigationLink {
                    WorkspaceInventoryDetailView(store: store, itemID: item.id, destination: destination)
                } label: {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        Text(item.title)
                        Text(item.status ?? item.summary).font(.bighelp(.caption)).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
            }
            pagination(count: rows.count)
        }
    }

    @MainActor
    struct WorkspaceInventoryDetailView: View {
        let store: WorkspaceManagementStore
        let itemID: String
        let destination: WorkspaceDestination

        private var item: WorkspaceInventoryItem? {
            guard store.ownsScope, case .inventory(let items) = store.content else { return nil }
            return items.first { $0.id == itemID }
        }

        var body: some View {
            Group {
                if let item {
                    List {
                        WorkspaceManagementStatusSection(store: store)
                        Section("Overview") {
                            Text(item.summary).fixedSize(horizontal: false, vertical: true)
                            if let status = item.status { LabeledContent("Status", value: status) }
                        }
                        Section("Details") {
                            ForEach(item.details) { detail in
                                LabeledContent(detail.label, value: detail.value)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    WorkspaceUnavailableView(destination: destination, hostName: store.hostName,
                        reason: "This item is no longer available in the selected workspace.")
                }
            }
            .navigationTitle(item?.title ?? destination.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func pagination(count: Int) -> some View {
        if count == 0 {
            Text(store.search.isEmpty ? "Nothing to show yet." : "No matching results.")
                .foregroundStyle(.secondary)
        } else if count > store.visibleLimit {
            Button("Show more (\(count - store.visibleLimit) remaining)") { store.loadMore() }
                .frame(minHeight: BighelpTokens.hitTarget)
        }
    }
}

@MainActor
struct WorkspaceManagementStatusSection: View {
    let store: WorkspaceManagementStore

    var body: some View {
        if store.isLoading || store.isSaving || store.isPreviewing {
            Section {
                ProgressView(store.isSaving ? "Waiting for Hermes confirmation" : store.isPreviewing ? "Opening file" : "Loading from Hermes")
            }
        }
        if let error = store.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                if store.content != nil {
                    Text("Showing the last successful read. Changes are disabled until refreshed.")
                        .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                }
                Button("Retry") { Task { await store.refresh() } }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .disabled(store.isLoading || store.isSaving)
            }
            .accessibilityIdentifier("workspace.error")
        }
        if let message = store.successMessage {
            Section { Label(message, systemImage: "checkmark.circle") }
                .accessibilityIdentifier("workspace.confirmed")
        }
    }
}

struct WorkspaceTextReader: View {
    let title: String
    let text: String

    private var chunks: [String] {
        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 4_096, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[index..<end]))
            index = end
        }
        return chunks
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                    Text(chunk).font(.bighelp(.body).monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
