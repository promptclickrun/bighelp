import SwiftUI

/// The page of the computer in use, from its operations store (Settings › System, the `.system`
/// destination, `-test-system-page`). With the computers list at hand it's that computer's page
/// (`BighelpConfiguredHostView`); without one (the fixture), just its updates, restarts and Advanced.
/// `extras` go in This device, after Advanced (Settings' Connection details and Clear local cache).
@MainActor
struct HostOperationsView<Extras: View>: View {
    let store: HostOperationsStore
    /// The computer's other pages (logs, webhooks, tool backends, Kanban boards, voice test, achievements).
    private let administration: NativeAdministrationPresentation?
    private let permissionCenter: PermissionCenter?
    private let extras: Extras
    @State private var pluginUpdate: HostPluginUpdateModel?
    @Environment(\.bighelpHostRegistry) private var hostRegistry

    /// `pluginUpdate` is for fixtures; otherwise the page reads the selected computer's own.
    init(store: HostOperationsStore, pluginUpdate: HostPluginUpdateModel? = nil,
         administration: NativeAdministrationPresentation? = nil, permissionCenter: PermissionCenter? = nil,
         @ViewBuilder extras: () -> Extras) {
        self.store = store
        self.administration = administration
        self.permissionCenter = permissionCenter
        _pluginUpdate = State(initialValue: pluginUpdate)
        self.extras = extras()
    }

    var body: some View {
        if pluginUpdate == nil, let hostRegistry, let hostID = hostRegistry.selectedHostID {
            BighelpConfiguredHostView(hostID: hostID, registry: hostRegistry, operations: store,
                                      administration: administration, permissionCenter: permissionCenter) {
                extras
            }
        } else {
            // HostUpdatesSections loads the store.
            Form {
                HostUpdatesSections(store: store, plugin: pluginUpdate)
                HostAdvancedSections(store: store, administration: administration,
                                     permissionCenter: permissionCenter)
                HostThisDeviceSection { extras }
            }
            .bighelpFormSurface()
            .navigationTitle(store.hostName)
            .navigationBarTitleDisplayMode(.inline)
            .bighelpRefreshable { await store.load() }
        }
    }
}

extension HostOperationsView where Extras == EmptyView {
    init(store: HostOperationsStore, pluginUpdate: HostPluginUpdateModel? = nil,
         administration: NativeAdministrationPresentation? = nil, permissionCenter: PermissionCenter? = nil) {
        self.init(store: store, pluginUpdate: pluginUpdate, administration: administration,
                  permissionCenter: permissionCenter) { EmptyView() }
    }
}

// MARK: - Updates and Restart

/// A computer page's Updates (Hermes, the bighelp plugin, Check for updates) and Restart (messaging,
/// dashboard). Only for the computer in use while it's connected: every action needs its connection.
@MainActor
struct HostUpdatesSections: View {
    @Bindable var store: HostOperationsStore
    let plugin: HostPluginUpdateModel?

    @State private var gatewayCommand: HermesMessagingGatewayCommand?
    @State private var confirmsUpdate = false
    @State private var confirmsDashboardRestart = false
    @State private var restartPrompt: HostPluginUpdateModel?

    var body: some View {
        messageSections
        updatesSection
        restartSection
    }

