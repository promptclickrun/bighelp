import Foundation

/// The plugin's `agents/activity` route (`native-agents-activity-v1`): what each agent's Bot Chat is
/// doing, in one read. It covers turns the app started, turns another agent asked for in another
/// Hermes process (`message_agent`, `hermes -p <agent> chat -q`), and approvals or questions waiting
/// on the person. Read-only.
@MainActor
final class DirectHermesBotChatActivityClient: BotChatActivityReading {
    static let feature = "native-agents-activity-v1"

    private let currentWorkspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(currentWorkspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.currentWorkspace = currentWorkspace
    }

    func activity(agentIDs: [String]) async -> [String: BotChatActivity]? {
        let ids = agentIDs.filter(AgentTalkIdentity.isProfileID).prefix(BotChatActivityStore.maximumAgents)
        guard !ids.isEmpty else { return [:] }
        guard let workspace = currentWorkspace(), let owner = workspace.owner else { return nil }
        let payload: [String: BighelpJSONValue] = ["agentIds": .array(ids.map { .string($0) })]
        let response: [String: BighelpJSONValue]
        do {
            response = try await workspace.perform(.agentsActivity, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            guard let retried = try? await workspace.perform(.agentsActivity, payload: payload, owner: owner) else {
                return nil
            }
            response = retried
        } catch {
            return nil
        }
        return Self.activities(from: response, asked: Set(ids))
    }

    /// Leniently: a row this build can't read is left out (unknown), never the whole answer.
    static func activities(from response: [String: BighelpJSONValue], asked: Set<String>) -> [String: BotChatActivity]? {
        guard let rows = response["agents"]?.array else { return nil }
        var result: [String: BotChatActivity] = [:]
        for value in rows.prefix(BotChatActivityStore.maximumAgents) {
            guard let row = value.object, let id = row["agentId"]?.string, asked.contains(id),
                  result[id] == nil, let state = row["state"]?.string else { continue }
            switch state {
            case "idle": result[id] = .idle
            case "waiting": result[id] = .waiting
            case "working":
                let tool = row["tool"]?.string.flatMap { ChatToolNames.plainName($0) == nil ? nil : $0 }
                result[id] = .working(tool: tool)
            default: continue
            }
        }
        return result
    }
}
