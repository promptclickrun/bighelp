import SwiftUI

/// Settings › Fleet settings, with every host shown: Update Hermes, update
/// the bighelp plugin and restart the gateway everywhere at once, or on one
/// host from its own row, each with its own live status. This app's
/// Appearance and Chat are here too.
struct FleetSettingsView: View {
    let store: FleetMaintenanceStore
    /// This app's own pages (Appearance, Chat), the same ones Settings opens.
    var appPage: ((SettingsMenuSection) -> AnyView)?
    @State private var confirmation: Confirmation?

    private enum Confirmation: Identifiable {
        case updateHermes(count: Int)
        case restartGateways(count: Int)
        case finishHermes(FleetMaintenanceHost)
        case restartPlugin(FleetMaintenanceHost)
        case updateHermesOn(FleetMaintenanceHost)
        case restartGatewayOn(FleetMaintenanceHost)

        var id: String {
            switch self {
            case .updateHermes: "hermes"
            case .restartGateways: "gateways"
            case .finishHermes(let host): "finish-\(host.id)"
            case .restartPlugin(let host): "plugin-\(host.id)"
            case .updateHermesOn(let host): "hermes-\(host.id)"
            case .restartGatewayOn(let host): "gateway-\(host.id)"
            }
        }
    }

    var body: some View {
        List {
            hermesSection
            pluginSection
            gatewaySection
            if let appPage { appSection(appPage) }
        }
        .listStyle(.insetGrouped)
        .bighelpFormSurface()
        .navigationTitle("Fleet settings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh(force: true) }
        .task { await store.refreshIfNeeded() }
        .confirmationDialog(confirmationTitle, isPresented: isConfirming, titleVisibility: .visible,
                            presenting: confirmation) { confirmation in
            Button(confirmButton(confirmation)) { run(confirmation) }
                .accessibilityIdentifier("fleet.settings.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmMessage(confirmation))
        }
        .accessibilityIdentifier("fleet.settings")
    }

    @BighelpThemeReader private var theme

    // MARK: Sections

    /// Appearance and Chat apply to bighelp on every host, so they're here too.
    private func appSection(_ page: @escaping (SettingsMenuSection) -> AnyView) -> some View {
        Section {
            ForEach([SettingsMenuSection.appearance, .chat]) { section in
                NavigationLink { page(section) } label: {
                    HStack(spacing: BighelpTokens.space12) {
                        BighelpIconTile(systemName: section == .appearance ? "paintpalette.fill" : "bubble.left.and.bubble.right.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(.bighelp(.body).weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                            Text(section.detail)
                                .font(.bighelp(.footnote))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                }
                .accessibilityIdentifier("fleet.settings.app.\(section.rawValue)")
            }
        } header: {
            Text("This app")
        }
    }

    private var hermesSection: some View {
        Section {
            let count = store.hermesCandidates.count
            BighelpActionRow(title: "Update Hermes", detail: summary(count, \.hermes),
                             systemImage: "arrow.down.circle.fill",
                             isWorking: store.hosts.contains { $0.hermes.kind == .working }) {
                confirmation = .updateHermes(count: count)
            }
            .disabled(count == 0)
            .accessibilityIdentifier("fleet.settings.hermes.update-all")
            ForEach(store.hosts) { host in
                FleetMaintenanceRow(name: host.name, job: host.hermes, identifier: "fleet.settings.hermes.\(host.name)",
                                    onRestart: { confirmation = .finishHermes(host) },
                                    action: host.hermes.kind == .pending
                                        ? .init(title: "Update") { confirmation = .updateHermesOn(host) } : nil)
            }
        } header: {
            Text("Hermes")
        }
    }

    private var pluginSection: some View {
        Section {
            let count = store.pluginCandidates.count
            BighelpActionRow(title: "Update bighelp Plugin", detail: summary(count, \.pluginJob),
                             systemImage: "puzzlepiece.extension.fill",
                             isWorking: store.hosts.contains { $0.pluginJob.kind == .working }) {
                Task { await store.updatePluginEverywhere() }
            }
            .disabled(count == 0)
            .accessibilityIdentifier("fleet.settings.plugin.update-all")
            ForEach(store.hosts) { host in
                FleetMaintenanceRow(name: host.name, job: host.pluginJob, identifier: "fleet.settings.plugin.\(host.name)",
                                    onRestart: { confirmation = .restartPlugin(host) },
                                    action: host.pluginJob.kind == .pending
                                        ? .init(title: "Update") { Task { await store.updatePlugin(on: host.id) } } : nil)
            }
        } header: {
            Text("bighelp plugin")
        } footer: {
            Text("Each host keeps running the old plugin until it restarts.")
        }
    }

    private var gatewaySection: some View {
        Section {
            let count = store.gatewayCandidates.count
            BighelpActionRow(title: "Restart Hermes Gateway",
                             detail: count == 0 ? "No host to restart" : "On \(hosts(count))",
                             systemImage: "arrow.clockwise",
                             isWorking: store.hosts.contains { $0.gateway.kind == .working }) {
                confirmation = .restartGateways(count: count)
            }
            .disabled(count == 0)
            .accessibilityIdentifier("fleet.settings.gateway.restart-all")
            ForEach(store.hosts) { host in
                FleetMaintenanceRow(name: host.name, job: host.gateway, identifier: "fleet.settings.gateway.\(host.name)",
                                    action: store.gatewayCandidates.contains { $0.id == host.id }
                                        ? .init(title: "Restart") { confirmation = .restartGatewayOn(host) } : nil)
            }
        } header: {
            Text("Messaging gateway")
        } footer: {
            Text("Hosts that are offline or signed out are skipped.")
        }
    }

    private func isChecking(_ job: KeyPath<FleetMaintenanceHost, FleetHostJob>) -> Bool {
        store.hosts.contains { $0[keyPath: job].kind == .checking }
    }

    private func hosts(_ count: Int) -> String { count == 1 ? "1 host" : "\(count) hosts" }

    private func summary(_ count: Int, _ job: KeyPath<FleetMaintenanceHost, FleetHostJob>) -> String {
        if count > 0 { return "\(hosts(count)) can update" }
        if store.hosts.contains(where: { $0[keyPath: job].kind == .working }) { return "Updating…" }
        return isChecking(job) ? "Checking hosts…" : "Nothing to update"
    }

    // MARK: Confirmations

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .updateHermes(let count): "Update Hermes on \(hosts(count))?"
        case .restartGateways(let count): "Restart the gateway on \(hosts(count))?"
        case .finishHermes(let host): "Restart the gateway on \(host.name)?"
        case .restartPlugin(let host): "Restart Hermes on \(host.name)?"
        case .updateHermesOn(let host): "Update Hermes on \(host.name)?"
        case .restartGatewayOn(let host): "Restart the gateway on \(host.name)?"
        case nil: ""
        }
    }

    private func confirmButton(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .updateHermes: "Update Hermes"
        case .restartGateways: "Restart Gateways"
        case .finishHermes: "Restart Gateway"
        case .restartPlugin(let host): host.plugin?.canRestartHost == false ? "Restart Gateway" : "Restart Hermes"
        case .updateHermesOn: "Update Hermes"
        case .restartGatewayOn: "Restart Gateway"
        }
    }

    private func confirmMessage(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .updateHermes:
            "Each host installs the update and may restart, so bighelp can disconnect for a moment."
        case .updateHermesOn:
            "It installs the update and may restart, so bighelp can disconnect for a moment."
        case .restartGatewayOn:
            "Messaging pauses for a moment on that host. Replies in progress may stop."
        case .restartGateways:
            "Messaging pauses for a moment on each host. Replies in progress may stop."
        case .finishHermes:
            "The messaging gateway restarts on the updated Hermes. Messaging pauses for a moment."
        case .restartPlugin(let host):
            host.plugin?.canRestartHost == false
                ? "The messaging gateway loads the new plugin. Then restart Hermes on that computer once."
                : "Hermes restarts so the new plugin loads. Replies in progress on that computer stop."
        }
    }

