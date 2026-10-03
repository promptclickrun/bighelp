import SwiftUI

/// The Hosts screen: every computer, each a tap from its page.
@MainActor
struct BighelpHostsPage: View {
    let registry: BighelpHostRegistry

    var body: some View {
        Form { BighelpConfiguredHostsSection(registry: registry) }
            .navigationTitle("Hosts")
    }
}

/// Top left while a computer connects or can't be reached: Hosts, to switch
/// to another one or fix this one without waiting.
@MainActor
struct BighelpHostsToolbarLink: ToolbarContent {
    let registry: BighelpHostRegistry?

    var body: some ToolbarContent {
        if let registry {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink("Hosts") { BighelpHostsPage(registry: registry) }
                    .accessibilityIdentifier("connection.hosts")
            }
        }
    }
}

/// Your computers: the one in use first-class, each one a tap from its page.
@MainActor
struct BighelpConfiguredHostsSection: View {
    let registry: BighelpHostRegistry
    @State private var renaming: BighelpConfiguredHost?

    var body: some View {
        Section("Computers") {
            ForEach(registry.hosts) { host in
                NavigationLink {
                    BighelpConfiguredHostView(hostID: host.id, registry: registry)
                } label: {
                    HostRowLabel(host: host, registry: registry)
                }
                .contextMenu {
                    if host.id != registry.selectedHostID {
                        Button("Use this computer", systemImage: "checkmark.circle") { registry.select(host.id) }
                    }
                    Button("Rename", systemImage: "pencil") { renaming = host }
                }
                .accessibilityIdentifier("hosts.host.\(host.id.uuidString)")
            }
            Button("Add a computer", systemImage: "plus") { registry.beginSetup() }
                .disabled(!registry.canConfigureHosts)
                .accessibilityIdentifier("hosts.add-host")
            if let error = registry.errorMessage { Text(error).bighelpFont(.metadata).foregroundStyle(.secondary) }
        }
        .modifier(HostRenamePrompt(host: $renaming, registry: registry))
    }
}

/// A computer's icon, name, and whether it's the one in use.
private struct HostRowLabel: View {
    let host: BighelpConfiguredHost
    let registry: BighelpHostRegistry

    var body: some View {
        let inUse = host.id == registry.selectedHostID
        let connection = HostStatus.connection(for: host, registry: registry)
        HStack(spacing: BighelpTokens.space12) {
            HostIcon(inUse: inUse, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let connection { BighelpConnectionIndicator(phase: connection.phase) }
                    Text(HostStatus.line(connection, host: host))
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                if let attention = HostPluginUpdateModel.existingModel(for: host.id)?.attentionTitle {
                    Text(attention)
                        .font(.bighelp(.footnote).weight(.medium))
                        .foregroundStyle(.tint)
                        .accessibilityIdentifier("hosts.host.plugin-update")
                }
            }
            Spacer(minLength: 0)
            if inUse {
                Image(systemName: "checkmark")
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(theme.action)
                    .accessibilityLabel("In use")
            }
        }
        .padding(.vertical, 2)
    }

    @BighelpThemeReader private var theme
}

private struct HostIcon: View {
    let inUse: Bool
    let size: CGFloat

    var body: some View {
        let tint = inUse ? theme.action : theme.secondaryText
        Image(systemName: "desktopcomputer")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: .circle)
            .accessibilityHidden(true)
    }

    @BighelpThemeReader private var theme
}

enum HostStatus {
    /// The computer in use is the one connected; the others have no status.
    @MainActor static func connection(for host: BighelpConfiguredHost,
                                      registry: BighelpHostRegistry) -> HostConnectionStatus? {
        guard host.id == registry.selectedHostID else { return nil }
        return HostConnectionStatus(workspace: registry.selectedWorkspace, keeper: WorkspaceConnectionKeeper.current)
    }

    /// "In use · Connected" for the computer in use; otherwise where it is.
    static func line(_ connection: HostConnectionStatus?, host: BighelpConfiguredHost) -> String {
        connection.map { "In use · \($0.label)" } ?? host.endpoint.host
    }
}

/// Rename a computer: only the name people see changes.
private struct HostRenamePrompt: ViewModifier {
    @Binding var host: BighelpConfiguredHost?
    let registry: BighelpHostRegistry
    @State private var draft = ""
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .alert("Rename computer", isPresented: Binding(get: { host != nil }, set: { if !$0 { host = nil } })) {
                TextField("Name", text: $draft)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("hosts.rename.field")
                Button("Save") {
                    guard let host else { return }
                    do { try registry.rename(host.id, to: draft) }
                    catch { self.error = error.localizedDescription }
                }
                .accessibilityIdentifier("hosts.rename.save")
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't rename", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .onChange(of: host?.id) { _, _ in draft = host?.name ?? "" }
    }
}

/// One computer: use it, rename it, sign in again, its plugin and alerts, and
/// (folded away) its address and access. Removing it keeps its chats and files.
@MainActor
struct BighelpConfiguredHostView: View {
    let hostID: UUID
    let registry: BighelpHostRegistry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationModel: HostNotificationSetupModel?
    @State private var pluginModel: HostNotificationSetupModel?
    @State private var updateModel: HostPluginUpdateModel?
    @State private var showsRemove = false
    @State private var renaming: BighelpConfiguredHost?
    @State private var isAccessEditorPresented = false
    /// Bumped after editing access so the summary rereads Keychain.
    @State private var accessRevision = 0
    @State private var error: String?
    private var host: BighelpConfiguredHost? { registry.hosts.first { $0.id == hostID } }

