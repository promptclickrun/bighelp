import SwiftUI

/// The Computers screen: every computer, each a tap from its page.
@MainActor
struct BighelpHostsPage: View {
    let registry: BighelpHostRegistry

    var body: some View {
        Form { BighelpConfiguredHostsSection(registry: registry) }
            .navigationTitle("Computers")
    }
}

/// Top left while a computer connects or can't be reached: Computers, to switch
/// to another one or fix this one without waiting.
@MainActor
struct BighelpHostsToolbarLink: ToolbarContent {
    let registry: BighelpHostRegistry?

    var body: some ToolbarContent {
        if let registry {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink("Computers") { BighelpHostsPage(registry: registry) }
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

/// One computer's page: its name and state (Use this computer when it isn't the one in use), its
/// updates and restarts (the computer in use, while connected), its name, AI providers and
/// notifications, its address and sign-in, with Advanced options its Messaging, Upkeep and Setup,
/// then the caller's This device. Removing it keeps its chats and files. Settings' computer rows and
/// Settings › System open it.
@MainActor
struct BighelpConfiguredHostView<Extras: View>: View {
    let hostID: UUID
    let registry: BighelpHostRegistry
    /// Opens Settings › Models for the computer in use; nil hides AI providers.
    var onOpenProviders: (() -> Void)?
    /// The operations store when the caller has one (Hermes' System page); otherwise the page makes
    /// its own while this is the computer in use and connected.
    private let suppliedOperations: HostOperationsStore?
    private let suppliedAdministration: NativeAdministrationPresentation?
    /// Advanced · Setup's Computer voice test needs it; nil hides that row.
    private let permissionCenter: PermissionCenter?
    /// This device's rows (Settings' Connection details and Clear local cache), drawn whatever the
    /// computer's state: the caller decides what shows and when.
    private let extras: Extras
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationModel: HostNotificationSetupModel?
    @State private var pluginModel: HostNotificationSetupModel?
    @State private var updateModel: HostPluginUpdateModel?
    /// The computer's own pages, made while it's the one in use and connected. Let go when this page
    /// leaves the stack (the holder's `deinit`), never on `.onDisappear`: its own pages cover it too.
    @State private var kept: RetainedAdministration?
    @State private var showsRemove = false
    @State private var renaming: BighelpConfiguredHost?
    @State private var error: String?
    private var host: BighelpConfiguredHost? { registry.hosts.first { $0.id == hostID } }

    init(hostID: UUID, registry: BighelpHostRegistry, onOpenProviders: (() -> Void)? = nil,
         operations: HostOperationsStore? = nil, administration: NativeAdministrationPresentation? = nil,
         permissionCenter: PermissionCenter? = nil, @ViewBuilder extras: () -> Extras) {
        self.hostID = hostID
        self.registry = registry
        self.onOpenProviders = onOpenProviders
        suppliedOperations = operations
        suppliedAdministration = administration
        self.permissionCenter = permissionCenter
        self.extras = extras()
    }

    private var administration: NativeAdministrationPresentation? { kept?.presentation }
    private var isInUse: Bool { hostID == registry.selectedHostID }
    private var operations: HostOperationsStore? {
        guard isInUse else { return nil }
        return suppliedOperations ?? administration?.hostOperations
    }
    private var tools: NativeAdministrationPresentation? { suppliedAdministration ?? administration }

    /// The plugin is there: its version and updates. Not yet: the install step.
    private var pluginIsInstalled: Bool {
        if let updateModel, updateModel.state != .notInstalled, updateModel.state != .idle { return true }
        return pluginModel.map { $0.state == .installed || $0.state == .enabled } ?? false
    }

    var body: some View {
        Form {
            if let host {
                ComputerHeaderSection(host: host, registry: registry) { dismiss() }
                if let operations, operations.ownsScope {
                    HostUpdatesSections(store: operations, plugin: updateModel)
                    if updateModel?.state == .notInstalled, let pluginModel {
                        HostPluginInstallationSection(model: pluginModel)
                    }
                } else {
                    pluginSection
                }
                thisComputerSection(host)
                ComputerAccessSection(host: host, registry: registry)
                if let operations, operations.ownsScope {
                    HostAdvancedSections(store: operations, administration: tools,
                                         permissionCenter: permissionCenter)
                }
                HostThisDeviceSection { extras }
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
        .bighelpRefreshable {
            await operations?.load()
            await updateModel?.check()
        }
        .modifier(HostRenamePrompt(host: $renaming, registry: registry))
        .alert("Remove this computer from Bighelp?", isPresented: $showsRemove) {
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
        // The computer in use, while connected: its operations, over the registry's own connection.
        .task(id: ConnectionKey(inUse: isInUse, isConnected: isInUse && registry.selectedWorkspace?.isConnected == true,
                                generation: registry.generation)) {
            guard suppliedOperations == nil, isInUse, registry.selectedWorkspace?.isConnected == true else {
                kept = nil
                return
            }
            // Back from one of its pages: the same connection keeps its stores.
            if administration?.isCurrent == true { return }
            kept = NativeAdministrationPresentation.computer(hostID, registry: registry).map(RetainedAdministration.init)
        }
        .onDisappear {
            pluginModel?.cancel()
            notificationModel?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            pluginModel?.sceneChanged(to: phase)
            notificationModel?.sceneChanged(to: phase)
        }
    }

    private struct ConnectionKey: Hashable {
        let inUse: Bool
        let isConnected: Bool
        let generation: UUID
    }

    /// Another computer, or the one in use while it isn't connected: its plugin as the computers list
    /// knows it. Not installed yet: the install step.
    @ViewBuilder
    private var pluginSection: some View {
        if pluginIsInstalled, let updateModel {
            HostPluginUpdateSection(model: updateModel)
        } else if let pluginModel {
            HostPluginInstallationSection(model: pluginModel)
        }
    }

    private func thisComputerSection(_ host: BighelpConfiguredHost) -> some View {
        Section {
            Button { renaming = host } label: {
                ComputerValueRow(title: String(localized: "Name"), value: host.name)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hosts.rename")
            if isInUse, let onOpenProviders {
                Button(action: onOpenProviders) {
                    ComputerValueRow(title: String(localized: "AI providers"), value: nil)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hosts.providers")
            }
            if let notificationModel {
                NavigationLink {
                    Form { HostNotificationSetupSection(model: notificationModel) }
                        .bighelpFormSurface()
                        .navigationTitle("Notifications")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    ComputerValueRow(title: String(localized: "Notifications"),
                                     value: Self.notificationValue(notificationModel), showsChevron: false)
                }
                .accessibilityIdentifier("hosts.notifications")
            }
        } header: {
            Text("This computer")
        }
    }

    /// On, Off, or that setup needs a look.
    private static func notificationValue(_ model: HostNotificationSetupModel) -> String {
        if model.isWorking { return String(localized: "Checking…") }
        return switch model.state {
        case .enabled: String(localized: "On")
        case .notConfigured: String(localized: "Off")
        default: String(localized: "Needs a look")
        }
    }
}

extension BighelpConfiguredHostView where Extras == EmptyView {
    init(hostID: UUID, registry: BighelpHostRegistry, onOpenProviders: (() -> Void)? = nil,
         permissionCenter: PermissionCenter? = nil) {
        self.init(hostID: hostID, registry: registry, onOpenProviders: onOpenProviders,
                  permissionCenter: permissionCenter) { EmptyView() }
    }
}

/// The top of a computer's page: its icon, name and state, and Use this computer when it isn't the
/// one in use.
@MainActor
private struct ComputerHeaderSection: View {
    let host: BighelpConfiguredHost
    let registry: BighelpHostRegistry
    let onSelect: () -> Void

    var body: some View {
        Section {
            VStack(spacing: BighelpTokens.space8) {
                HostIcon(inUse: host.id == registry.selectedHostID, size: 64)
                Text(host.name)
                    .font(.bighelp(.title2).weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                connectionLine
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BighelpTokens.space8)
        }
        .listRowBackground(Color.clear)
        if host.id != registry.selectedHostID {
            Section {
                Button("Use this computer", systemImage: "checkmark.circle") {
                    registry.select(host.id)
                    onSelect()
                }
                .accessibilityIdentifier("hosts.select")
            }
        }
    }

    /// The computer in use: how its connection is doing. Another: where it is.
    @ViewBuilder
    private var connectionLine: some View {
        if let connection = HostStatus.connection(for: host, registry: registry) {
            BighelpConnectionPill(phase: connection.phase, label: HostStatus.line(connection, host: host))
        } else {
            Text(HostStatus.line(nil, host: host))
                .font(.bighelp(.subheadline))
                .foregroundStyle(.secondary)
        }
    }
}

/// A computer page's Access: its address and what gets past a proxy (behind a tap), and Sign in again.
@MainActor
private struct ComputerAccessSection: View {
    let host: BighelpConfiguredHost
    let registry: BighelpHostRegistry
    @State private var isAccessEditorPresented = false
    /// Bumped after editing access so the summary rereads Keychain.
    @State private var accessRevision = 0

    var body: some View {
        Section {
            NavigationLink {
                addressPage
            } label: {
                ComputerValueRow(title: String(localized: "Address and sign-in"), value: host.endpoint.host,
                                 showsChevron: false)
            }
            .accessibilityIdentifier("hosts.connection")
            Button("Sign in again", systemImage: "person.badge.key") { registry.beginAuthentication(for: host) }
                .accessibilityIdentifier("hosts.sign-in")
        } header: {
            Text("Access")
        }
    }

    private var addressPage: some View {
        Form {
            Section("Address") {
                Text(host.endpoint.identity).bighelpFont(.code).textSelection(.enabled)
            }
            Section {
                accessSummary(host.endpoint)
                    .id(accessRevision)
                Button("Edit access", systemImage: "lock.shield") { isAccessEditorPresented = true }
                    .accessibilityIdentifier("hosts.edit-access")
            } header: {
                Text("Sign-in")
            } footer: {
                Text("Sign-ins stay in this device's Keychain.")
            }
        }
        .bighelpFormSurface()
        .navigationTitle("Address and sign-in")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpSheet(isPresented: $isAccessEditorPresented) {
            HostAccessEditorView(endpoint: host.endpoint) {
                accessRevision += 1
                guard host.id == registry.selectedHostID, let workspace = registry.selectedWorkspace else { return }
                // New connections pick up the saved access; reconnect the current one now.
                Task { await workspace.suspend(); await workspace.reconnect() }
            }
            .bighelpSheetSize(.standard)
        }
    }

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
        } else {
            Text("Only the sign-in. No proxy access saved.")
                .bighelpFont(.metadata).foregroundStyle(.secondary)
        }
    }
}

/// A computer page row: the thing, its value under it.
private struct ComputerValueRow: View {
    let title: String
    let value: String?
    /// Buttons draw a chevron of their own; links get the List's, except on the Mac.
    var showsChevron = true

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bighelp(.body)).foregroundStyle(theme.primaryText)
                if let value, !value.isEmpty {
                    Text(value).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            if showsChevron || BighelpPlatform.drawsOwnLinkChevron {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}
