import Foundation

/// Reads one computer's usage over a connection to it: each agent's Hermes
/// analytics, and its plans and limits when asked. The stock dashboard routes
/// carry the numbers; the plugin adds hours and models per day when it has them.
@MainActor
enum HostUsageLoader {
    /// Agents read per computer; a long list keeps its first ones.
    static let maximumAgents = 24

    static func read(hostID: String, hostName: String, agents: [(id: String, name: String)],
                     workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner, days: Int,
                     limits: Bool, refresh: Bool) async -> HostUsage {
        var host = HostUsage(id: hostID, name: hostName)
        var firstError: (any Error)?
        for agent in (agents.isEmpty ? [("default", hostName)] : agents).prefix(maximumAgents) {
            if Task.isCancelled { break }
            let query: [String: BighelpJSONValue] = ["profile": .string(agent.id), "days": .integer(days)]
            do {
                let usage = try await workspace.perform(.usageSummary, payload: query, owner: owner)
                // A host without the models route still shows its days and totals.
                let models = try? await workspace.perform(.usageModels, payload: query, owner: owner)
                let activity = try? await workspace.perform(
                    .usageActivity, payload: ["agentId": .string(agent.id), "days": .integer(days)], owner: owner)
                let report = try HermesUsageReport(usage: usage, models: models, activity: activity)
                host.agents.append(AgentUsage(id: agent.id, name: agent.name, report: report))
            } catch {
                firstError = firstError ?? error
                host.unreadAgents.append(agent.name)
            }
        }
        if host.agents.isEmpty, let firstError {
            host.failure = reason(firstError)
            host.unreadAgents = []
        }
        if limits { host.limits = await readLimits(workspace: workspace, owner: owner, refresh: refresh) }
        return host
    }

    static func readLimits(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner,
                           refresh: Bool) async -> HostUsage.Limits {
        let payload: [String: BighelpJSONValue] = ["agentId": .string("default"), "refresh": .boolean(refresh)]
        do {
            return .loaded(try ProviderUsageReport(json: await workspace.perform(.usageList, payload: payload, owner: owner)))
        } catch WorkspaceClientError.unavailable(.unsupportedOperation), WorkspaceClientError.unavailable(.pluginRequired) {
            return .needsPluginUpdate
        } catch {
            return .unavailable(ProviderUsageStore.reason(error))
        }
    }

    static func reason(_ error: any Error) -> String {
        switch error {
        case WorkspaceClientError.unavailable:
            "This computer's Hermes doesn't share usage. Update Hermes on it."
        case WorkspaceClientError.authenticationRequired, DirectHermesError.authenticationRequired:
            "Sign in to this computer again in Settings › Hosts."
        case _ where ProviderUsageStore.isConnectionHiccup(error):
            "Couldn't reach this computer."
        default:
            "Usage couldn't be read from this computer."
        }
    }
}

/// The computer in use, through the app's own connection, plus every other
/// computer while All hosts is on. Waits a few seconds for a connection that's
/// on its way back, as Provider Usage does.
@MainActor
final class LiveUsageReader: UsageReading {
    private let hostID: String
    private let hostName: String
    private let currentWorkspace: @MainActor () -> (any WorkspaceOperationPerforming)?
    private let agents: @MainActor () -> [(id: String, name: String)]
    private let fleet: FleetStore?

    init(hostID: String, hostName: String,
         currentWorkspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?,
         agents: @escaping @MainActor () -> [(id: String, name: String)], fleet: FleetStore?) {
        self.hostID = hostID
        self.hostName = hostName
        self.currentWorkspace = currentWorkspace
        self.agents = agents
        self.fleet = fleet
    }

    func read(days: Int, refresh: Bool) async -> [HostUsage] {
        var hosts = [await readSelected(days: days)]
        if let fleet {
            for host in fleet.hosts where host.id.uuidString != hostID {
                hosts.append(await fleet.reader.usage(host.id, name: host.name, days: days, refresh: refresh))
            }
        }
        return hosts
    }

    private func readSelected(days: Int) async -> HostUsage {
        for attempt in 0...20 {
            if let workspace = currentWorkspace(), let owner = workspace.owner {
                return await HostUsageLoader.read(hostID: hostID, hostName: hostName, agents: agents(),
                                                  workspace: workspace, owner: owner, days: days,
                                                  limits: false, refresh: false)
            }
            if attempt < 20 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        return HostUsage(id: hostID, name: hostName, failure: "bighelp isn't connected to this computer right now.")
    }
}

extension FleetHostReading {
    func usage(_ hostID: UUID, name: String, days: Int, refresh: Bool) async -> HostUsage {
        HostUsage(id: hostID.uuidString, name: name, failure: "Usage isn't available for this computer.")
    }
}

extension RegistryFleetReader {
    /// Another computer's usage and limits over its own saved sign-in.
    func usage(_ hostID: UUID, name: String, days: Int, refresh: Bool) async -> HostUsage {
        do {
            return try await withWorkspace(hostID) { workspace, owner, current, _ in
                let rows = (try? await DirectHermesAgentProfileService(
                    workspace: workspace, owner: owner, currentOwner: current
                ).rows()) ?? []
                return await HostUsageLoader.read(hostID: hostID.uuidString, hostName: name,
                                                  agents: rows.map { ($0.id, $0.name) }, workspace: workspace,
                                                  owner: owner, days: days, limits: true, refresh: refresh)
            }
        } catch let error as FleetReadError {
            return HostUsage(id: hostID.uuidString, name: name, failure: error.message)
        } catch {
            return HostUsage(id: hostID.uuidString, name: name, failure: "Couldn't reach this computer.")
        }
    }
}
