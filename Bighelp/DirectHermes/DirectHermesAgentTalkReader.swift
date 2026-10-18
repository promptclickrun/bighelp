import CryptoKit
import Foundation

/// One run of another agent that this chat's agent started, as the bighelp
/// plugin reads it from that agent's own history (`native-agent-talk-v1`):
/// which chat it ran in, which message started it (a hash, never the words)
/// and what it's doing now.
struct AgentTalkRun: Equatable, Sendable {
    let agentID: String
    let sessionID: String
    /// SHA-256 of the first message, signature removed (`AgentTalkMessageHash`).
    let messageHash: String?
    let startedAt: Date?
    let isWorking: Bool
    /// The Hermes tool it's running, while it works.
    let toolName: String?
}

/// A call to look up: the agent written to and the message's hash.
struct AgentTalkRunQuery: Equatable, Hashable, Sendable {
    let agentID: String
    let messageHash: String
}

/// Reads other agents' runs and what they did, for a chat's agent-to-agent rails.
@MainActor
protocol AgentTalkReading: AnyObject {
    /// The runs these calls started, by the agent each wrote to and a hash of its message.
    /// Nil when the host can't say (an older plugin, no connection).
    func runs(agentID: String, sessionID: String, calls: [AgentTalkRunQuery]) async -> [AgentTalkRun]?
    /// What `agentID` did in its chat `sessionID`, in plain words ("Searched the web").
    func steps(agentID: String, sessionID: String) async -> [String]?
    /// Whether another Hermes process is running this chat now: an agent another one asked, working
    /// in its Bot Chat.
    func otherProcessRun(agentID: String, sessionID: String) async -> ChatOtherProcessReading
    /// Stops that run as Ctrl-C would. False when nothing was stopped.
    func stopOtherProcessRun(agentID: String, sessionID: String) async -> Bool
}

extension AgentTalkReading {
    func otherProcessRun(agentID: String, sessionID: String) async -> ChatOtherProcessReading { .unavailable }
    func stopOtherProcessRun(agentID: String, sessionID: String) async -> Bool { false }
}

/// A chat another Hermes process is running: the tool it's on, and whether Stop can reach it.
struct ChatOtherProcessRun: Equatable, Sendable {
    let toolName: String?
    let canStop: Bool
}

enum ChatOtherProcessReading: Equatable, Sendable {
    /// An older plugin, or no connection.
    case unavailable
    case idle
    case running(ChatOtherProcessRun)
}

