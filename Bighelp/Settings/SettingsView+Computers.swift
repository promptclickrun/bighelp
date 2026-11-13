import SwiftUI

/// Settings › Chat › Archived chats: the chats put away, and opening one of them.
@MainActor
struct SettingsArchivedChats {
    let catalog: SessionCatalogStore
    let agentName: (String) -> String
    let onOpen: (SessionSummary) -> Void
}

/// Settings' Your computers: each computer opens its own page, then Add a computer, Show every
/// computer, the time zone of the computer in use and, with two or more, Update every computer.
extension SettingsView {
    @ViewBuilder
    var computersSection: some View {
        let offersEveryComputer = fleet?.offersAllGateways == true
        Section {
            if let hostRegistry {
                ForEach(hostRegistry.hosts) { host in
                    computerRow(host, registry: hostRegistry)
                }
                Button { hostRegistry.beginSetup() } label: {
                    rowLabel(String(localized: "Add a computer"), symbol: "plus", showsChevron: false)
                }
                .bighelpSettingsButton()
                .disabled(!hostRegistry.canConfigureHosts)
                .accessibilityIdentifier("settings.add-computer")
                .driveTarget("settings.add-computer")
                if let error = hostRegistry.errorMessage {
                    Text(error).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                }
            }
            if offersEveryComputer, let everyComputer = everyComputerBinding {
                tileToggle(String(localized: "Show every computer"), symbol: "square.stack.3d.up.fill",
                           isOn: everyComputer)
                    .accessibilityIdentifier("simple-bots.settings.multi-gateway")
                    .driveTarget("simple-bots.settings.multi-gateway")
                // Bots mode's home: a filter button beside Search, for one computer's bots.
                if settings.simpleBotsEnabled, settings.simpleBotsMultiGateway {
                    tileToggle(String(localized: "Computer filter"), symbol: "line.3.horizontal.decrease",
                               isOn: $settings.simpleBotsGatewayFilter)
                        .accessibilityIdentifier("simple-bots.settings.gateway-filter")
                        .driveTarget("simple-bots.settings.gateway-filter")
                }
            }
            if let computerTimeZone, hostRegistry?.selectedHostID != nil || usesDemoComputer {
                SettingsTimeZoneRow(make: computerTimeZone,
                                    scope: workspaceConnections?.owner?.cacheScopeID) { value in
                    rowLabel(String(localized: "Time zone"), detail: value, symbol: "globe",
                             showsChevron: BighelpPlatform.drawsOwnLinkChevron)
                }
            }
            if offersEveryComputer, let fleet {
                NavigationLink {
                    settingsDone(SettingsUpdateEveryComputerPage(fleet: fleet))
                } label: {
                    rowLabel(String(localized: "Update every computer"), symbol: "arrow.triangle.2.circlepath",
                             showsChevron: BighelpPlatform.drawsOwnLinkChevron)
                        .bighelpSettingsLinkLabel()
                }
                .bighelpSettingsLink()
                .accessibilityIdentifier("settings.update-every-computer")
                .driveTarget("settings.update-every-computer")
            }
        } header: {
            Text("Your computers")
        }
        .listRowBackground(theme.surface)
    }

    /// A computer's page. The one in use also shows this device's side of the link: the cache reset
    /// and, with Advanced options on, Connection details. Another computer's page has no such rows,
    /// so it gets no "This device" section.
    @ViewBuilder
    private func computerPage(_ host: BighelpConfiguredHost, registry: BighelpHostRegistry) -> some View {
        let openProviders: (() -> Void)? = onOpenWorkspaceDestination.map { open in { open(.models) } }
        if host.id == registry.selectedHostID {
            BighelpConfiguredHostView(hostID: host.id, registry: registry, onOpenProviders: openProviders,
                                      permissionCenter: permissionCenter) { thisDeviceRows }
                .modifier(ClearCacheConfirmation(isPresented: $isClearCacheConfirmationPresented,
                                                 onConfirm: clearLocalCache))
        } else {
            BighelpConfiguredHostView(hostID: host.id, registry: registry, onOpenProviders: openProviders,
                                      permissionCenter: permissionCenter)
        }
    }