    private func run(_ confirmation: Confirmation) {
        Task {
            switch confirmation {
            case .updateHermes: await store.updateHermesEverywhere()
            case .restartGateways: await store.restartGatewaysEverywhere()
            case .finishHermes(let host): await store.finishHermesUpdate(on: host.id)
            case .restartPlugin(let host): await store.restartPlugin(on: host.id)
            case .updateHermesOn(let host): await store.updateHermes(on: host.id)
            case .restartGatewayOn(let host): await store.restartGateway(on: host.id)
            }
        }
    }
}

/// One host's line: its name, where it stands, and Restart when it needs one.
struct FleetMaintenanceRow: View {
    let name: String
    let job: FleetHostJob
    let identifier: String
    var onRestart: (() -> Void)?
    /// This host's own Update or Restart, beside its status.
    var action: Action?

    struct Action {
        let title: String
        let run: () -> Void
    }

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: "desktopcomputer", tint: job.kind == .unavailable ? .gray : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(job.kind == .unavailable ? theme.secondaryText : theme.primaryText)
                Text(job.text)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).status")
            }
            Spacer(minLength: BighelpTokens.space8)
            trailing
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.kind {
        case .checking, .working:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Working")
        case .needsRestart:
            if let onRestart {
                Button("Restart", action: onRestart)
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(theme.action)
                    .foregroundStyle(theme.actionForeground)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityLabel("Restart \(name)")
                    .accessibilityIdentifier("\(identifier).restart")
            }
        case _ where action != nil:
            if let action {
                Button(action.title, action: action.run)
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityLabel("\(action.title) \(name)")
                    .accessibilityIdentifier("\(identifier).action")
            }
        case .done:
            symbol("checkmark.circle.fill", color: .green)
        case .current:
            symbol("checkmark.circle", color: theme.tertiaryText)
        case .failed:
            symbol("exclamationmark.triangle.fill", color: .orange)
        case .unavailable:
            symbol("wifi.slash", color: theme.tertiaryText)
        case .pending, .manual:
            EmptyView()
        }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.bighelp(.body))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var detailColor: Color {
        switch job.kind {
        case .failed: .orange
        case .needsRestart: theme.action
        default: theme.secondaryText
        }
    }

    @BighelpThemeReader private var theme
}