/// The message hash both sides compute: the words with Hermes' "Message from
/// Name (@handle):" signature removed and the ends trimmed, as SHA-256 hex.
/// The plugin's `agent_talk.message_hash` does the same.
enum AgentTalkMessageHash {
    static func hash(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let signature = body.firstMatch(of: /^Message from [^\n()]{1,80}\(@[A-Za-z0-9][A-Za-z0-9_.\/@-]{0,127}\):/) {
            body = String(body[signature.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// The plugin's `agents/talk` route, and the stock session history for an
/// agent's own chat. Everything is optional: an older plugin or a missing
/// chat just leaves the rail with what the tool call said.
@MainActor
final class DirectHermesAgentTalkReader: AgentTalkReading {
    static let feature = "native-agent-talk-v1"
    static let chatActivityFeature = "native-chat-activity-v1"
    static let maximumCalls = 16
    static let maximumRuns = 32
    static let maximumSteps = 12

    private let currentWorkspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(currentWorkspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.currentWorkspace = currentWorkspace
    }

    func otherProcessRun(agentID: String, sessionID: String) async -> ChatOtherProcessReading {
        guard let response = await perform(.chatActivity, agentID: agentID, sessionID: sessionID),
              let working = response["working"]?.boolean else { return .unavailable }
        guard working else { return .idle }
        let tool = response["tool"]?.string.flatMap { $0.count <= 64 ? $0 : nil }
        return .running(ChatOtherProcessRun(toolName: tool, canStop: response["canStop"]?.boolean == true))
    }

    func stopOtherProcessRun(agentID: String, sessionID: String) async -> Bool {
        await perform(.chatStop, agentID: agentID, sessionID: sessionID)?["stopped"]?.boolean == true
    }

    private func perform(_ operation: WorkspaceOperation, agentID: String,
                         sessionID: String) async -> [String: BighelpJSONValue]? {
        guard let workspace = currentWorkspace(), let owner = workspace.owner else { return nil }
        let payload: [String: BighelpJSONValue] = ["agentId": .string(agentID), "sessionId": .string(sessionID)]
        do {
            return try await workspace.perform(operation, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            return try? await workspace.perform(operation, payload: payload, owner: owner)
        } catch {
            return nil
        }
    }

    func runs(agentID: String, sessionID: String, calls: [AgentTalkRunQuery]) async -> [AgentTalkRun]? {
        guard let workspace = currentWorkspace(), let owner = workspace.owner else { return nil }
        let payload: [String: BighelpJSONValue] = [
            "agentId": .string(agentID), "sessionId": .string(sessionID),
            "calls": .array(calls.filter { AgentTalkMessageHash.isHash($0.messageHash) }.prefix(Self.maximumCalls)
                .map { .object(["agentId": .string($0.agentID), "message": .string($0.messageHash)]) }),
        ]
        let response: [String: BighelpJSONValue]
        do {
            response = try await workspace.perform(.agentTalkRuns, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            guard let retried = try? await workspace.perform(.agentTalkRuns, payload: payload, owner: owner) else {
                return nil
            }
            response = retried
        } catch {
            return nil
        }
        return Self.runs(from: response)
    }

    static func runs(from response: [String: BighelpJSONValue]) -> [AgentTalkRun]? {
        guard let values = response["runs"]?.array else { return nil }
        return values.prefix(maximumRuns).compactMap { value in
            guard let row = value.object,
                  let agent = row["agentId"]?.string.flatMap(AgentTalkIdentity.agentID(fromHandle:)),
                  let session = row["sessionId"]?.string, AgentTalkIdentity.isSessionID(session) else { return nil }
            let hash = row["message"]?.string.flatMap { AgentTalkMessageHash.isHash($0) ? $0 : nil }
            let tool = row["tool"]?.string.flatMap { ChatToolNames.plainName($0) == nil ? nil : $0 }
            let started = row["startedAt"]?.number.map { Date(timeIntervalSince1970: $0) }
            return AgentTalkRun(agentID: agent, sessionID: session, messageHash: hash, startedAt: started,
                                isWorking: row["working"]?.boolean ?? false, toolName: tool)
        }
    }

    func steps(agentID: String, sessionID: String) async -> [String]? {
        guard let workspace = currentWorkspace(), let owner = workspace.owner,
              let response = try? await workspace.perform(.sessionHistory, payload: [
                  "session_id": .string(sessionID), "profile": .string(agentID), "limit": .integer(200),
                  "offset": .integer(0), "order": .string("oldest"),
              ], owner: owner),
              let values = response["messages"]?.array else { return nil }
        let rows = values.compactMap { try? DirectHermesHistoryRow($0, sessionID: sessionID) }
        return Self.steps(from: rows)
    }

    /// The tools the agent ran, in order, in the words its own chat would use.
    static func steps(from rows: [DirectHermesHistoryRow]) -> [String] {
        var steps: [String] = []
        for row in rows where row.isVisible {
            for call in row.toolCalls {
                let phrase = ChatToolPhrase.phrase(forTool: call.name, arguments: call.arguments).past
                if steps.last != phrase { steps.append(phrase) }
            }
        }
        return Array(steps.prefix(maximumSteps))
    }
}

extension ChatActivityEvent {
    /// How the plugin finds the run this call started. Words sent in a file have no hash to match.
    var agentTalkRunQuery: AgentTalkRunQuery? {
        guard let call = agentTalkCall, call.route != .peer, let message = call.message,
              AgentTalkIdentity.isProfileID(call.targetID) else { return nil }
        return AgentTalkRunQuery(agentID: call.targetID, messageHash: AgentTalkMessageHash.hash(message))
    }
}

/// A chat's view of the other agents it's talking to: what each running call's
/// agent is doing and which chat it ran in, matched to the calls by message.
@MainActor
@Observable
final class ChatAgentTalkLive {
    private(set) var activities: [String: AgentTalkLiveActivity] = [:]

    var hasWorkingRuns: Bool { activities.values.contains(where: \.isWorking) }

    /// Each call takes the earliest unclaimed run its message started with that agent.
    func update(runs: [AgentTalkRun], calls: [ChatActivityEvent]) {
        var remaining = runs.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        var result: [String: AgentTalkLiveActivity] = [:]
        func claim(_ call: ChatActivityEvent, where predicate: (AgentTalkRun) -> Bool) {
            guard let index = remaining.firstIndex(where: predicate) else { return }
            let run = remaining.remove(at: index)
            result[call.id] = AgentTalkLiveActivity(sessionID: run.sessionID, toolName: run.isWorking ? run.toolName : nil,
                                                    isWorking: run.isWorking)
        }
        for call in calls {
            guard let query = call.agentTalkRunQuery else { continue }
            claim(call) { $0.agentID == query.agentID && $0.messageHash == query.messageHash }
        }
        if result != activities { activities = result }
    }
}
