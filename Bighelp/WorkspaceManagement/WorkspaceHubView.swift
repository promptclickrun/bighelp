import SwiftUI

@MainActor
struct WorkspaceHubView: View {
    let hostName: String
    let profileName: String
    let onOpen: (WorkspaceDestination) -> Void
    var unavailable: [WorkspaceDestination: String] = [:]

    @State private var search = ""

    @BighelpThemeReader private var theme

    private var visibleDestinations: [WorkspaceDestination] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspaceDestination.appMenuCases.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section("Current workspace") {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(hostName).font(.bighelp(.headline))
                    Text(profileName).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Workspace, \(hostName), profile \(profileName)")
                .listRowBackground(theme.surface)
            }

            ForEach(WorkspaceDestination.Section.allCases) { section in
                let destinations = visibleDestinations.filter { $0.section == section }
                if !destinations.isEmpty {
                    Section(section.rawValue) {
                        ForEach(destinations) { destination in
                            Button {
                                onOpen(destination)
                            } label: {
                                row(destination)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("workspace.open.\(destination.rawValue)")
                            .listRowBackground(theme.surface)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .tint(theme.action)
        .navigationTitle("Hermes Tools")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Find a tool")
        .overlay {
            if visibleDestinations.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .accessibilityIdentifier("workspace.hub")
    }

    private func row(_ destination: WorkspaceDestination) -> some View {
        HStack(alignment: .center, spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: destination.symbol)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(destination.title).font(.bighelp(.body))
                Text(unavailable[destination] ?? destination.summary)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: BighelpTokens.space8)
            if unavailable[destination] != nil {
                Image(systemName: "info.circle")
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct WorkspaceUnavailableView: View {
    let destination: WorkspaceDestination
    let hostName: String
    let reason: String

    var body: some View {
        ContentUnavailableView {
            Label(destination.title, systemImage: destination.symbol)
        } description: {
            Text("\(reason)\n\nSelected host: \(hostName)")
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("workspace.unavailable.\(destination.rawValue)")
    }
}

/// A host page while its computer reconnects (after you come back to the
/// app): it comes back by itself, so there's nothing to reopen.
struct WorkspaceReconnectingView: View {
    let destination: WorkspaceDestination
    let hostName: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(destination.title)
            } icon: {
                ProgressView()
            }
        } description: {
            Text("Reconnecting to \(hostName)…")
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("workspace.reconnecting.\(destination.rawValue)")
    }
}

struct WorkspaceDocumentationView: View {
    var body: some View {
        List {
            Section("Guides") {
                Link("Getting started", destination: URL(string: "https://hermes-agent.nousresearch.com/docs")!)
                Link("Web dashboard and remote access", destination: URL(string: "https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard")!)
                Link("Plugins", destination: URL(string: "https://hermes-agent.nousresearch.com/docs/developer-guide/plugins")!)
            }
            Section("About these links") {
                Text("These links open the official documentation. They do not enable unavailable host features or change Hermes settings.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Documentation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A content index over the selected host's actual session records. It shows
/// tasks/files themselves rather than sending the user to the Chats menu.
@MainActor
struct WorkspaceSessionContentView: View {
    let destination: WorkspaceDestination
    let catalog: SessionCatalogStore
    let profileID: String
    let isCurrent: @MainActor () -> Bool
    let onOpenChat: (SessionSummary) -> Void
    @State private var records: [SessionRecord] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var limit = 10

    var body: some View {
        List {
            if isLoading && records.isEmpty { ProgressView("Loading \(destination.title.lowercased())") }
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(records) { record in
                let tasks = record.activityEvents.reduce(nil as ChatTaskDrawerState?) { ChatTodoProjection.applying($1, to: $0) }
                let files = artifacts(record)
                if destination == .tasks && (tasks != nil || record.sessionGoal?.summary != nil) {
                    Section(record.title) {
                        if let goal = record.sessionGoal, let summary = goal.summary {
                            Label(summary, systemImage: goal.status == .paused ? "pause.circle" : "scope")
                        }
                        ForEach(tasks?.items ?? []) { task in
                            Label(task.content, systemImage: task.status == .completed ? "checkmark.circle" : "circle")
                                .strikethrough(task.status == .cancelled)
                        }
                        Button("Open chat") { onOpenChat(record.summary) }
                    }
                } else if destination == .artifacts && !files.isEmpty {
                    Section(record.title) {
                        ForEach(files) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(file.fileName, systemImage: file.kind == .image ? "photo" : "doc")
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                        }
                        Button("Open chat") { onOpenChat(record.summary) }
                    }
                }
            }
            if !isLoading && !hasContent {
                ContentUnavailableView(destination == .tasks ? "No tasks in recent chats" : "No artifacts in recent chats",
                    systemImage: destination.symbol)
            }
            Section {
                Text("From the latest messages in \(records.count) chats for this agent.")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
                if catalog.records.filter({ $0.agentIDs.contains(profileID) }).count > limit {
                    Button("Load more chats") { limit += 10 }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("workspace.content.\(destination.rawValue)")
        .task(id: limit) { await load() }
        .refreshable { await load() }
    }

    private var hasContent: Bool {
        records.contains { record in
            if destination == .artifacts { return !artifacts(record).isEmpty }
            return record.sessionGoal?.summary != nil || record.activityEvents.reduce(nil as ChatTaskDrawerState?) {
                ChatTodoProjection.applying($1, to: $0)
            } != nil
        }
    }

    private func artifacts(_ record: SessionRecord) -> [ChatAttachment] {
        let values = record.items.filter { $0.role == .assistant }.flatMap(\.attachments)
            + record.activityEvents.flatMap { $0.generatedMedia?.attachments ?? [] }
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private func load() async {
        guard isCurrent(), !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        error = nil
        let sources = Array(catalog.records.filter { $0.agentIDs.contains(profileID) }.prefix(limit))
        do {
            var next: [SessionRecord] = []
            for source in sources {
                try Task.checkCancellation()
                guard isCurrent() else { return }
                let record = try await catalog.hydrateInitialPage(id: source.id)
                guard isCurrent() else { return }
                next.append(record)
            }
            if records != next { records = next }
        } catch is CancellationError { }
        catch { if isCurrent() { self.error = "Some chat content could not be refreshed. Pull down to try again." } }
    }
}
