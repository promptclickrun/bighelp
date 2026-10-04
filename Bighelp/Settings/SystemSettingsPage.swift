import SwiftUI

/// Settings › System for the computer in use. It reaches the computer the way Fleet settings
/// does and shows its System screen; until then, or while it's offline, the computers list.
struct SystemSettingsPage<Offline: View, Extras: View>: View {
    let registry: BighelpHostRegistry
    private let offline: Offline
    private let extras: Extras
    @State private var operations: HostOperationsStore?
    @State private var operationsHostID: UUID?

    init(registry: BighelpHostRegistry, @ViewBuilder offline: () -> Offline, @ViewBuilder extras: () -> Extras) {
        self.registry = registry
        self.offline = offline()
        self.extras = extras()
    }

    var body: some View {
        Group {
            if let operations, operations.ownsScope {
                HostOperationsView(store: operations) { extras }
            } else {
                offline
            }
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