    /// One computer: its name, and "In use · Connected" or where it is (or that its plugin has an
    /// update). Its page is the one the computers list opens (`BighelpConfiguredHostView`), where
    /// Use this computer picks the one in use. Done closes Settings from it, as from every page.
    private func computerRow(_ host: BighelpConfiguredHost, registry: BighelpHostRegistry) -> some View {
        let status = HostPluginUpdateModel.existingModel(for: host.id)?.attentionTitle
            ?? HostStatus.line(HostStatus.connection(for: host, registry: registry), host: host)
        return NavigationLink {
            settingsDone(computerPage(host, registry: registry))
        } label: {
            rowLabel(host.name, detail: status, symbol: "desktopcomputer",
                     showsChevron: BighelpPlatform.drawsOwnLinkChevron)
                .bighelpSettingsLinkLabel()
        }
        .bighelpSettingsLink()
        .contextMenu {
            if host.id != registry.selectedHostID {
                Button("Use this computer", systemImage: "checkmark.circle") { registry.select(host.id) }
            }
        }
        .accessibilityIdentifier("hosts.host.\(host.id.uuidString)")
    }

    /// The computer in use's page, in its This device group, connected or not: the cache reset
    /// for everyone, then Connection details with Advanced options on.
    @ViewBuilder
    private var thisDeviceRows: some View {
        clearLocalCacheRows
        if settings.nerdModeEnabled {
            settingsLink(to: .connection) {
                Label("Connection details", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .accessibilityIdentifier("settings.system.connection")
            .driveTarget("settings.system.connection")
        }
    }

    /// Show every computer, by `SettingsEveryComputer.choice`. Nil when there is no setting to change.
    private var everyComputerBinding: Binding<Bool>? {
        switch SettingsEveryComputer.choice(botsModeOn: settings.simpleBotsEnabled,
                                            canSetAllHosts: onSetAllHosts != nil) {
        case .botsMultiGateway: return $settings.simpleBotsMultiGateway
        case .allHosts:
            guard let onSetAllHosts else { return nil }
            return Binding(get: { settings.allHostsMode }, set: { onSetAllHosts($0) })
        case nil: return nil
        }
    }

    /// Demo mode's made-up computer has no row in the registry, but its time zone still saves.
    private var usesDemoComputer: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-use-demo-fixtures")
        #else
        false
        #endif
    }

    /// A switch with an icon tile, in line with the root's other rows.
    func tileToggle(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: BighelpTokens.space12) {
                BighelpIconTile(systemName: symbol)
                settingTitle(title)
            }
            .padding(.horizontal, BighelpMenuRowLayout.labelInset)
        }
        .bighelpMacSettingsRowInsets()
    }
}

/// Which stored setting Show every computer changes: Bots mode's Multi-gateway while Bots mode is
/// on (its home lists every computer's bots), the all-hosts view elsewhere, which only the shell
/// can turn on and off.
enum SettingsEveryComputer: Equatable {
    case botsMultiGateway
    case allHosts

    static func choice(botsModeOn: Bool, canSetAllHosts: Bool) -> SettingsEveryComputer? {
        if botsModeOn { return .botsMultiGateway }
        return canSetAllHosts ? .allHosts : nil
    }
}

/// Your computers › Time zone: the time zone every bot on the computer in use works in, or
/// Automatic, which follows this device's (also after travel, when bighelp comes back).
@MainActor
struct SettingsTimeZoneRow<Label: View>: View {
    let make: @MainActor () -> SimpleBotHostSettings?
    /// The computer in use (`cacheScopeID`): another one gets a store of its own. Nil while
    /// disconnected, which keeps the store it has.
    let scope: String?
    @ViewBuilder let label: (String?) -> Label

