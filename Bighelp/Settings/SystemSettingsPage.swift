import SwiftUI

/// Settings › System for the computer in use. It reaches the computer the way Fleet settings
/// does and shows its System screen; until then, or while it's offline, the computers list.
/// With more than one gateway, Manage all gateways turns it into Fleet settings: update and
/// restart every gateway together, or one by one.
struct SystemSettingsPage<Offline: View, Extras: View>: View {
    let registry: BighelpHostRegistry
    @Binding var managesAllGateways: Bool
    let fleet: SettingsFleetAccess?
    private let offline: Offline
    private let extras: Extras
    @State private var operations: HostOperationsStore?
    @State private var operationsHostID: UUID?
    @State private var fleetStore: FleetMaintenanceStore?

    init(registry: BighelpHostRegistry, managesAllGateways: Binding<Bool>,
         fleet: SettingsFleetAccess?,
         @ViewBuilder offline: () -> Offline, @ViewBuilder extras: () -> Extras) {
        self.registry = registry
        _managesAllGateways = managesAllGateways
        self.fleet = fleet
        self.offline = offline()
        self.extras = extras()
    }

    private var offersAllGateways: Bool { fleet?.offersAllGateways == true }

    var body: some View {
        Group {
            if offersAllGateways, managesAllGateways, let fleetStore {
                FleetSettingsView(store: fleetStore, leading: AnyView(SystemAllGatewaysSwitch(isOn: $managesAllGateways)))
            } else if let operations, operations.ownsScope {
                HostOperationsView(store: operations,
                                   leading: offersAllGateways ? AnyView(SystemAllGatewaysSwitch(isOn: $managesAllGateways)) : nil) {
                    extras
                }
            } else {
                offline
            }
        }
        // Made outside `body`: Fleet settings' store is created on first use.
        .task(id: managesAllGateways) {
            if managesAllGateways, fleetStore == nil { fleetStore = fleet?.maintenance() }
        }
        .task(id: ConnectionKey(hostID: registry.selectedHostID,
                                isConnected: registry.selectedWorkspace?.isConnected == true)) {
            guard let hostID = registry.selectedHostID, registry.selectedWorkspace?.isConnected == true else {
                operations?.retire()
                operations = nil
                return
            }
            // Back from one of its pages: the same computer keeps its store.
            if operationsHostID == hostID, operations?.ownsScope == true { return }
            if case .ready(let store, _) = await RegistryFleetMaintenance(registry: registry).connect(hostID),
               registry.selectedHostID == hostID {
                operations?.retire()
                operations = store
                operationsHostID = hostID
            }
        }
    }

    private struct ConnectionKey: Hashable {
        let hostID: UUID?
        let isConnected: Bool
    }
}

/// Where Settings finds every gateway: Fleet settings' store, made on first use, and how many there are.
struct SettingsFleetAccess {
    let maintenance: @MainActor () -> FleetMaintenanceStore?
    let gatewayCount: @MainActor () -> Int

    /// One gateway has nothing to manage together.
    @MainActor var offersAllGateways: Bool { gatewayCount() > 1 }
}

/// Settings › System's Manage all gateways, on each of its screens.
struct SystemAllGatewaysSwitch: View {
    @Binding var isOn: Bool
    @BighelpThemeReader private var theme

    var body: some View {
        Section {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage all gateways")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                    Text("Update and restart every gateway together.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .accessibilityIdentifier("settings.system.manage-all-gateways")
        }
    }
}
