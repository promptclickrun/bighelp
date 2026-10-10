import Foundation

/// A gateway: a computer running Hermes that bighelp connects to. Shortcuts can
/// be set to one, so they run there whichever one the app is using.
struct BighelpShortcutGateway: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    let isInUse: Bool
}

/// An agent in a Shortcut and the gateway it's on. Agent IDs are only unique on
/// one gateway, so a picked agent's entity ID carries both. A bare agent ID
/// (Shortcuts made before gateways) means that agent on the gateway in use.
struct BighelpShortcutAgentReference: Equatable, Hashable, Sendable {
    let hostID: UUID?
    let agentID: String

    init(hostID: UUID?, agentID: String) {
        self.hostID = hostID
        self.agentID = agentID
    }

    init?(entityID: String) {
        let parts = entityID.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let agentID = parts.last, !agentID.isEmpty,
              agentID.utf8.count <= 96 else { return nil }
        if parts.count == 2 {
            guard let hostID = UUID(uuidString: parts[0]) else { return nil }
            self.hostID = hostID
        } else {
            hostID = nil
        }
        self.agentID = agentID
    }

    var entityID: String { hostID.map { $0.uuidString + "\u{1F}" + agentID } ?? agentID }
}

/// The gateways Shortcuts offer, and what's on those not in use, read without
/// switching to them. The app binds `RegistryShortcutGateways`.
@MainActor
protocol BighelpShortcutGatewayDirectory: AnyObject {
    /// In the person's order, the one in use marked.
    var gateways: [BighelpShortcutGateway] { get }
    /// The agents on the gateway in use, as this device has them now.
    var agentsInUse: [BighelpShortcutAgent] { get }
    /// Makes a gateway the one bighelp uses.
    func select(_ id: UUID)
    /// Agents on a gateway not in use: read from it, else its last copy on this
    /// device. `reachOnly` never falls back to the copy.
    func agents(on id: UUID, reachOnly: Bool) async throws -> [BighelpShortcutAgent]
    /// The model choices for an agent on a gateway not in use.
    func modelProviders(on id: UUID, agentID: String) async throws -> [BighelpLinkModelProvider]
    /// The scheduled tasks and group chats on a gateway not in use.
    func snapshot(of id: UUID) async throws -> FleetSnapshot
    /// What All agents last read from a gateway not in use, without reaching it.
    func savedSnapshot(of id: UUID) -> FleetSnapshot?
    /// The agents last seen on a gateway not in use, without reaching it.
    func savedAgents(on id: UUID) -> [BighelpShortcutAgent]
}

extension BighelpShortcutGatewayDirectory {
    func agents(on id: UUID) async throws -> [BighelpShortcutAgent] { try await agents(on: id, reachOnly: false) }
}

/// No gateways: demo data and tests that don't set any.
final class BighelpNoShortcutGateways: BighelpShortcutGatewayDirectory {
    var gateways: [BighelpShortcutGateway] { [] }
    var agentsInUse: [BighelpShortcutAgent] { [] }
    func select(_ id: UUID) {}
    func agents(on id: UUID, reachOnly: Bool) async throws -> [BighelpShortcutAgent] {
        throw BighelpShortcutServiceError.gatewayUnavailable
    }
    func modelProviders(on id: UUID, agentID: String) async throws -> [BighelpLinkModelProvider] {
        throw BighelpShortcutServiceError.gatewayUnavailable
    }
    func snapshot(of id: UUID) async throws -> FleetSnapshot { throw BighelpShortcutServiceError.gatewayUnavailable }
    func savedSnapshot(of id: UUID) -> FleetSnapshot? { nil }
    func savedAgents(on id: UUID) -> [BighelpShortcutAgent] { [] }
}

/// The computers in bighelp's host registry. One not in use is read the way All
/// agents reads it (`RegistryFleetReader`): connected for the read, then let go.
@MainActor
final class RegistryShortcutGateways: BighelpShortcutGatewayDirectory {
    private let registry: BighelpHostRegistry
    private let fleet: FleetStore
    private let reader: RegistryFleetReader
    private let liveAgents: @MainActor () -> [AgentProfile]

    init(registry: BighelpHostRegistry, fleet: FleetStore, liveAgents: @escaping @MainActor () -> [AgentProfile]) {
        self.registry = registry
        self.fleet = fleet
        self.reader = RegistryFleetReader(registry: registry)
        self.liveAgents = liveAgents
    }

