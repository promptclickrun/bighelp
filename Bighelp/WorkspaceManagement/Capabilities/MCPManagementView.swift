import SwiftUI

/// Settings › Hermes tools › MCP Servers: the profile's servers by state, each with its switch, then
/// the host's catalog under Add more. A server's name opens its page.
@MainActor
struct MCPManagementView: View {
    @Bindable var model: MCPManagementModel
    let hostName: String
    let profileName: String
    @State private var showsAdd = false
    @State private var catalogCandidate: MCPCatalogEntry?
    @State private var search = ""
    @State private var filter: HermesToolFilter = .all
    /// The server whose switch is changing, so only its row shows the new value.
    @State private var changing: HermesToolChange?
    @State private var opened: String?

    var body: some View {
        List {
            HermesToolSearchSection(search: $search, prompt: String(localized: "Search MCP servers"),
                                    searchIdentifier: "mcp.search", filters: [.all, .on, .off],
                                    filter: $filter, filtersIdentifier: "mcp.filters")
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy && changing == nil,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let snapshot = model.snapshot {
                content(snapshot)
            }
            CapabilitiesScopeSection(hostName: hostName, profileName: profileName)
        }
        .bighelpFormSurface()
        .bighelpRefreshable { await model.load() }
        .task { if model.snapshot == nil { await model.load() } }
        .navigationDestination(item: $opened) { name in
            MCPServerDetailView(model: model, serverName: name)
        }
        .bighelpSheet(isPresented: $showsAdd) {
            MCPServerFormView(isBusy: model.isBusy) { draft in
                showsAdd = false
                Task { await model.add(draft) }
            }
            .bighelpSheetSize(.standard)
        }
        .bighelpSheet(item: $catalogCandidate) { entry in
            MCPCatalogInstallView(entry: entry, isBusy: model.isBusy) { environment, enabled in
                catalogCandidate = nil
                Task { await model.install(entry, environment: environment, enable: enabled) }
            }
            .bighelpSheetSize(.standard)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: MCPSnapshot) -> some View {
        let servers = snapshot.servers.filter {
            ManagementSearch.matches(search, $0.name, $0.transport) && filter.admits(isOn: $0.isEnabled)
        }
        let catalog = filter != .all ? [] : snapshot.catalog.filter({
            !$0.isInstalled && ManagementSearch.matches(search, $0.name, $0.summary, $0.transport)
        })
        if servers.isEmpty, catalog.isEmpty, ManagementSearch.isActive(search) {
            ManagementSearchEmptySection(search: search)
        } else {
            if snapshot.servers.isEmpty {
                Section { Text("No MCP servers yet.").foregroundStyle(.secondary) }
            } else if servers.isEmpty {
                Section { Text("No servers match this filter.").foregroundStyle(.secondary) }
            }
            serverSection(String(localized: "On"), servers.filter(\.isEnabled))
            serverSection(String(localized: "Off"), servers.filter { !$0.isEnabled })
            Section {
                Button("Add server", systemImage: "plus") { showsAdd = true }
                    .disabled(model.isBusy)
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            if !catalog.isEmpty {
                Section {
                    ForEach(catalog) { catalogRow($0) }
                } header: {
                    Text(HermesTools.heading(String(localized: "Add more"), catalog.count))
                } footer: {
                    Text("Only declared fields are sent to Hermes. Secrets are not saved in Bighelp.")
                }
            }
            if !snapshot.diagnostics.isEmpty, !ManagementSearch.isActive(search), filter == .all {
                Section("Advanced · Catalog diagnostics") {
                    ForEach(snapshot.diagnostics, id: \.self) { Text($0).font(.bighelp(.footnote)) }
                }
            }
        }
    }

    @ViewBuilder
    private func serverSection(_ title: String, _ servers: [MCPServer]) -> some View {
        if !servers.isEmpty {
            Section(HermesTools.heading(title, servers.count)) {
                ForEach(servers) { serverRow($0) }
            }
        }
    }

    private func serverRow(_ server: MCPServer) -> some View {
        HermesToolRow(art: MCPServer.art(server.name), name: server.name, detail: detail(server),
                      open: { opened = server.name }) {
            HermesToolSwitch(title: server.name, isOn: server.isEnabled,
                             pending: changing?.pending(for: server.id), isLocked: model.isBusy,
                             identifier: "mcp.server.switch.\(server.name)") { set($0, server) }
        }
        .accessibilityIdentifier("mcp.server.\(server.name)")
    }

    private func catalogRow(_ entry: MCPCatalogEntry) -> some View {
        HermesToolRow(art: .symbol("shippingbox", key: entry.name), name: entry.name,
                      detail: entry.summary.isEmpty ? MCPServer.transportName(entry.transport) : entry.summary) {
            HermesToolGetButton(accessibilityLabel: "Get \(entry.name)",
                                identifier: "mcp.catalog.get.\(entry.name)",
                                isDisabled: model.isBusy) { catalogCandidate = entry }
        }
        .accessibilityIdentifier("mcp.catalog.\(entry.name)")
    }

    private func detail(_ server: MCPServer) -> String {
        guard let runtime = model.runtimeStatus(for: server.name) else {
            return MCPServer.transportName(server.transport)
        }
        return HermesTools.line(runtime.state.displayName,
                                runtime.toolCount == 1 ? "1 tool" : "\(runtime.toolCount.formatted()) tools")
    }

    private func set(_ isOn: Bool, _ server: MCPServer) {
        guard changing == nil, !model.isBusy else { return }
        changing = HermesToolChange(id: server.id, isOn: isOn)
        Task {
            await model.setEnabled(isOn, server: server)
            changing = nil
        }
    }
}

private extension MCPServer {
    /// MCP servers have no logo or topic from the host: a plug tile, its color by name.
    static func art(_ name: String) -> HermesToolArt {
        .symbol("point.3.connected.trianglepath.dotted", key: name)
    }

    /// "http" and "stdio" in everyday words.
    static func transportName(_ transport: String) -> String {
        switch transport.lowercased() {
        case "http", "sse", "streamable-http": String(localized: "Online server")
        case "stdio": String(localized: "Runs on the computer")
        default: transport.uppercased()
        }
    }
}

private struct MCPServerFormView: View {
    let isBusy: Bool
    let save: (MCPServerDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var transport: MCPServerDraft.Transport = .http
    @State private var url = ""
    @State private var command = ""
    @State private var arguments = ""
    @State private var authentication: MCPServerDraft.Authentication = .none
    @State private var bearerToken = ""
    @State private var environmentKey = ""
    @State private var environmentValue = ""
    @State private var enabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Transport", selection: $transport) {
                        Text("HTTP").tag(MCPServerDraft.Transport.http)
                        Text("Standard input/output").tag(MCPServerDraft.Transport.stdio)
                    }
                    Toggle("Enable for new sessions", isOn: $enabled)
                }
                if transport == .http {
                    Section("Connection") {
                        TextField("https://server.example/mcp", text: $url)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL)
                        Picker("Authentication", selection: $authentication) {
                            Text("None").tag(MCPServerDraft.Authentication.none)
                            Text("Browser OAuth").tag(MCPServerDraft.Authentication.oauth)
                            Text("Bearer token").tag(MCPServerDraft.Authentication.bearer)
                        }
                        if authentication == .bearer {
                            SecureField("Bearer token", text: $bearerToken)
                                .textContentType(.password)
                        }
                    }
                } else {
                    Section("Connection") {
                        TextField("Executable", text: $command).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("One argument per line", text: $arguments, axis: .vertical)
                            .lineLimit(2...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Section {
                        TextField("VARIABLE_NAME", text: $environmentKey)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        SecureField("Value", text: $environmentValue).textContentType(.password)
                    } header: {
                        Text("Advanced · Environment")
                    } footer: {
                        Text("The value is discarded when this form closes.")
                    }
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Add MCP server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save(draft) }.disabled(!isValid || isBusy)
                }
            }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (transport == .http
                ? (!url.isEmpty && (authentication != .bearer || !bearerToken.isEmpty))
                : (!command.isEmpty && (environmentKey.isEmpty == environmentValue.isEmpty)))
    }

    private var draft: MCPServerDraft {
        var result = MCPServerDraft()
        result.name = name
        result.transport = transport
        result.url = url
        result.command = command
        result.arguments = arguments.split(whereSeparator: \.isNewline).map(String.init)
        if !environmentKey.isEmpty { result.environment = [environmentKey: environmentValue] }
        result.authentication = authentication
        result.bearerToken = bearerToken
        result.isEnabled = enabled
        return result
    }
}