    /// The load and every dialog hang on Check for updates, the one row always here: on a Section
    /// SwiftUI repeats a modifier on each row, and a task there stops when its rows hide.
    private var checkButton: some View {
        Button("Check for updates", systemImage: "arrow.triangle.2.circlepath") {
            Task {
                await store.checkForUpdates(force: true)
                await plugin?.check()
            }
        }
        .disabled(!store.canAct)
        .accessibilityIdentifier("system.hermes.check")
        .task { if store.overview == nil { await store.load() } }
        .confirmationDialog("Update Hermes?", isPresented: $confirmsUpdate, titleVisibility: .visible) {
            Button("Update Hermes") { Task { await store.applyReviewedUpdate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes installs the update and may restart, so bighelp can disconnect for a moment.")
        }
        .pluginRestartPrompt($restartPrompt)
        .modifier(GatewayCommandConfirmation(command: $gatewayCommand, store: store))
        .confirmationDialog("Restart the Hermes dashboard?", isPresented: $confirmsDashboardRestart,
                            titleVisibility: .visible) {
            Button("Restart") { Task { await plugin?.restartDashboard() } }
                .accessibilityIdentifier("system.dashboard.restart.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("bighelp disconnects for a moment and reconnects. Replies in progress on your computer stop.")
        }
    }

    @ViewBuilder
    private var messageSections: some View {
        if let message = store.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Dismiss") { store.clearMessages() }
            }
        }
        if let message = store.successMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Button("Dismiss") { store.clearMessages() }
            }
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        Section {
            hermesRows
            if let plugin, plugin.state != .notInstalled { pluginRows(plugin) }
            checkButton
        } header: {
            Text("Updates")
        }
    }

    @ViewBuilder
    private var hermesRows: some View {
        let version = store.overview?.version ?? store.updateCheck?.currentVersion
        let check = store.updateCheck
        if version != nil || check != nil {
            LabeledContent("Hermes", value: hermesValue(version: version, check: check))
                .accessibilityIdentifier("system.hermes.version")
        }
        if let check, check.updateAvailable {
            if check.canApply {
                BighelpActionRow(title: String(localized: "Update Hermes"), detail: check.behindText,
                                 systemImage: "arrow.down.circle.fill") { confirmsUpdate = true }
                    .disabled(!store.canAct)
                    .accessibilityIdentifier("system.hermes.update")
            } else {
                Label("Update Hermes on your computer", systemImage: "arrow.down.circle")
                    .accessibilityIdentifier("system.hermes.update-on-computer")
            }
            if !check.commits.isEmpty {
                DisclosureGroup("What's new") {
                    ForEach(check.commits.prefix(20)) { commit in
                        Text(commit.summary).font(.bighelp(.subheadline))
                    }
                }
                .accessibilityIdentifier("system.hermes.whats-new")
            }
        }
    }

    /// "12 commits behind" when there's an update, else the version (or Up to date).
    private func hermesValue(version: String?, check: HermesUpdateCheck?) -> String {
        if let check, check.updateAvailable { return check.behindText }
        return version ?? String(localized: "Up to date")
    }

