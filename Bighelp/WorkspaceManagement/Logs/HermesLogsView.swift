import SwiftUI

@MainActor
struct HermesLogsDestinationView: View {
    @State private var store: HermesLogsStore

    init(
        hostName: String,
        owner: WorkspaceOwner,
        http: any DirectHermesAuthenticatedHTTP,
        workspace: any WorkspaceOperationPerforming,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        let client = DirectHermesLogsClient(
            http: http,
            workspace: workspace,
            owner: owner,
            currentOwner: currentOwner
        )
        _store = State(initialValue: HermesLogsStore(hostName: hostName, owner: owner, client: client))
    }

    var body: some View {
        HermesLogsView(store: store)
    }
}

@MainActor
struct HermesLogsView: View {
    @Bindable var store: HermesLogsStore

    var body: some View {
        Group {
            if !store.ownsScope {
                ContentUnavailableView(
                    "Logs are no longer connected",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Return to Workspace and reopen Logs for the selected host."))
            } else if store.isUnsupported {
                ContentUnavailableView {
                    Label("Logs unavailable", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("This Hermes host does not expose the authenticated bounded GET /api/logs endpoint. bighelp did not fall back to host files or a console.")
                } actions: {
                    Button("Try Again") { Task { await store.refresh() } }
                }
            } else {
                logList
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.appliedQuery == nil { await store.refresh(resetWindow: true) } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .disabled(store.isLoading || !store.ownsScope)
            }
        }
        .onChange(of: store.ownsScope) { _, ownsScope in
            if !ownsScope { store.retire() }
        }
        .onDisappear { store.retire() }
        .accessibilityIdentifier("workspace.logs")
    }

    private var logList: some View {
        List {
            Section("Workspace") {
                LabeledContent("Host", value: store.hostName)
                Text("Logs are host-wide and private. bighelp keeps only this in-memory window, marks it sensitive, and discards it when this screen closes.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
            }

            filterSection

            if store.isLoading {
                Section { ProgressView("Loading bounded logs…") }
            }
            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { Task { await store.refresh() } }
                        .disabled(store.isLoading)
                }
                .accessibilityIdentifier("logs.error")
            }

            if !store.entries.isEmpty {
                Section("Newest first") {
                    ForEach(store.entries) { entry in
                        logRow(entry)
                    }
                    if store.canLoadEarlier {
                        Button("Load earlier lines") { Task { await store.loadEarlier() } }
                            .frame(minHeight: BighelpTokens.hitTarget)
                    } else if store.appliedQuery?.lineLimit == HermesLogQuery.maximumLineLimit,
                              store.entries.count == HermesLogQuery.maximumLineLimit {
                        Text("Reached bighelp’s 500-line maximum window.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !store.isLoading && store.errorMessage == nil && store.appliedQuery != nil {
                Section {
                    ContentUnavailableView(
                        "No matching log lines",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Change the fixed filters or refresh this host window."))
                }
            }

            if let query = store.appliedQuery {
                Section("Window") {
                    Text("\(store.entries.count) lines returned from the requested last \(query.lineLimit). Hermes applies level, component, and text filters on the server before bighelp displays the bounded result.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .bighelpRefreshable { await store.refresh() }
    }

    private var filterSection: some View {
        Section {
            Picker("Log file", selection: $store.selectedFile) {
                ForEach(HermesLogFile.allCases) { file in
                    Text(file.title).tag(file)
                }
            }
            .pickerStyle(.menu)
            Picker("Minimum severity", selection: $store.selectedLevel) {
                ForEach(HermesLogLevelFilter.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.menu)
            Picker("Component", selection: $store.selectedComponent) {
                ForEach(HermesLogComponent.allCases) { component in
                    Text(component.title).tag(component)
                }
            }
            .pickerStyle(.menu)
            TextField("Contains text", text: $store.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .onSubmit { Task { await store.applyFilters() } }
            Button("Apply filters", systemImage: "line.3.horizontal.decrease") {
                Task { await store.applyFilters() }
            }
            .disabled(store.isLoading || !store.hasUnappliedFilters)
        } header: { Text("Filters") } footer: {
            Text("Search is a case-insensitive host-side substring filter, not console input. Filter text is sent only to the selected Hermes host and is discarded with this screen.")
        }
    }

    private func logRow(_ entry: HermesLogEntry) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: .firstTextBaseline) {
                Label(entry.severity.title, systemImage: entry.severity.symbol)
                    .font(.bighelp(.caption).weight(.semibold))
                Spacer(minLength: BighelpTokens.space8)
                if let timestamp = entry.timestampText {
                    Text(timestamp)
                        .font(.bighelp(.caption).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Host time \(timestamp)")
                }
            }
            if let logger = entry.logger {
                Text(logger)
                    .font(.bighelp(.caption).monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(entry.message.isEmpty ? "No message text" : entry.message)
                .font(.bighelp(.body).monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .privacySensitive()
        }
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .combine)
    }
}
