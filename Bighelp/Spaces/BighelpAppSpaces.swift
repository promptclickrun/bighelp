import SwiftUI

extension BighelpApp {
    /// Where Today's spaces come from (`SpacesHost`): every computer, the one in use first. The one
    /// in use and the others Show every computer keeps connected are read live; the
    /// rest show what the phone kept, by their saved cache scope. Demo mode's computer is
    /// `DemoSpacesClient`, with its pages in `DemoHTMLAppsClient`.
    static func wireSpaces(registry: BighelpHostRegistry, connections: WorkspaceConnectionStore, fleet: FleetStore,
                           nativeWorkspaces: NativeWorkspaceSelectionStore, demoHosts: DemoHosts,
                           demoAgents: AgentDirectoryStore, usesDemoWorkspace: Bool) {
        let others = RegistryFleetReader(registry: registry)
        let usesDemo: @MainActor () -> Bool = { usesDemoWorkspace && !connections.isDirectSelected }
        SpacesHost.current = {
            if usesDemo() {
                let scope = (try? WorkspaceAuthority.fixture(id: demoHosts.selectedHostID ?? "demo"))?.cacheScopeID ?? "demo"
                let name = demoHosts.hosts.first { $0.id == demoHosts.selectedHostID }?.name ?? "Demo"
                return SpacesComputer(hostKey: "demo", scope: scope, name: name,
                                      api: SpacesAPI(client: DemoSpacesClient.shared),
                                      bots: demoAgents.profiles.map { SpacesBot(id: $0.id, name: $0.name) },
                                      isCurrent: true)
            }
            guard let owner = connections.owner, let hostID = registry.selectedHostID else { return nil }
            return SpacesComputer(hostKey: hostID.uuidString, scope: owner.cacheScopeID,
                                  name: registry.hosts.first { $0.id == hostID }?.name ?? "",
                                  api: SpacesAPI(client: DirectHermesSpacesClient(workspace: { connections.workspace })),
                                  bots: nativeWorkspaces.current?.agents.profiles
                                      .map { SpacesBot(id: $0.id, name: $0.name) } ?? [],
                                  isCurrent: true)
        }
        SpacesHost.computers = {
            if usesDemo() { return SpacesHost.current().map { [$0] } ?? [] }
            var list: [SpacesComputer] = []
            for host in registry.hosts {
                if host.id == registry.selectedHostID, let current = SpacesHost.current() {
                    list.insert(current, at: 0)
                    continue
                }
                let workspace = others.connectedPluginWorkspace(host.id)
                // A computer that isn't connected shows what the phone kept, by its saved scope.
                guard let scope = workspace?.owner?.cacheScopeID
                        ?? registry.workspace(for: host).savedConnection?.workspaceAuthority?.cacheScopeID else { continue }
                let api = workspace.map { workspace in
                    SpacesAPI(client: DirectHermesSpacesClient(workspace: { workspace }))
                }
                list.append(SpacesComputer(hostKey: host.id.uuidString, scope: scope, name: host.name, api: api,
                                           bots: (fleet.snapshots[host.id]?.agents ?? [])
                                               .map { SpacesBot(id: $0.profileID, name: $0.name) },
                                           isCurrent: false))
            }
            return list
        }
        SpacesHost.pages = { scope in
            if usesDemo() { return HTMLAppsAPI(client: DemoHTMLAppsClient.shared) }
            if connections.owner?.cacheScopeID == scope {
                return HTMLAppsAPI(client: DirectHermesHTMLAppsClient(workspace: { connections.workspace }))
            }
            for host in registry.hosts where host.id != registry.selectedHostID {
                guard let workspace = others.connectedPluginWorkspace(host.id),
                      workspace.owner?.cacheScopeID == scope else { continue }
                return HTMLAppsAPI(client: DirectHermesHTMLAppsClient(workspace: { workspace }))
            }
            return nil
        }
    }
}
