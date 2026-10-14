import Foundation
import Testing
@testable import Bighelp

/// Stop and Steer for a running helper: gated on the host's capabilities, sent
/// over this chat's own session, and honest about what Hermes answered.
@MainActor
struct SubagentControlTests {
    private func chat(_ rpc: ControlRPC, supports: Set<WorkspaceCapability> = [.subagentStop, .subagentSteer])
        throws -> (DirectHermesConversationClient, ChatModel, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "kai",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        client.supportsCapability = { supports.contains($0) }
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        client.receive(.init(type: "subagent.start", sessionID: "runtime", payload: [
            "subagent_id": .string("sa-1"), "goal": .string("Compare three ryokans"), "task_count": .integer(1),
            "task_index": .integer(0),
        ], sequence: 1))
        return (client, model, root)
    }

    @Test func aHostWithoutTheCapabilityOffersNeitherAndSendsNothing() async throws {
        let rpc = ControlRPC()
        let (client, model, root) = try chat(rpc, supports: [])
        defer { client.suspend(); try? FileManager.default.removeItem(at: root) }
        #expect(!model.canStopSubagents)
        #expect(!model.canSteerSubagents)
        #expect(await model.stopSubagent(id: "sa-1") == .unsupported)
        #expect(await model.steerSubagent(id: "sa-1", text: "Only two, please") == .unsupported)
        await model.refreshSubagentSteering()
        #expect(model.subagentCanvases["sa-1"]?.acceptsSteering == nil)
        #expect(!rpc.requests.contains { $0.method.hasPrefix("subagent.") && $0.method != "subagent.list" })
    }

    @Test func stopCanBeOfferedWithoutSteer() throws {
        let (client, model, root) = try chat(ControlRPC(), supports: [.subagentStop])
        defer { client.suspend(); try? FileManager.default.removeItem(at: root) }
        #expect(model.canStopSubagents)
        #expect(!model.canSteerSubagents)
    }