    @ViewBuilder
    private func pluginRows(_ plugin: HostPluginUpdateModel) -> some View {
        LabeledContent("bighelp plugin", value: plugin.installedVersion ?? "—")
            .accessibilityIdentifier("settings.plugin.installed")
        if let running = plugin.runningVersion, running != plugin.installedVersion {
            LabeledContent("Running", value: running)
                .accessibilityIdentifier("settings.plugin.running")
        }
        switch plugin.state {
        case .updateAvailable:
            BighelpActionRow(title: String(localized: "Update plugin"),
                             detail: String(localized: "Version \(plugin.latestVersion ?? "") is ready"),
                             systemImage: "arrow.down.circle.fill") {
                Task { if await plugin.update() { restartPrompt = plugin } }
            }
            .accessibilityLabel("Update plugin to \(plugin.latestVersion ?? "the latest version")")
            .accessibilityIdentifier("settings.plugin.update")
        case .restartNeeded where plugin.canRestartHost:
            BighelpActionRow(title: String(localized: "Restart Hermes"),
                             detail: String(localized: "Restarts the dashboard and messaging"),
                             systemImage: "arrow.clockwise") { restartPrompt = plugin }
                .accessibilityIdentifier("settings.plugin.restart")
        default:
            EmptyView()
        }
        if let message = pluginStatus(plugin) {
            Label {
                Text(message)
            } icon: {
                if plugin.isWorking { ProgressView().controlSize(.small) } else { Image(systemName: "info.circle") }
            }
            .font(.bighelp(.footnote))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.plugin.status")
        }
        if plugin.state == .updateAvailable, let release = plugin.release, !release.whatsNew.isEmpty {
            DisclosureGroup("What's new in \(release.version)") {
                Text(release.whatsNew)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("settings.plugin.whats-new")
        }
    }

    /// Only what needs saying: progress, a problem, a step on the computer, or that an update
    /// finished. "Version 3.2 is ready" is already the button.
    private func pluginStatus(_ plugin: HostPluginUpdateModel) -> String? {
        switch plugin.state {
        case .checking: String(localized: "Checking the plugin…")
        case .updateAvailable: nil
        default: plugin.message
        }
    }

    // MARK: Restart

    @ViewBuilder
    private var restartSection: some View {
        if let overview = store.overview {
            Section {
                if overview.gatewayRunning {
                    BighelpActionRow(title: String(localized: "Restart messaging"),
                                     detail: overview.gatewayBusy ? String(localized: "Replies in progress will stop")
                                         : String(localized: "Pauses for a moment"),
                                     systemImage: "arrow.clockwise") { gatewayCommand = .restart }
                        .disabled(!store.canAct)
                        .accessibilityIdentifier("system.gateway.restart")
                } else {
                    BighelpActionRow(title: String(localized: "Start messaging"),
                                     detail: String(localized: "Messaging is off"),
                                     systemImage: "play.fill") { gatewayCommand = .start }
                        .disabled(!store.canAct)
                        .accessibilityIdentifier("system.gateway.start")
                }
                if let plugin, plugin.state != .notInstalled { dashboardRow(plugin) }
            } header: {
                Text("Restart")
            } footer: {
                if plugin?.state == .restartNeeded {
                    Text("The dashboard serves bighelp's connection and the bighelp plugin. A new or updated plugin takes effect after the dashboard and messaging restart.")
                }
            }
        } else if store.isLoading {
            Section { ProgressView("Loading…") }
        }
    }

    /// The Hermes dashboard (`hermes dashboard` or `hermes serve`) serves this app's connection and
    /// the bighelp plugin's routes. Hermes can't restart it for an app, so the plugin running in it
    /// does, in place; before the dashboard has loaded the plugin, only the computer can.
    @ViewBuilder
    private func dashboardRow(_ plugin: HostPluginUpdateModel) -> some View {
        if plugin.canRestartHost {
            BighelpActionRow(title: String(localized: "Restart dashboard"),
                             detail: plugin.state == .restarting ? String(localized: "Restarting…")
                                 : String(localized: "bighelp reconnects"),
                             systemImage: "arrow.clockwise") { confirmsDashboardRestart = true }
                .disabled(plugin.isWorking || !store.canAct)
                .accessibilityIdentifier("system.dashboard.restart")
        } else if ![.idle, .checking].contains(plugin.state) {
            // Until the plugin was read, there's no telling whether it can restart the dashboard.
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restart the dashboard on your computer")
                    Text(plugin.isLoaded
                         ? "This dashboard can't restart from bighelp."
                         : "The dashboard hasn't loaded the bighelp plugin yet, so only your computer can restart it.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "desktopcomputer")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("system.dashboard.restart-on-computer")
        }
    }
}

// MARK: - Advanced

/// A computer page's Advanced groups (Advanced options only): Messaging, Upkeep and Setup. Only
/// for the computer in use while it's connected.
@MainActor
struct HostAdvancedSections: View {
    @Bindable var store: HostOperationsStore
    let administration: NativeAdministrationPresentation?
    let permissionCenter: PermissionCenter?

    @State private var gatewayCommand: HermesMessagingGatewayCommand?
    @State private var drainTarget: Bool?
    @State private var confirmsMigration = false
    @AppStorage("loopdy.settings.nerd-mode") private var nerdMode = false

    var body: some View {
        if nerdMode {
            if let overview = store.overview { messagingSection(overview) }
            upkeepSection
            setupSection
        }
    }

    // MARK: Advanced · Messaging

    private func messagingSection(_ overview: HermesHostOverview) -> some View {
        Section {
            // The section's dialogs hang on its one row that's always here (a Section repeats them per row).
            LabeledContent("Messaging", value: "\(gatewayStatus(overview)) · \(activityText(overview))")
                .accessibilityIdentifier("system.gateway.status")
                .modifier(GatewayCommandConfirmation(command: $gatewayCommand, store: store))
                .modifier(DrainConfirmation(target: $drainTarget, store: store))
                .confirmationDialog("Combine messaging?", isPresented: $confirmsMigration,
                                    titleVisibility: .visible) {
                    Button("Combine messaging") { Task { await store.migrateGateway() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Hermes checks the plan again, then runs one messaging service for every bot that can share it.")
                }
            if overview.gatewayState == "draining" {
                Button("Accept new messages", systemImage: "arrow.uturn.backward") { drainTarget = false }
                    .disabled(!store.canAct)
                    .accessibilityIdentifier("system.gateway.accept")
            } else if overview.gatewayDrainable {
                Button("Pause new messages", systemImage: "hourglass") { drainTarget = true }
                    .disabled(!store.canAct)
                    .accessibilityIdentifier("system.gateway.pause")
            }
            if overview.gatewayRunning {
                Button("Stop messaging", systemImage: "stop.fill", role: .destructive) { gatewayCommand = .stop }
                    .disabled(!store.canAct || overview.gatewayBusy)
                    .accessibilityIdentifier("system.gateway.stop")
            }
            LabeledContent("Messaging mode", value: overview.gatewayMode.capitalized)
            if !overview.gatewaySharedWith.isEmpty {
                LabeledContent("Serving bots", value: overview.gatewaySharedWith.joined(separator: ", "))
            }
            if let plan = store.migrationPlan { migrationPlan(plan) }
        } header: {
            Text("Advanced · Messaging")
        }
    }

    private func gatewayStatus(_ overview: HermesHostOverview) -> String {
        if overview.gatewayState == "draining" { return String(localized: "Paused for new messages") }
        return overview.gatewayRunning ? String(localized: "Running") : String(localized: "Stopped")
    }

    private func activityText(_ overview: HermesHostOverview) -> String {
        let bots = overview.activeAgents == 1 ? String(localized: "1 bot")
            : String(localized: "\(overview.activeAgents.formatted()) bots")
        let chats = overview.activeSessions == 1 ? String(localized: "1 chat")
            : String(localized: "\(overview.activeSessions.formatted()) chats")
        return String(localized: "\(bots) · \(chats) active")
    }

    @ViewBuilder
    private func migrationPlan(_ plan: HermesGatewayMigrationPlan) -> some View {
        if !plan.alreadyMultiplexed {
            DisclosureGroup("Combine messaging") {
                ForEach(plan.profiles) { profile in
                    LabeledContent(profile.id, value: profile.hasRunningProcess ? "Running" : "Not running")
                }
                ForEach(plan.notices, id: \.self) { notice in
                    Label(notice, systemImage: "info.circle")
                }
                ForEach(plan.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "exclamationmark.octagon")
                        .foregroundStyle(.orange)
                }
                if plan.isEligible && plan.blockers.isEmpty {
                    Button("Combine messaging") { confirmsMigration = true }
                        .disabled(!store.canAct)
                }
            }
        }
    }

    // MARK: Advanced · Upkeep

    private var upkeepSection: some View {
        Section {
            NavigationLink("Diagnostics") { HostDiagnosticsView(store: store) }
                .accessibilityIdentifier("system.diagnostics")
                // Achievements' and Kanban's rows show only once their plugin is found, so the
                // look runs here (again for a new connection): a task on a row that isn't drawn never starts.
                .task(id: administration?.id) {
                    if let achievements = administration?.achievements, achievements.mount == .unknown {
                        await achievements.load()
                    }
                    if let kanban = administration?.kanban, kanban.mount == .unknown { await kanban.load() }
                }
            NavigationLink("Backups") { HostBackupView(store: store) }
                .accessibilityIdentifier("system.backups")
            NavigationLink("Import a backup") { HostImportView(store: store) }
                .accessibilityIdentifier("system.import")
            if let administration {
                NavigationLink("Logs") { administration.makeLogs() }
                    .accessibilityIdentifier("system.logs")
            }
            NavigationLink("Status") { HostStatusPage(store: store) }
                .accessibilityIdentifier("system.details")
            if let achievements = administration?.achievements, achievements.mount == .available {
                NavigationLink("Achievements") { HermesAchievementsView(store: achievements) }
                    .accessibilityIdentifier("system.achievements")
            }
        } header: {
            Text("Advanced · Upkeep")
        }
    }

    // MARK: Advanced · Setup

    private var setupSection: some View {
        Section {
            NavigationLink("Edit config.yaml") { RawConfigurationView(store: store.rawConfiguration) }
                .accessibilityIdentifier("system.raw-configuration")
            NavigationLink("Shell hooks") { HostHooksView(store: store) }
                .accessibilityIdentifier("system.hooks")
            if let administration {
                NavigationLink("Webhooks") { WebhookEditorView(store: administration.webhooks) }
                    .accessibilityIdentifier("system.webhooks")
                NavigationLink("Tool backends") { HostToolBackendsView(store: administration.toolBackends) }
                    .accessibilityIdentifier("system.tool-backends")
                if administration.kanban.mount == .available {
                    NavigationLink("Kanban boards") { HermesKanbanView(store: administration.kanban) }
                        .accessibilityIdentifier("system.kanban")
                }
                if let voice = administration.voice, let permissionCenter {
                    NavigationLink("Computer voice test") {
                        VoiceConfigurationView(store: voice, permissionCenter: permissionCenter)
                    }
                    .accessibilityIdentifier("system.voice-test")
                }
            }
        } header: {
            Text("Advanced · Setup")
        }
    }
}

/// A computer page's This device: what the caller adds about this device's side of the link
/// (Settings' Connection details and Clear local cache), whatever state the computer is in. The
/// caller decides what goes in it and when; with nothing, there's no section.
@MainActor
struct HostThisDeviceSection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if Content.self != EmptyView.self {
            Section {
                content
            } header: {
                Text("This device")
            }
        }
    }
}

/// Advanced · Upkeep › Status: what the computer reports about itself, its last update, the
/// actions this page started and what this computer doesn't have.
@MainActor
private struct HostStatusPage: View {
    @Bindable var store: HostOperationsStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Computer", value: store.hostName)
                LabeledContent("Bot", value: store.profileID)
                if let overview = store.overview {
                    LabeledContent("Overall", value: overview.overall.capitalized)
                    ForEach(overview.components) { component in
                        LabeledContent(component.id.replacingOccurrences(of: "_", with: " ").capitalized,
                                       value: component.status.capitalized)
                    }
                }
                if let check = store.updateCheck {
                    LabeledContent("Install method", value: check.installMethod)
                }
            }
            if let receipt = store.updateReceipt { lastUpdate(receipt) }
            if !store.actionReceipts.isEmpty { recentActions }
            if !store.unavailableFeatures.isEmpty {
                Section("Not on this computer") {
                    ForEach(store.unavailableFeatures, id: \.self) { feature in
                        Label(feature, systemImage: "nosign")
                    }
                }
            }
        }
        .bighelpFormSurface()
        .navigationTitle("Status")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await store.load() }
    }

    private func lastUpdate(_ receipt: HermesUpdateReceipt) -> some View {
        Section("Last update") {
            LabeledContent("Result", value: receipt.summary.outcome.capitalized)
            if let version = receipt.summary.postUpdateVersion {
                LabeledContent("Version", value: version)
            }
            if let finished = receipt.summary.finishedAt {
                LabeledContent("Finished", value: finished.formatted(date: .abbreviated, time: .shortened))
            }
            ForEach(receipt.steps.prefix(100)) { step in
                Label(step.name, systemImage: step.succeeded ? "checkmark.circle" : "xmark.circle")
            }
            ForEach(receipt.fleet.prefix(50)) { member in
                LabeledContent(member.profile, value: member.state.capitalized)
            }
        }
    }

    private var recentActions: some View {
        Section("Recent actions") {
            ForEach(store.actionReceipts) { receipt in
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    HStack {
                        Text(HostStatusPage.actionTitle(receipt.action)).font(.bighelp(.headline))
                        Spacer()
                        statusLabel(store.actionStatuses[receipt.id])
                    }
                    HStack {
                        Button("Refresh") { Task { await store.pollAction(receipt) } }
                            .buttonStyle(.bordered)
                        Button("Dismiss") { store.dismissAction(receipt) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, BighelpTokens.space4)
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: HermesHostActionStatus?) -> some View {
        switch status?.phase {
        case .running, nil:
            Label("Pending", systemImage: "clock").font(.bighelp(.caption)).foregroundStyle(.secondary)
        case .succeeded:
            Label("Completed", systemImage: "checkmark.circle.fill").font(.bighelp(.caption)).foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill").font(.bighelp(.caption)).foregroundStyle(.red)
        case .outcomeUnknown:
            Label("Unknown", systemImage: "questionmark.circle").font(.bighelp(.caption)).foregroundStyle(.orange)
        }
    }

    /// "gateway-restart" reads as "Messaging restart": the gateway is messaging to people.
    static func actionTitle(_ action: HermesHostAction) -> String {
        var words = action.rawValue.replacingOccurrences(of: "-", with: " ")
        if words.hasPrefix("gateway ") { words = "messaging" + String(words.dropFirst("gateway".count)) }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

// MARK: - Confirmations

/// Start, stop or restart messaging (Hermes' gateway), after a yes.
private struct GatewayCommandConfirmation: ViewModifier {
    @Binding var command: HermesMessagingGatewayCommand?
    let store: HostOperationsStore

    func body(content: Content) -> some View {
        content.confirmationDialog(
            command.map(question) ?? String(localized: "Messaging"),
            isPresented: Binding(get: { command != nil }, set: { if !$0 { command = nil } }),
            titleVisibility: .visible
        ) {
            if let command {
                Button(title(command), role: command == .stop ? .destructive : nil) {
                    self.command = nil
                    Task { await store.launchGateway(command) }
                }
            }
            Button("Cancel", role: .cancel) { command = nil }
        } message: {
            Text(message)
        }
    }

    private func question(_ command: HermesMessagingGatewayCommand) -> String {
        switch command {
        case .start: String(localized: "Start messaging?")
        case .stop: String(localized: "Stop messaging?")
        case .restart: String(localized: "Restart messaging?")
        }
    }

    private func title(_ command: HermesMessagingGatewayCommand) -> String {
        switch command {
        case .start: String(localized: "Start")
        case .stop: String(localized: "Stop")
        case .restart: String(localized: "Restart")
        }
    }

    private var message: String {
        guard let command else { return "" }
        return switch command {
        case .start:
            String(localized: "Hermes starts messaging for this bot.")
        case .stop:
            String(localized: "Messaging stops until you start it again. Chats in bighelp keep working.")
        case .restart:
            String(localized: "Messaging pauses for a moment while it restarts. bighelp may reconnect.")
        }
    }
}

/// Pause new messages, or take them again, after a yes.
private struct DrainConfirmation: ViewModifier {
    @Binding var target: Bool?
    let store: HostOperationsStore

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target == true ? String(localized: "Pause new messages?") : String(localized: "Accept new messages again?"),
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible
        ) {
            if let draining = target {
                Button(draining ? String(localized: "Pause new messages") : String(localized: "Accept messages")) {
                    target = nil
                    Task { await store.setGatewayDraining(draining) }
                }
            }
            Button("Cancel", role: .cancel) { target = nil }
        } message: {
            Text(target == true
                 ? "Work already running finishes; new messages wait."
                 : "Messaging takes new messages again.")
        }
    }
}
