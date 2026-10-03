import Foundation

/// Reaches the person's hosts for Fleet settings through their saved sign-ins,
/// the way the all-hosts view reads them. Each host gets the System page's
/// own store and its shared plugin model, bound to that host's connection.
@MainActor
final class RegistryFleetMaintenance: FleetMaintenanceConnecting {
    private let registry: BighelpHostRegistry

    init(registry: BighelpHostRegistry) { self.registry = registry }

    var hosts: [FleetHost] {
        registry.hosts.map { FleetHost(id: $0.id, name: $0.name, isSelected: $0.id == registry.selectedHostID) }
    }

    func connect(_ hostID: UUID) async -> FleetMaintenanceReach {
        guard registry.isWorkspaceReady, let host = registry.hosts.first(where: { $0.id == hostID }) else {
            return .offline("Couldn't reach this host.")
        }
        let workspace = registry.workspace(for: host)
        guard workspace.hasSavedConnection else { return .signedOut }
        // Another caller is already connecting it (the all-hosts view, or a switch).
        for _ in 0..<100 where workspace.isConnecting {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return .offline("Couldn't reach this host.") }
        }
        if !workspace.isConnected { await workspace.reconnect() }
        guard workspace.isConnected, let direct = workspace.nativeClient, let saved = workspace.savedConnection,
              DirectHermesIdentity.matches(saved.identity, host.principalIdentity),
              let authority = saved.workspaceAuthority else {
            return workspace.hasSavedConnection ? .offline("Offline. Couldn't reach this host.") : .signedOut
        }
        let generation = registry.generation
        let connectionGeneration = workspace.connectionGeneration
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: generation,
                                   connectionGeneration: connectionGeneration)
        let current: @MainActor () -> WorkspaceOwner? = { [weak registry, weak workspace] in
            guard let registry, let workspace, registry.generation == generation,
                  workspace.connectionGeneration == connectionGeneration, workspace.isConnected else { return nil }
            return owner
        }
        let client = DirectHermesHostOperationsClient(rpc: direct, http: direct, owner: owner, currentOwner: current)
        let profile = workspace.selectedProfile.isEmpty ? "default" : workspace.selectedProfile
        let operations = HostOperationsStore(hostName: host.name, profileID: profile, client: client,
                                             isCurrent: { current() == owner })
        return .ready(operations: operations, plugin: HostPluginUpdateModel.model(for: hostID, registry: registry))
    }
}