private struct MCPCatalogInstallView: View {
    let entry: MCPCatalogEntry
    let isBusy: Bool
    let install: ([String: String], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var enabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Name", value: entry.name)
                    LabeledContent("Source", value: entry.source)
                    LabeledContent("Transport", value: entry.transport.uppercased())
                    LabeledContent("Authentication", value: entry.authType)
                    if let command = entry.command { LabeledContent("Command", value: command).textSelection(.enabled) }
                    if let url = entry.url { LabeledContent("URL", value: url).textSelection(.enabled) }
                    Toggle("Enable for new sessions", isOn: $enabled)
                }
                Section("Advanced · Source") {
                    if let installURL = entry.installURL { LabeledContent("Install source", value: installURL).textSelection(.enabled) }
                    if let reference = entry.installReference { LabeledContent("Pinned reference", value: reference).textSelection(.enabled) }
                    if !entry.bootstrap.isEmpty { LabeledContent("Bootstrap", value: entry.bootstrap.joined(separator: " ")).textSelection(.enabled) }
                }
                if !entry.requiredEnvironment.isEmpty {
                    Section("Required configuration") {
                        ForEach(entry.requiredEnvironment) { requirement in
                            SecureField(requirement.prompt, text: Binding(
                                get: { values[requirement.name] ?? "" },
                                set: { values[requirement.name] = $0 }
                            ))
                            .textContentType(.password)
                            Text(requirement.name).font(.bighelp(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                if !entry.postInstall.isEmpty { Section("After installation") { Text(entry.postInstall) } }
                Section {
                    Button("Install this catalog server") { install(values, enabled) }
                        .disabled(isBusy || missingRequiredValue)
                } footer: {
                    Text("Only this entry and its declared fields are sent to Hermes. Values are not stored in Bighelp.")
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Install MCP server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private var missingRequiredValue: Bool {
        entry.requiredEnvironment.filter(\.isRequired).contains { (values[$0.name] ?? "").isEmpty }
    }
}

/// One server: its switch, its connection (test, sign in, API key), the tools it adds, Advanced
/// details and Remove.
@MainActor
private struct MCPServerDetailView: View {
    @Bindable var model: MCPManagementModel
    let serverName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsRemoval = false
    @State private var showsCredentialUpdate = false
    /// The new value while this page's switch is changing.
    @State private var changing: Bool?

    private var server: MCPServer? { model.snapshot?.servers.first { $0.name == serverName } }

    var body: some View {
        List {
            if let server {
                Section {
                    HermesToolHeader(art: .symbol("point.3.connected.trianglepath.dotted", key: server.name),
                                     name: server.name, summary: summary(server))
                }
                CapabilitiesStatusSections(
                    support: model.support, isBusy: model.isBusy && changing == nil,
                    errorMessage: model.errorMessage, successMessage: model.successMessage,
                    retry: { Task { await model.test(server) } }
                )
                Section {
                    HermesToolSwitch(title: String(localized: "Turned on"), isOn: server.isEnabled,
                                     pending: changing, isLocked: model.isBusy, showsTitle: true,
                                     identifier: "mcp.server.enabled") { set($0, server) }
                } footer: {
                    Text("New chats in this profile use the change.")
                }
                connectionSection(server)
                toolsSection(server)
                advancedSections(server)
                Section {
                    Button("Remove server", role: .destructive) { confirmsRemoval = true }
                        .disabled(model.isBusy)
                }
            } else {
                ContentUnavailableView("Server unavailable", systemImage: "externaldrive.badge.questionmark")
            }
        }
        .bighelpFormSurface()
        .navigationTitle(serverName)
        .navigationBarTitleDisplayMode(.inline)
        // Back from signing in in the browser: check right away.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let server, let flow = model.oauthFlows[server.name],
                  [.starting, .authorizationRequired].contains(flow.status) else { return }
            Task { await model.pollOAuth(server) }
        }
        .bighelpSheet(isPresented: $showsCredentialUpdate) {
            MCPServerCredentialEditorView(model: model, serverName: serverName)
                .bighelpSheetSize(.standard)
        }
        .confirmationDialog("Remove this MCP server?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            if let server {
                Button("Remove \(server.name)", role: .destructive) {
                    Task { await model.remove(server); if model.errorMessage == nil { dismiss() } }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes only the selected profile’s server configuration. Hermes-managed OAuth tokens for that server follow the host’s removal policy.")
        }
    }

    private func summary(_ server: MCPServer) -> String {
        guard let runtime = model.runtimeStatus(for: server.name) else {
            return MCPServer.transportName(server.transport)
        }
        return HermesTools.line(MCPServer.transportName(server.transport), runtime.state.displayName)
    }

    @ViewBuilder
    private func connectionSection(_ server: MCPServer) -> some View {
        Section("Connection") {
            Button("Test connection", systemImage: "stethoscope") { Task { await model.test(server) } }
                .disabled(model.isBusy)
            if server.auth != "oauth" {
                Button("Update API key", systemImage: "key") { showsCredentialUpdate = true }
                    .disabled(model.isBusy)
            }
            if server.auth == "oauth" && server.transport == "http" {
                Button("Authorize in browser", systemImage: "safari") {
                    Task {
                        if let url = await model.startOAuth(server) { openURL(url) }
                    }
                }
                if let flow = model.oauthFlows[server.name] {
                    LabeledContent("Authorization", value: HermesTools.readable(flow.status.rawValue))
                    Button("Check authorization") { Task { await model.pollOAuth(server) } }
                    Button("Cancel authorization", role: .destructive) { Task { await model.cancelOAuth(server) } }
                }
            }
        }
    }

    @ViewBuilder
    private func toolsSection(_ server: MCPServer) -> some View {
        Section("Tools it adds") {
            if let probe = model.probes[server.name] {
                if let error = probe.error { Text(error).foregroundStyle(.secondary) }
                if probe.tools.isEmpty, probe.error == nil {
                    Text("This server offers no tools.").foregroundStyle(.secondary)
                }
                if probe.toolCount > probe.tools.count {
                    Text("Showing the first \(probe.tools.count.formatted()). Hermes uses only the tools your MCP settings include.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.secondary)
                }
                ForEach(probe.tools) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.bighelp(.body))
                        if !tool.summary.isEmpty {
                            Text(tool.summary).font(.bighelp(.footnote)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            } else if let runtime = model.runtimeStatus(for: server.name) {
                Text(runtime.toolCount == 1 ? "1 tool. Test the connection to see it."
                     : "\(runtime.toolCount.formatted()) tools. Test the connection to see them.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Test the connection to see its tools.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func advancedSections(_ server: MCPServer) -> some View {
        Section("Advanced") {
            LabeledContent("Transport", value: server.transport.uppercased())
            if let url = server.url { LabeledContent("URL", value: url).textSelection(.enabled) }
            if let command = server.command { LabeledContent("Command", value: command).textSelection(.enabled) }
            if let auth = server.auth { LabeledContent("Authentication", value: auth) }
            if !server.environmentKeys.isEmpty { LabeledContent("Environment", value: server.environmentKeys.joined(separator: ", ")) }
        }
        if let runtime = model.runtimeStatus(for: server.name) {
            Section {
                LabeledContent("State", value: runtime.state.displayName)
                LabeledContent("Connected", value: runtime.isConnected ? "Yes" : "No")
                LabeledContent("Registered tools", value: runtime.toolCount.formatted())
                if let checkedAt = model.runtimeSnapshot?.checkedAt {
                    LabeledContent("Checked", value: checkedAt.formatted(date: .abbreviated, time: .standard))
                }
            } header: {
                Text("Advanced · Runtime details")
            } footer: {
                Text("Cached status only; viewing it does not connect or authorize.")
            }
        }
        if let probe = model.probes[server.name] {
            Section("Advanced · Latest test") {
                LabeledContent("Result", value: probe.succeeded ? "Connected" : "Failed")
                LabeledContent("Tools on this server", value: probe.toolCount.formatted())
                LabeledContent("Prompts", value: probe.promptCount.formatted())
                LabeledContent("Resources", value: probe.resourceCount.formatted())
            }
        }
    }

    private func set(_ isOn: Bool, _ server: MCPServer) {
        guard changing == nil, !model.isBusy else { return }
        changing = isOn
        Task {
            await model.setEnabled(isOn, server: server)
            changing = nil
        }
    }
}

@MainActor
private struct MCPServerCredentialEditorView: View {
    @Bindable var model: MCPManagementModel
    let serverName: String
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var environmentVariable = ""
    @State private var confirmsUpdate = false

    private var server: MCPServer? { model.snapshot?.servers.first { $0.name == serverName } }

    var body: some View {
        NavigationStack {
            Form {
                if model.isBusy {
                    Section { ProgressView("Updating credential") }
                }
                if let message = model.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                        Button("Refresh server state") { Task { await model.load() } }
                            .disabled(model.isBusy)
                    }
                }
                if let server {
                    Section {
                        SecureField("New API key", text: $value)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .accessibilityIdentifier("mcp.server.api-key")
                        TextField("Environment variable (optional)", text: $environmentVariable)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("mcp.server.api-key-environment")
                    } header: {
                        Text("New credential")
                    } footer: {
                        Text("Blank uses Hermes’s default variable. The saved value is never read into Bighelp; this field is cleared after use.")
                    }
                    Section {
                        Button("Review API key update") { confirmsUpdate = true }
                            .disabled(!isValid || model.isBusy)
                    } footer: {
                        Text(server.transport == "http"
                            ? "Hermes stores the value in this profile and keeps only an Authorization-header reference in the server configuration."
                            : "Hermes stores the value in this profile and keeps only an environment reference in the server configuration.")
                    }
                } else {
                    ContentUnavailableView("Server unavailable", systemImage: "externaldrive.badge.questionmark")
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Update API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
            .onAppear { model.clearMessages() }
            .onDisappear { value = "" }
            .confirmationDialog("Update this server’s API key?", isPresented: $confirmsUpdate, titleVisibility: .visible) {
                if let server {
                    Button("Update") {
                        let submitted = value
                        let variable = environmentVariable.trimmingCharacters(in: .whitespacesAndNewlines)
                        value = ""
                        Task {
                            if await model.setAPIKey(
                                submitted,
                                environmentVariable: variable.isEmpty ? nil : variable,
                                server: server
                            ) { dismiss() }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Success appears only after Hermes acknowledges this server and profile and Bighelp reads the configuration back.")
            }
        }
    }

    private var isValid: Bool {
        guard !value.isEmpty, value.utf8.count <= 16_384,
              !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else { return false }
        let variable = environmentVariable.trimmingCharacters(in: .whitespacesAndNewlines)
        return variable.isEmpty
            || variable.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil
    }
}

private extension MCPRuntimeState {
    var displayName: String {
        switch self {
        case .connected: "Connected"
        case .disabled: "Turned off"
        case .connecting: "Connecting"
        case .failed: "Failed"
        case .configured: "Configured"
        }
    }
}