    var gateways: [BighelpShortcutGateway] {
        registry.hosts.map { .init(id: $0.id, name: $0.name, isInUse: $0.id == registry.selectedHostID) }
    }

    var agentsInUse: [BighelpShortcutAgent] {
        guard let host = registry.selectedHost else { return [] }
        return liveAgents().map {
            BighelpShortcutAgent(id: $0.id, name: $0.name, role: $0.role, isDefault: $0.isDefault,
                                 hostID: host.id, hostName: host.name)
        }
    }

    func select(_ id: UUID) { fleet.select(id) }

    func agents(on id: UUID, reachOnly: Bool) async throws -> [BighelpShortcutAgent] {
        do {
            let profiles = try await reader.withWorkspace(id) { workspace, owner, current, _ in
                try await DirectHermesAgentDirectoryClient(workspace: workspace, owner: owner, currentOwner: current).list()
            }
            let name = registry.hosts.first { $0.id == id }?.name
            return profiles.map {
                BighelpShortcutAgent(id: $0.id, name: $0.name, role: $0.role, isDefault: $0.isDefault,
                                     hostID: id, hostName: name)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let saved = reachOnly ? [] : savedAgents(on: id)
            guard !saved.isEmpty else { throw BighelpShortcutServiceError.gatewayUnreachable }
            return saved
        }
    }

    func modelProviders(on id: UUID, agentID: String) async throws -> [BighelpLinkModelProvider] {
        do {
            return try await reader.withWorkspace(id) { workspace, owner, current, _ in
                try await DirectHermesAgentRuntimeDefaultsClient(workspace: workspace, owner: owner, currentOwner: current)
                    .loadModelProviders(agentID: agentID)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BighelpShortcutServiceError.gatewayUnreachable
        }
    }

    func snapshot(of id: UUID) async throws -> FleetSnapshot {
        do {
            return try await reader.read(id, avatars: fleet.avatars)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let saved = savedSnapshot(of: id) else { throw BighelpShortcutServiceError.gatewayUnreachable }
            return saved
        }
    }

    func savedSnapshot(of id: UUID) -> FleetSnapshot? { fleet.snapshots[id] }

    /// All agents' copy, else what the gateway's widgets last showed.
    func savedAgents(on id: UUID) -> [BighelpShortcutAgent] {
        let name = registry.hosts.first { $0.id == id }?.name
        if let agents = savedSnapshot(of: id)?.agents, !agents.isEmpty {
            return agents.map {
                BighelpShortcutAgent(id: $0.profileID, name: $0.name, role: $0.role, isDefault: $0.isDefault,
                                     hostID: id, hostName: name)
            }
        }
        return (BighelpWidgetSnapshot.load(gateway: id.uuidString).agents ?? []).map {
            BighelpShortcutAgent(id: $0.id, name: $0.name, role: "", isDefault: false, hostID: id, hostName: name)
        }
    }
}

extension BighelpShortcutService {
    // MARK: Gateways

    func availableGateways() -> [BighelpShortcutGateway] { gatewayDirectory.gateways }

    /// The gateway a Shortcut runs on: its agent's, else the one it's set to, else
    /// the one in use (nil).
    func gateway(_ gatewayID: UUID?, for agent: BighelpShortcutAgentReference? = nil) throws -> BighelpShortcutGateway? {
        if let gatewayID, let agentHost = agent?.hostID, agentHost != gatewayID {
            throw BighelpShortcutServiceError.agentNotOnGateway
        }
        guard let id = agent?.hostID ?? gatewayID else { return nil }
        guard let gateway = gatewayDirectory.gateways.first(where: { $0.id == id }) else {
            throw BighelpShortcutServiceError.gatewayUnavailable
        }
        return gateway
    }

    /// Makes the Shortcut's gateway the one bighelp uses, so what follows runs
    /// there. It doesn't wait: the next call to the host waits for it to answer.
    func useGateway(_ gatewayID: UUID?, for agent: BighelpShortcutAgentReference? = nil) throws {
        guard let gateway = try gateway(gatewayID, for: agent), !gateway.isInUse else { return }
        gatewayDirectory.select(gateway.id)
        forgetWorkspaceChecks()
    }

    /// The agents a Shortcut offers: on its gateway, else on the one in use.
    func availableAgents(on gatewayID: UUID?) async throws -> [BighelpShortcutAgent] {
        guard let gateway = try gateway(gatewayID), !gateway.isInUse else { return try await availableAgents() }
        return try await gatewayDirectory.agents(on: gateway.id)
    }

    /// The model choices for a Shortcut's agent, from the gateway it's on.
    func availableModels(for agent: BighelpShortcutAgentReference?) async throws -> [BighelpShortcutModel] {
        guard let agent, let gateway = try gateway(nil, for: agent), !gateway.isInUse else {
            return try await availableModels(agentID: agent?.agentID)
        }
        return try await gatewayDirectory.modelProviders(on: gateway.id, agentID: agent.agentID).flatMap { provider in
            provider.models.map { BighelpShortcutModel(providerID: provider.id, providerName: provider.name, modelID: $0) }
        }
    }

    /// Agents saved in Shortcuts, from what this device last saw, so a Shortcut
    /// starts without waiting for its gateway. An unknown one keeps its ID as its
    /// name; running the Shortcut says if it's gone.
    func savedAgents(_ entityIDs: [String]) -> [BighelpShortcutAgent] {
        entityIDs.compactMap { entityID in
            guard let reference = BighelpShortcutAgentReference(entityID: entityID) else { return nil }
            if let known = savedAgent(reference) { return known }
            let hostName = reference.hostID.flatMap { id in gatewayDirectory.gateways.first { $0.id == id }?.name }
            return BighelpShortcutAgent(id: reference.agentID, name: reference.agentID, role: "", isDefault: false,
                                        hostID: reference.hostID, hostName: hostName)
        }
    }

    private func savedAgent(_ reference: BighelpShortcutAgentReference) -> BighelpShortcutAgent? {
        let inUse = gatewayDirectory.gateways.first(where: \.isInUse)?.id
        let agents: [BighelpShortcutAgent]
        if let hostID = reference.hostID, hostID != inUse {
            agents = gatewayDirectory.savedAgents(on: hostID)
        } else {
            let live = gatewayDirectory.agentsInUse
            agents = live.isEmpty ? fallbackAgents : live
        }
        guard let agent = agents.first(where: { $0.id == reference.agentID }) else { return nil }
        let hostName = reference.hostID.flatMap { id in gatewayDirectory.gateways.first { $0.id == id }?.name }
        return BighelpShortcutAgent(id: agent.id, name: agent.name, role: agent.role, isDefault: agent.isDefault,
                                    hostID: reference.hostID, hostName: hostName)
    }

    // MARK: Opening bighelp

    /// Start voice chat: the agent's Bot Chat on its gateway, in voice. The voice
    /// stage shows at once and the app does the rest (switching gateway, connecting,
    /// opening the chat), so the Shortcut never waits on the host.
    func startVoiceChat(gatewayID: UUID?, agent: BighelpShortcutAgentReference?) throws {
        let gateway = try gateway(gatewayID, for: agent)
        let known = agent.flatMap(savedAgent)
        VoiceLaunchState.shared.begin(agent: known.map { .init(id: $0.id, name: $0.name, imageURL: nil) })
        openLink(BighelpShortcutLinks.voice(agentID: agent?.agentID, hostID: gateway?.id))
    }

    /// New chat: bighelp opens on a new chat with the agent, on its gateway.
    func startNewChat(gatewayID: UUID?, agent: BighelpShortcutAgentReference?) throws {
        let gateway = try gateway(gatewayID, for: agent)
        openLink(BighelpWidgetSnapshot.newChatURL(agentID: agent?.agentID, hostID: gateway?.id.uuidString))
    }

    /// Open agent: the agent's home on its gateway.
    func openAgentHome(gatewayID: UUID?, agent: BighelpShortcutAgentReference) throws {
        let gateway = try gateway(gatewayID, for: agent)
        openLink(BighelpShortcutLinks.on(gateway?.id, BighelpShortcutLinks.agentHome(agent.agentID)))
    }

    /// Open in bighelp: a place, on the gateway the Shortcut is set to.
    func open(_ destination: BighelpShortcutDestination, gatewayID: UUID?) throws {
        let gateway = try gateway(gatewayID)
        openLink(BighelpShortcutLinks.on(gateway?.id, destination.url))
    }
}