    @Test func aQueuedSteerGoesToThisChatsSessionTrimmed() async throws {
        let rpc = ControlRPC()
        rpc.steerStatus = "queued"
        let (client, model, root) = try chat(rpc)
        defer { client.suspend(); try? FileManager.default.removeItem(at: root) }
        #expect(await model.steerSubagent(id: "sa-1", text: "  Only two, please \n") == .steerQueued)
        let request = try #require(rpc.requests.last { $0.method == "subagent.steer" })
        #expect(request.params == ["session_id": .string("runtime"), "subagent_id": .string("sa-1"),
                                   "text": .string("Only two, please")])
    }

    @Test func aRejectedSteerSaysSoAndHidesTheBox() async throws {
        let rpc = ControlRPC()
        rpc.steerStatus = "rejected"
        rpc.roster = [("sa-1", true)]
        let (client, model, root) = try chat(rpc)
        defer { client.suspend(); try? FileManager.default.removeItem(at: root) }
        await model.refreshSubagentSteering()
        #expect(model.subagentCanvases["sa-1"]?.acceptsSteering == true)
        let outcome = await model.steerSubagent(id: "sa-1", text: "Only two, please")
        #expect(outcome == .steerRejected)
        #expect(outcome.message == "It isn't taking messages right now.")
        #expect(model.subagentCanvases["sa-1"]?.acceptsSteering == false)
    }

    @Test func anEmptyOrHugeMessageIsNeverSent() async throws {
        let rpc = ControlRPC()
        let (client, model, root) = try chat(rpc)
        defer { client.suspend(); try? FileManager.default.removeItem(at: root) }
        #expect(await model.steerSubagent(id: "sa-1", text: "   ") == .failed)
        #expect(await model.steerSubagent(id: "sa-1", text: String(repeating: "a", count: 4_001)) == .failed)
        #expect(!rpc.requests.contains { $0.method == "subagent.steer" })
    }

    @Test(arguments: [(true, ChatModel.SubagentControlOutcome.stopping), (false, .alreadyEnded)])
    func stopSaysWhetherTheHelperWasStillRunning(found: Bool, outcome: ChatModel.SubagentControlOutcome) async throws {
        let rpc = ControlRPC()
        rpc.found = found
        let (client, model, root) = try chat(rpc)
        defer { client.suspend(); try? FileManager.default.removeItem(at: root) }
        #expect(await model.stopSubagent(id: "sa-1") == outcome)
        #expect(rpc.requests.last?.params == ["session_id": .string("runtime"), "subagent_id": .string("sa-1")])
    }

    @Test(arguments: [(-32601, ChatModel.SubagentControlOutcome.unsupported), (4001, .unreachable), (5000, .failed)])
    func hostRefusalsAreExplained(code: Int, outcome: ChatModel.SubagentControlOutcome) async throws {
        let rpc = ControlRPC()
        rpc.refusal = code
        let (client, model, root) = try chat(rpc)
        defer { client.suspend(); try? FileManager.default.removeItem(at: root) }
        #expect(await model.stopSubagent(id: "sa-1") == outcome)
        #expect(await model.steerSubagent(id: "sa-1", text: "Hi") == outcome)
    }

    @Test func aMalformedAnswerIsNotTakenAsSuccess() async throws {
        let rpc = ControlRPC()
        rpc.steerStatus = "maybe"
        let (client, model, root) = try chat(rpc)
        defer { client.suspend(); try? FileManager.default.removeItem(at: root) }
        #expect(await model.steerSubagent(id: "sa-1", text: "Hi") == .failed)
    }

    @Test func theRosterSaysWhoTakesMessagesAndAnUnlistedHelperDoesNot() async throws {
        let rpc = ControlRPC()
        rpc.roster = [("sa-1", true)]
        let (client, model, root) = try chat(rpc)
        defer { client.suspend(); try? FileManager.default.removeItem(at: root) }
        await model.refreshSubagentSteering()
        #expect(model.subagentCanvases["sa-1"]?.acceptsSteering == true)
        rpc.roster = []
        await model.refreshSubagentSteering()
        #expect(model.subagentCanvases["sa-1"]?.acceptsSteering == false)
    }

    @Test func aReplacedChatHasNoHelperControls() async throws {
        let rpc = ControlRPC()
        let (client, model, root) = try chat(rpc)
        defer { client.suspend(); try? FileManager.default.removeItem(at: root) }
        model.invalidateReferenceOwnership()
        #expect(!model.canStopSubagents)
        #expect(await model.stopSubagent(id: "sa-1") == .unsupported)
        #expect(!rpc.requests.contains { $0.method == "subagent.interrupt" })
    }

    @Test func theHostsCapabilitiesIncludeStopAndSteer() throws {
        let manifest = try DirectHermesCapabilityManifest.decode(.object(["per_session_exclusive_submit": .boolean(true)]))
        #expect(manifest.supportedOperations.isSuperset(of: [.subagentStop, .subagentSteer]))
    }
}

@MainActor
private final class ControlRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var requests: [(method: String, params: [String: BighelpJSONValue])] = []
    var roster: [(String, Bool)] = []
    var steerStatus = "queued"
    var found = true
    var refusal: Int?

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        requests.append((method, params))
        if let refusal, method.hasPrefix("subagent."), method != "subagent.list" {
            throw DirectHermesError.rpcRejected(code: refusal)
        }
        switch method {
        case "subagent.list":
            return .object(["subagents": .array(roster.map {
                .object(["subagent_id": .string($0.0), "status": .string("running"), "accepting_steer": .boolean($0.1)])
            })])
        case "subagent.steer":
            return .object(["status": .string(steerStatus), "subagent_id": params["subagent_id"] ?? .null])
        case "subagent.interrupt":
            return .object(["found": .boolean(found), "subagent_id": params["subagent_id"] ?? .null])
        case "session.control.read":
            return .object(["control": .object(["goal": .null, "loop": .null, "heartbeat": .null,
                                                "revision": .string("fixture"), "updated_at": .integer(0)])])
        default:
            throw DirectHermesError.invalidResponse
        }
    }

    func disconnect() async {}
}