    @State private var host: SimpleBotHostSettings?
    @State private var hostScope: String?
    /// Whether a store was asked for yet; before that the row says nothing.
    @State private var asked = false
    @State private var isPickerPresented = false
    // Kept under Bots mode's key, so the choice made there stays.
    @AppStorage("bighelp.simple-bots.automatic-time-zone") private var automatic = false
    @Environment(\.scenePhase) private var scenePhase
    @BighelpThemeReader private var theme

    var body: some View {
        Button { isPickerPresented = true } label: { label(value) }
            .bighelpSettingsButton()
            .disabled(host?.load != .loaded || host?.isSaving == true)
            .accessibilityIdentifier("simple-bots.settings.time-zone")
            .driveTarget("simple-bots.settings.time-zone")
            // Also after a reconnect: a computer that wasn't there when Settings opened gets its store,
            // and one picked from its row's menu gets its own.
            .task(id: TaskKey(scope: scope, phase: scenePhase)) {
                if let scope, scope != hostScope { host = nil }
                if host == nil {
                    host = make()
                    hostScope = scope
                }
                asked = true
                guard let host else { return }
                await host.refresh()
                await followDevice(host)
            }
            .bighelpSheet(isPresented: $isPickerPresented) {
                if let host {
                    SimpleBotTimeZonePicker(current: host.timeZone, isAutomatic: automatic) { zone in
                        isPickerPresented = false
                        automatic = zone == nil
                        Task { await host.setTimeZone(zone ?? TimeZone.current.identifier) }
                    }
                    .bighelpSheetSize(.large)
                }
            }
        if let error = host?.errorMessage {
            Text(error)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct TaskKey: Equatable {
        let scope: String?
        let phase: ScenePhase
    }

    private var value: String? {
        SettingsTimeZoneValue.text(load: asked ? (host?.load ?? .unavailable) : .idle,
                                   timeZone: host?.timeZone ?? "", automatic: automatic)
    }

    private func followDevice(_ host: SimpleBotHostSettings) async {
        guard automatic, scenePhase == .active, host.load == .loaded,
              host.timeZone != TimeZone.current.identifier else { return }
        await host.setTimeZone(TimeZone.current.identifier)
    }
}

/// The time zone row's second line: "Automatic", the zone, or the computer's own once the
/// computer answers; why it can't change while the computer isn't reachable; nothing meanwhile.
@MainActor
enum SettingsTimeZoneValue {
    static func text(load: SimpleBotHostSettings.Load, timeZone: String, automatic: Bool) -> String? {
        switch load {
        case .idle, .loading: return nil
        case .unavailable: return String(localized: "Connect your computer first.")
        case .loaded:
            if automatic { return String(localized: "Automatic") }
            return timeZone.isEmpty ? String(localized: "The computer's own") : SimpleBotTimeZonePicker.name(timeZone)
        }
    }
}

/// Where Settings finds every computer: Fleet settings' store, made on first use, and how many there are.
struct SettingsFleetAccess {
    let maintenance: @MainActor () -> FleetMaintenanceStore?
    let gatewayCount: @MainActor () -> Int

    /// One computer has nothing to manage together.
    @MainActor var offersAllGateways: Bool { gatewayCount() > 1 }
}

/// Your computers › Update every computer: Fleet settings, to update and restart them together.
@MainActor
struct SettingsUpdateEveryComputerPage: View {
    let fleet: SettingsFleetAccess
    @State private var store: FleetMaintenanceStore?
    @State private var looked = false

    var body: some View {
        Group {
            if let store {
                FleetSettingsView(store: store)
            } else if looked {
                ContentUnavailableView("Your computers aren't reachable", systemImage: "desktopcomputer",
                                       description: Text("Connect to them, then come back."))
            } else {
                ProgressView()
            }
        }
        // Made on first use, as Settings › System made it.
        .task {
            if store == nil { store = fleet.maintenance() }
            looked = true
        }
    }
}
