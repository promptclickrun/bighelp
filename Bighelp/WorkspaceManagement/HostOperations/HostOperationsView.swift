import SwiftUI

/// Settings › System, laid out like Fleet settings for the computer in use: its computers,
/// then update Hermes, the bighelp plugin and restart the gateway; everything else waits in
/// Additional settings, folded away.
@MainActor
struct HostOperationsView<MoreLinks: View>: View {
    @Bindable var store: HostOperationsStore
    /// Other host pages, listed with Advanced.
    private let moreLinks: MoreLinks

    @State private var gatewayCommand: HermesMessagingGatewayCommand?
    @State private var drainTarget: Bool?
    @State private var confirmsMigration = false
    @State private var confirmsUpdate = false
    @State private var showsAdditional = false
    @State private var pluginUpdate: HostPluginUpdateModel?
    @Environment(\.bighelpHostRegistry) private var hostRegistry

    init(store: HostOperationsStore, @ViewBuilder moreLinks: () -> MoreLinks) {
        _store = Bindable(wrappedValue: store)
        self.moreLinks = moreLinks()
    }

    var body: some View {
        List {
            if let hostRegistry, !hostRegistry.hosts.isEmpty {
                BighelpConfiguredHostsSection(registry: hostRegistry)
            }
            messageSections
            hermesSection
            if let pluginUpdate, pluginUpdate.state != .notInstalled {
                HostPluginUpdateSection(model: pluginUpdate)
            }
            if let overview = store.overview {
                gatewaySection(overview)
            } else if store.isLoading {
                Section { ProgressView("Loading…") }
            }
            additionalSettings
        }
        .listStyle(.insetGrouped)
        .bighelpFormSurface()
        .navigationTitle("System")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { if store.overview == nil { await store.load() } }
        .task(id: hostRegistry?.selectedHostID) {
            guard let hostRegistry, let hostID = hostRegistry.selectedHostID,
                  hostRegistry.selectedWorkspace?.isConnected == true else { return }
            let model = HostPluginUpdateModel.model(for: hostID, registry: hostRegistry)
            pluginUpdate = model
            await model.checkIfNeeded()
        }
        .confirmationDialog(
            gatewayCommand.map { "\(gatewayTitle($0)) the Hermes gateway?" } ?? "Hermes gateway",
            isPresented: Binding(
                get: { gatewayCommand != nil },
                set: { if !$0 { gatewayCommand = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let command = gatewayCommand {
                Button(gatewayTitle(command), role: command == .stop ? .destructive : nil) {
                    gatewayCommand = nil
                    Task { await store.launchGateway(command) }
                }
            }
            Button("Cancel", role: .cancel) { gatewayCommand = nil }
        } message: {
            Text(gatewayConfirmationMessage)
        }
        .confirmationDialog(
            drainTarget == true ? "Pause new messages?" : "Accept new messages again?",
            isPresented: Binding(
                get: { drainTarget != nil },
                set: { if !$0 { drainTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let draining = drainTarget {
                Button(draining ? "Pause New Messages" : "Accept Messages") {
                    drainTarget = nil
                    Task { await store.setGatewayDraining(draining) }
                }
            }
            Button("Cancel", role: .cancel) { drainTarget = nil }
        } message: {
            Text(drainTarget == true
                 ? "Work already running finishes; new messages wait."
                 : "The gateway takes new messages again.")
        }
        .confirmationDialog(
            "Combine messaging gateways?",
            isPresented: $confirmsMigration,
            titleVisibility: .visible
        ) {
            Button("Combine Gateways") { Task { await store.migrateGateway() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes checks the plan again, then runs one gateway for every eligible profile.")
        }
        .confirmationDialog(
            "Update Hermes?",
            isPresented: $confirmsUpdate,
            titleVisibility: .visible
        ) {
            Button("Update Hermes") { Task { await store.applyReviewedUpdate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes installs the update and may restart, so bighelp can disconnect for a moment.")
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

    // MARK: Hermes version and update

    private var hermesSection: some View {
        Section {
            if let version = store.overview?.version ?? store.updateCheck?.currentVersion {
                LabeledContent("Version", value: version)
                    .accessibilityIdentifier("system.hermes.version")
            }
            if let check = store.updateCheck {
                if check.updateAvailable && check.canApply {
                    BighelpActionRow(title: "Update Hermes", detail: check.behindText,
                                     systemImage: "arrow.down.circle.fill") { confirmsUpdate = true }
                        .disabled(!store.canAct)
                        .accessibilityIdentifier("system.hermes.update")
                } else if check.updateAvailable {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update available")
                            Text("\(check.behindText). Update Hermes on your computer.")
                                .font(.bighelp(.footnote))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("system.hermes.update-on-computer")
                } else {
                    Label("Hermes is up to date", systemImage: "checkmark.circle.fill")
                        .accessibilityIdentifier("system.hermes.up-to-date")
                }
                if check.updateAvailable, !check.commits.isEmpty {
                    DisclosureGroup("What's new") {
                        ForEach(check.commits.prefix(20)) { commit in
                            Text(commit.summary).font(.bighelp(.subheadline))
                        }
                    }
                    .accessibilityIdentifier("system.hermes.whats-new")
                }
            }
            Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                Task { await store.checkForUpdates(force: true) }
            }
            .disabled(!store.canAct)
            .accessibilityIdentifier("system.hermes.check")
        } header: {
            Text("Hermes")
        }
    }

    // MARK: Messaging gateway

    private func gatewaySection(_ overview: HermesHostOverview) -> some View {
        Section {
            HStack {
                Label(gatewayStatus(overview), systemImage: overview.gatewayRunning
                      ? "antenna.radiowaves.left.and.right" : "stop.circle")
                Spacer()
                Text(activityText(overview))
                    .font(.bighelp(.caption))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("system.gateway.status")

            if overview.gatewayRunning {
                BighelpActionRow(title: "Restart Hermes Gateway",
                                 detail: overview.gatewayBusy ? "Replies in progress will stop" : "Messaging pauses for a moment",
                                 systemImage: "arrow.clockwise") { gatewayCommand = .restart }
                    .disabled(!store.canAct)
                    .accessibilityIdentifier("system.gateway.restart")
            } else {
                BighelpActionRow(title: "Start Hermes Gateway", detail: "Messaging is off",
                                 systemImage: "play.fill") { gatewayCommand = .start }
                    .disabled(!store.canAct)
                    .accessibilityIdentifier("system.gateway.start")
            }

        } header: {
            Text("Messaging gateway")
        }
    }

    private func gatewayStatus(_ overview: HermesHostOverview) -> String {
        if overview.gatewayState == "draining" { return "Paused for new messages" }
        return overview.gatewayRunning ? "Running" : "Stopped"
    }

    private func activityText(_ overview: HermesHostOverview) -> String {
        let agents = overview.activeAgents == 1 ? "1 agent" : "\(overview.activeAgents.formatted()) agents"
        let chats = overview.activeSessions == 1 ? "1 chat" : "\(overview.activeSessions.formatted()) chats"
        return "\(agents) · \(chats) active"
    }

    @ViewBuilder
    private func migrationPlan(_ plan: HermesGatewayMigrationPlan) -> some View {
        if !plan.alreadyMultiplexed {
            DisclosureGroup("Combine gateways") {
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
                    Button("Combine Gateways") { confirmsMigration = true }
                        .disabled(!store.canAct)
                }
            }
        }
    }

    // MARK: Additional settings

    /// Everything past update and restart, folded away like Fleet settings keeps it.
    private var additionalSettings: some View {
        Section {
            DisclosureGroup(isExpanded: $showsAdditional) {
                if let overview = store.overview { gatewayControls(overview) }
                if let receipt = store.updateReceipt { lastUpdate(receipt) }
                recentActions
                details
                advancedLinks
                unavailable
            } label: {
                Label("Additional settings", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("system.additional")
        }
    }

    @ViewBuilder
    private func gatewayControls(_ overview: HermesHostOverview) -> some View {
        if overview.gatewayRunning {
            Button("Stop Gateway", systemImage: "stop.fill", role: .destructive) {
                gatewayCommand = .stop
            }
            .disabled(!store.canAct || overview.gatewayBusy)
        }
        if overview.gatewayState == "draining" {
            Button("Accept New Messages", systemImage: "arrow.uturn.backward") { drainTarget = false }
                .disabled(!store.canAct)
        } else if overview.gatewayDrainable {
            Button("Pause New Messages", systemImage: "hourglass") { drainTarget = true }
                .disabled(!store.canAct)
        }
        LabeledContent("Gateway mode", value: overview.gatewayMode.capitalized)
        if !overview.gatewaySharedWith.isEmpty {
            LabeledContent("Serving profiles", value: overview.gatewaySharedWith.joined(separator: ", "))
        }
        if let plan = store.migrationPlan {
            migrationPlan(plan)
        }
    }

    private func lastUpdate(_ receipt: HermesUpdateReceipt) -> some View {
            DisclosureGroup("Last update") {
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

    private var details: some View {
        DisclosureGroup("Details") {
            LabeledContent("Host", value: store.hostName)
            LabeledContent("Profile", value: store.profileID)
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
        .accessibilityIdentifier("system.details")
    }

    @ViewBuilder
    private var advancedLinks: some View {
        NavigationLink {
            HostDiagnosticsView(store: store)
        } label: {
            Label("Diagnostics & Egress", systemImage: "stethoscope")
        }
        NavigationLink {
            HostBackupView(store: store)
        } label: {
            Label("Backups & Checkpoints", systemImage: "externaldrive")
        }
        NavigationLink {
            HostImportView(store: store)
        } label: {
            Label("Import Backup", systemImage: "square.and.arrow.down")
        }
        NavigationLink {
            HostHooksView(store: store)
        } label: {
            Label("Shell Hooks", systemImage: "terminal")
        }
        NavigationLink {
            RawConfigurationView(store: store.rawConfiguration)
        } label: {
            Label("Raw Configuration", systemImage: "lock.doc")
        }
        moreLinks
    }

    @ViewBuilder
    private var recentActions: some View {
        if !store.actionReceipts.isEmpty {
            DisclosureGroup("Recent actions") {
                ForEach(store.actionReceipts) { receipt in
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        HStack {
                            Text(Self.actionTitle(receipt.action)).font(.bighelp(.headline))
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
    }

    @ViewBuilder
    private var unavailable: some View {
        if !store.unavailableFeatures.isEmpty {
            DisclosureGroup("Not available on this host (\(store.unavailableFeatures.count))") {
                ForEach(store.unavailableFeatures, id: \.self) { feature in
                    Label(feature, systemImage: "nosign")
                }
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

    /// "gateway-restart" reads as "Gateway restart".
    static func actionTitle(_ action: HermesHostAction) -> String {
        let words = action.rawValue.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func gatewayTitle(_ command: HermesMessagingGatewayCommand) -> String {
        switch command {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        }
    }

    private var gatewayConfirmationMessage: String {
        guard let command = gatewayCommand else { return "" }
        return switch command {
        case .start:
            "Hermes starts messaging for this profile."
        case .stop:
            "Messaging stops until you start the gateway again. Chats in bighelp keep working."
        case .restart:
            "Messaging pauses for a moment while it restarts. bighelp may reconnect."
        }
    }
}

extension HostOperationsView where MoreLinks == EmptyView {
    init(store: HostOperationsStore) {
        self.init(store: store) { EmptyView() }
    }
}