    /// What bighelp sends to get past a proxy or Cloudflare Access (names only, never values).
    @ViewBuilder
    private func accessSummary(_ endpoint: DirectHermesEndpoint) -> some View {
        let store = DirectHermesAccessCredentialStore.shared
        let access = store.savedCredentials(for: endpoint)
        let headers = store.savedCustomHeaders(for: endpoint)
        if access != nil || !headers.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let access {
                    Text(access.kind == .basic ? "Proxy username and password saved"
                                               : "Cloudflare Access service token saved")
                }
                if !headers.isEmpty {
                    Text("Custom headers: " + headers.map(\.name).joined(separator: ", "))
                }
            }
            .bighelpFont(.metadata).foregroundStyle(.secondary)
            .accessibilityIdentifier("hosts.cloudflare-access")
        }
    }

    /// The computer in use: how its connection is doing. Another: where it is.
    @ViewBuilder
    private func connectionHeader(_ host: BighelpConfiguredHost) -> some View {
        if let connection = HostStatus.connection(for: host, registry: registry) {
            BighelpConnectionPill(phase: connection.phase, label: HostStatus.line(connection, host: host))
        } else {
            Text(HostStatus.line(nil, host: host))
                .font(.bighelp(.subheadline))
                .foregroundStyle(.secondary)
        }
    }

    /// The plugin is there: its version and updates. Not yet: the install step.
    private var pluginIsInstalled: Bool {
        if let updateModel, updateModel.state != .notInstalled, updateModel.state != .idle { return true }
        return pluginModel.map { $0.state == .installed || $0.state == .enabled } ?? false
    }

    var body: some View {
        Form {
            if let host {
                Section {
                    VStack(spacing: BighelpTokens.space8) {
                        HostIcon(inUse: host.id == registry.selectedHostID, size: 64)
                        Text(host.name)
                            .font(.bighelp(.title2).weight(.bold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        connectionHeader(host)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BighelpTokens.space8)
                }
                .listRowBackground(Color.clear)
                Section {
                    if host.id != registry.selectedHostID {
                        Button("Use this computer", systemImage: "checkmark.circle") {
                            registry.select(host.id)
                            dismiss()
                        }
                        .accessibilityIdentifier("hosts.select")
                    }
                    Button("Rename", systemImage: "pencil") { renaming = host }
                        .accessibilityIdentifier("hosts.rename")
                    Button("Sign in again", systemImage: "person.badge.key") { registry.beginAuthentication(for: host) }
                        .accessibilityIdentifier("hosts.sign-in")
                }
                if pluginIsInstalled, let updateModel {
                    HostPluginUpdateSection(model: updateModel)
                } else if let pluginModel {
                    HostPluginInstallationSection(model: pluginModel)
                }
                if let notificationModel {
                    HostNotificationSetupSection(model: notificationModel)
                }
                Section {
                    DisclosureGroup("Address and access") {
                        Text(host.endpoint.identity).bighelpFont(.code).textSelection(.enabled)
                        accessSummary(host.endpoint)
                            .id(accessRevision)
                        Button("Edit access", systemImage: "lock.shield") { isAccessEditorPresented = true }
                            .accessibilityIdentifier("hosts.edit-access")
                    }
                    .accessibilityIdentifier("hosts.connection")
                }
                Section {
                    Button("Remove this computer", role: .destructive) { showsRemove = true }
                        .accessibilityIdentifier("hosts.remove")
                } footer: {
                    Text("Your chats and files stay on the computer.")
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            } else {
                Text("This computer is no longer set up on this device.")
            }
        }
        .bighelpFormSurface()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(HostRenamePrompt(host: $renaming, registry: registry))
        .sheet(isPresented: $isAccessEditorPresented) {
            if let host {
                HostAccessEditorView(endpoint: host.endpoint) {
                    accessRevision += 1
                    guard host.id == registry.selectedHostID, let workspace = registry.selectedWorkspace else { return }
                    // New connections pick up the saved access; reconnect the current one now.
                    Task { await workspace.suspend(); await workspace.reconnect() }
                }
                .bighelpSheetSize(.standard)
            }
        }
        .alert("Remove this computer from bighelp?", isPresented: $showsRemove) {
            Button("Remove", role: .destructive) {
                guard let host else { return }
                do { try registry.remove(host); dismiss() }
                catch { self.error = "The computer could not be completely removed. Unlock the device and try again." }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Its sign-in and drafts leave this device. Chats and files on the computer aren't touched.")
        }
        .task(id: hostID) {
            if let host {
                pluginModel = HostNotificationSetupModel(
                    host: host,
                    registry: registry,
                    enrollNotifications: false
                )
                notificationModel = HostNotificationSetupModel(host: host, registry: registry)
                await pluginModel?.refreshInstalledState()
                let update = HostPluginUpdateModel.model(for: host.id, registry: registry)
                updateModel = update
                await update.checkIfNeeded()
            }
        }
        .onDisappear {
            pluginModel?.cancel()
            notificationModel?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            pluginModel?.cancel()
            notificationModel?.cancel()
        }
    }
}

@MainActor
struct BighelpNativeHostMenu: View {
    let registry: BighelpHostRegistry
    let hasLinkHost: Bool
    let openAccount: () -> Void
    var body: some View {
        HStack {
            Menu {
                ForEach(registry.hosts) { host in
                    Button(host.name, systemImage: host.id == registry.selectedHostID ? "checkmark" : "server.rack") { registry.select(host.id) }
                }
                Button("Add Host", systemImage: "plus") { registry.beginSetup() }

            } label: {
                Label(registry.selectedHost?.name ?? "Hosts", systemImage: "server.rack")
                    .bighelpFont(.label, weight: .semibold).lineLimit(1).frame(minHeight: 44)
            }
            .accessibilityIdentifier("hosts.switcher")
            Spacer()
        }.padding(.horizontal)
    }
}
