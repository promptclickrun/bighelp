import Foundation

/// Other saved computers, for group chats with their agents. Each is reached
/// with its own saved sign-in, connected for the call and let go after, the
/// way the all-computers view reads them. Their agents' names and pictures
/// come from that view's copy of each computer (`fleet`).
@MainActor
final class RegistryRoomPeerHosts: HermesBotModePeerHosts {
    private let registry: BighelpHostRegistry
    private let reader: RegistryFleetReader
    private weak var fleet: FleetStore?

    init(registry: BighelpHostRegistry, fleet: FleetStore? = nil) {
        self.registry = registry
        reader = RegistryFleetReader(registry: registry)
        self.fleet = fleet
    }

    func roomLink(hostID: String, profile: String) async throws -> HermesBotModeRoomLink {
        try await withRoomClient(hostID) { try await $0.groupsRoomLink(profile: profile) }
    }

    func invite(hostID: String, profile: String, roomID: String, homeInstallID: String,
                authorityGatewayID: String, authorityEpoch: Int, memberID: String) async throws -> HermesBotModePeerInvite {
        try await withRoomClient(hostID) {
            try await $0.groupsPeerInvite(profile: profile, roomID: roomID, homeInstallID: homeInstallID,
                                          authorityGatewayID: authorityGatewayID, authorityEpoch: authorityEpoch,
                                          memberID: memberID)
        }
    }

    func hostName(peerID: String) -> String? {
        registry.hosts.first { HermesBotModePeerMembers.slug($0.name) == peerID }?.name
    }

    func agent(peerID: String, profile: String) -> HermesBotModePeerAgent? {
        fleet?.peerAgent(peerID: peerID, profile: profile)
    }

    func refreshAgents() {
        fleet?.refresh()
    }

    func connect(peerID: String) async throws -> any HermesBotModePeerConnection {
        guard let host = registry.hosts.first(where: { HermesBotModePeerMembers.slug($0.name) == peerID }) else {
            throw WorkspaceClientError.invalidRequest
        }
        let held = try await reader.holdWorkspace(host.id)
        // What its bighelp plugin offers; a host without it still connects.
        _ = try? await held.directWorkspace.perform(.nativeContext, payload: [:], owner: held.owner)
        held.pluginFeatures = held.directWorkspace.nativeContext?.features ?? []
        return held
    }

    private func withRoomClient<T>(
        _ hostID: String, _ body: @MainActor (HermesHostedRoomClient) async throws -> T
    ) async throws -> T {
        guard let id = UUID(uuidString: hostID) else { throw WorkspaceClientError.invalidRequest }
        return try await reader.withWorkspace(id) { workspace, owner, _, _ in
            try await body(HermesHostedRoomClient(workspace: workspace, owner: owner))
        }
    }
}
