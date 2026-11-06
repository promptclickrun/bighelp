import SwiftUI

extension BighelpApp {
    /// Bots mode's choices on the person's computers (`BotsAppStateSync`): the gateway in use, and
    /// the others the all-hosts view or Multi-gateway keeps connected. Demo mode's computer keeps
    /// them in memory for the run.
    static func startBotsAppState(registry: BighelpHostRegistry, connections: WorkspaceConnectionStore, fleet: FleetStore,
                                  settings: SettingsStore, companions: CompanionStore, demo: DemoHosts?,
                                  liveAgents: @escaping @MainActor () -> (scope: String, agents: AgentDirectoryStore)?) {
        let sync = BotsAppStateSync.shared
        let others = RegistryFleetReader(registry: registry)
        let usesDemo = { demo != nil && !connections.isDirectSelected }
        sync.hosts = {
            if usesDemo() {
                let scope = (try? WorkspaceAuthority.fixture(id: demo?.selectedHostID ?? "demo"))?.cacheScopeID ?? "demo"
                return [BotsAppStateHost(hostKey: "demo", scopes: [scope], faceScope: "fixture-account:fixture-host",
                                         isSelected: true)]
            }
            return registry.hosts.map { host in
                let selected = host.id == registry.selectedHostID
                var scopes = selected ? [connections.owner?.cacheScopeID].compactMap { $0 } : []
                if let saved = registry.workspace(for: host).savedConnection?.workspaceAuthority?.cacheScopeID,
                   !scopes.contains(saved) {
                    scopes.append(saved)
                }
                return BotsAppStateHost(hostKey: host.id.uuidString, scopes: scopes,
                                        faceScope: CompanionSurfaceScope.computer(host.id.uuidString), isSelected: selected)
            }
        }
        sync.computers = {
            if usesDemo() { return [AppStateComputer(hostKey: "demo", client: DemoAppStateClient.shared)] }
            var reached: [AppStateComputer] = []
            if let selected = registry.selectedHostID, connections.owner != nil {
                reached.append(AppStateComputer(hostKey: selected.uuidString,
                                                client: DirectHermesAppStateClient(workspace: { connections.workspace })))
            }
            for host in registry.hosts where host.id != registry.selectedHostID {
                guard let workspace = others.connectedPluginWorkspace(host.id) else { continue }
                reached.append(AppStateComputer(hostKey: host.id.uuidString,
                                                client: DirectHermesAppStateClient(workspace: { workspace })))
            }
            return reached
        }
        sync.start(BotsAppStateStores(
            order: .shared, fleet: fleet,
            primary: { settings.simpleBotsMultiPrimary }, setPrimary: { settings.simpleBotsMultiPrimary = $0 },
            voices: .shared, marks: .shared, pets: .shared, companions: companions,
            restorePet: { slug, key in
                // Demo mode's pets are drawn in the app; others come from petdex, as Bot Studio's do.
                PetAvatarStore.shared.restore(slug, to: key, find: { slug in
                    if usesDemo() { return PetdexFixtures.pets.first { $0.slug == slug } }
                    return (try? await PetdexPublicCatalog.shared.gallery())?.first { $0.slug == slug }
                }, loadSheet: { pet in
                    if usesDemo(), let data = PetdexFixtures.sheet(slug: pet.slug) { return data }
                    return try await PetdexPublicCatalog.shared.sheet(pet)
                })
            },
            // The gateway in use's agents hold its pins; the others' are in each sign-in's own settings.
            pins: { scope in
                if let live = liveAgents(), live.scope == scope { return live.agents.savedPins }
                guard let defaults = UserDefaults(suiteName: "app.loopdy.native-workspace." + scope) else { return .init() }
                return AgentDirectoryStore.savedPins(in: defaults, hostBucket: scope)
            },
            setPins: { pins, scope in
                if let live = liveAgents(), live.scope == scope { return live.agents.applySavedPins(pins) }
                guard !usesDemo(), let defaults = UserDefaults(suiteName: "app.loopdy.native-workspace." + scope) else { return }
                AgentDirectoryStore.savePins(pins, in: defaults, hostBucket: scope)
            }))
    }

    /// When Bots mode's choices are read from the computers: each new connection to the gateway in
    /// use, coming back to bighelp, and other gateways kept connected or let go.
    static func botsAppStateKey(connections: WorkspaceConnectionStore, registry: BighelpHostRegistry,
                                isActive: Bool) -> String {
        let owner = connections.owner
        return [owner?.cacheScopeID ?? "", owner.map { String(describing: $0.connectionGeneration) } ?? "",
                String(isActive), String(registry.keepsOtherHostsConnected)].joined(separator: "|")
    }
}
