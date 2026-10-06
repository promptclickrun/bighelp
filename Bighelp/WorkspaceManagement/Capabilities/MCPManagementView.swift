import SwiftUI

@MainActor
struct MCPManagementView: View {
    @Bindable var model: MCPManagementModel
    let hostName: String
    let profileName: String
    @State private var showsAdd = false
    @State private var catalogCandidate: MCPCatalogEntry?
    @State private var search = ""

    var body: some View {
        List {
            CapabilitiesScopeSection(hostName: hostName, profileName: profileName)
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let snapshot = model.snapshot {
                let servers = snapshot.servers.filter { ManagementSearch.matches(search, $0.name, $0.transport) }
                let catalog = snapshot.catalog.filter {
                    ManagementSearch.matches(search, $0.name, $0.summary, $0.transport)
                }
                if ManagementSearch.isActive(search), servers.isEmpty, catalog.isEmpty {
                    ManagementSearchEmptySection(search: search)
                } else {
                    Section("Your servers") {
                        if snapshot.servers.isEmpty { Text("No MCP servers configured.").foregroundStyle(.secondary) }
                        ForEach(servers) { server in
                            NavigationLink {
                                MCPServerDetailView(model: model, serverName: server.name)
                            } label: {
                                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                    Text(server.name)
                                    Text("\(server.transport.uppercased()) • \(server.isEnabled ? "Enabled" : "Disabled")")
                                        .font(.bighelp(.caption)).foregroundStyle(.secondary)
                                    if let runtime = model.runtimeStatus(for: server.name) {
                                        Text("Runtime: \(runtime.state.displayName) • \(runtime.toolCount) tools")
                                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(minHeight: BighelpTokens.hitTarget)
                            }
                        }
                        Button("Add server", systemImage: "plus") { showsAdd = true }
                            .disabled(model.isBusy)
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }

                    Section {
                        ForEach(catalog) { entry in
                            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                                HStack {
                                    Text(entry.name).font(.bighelp(.headline))
                                    Spacer()
                                    if entry.isInstalled { Image(systemName: "checkmark.circle.fill").accessibilityLabel("Installed") }
                                }
                                if !entry.summary.isEmpty { Text(entry.summary).font(.bighelp(.subheadline)) }
                                Text("\(entry.transport.uppercased()) • \(entry.authType)")
                                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                                Button(entry.isInstalled ? "Already installed" : "Review installation") {
                                    catalogCandidate = entry
                                }
                                .buttonStyle(.bordered)
                                .disabled(entry.isInstalled || model.isBusy)
                            }
                            .padding(.vertical, BighelpTokens.space4)
                        }
                    } header: { Text("Add from catalog") }
                      footer: { Text("Only declared fields are sent to Hermes. Secrets are not saved in bighelp.") }

                    if !snapshot.diagnostics.isEmpty, !ManagementSearch.isActive(search) {
                        Section("Advanced · Catalog diagnostics") {
                            ForEach(snapshot.diagnostics, id: \.self) { Text($0).font(.bighelp(.footnote)) }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search MCP servers")
        .refreshable { await model.load() }
        .task { if model.snapshot == nil { await model.load() } }
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
                    Text("Only this entry and its declared fields are sent to Hermes. Values are not stored in bighelp.")
                }
            }
            .navigationTitle("Install MCP server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
        }
    }

    private var missingRequiredValue: Bool {
        entry.requiredEnvironment.filter(\.isRequired).contains { (values[$0.name] ?? "").isEmpty }
    }
}

@MainActor
private struct MCPServerDetailView: View {
    @Bindable var model: MCPManagementModel
    let serverName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsRemoval = false
    @State private var showsCredentialUpdate = false

    private var server: MCPServer? { model.snapshot?.servers.first { $0.name == serverName } }

    var body: some View {
        List {
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { if let server { await model.test(server) } } }
            )
            if let server {
                Section("Overview") {
                    LabeledContent("Transport", value: server.transport.uppercased())
                    LabeledContent("Status", value: server.isEnabled ? "Enabled" : "Disabled")
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
                Section("Manage server") {
                    Button(server.isEnabled ? "Disable" : "Enable") {
                        Task { await model.setEnabled(!server.isEnabled, server: server) }
                    }
                    Button("Test connection", systemImage: "stethoscope") { Task { await model.test(server) } }
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
                            LabeledContent("Authorization", value: flow.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                            Button("Check authorization") { Task { await model.pollOAuth(server) } }
                            Button("Cancel authorization", role: .destructive) { Task { await model.cancelOAuth(server) } }
                        }
                    }
                    Button("Remove server", role: .destructive) { confirmsRemoval = true }
                }
                if let probe = model.probes[server.name] {
                    Section("Advanced · Latest test") {
                        LabeledContent("Result", value: probe.succeeded ? "Connected" : "Failed")
                        LabeledContent("Tools on this server", value: probe.toolCount.formatted())
                        LabeledContent("Prompts", value: probe.promptCount.formatted())
                        LabeledContent("Resources", value: probe.resourceCount.formatted())
                        if let error = probe.error { Text(error).foregroundStyle(.secondary) }
                        if probe.toolCount > probe.tools.count {
                            Text("Showing the first \(probe.tools.count.formatted()). Hermes uses only the tools your MCP settings include.")
                                .font(.bighelp(.footnote))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(probe.tools) { tool in
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(tool.name)
                                if !tool.summary.isEmpty { Text(tool.summary).font(.bighelp(.caption)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Server unavailable", systemImage: "externaldrive.badge.questionmark")
            }
        }
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
                        Text("Blank uses Hermes’s default variable. The saved value is never read into bighelp; this field is cleared after use.")
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
                Text("Success appears only after Hermes acknowledges this server and profile and bighelp reads the configuration back.")
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
        case .disabled: "Disabled"
        case .connecting: "Connecting"
        case .failed: "Failed"
        case .configured: "Configured"
        }
    }
}
