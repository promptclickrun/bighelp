import Observation
import SwiftUI

/// Teamwork on a computer, as the bighelp plugin reports it (`native-team-v1`):
/// whether every agent is told about the others and how to ask them for help.
struct TeamworkStatus: Equatable, Sendable {
    struct Agent: Equatable, Sendable {
        let id: String
        let name: String
        let role: String
    }

    let enabled: Bool
    let agents: [Agent]
    /// Agents whose instructions carry the team brief now.
    let reached: [String]
    /// Agents the computer didn't save it for.
    let failed: [String]

    init(enabled: Bool, agents: [Agent], reached: [String], failed: [String]) {
        self.enabled = enabled
        self.agents = agents
        self.reached = reached
        self.failed = failed
    }

    /// Read leniently: an unknown key is ignored, a bad agent is skipped.
    init(json: [String: BighelpJSONValue]) throws {
        guard let enabled = json["enabled"]?.boolean else { throw WorkspaceClientError.invalidResponse }
        func ids(_ key: String) -> [String] {
            (json[key]?.array ?? []).prefix(64).compactMap { $0.string.flatMap(AgentTalkIdentity.agentID(fromHandle:)) }
        }
        self.enabled = enabled
        agents = (json["agents"]?.array ?? []).prefix(64).compactMap { value in
            guard let row = value.object, let id = row["id"]?.string.flatMap(AgentTalkIdentity.agentID(fromHandle:)),
                  let name = row["name"]?.string, !name.isEmpty, name.count <= 120 else { return nil }
            return Agent(id: id, name: name, role: String((row["role"]?.string ?? "").prefix(200)))
        }
        reached = ids("reached")
        failed = ids("failed")
    }
}

@MainActor
protocol TeamworkClient: AnyObject {
    /// The status; with `enabled`, turns teamwork on or off first.
    func team(enabled: Bool?) async throws -> TeamworkStatus
}

/// The plugin's `team` route on the computer in use.
@MainActor
final class DirectHermesTeamworkClient: TeamworkClient {
    static let feature = "native-team-v1"

    private let workspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(workspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.workspace = workspace
    }

    func team(enabled: Bool?) async throws -> TeamworkStatus {
        guard let workspace = workspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.transportUnavailable
        }
        var payload: [String: BighelpJSONValue] = ["agentId": .string("default")]
        if let enabled { payload["enabled"] = .boolean(enabled) }
        do {
            return try TeamworkStatus(json: try await workspace.perform(.teamSettings, payload: payload, owner: owner))
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            return try TeamworkStatus(json: try await workspace.perform(.teamSettings, payload: payload, owner: owner))
        }
    }
}

/// Demo mode's computer: three agents, teamwork off until you turn it on.
@MainActor
final class DemoTeamworkClient: TeamworkClient {
    static let shared = DemoTeamworkClient()
    private var enabled = false

    func team(enabled: Bool?) async throws -> TeamworkStatus {
        if let enabled { self.enabled = enabled }
        let agents = [TeamworkStatus.Agent(id: "finance", name: "Avery Park", role: "Finance agent"),
                      .init(id: "travel", name: "Mina Shah", role: "Travel agent"),
                      .init(id: "home", name: "Jordan Lee", role: "Home agent")]
        return TeamworkStatus(enabled: self.enabled, agents: agents,
                              reached: self.enabled ? agents.map(\.id) : [], failed: [])
    }
}

/// The Teamwork switch's state for one Settings screen.
@MainActor
@Observable
final class TeamworkModel {
    enum Load: Equatable { case idle, loading, loaded, needsPluginUpdate, unavailable }

    private(set) var load: Load = .idle
    private(set) var status: TeamworkStatus?
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let client: any TeamworkClient

    init(client: any TeamworkClient) {
        self.client = client
    }

    var isOn: Bool { status?.enabled ?? false }

    func refresh() async {
        if status == nil { load = .loading }
        await run(nil)
    }

    func set(_ enabled: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        await run(enabled)
    }

    private func run(_ enabled: Bool?) async {
        errorMessage = nil
        do {
            let status = try await client.team(enabled: enabled)
            self.status = status
            load = .loaded
            if !status.failed.isEmpty {
                let names = status.failed.map { id in status.agents.first { $0.id == id }?.name ?? id }
                errorMessage = "The computer didn't save it for \(ChatAgentTalkPresentation.list(names)). Try again."
            }
        } catch WorkspaceClientError.unavailable(.unsupportedOperation),
                WorkspaceClientError.unavailable(.pluginRequired) {
            load = .needsPluginUpdate
        } catch {
            if status == nil { load = .unavailable }
            errorMessage = enabled == nil ? nil : "The computer didn't save that. Try again in a moment."
        }
    }

    /// One line under the switch, in plain words.
    var detail: String {
        switch load {
        case .needsPluginUpdate: return "Update the bighelp plugin on this computer to use this."
        case .unavailable: return "Connect to your computer to change this."
        case .idle, .loading, .loaded:
            if let errorMessage { return errorMessage }
            let count = status?.agents.count ?? 0
            guard isOn else { return "Your agents learn about each other and ask each other for help." }
            return count > 1
                ? "Your \(count) agents know each other and ask each other for help."
                : "On. Make another agent and they'll work together."
        }
    }
}

/// The Teamwork switch, for Settings and Simple Bot mode's Settings.
struct TeamworkToggle<Label: View>: View {
    let model: TeamworkModel
    @ViewBuilder let label: (String) -> Label

    var body: some View {
        Toggle(isOn: Binding(get: { model.isOn }, set: { on in Task { await model.set(on) } })) {
            label(model.detail)
        }
        .disabled(model.load != .loaded || model.isSaving)
        .task { if model.load == .idle { await model.refresh() } }
        .accessibilityIdentifier("settings.teamwork")
    }
}
