#if DEBUG
import Foundation
import SwiftUI

/// Demo of a turn whose agent asked two helpers for help, driven through the
/// real native chat: Hermes-shaped `subagent.*` events go through the same
/// client and projection a host's would, and each helper's saved session is
/// served as Hermes' `/api/sessions/{id}/messages` would. Made-up content
/// only. Opening the ryokan helper's canvas (its first saved-record read) lets
/// the rest of its work arrive, so a test can watch the canvas change.
@MainActor
struct SubagentCanvasFixtureView: View {
    static let launchArgument = "-test-subagent-canvas"

    @State private var fixture: SubagentCanvasFixture?
    @State private var error: String?

    var body: some View {
        Group {
            if let fixture {
                DirectHermesChatView(chat: fixture.chat, store: fixture.store)
            } else if let error {
                Text(error).accessibilityIdentifier("subagent-canvas-fixture.error")
            } else {
                ProgressView("Preparing the helpers demo")
            }
        }
        .task {
            guard fixture == nil else { return }
            do {
                let value = try SubagentCanvasFixture()
                try await value.chat.client.recover(epoch: "fixture-epoch")
                value.start()
                fixture = value
            } catch {
                self.error = "The helpers demo couldn't start"
            }
        }
        .onDisappear { fixture?.close() }
    }
}

@MainActor
private final class SubagentCanvasFixture {
    let root: URL
    let rpc: SubagentCanvasFixtureRPC
    let chat: DirectHermesChat
    let store: DirectHermesWorkspaceStore
    private var script: Task<Void, Never>?
    private var sequence = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "subagent-canvas-ui-" + UUID().uuidString)
        rpc = SubagentCanvasFixtureRPC()
        let drafts = DirectHermesDraftStore(root: root)
        store = DirectHermesWorkspaceStore(vault: EmptySubagentCanvasVault(), drafts: drafts)
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "offline-subagents", profile: "kai",
            runtimeID: "fixture-runtime", storedID: "fixture-stored", title: "Kyoto weekend",
            epoch: "fixture-epoch", drafts: drafts
        )
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        chat = DirectHermesChat(id: client.conversationID, client: client, model: model)
    }

    func start() {
        emit("message.start", [:])
        emit("tool.start", ["tool_id": .string("call-delegate"), "name": .string("delegate_task"),
                            "context": .string("2 tasks")])
        for helper in Helper.allCases {
            emit("subagent.spawn_requested", helper.identity)
            emit("subagent.start", helper.identity.merging(["tool_count": .integer(0)]) { $1 })
        }
        emit("subagent.tool", Helper.ryokan.tool(1, "read_file", "notes/kyoto-trip.md"))
        emit("subagent.thinking", Helper.ryokan.identity.merging([
            "tool_count": .integer(1),
            "text": .string("Three ryokans fit the dates. Checking which still have a room for two."),
        ]) { $1 })
        emit("subagent.tool", Helper.trains.tool(1, "web_search", "kyoto station to arashiyama"))
        rpc.savedSteps[Helper.ryokan.child] = 1
        rpc.savedSteps[Helper.trains.child] = 1

        script = Task { [weak self] in
            // The rest arrives once someone is watching the ryokan helper.
            while let self, !Task.isCancelled, !self.rpc.didReadRyokanRecord {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let steps: [@MainActor (SubagentCanvasFixture) -> Void] = [
                { $0.emit("subagent.tool", Helper.ryokan.tool(2, "web_extract", "https://ryokan-kanra.example/rooms"))
                  $0.rpc.savedSteps[Helper.ryokan.child] = 2 },
                { $0.emit("subagent.tool", Helper.ryokan.tool(3, "write_file", "notes/ryokan-pick.md"))
                  $0.rpc.savedSteps[Helper.ryokan.child] = 3 },
                { $0.rpc.savedSteps[Helper.ryokan.child] = 4
                  $0.emit("subagent.complete", Helper.ryokan.identity.merging([
                      "tool_count": .integer(3), "status": .string("completed"),
                      "summary": .string(SubagentCanvasFixtureRPC.ryokanReply),
                      "duration_seconds": .number(84.2),
                      "files_written": .array([.string("notes/ryokan-pick.md")]),
                  ]) { $1 }) },
                { $0.emit("subagent.tool", Helper.trains.tool(2, "web_extract", "https://trains.example/sagano"))
                  $0.rpc.savedSteps[Helper.trains.child] = 2 },
            ]
            for step in steps {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                step(self)
            }
        }
    }

    private func emit(_ type: String, _ payload: [String: BighelpJSONValue]) {
        sequence += 1
        chat.client.receive(.init(type: type, sessionID: "fixture-runtime", payload: payload, sequence: sequence))
    }

    func close() {
        script?.cancel()
        chat.client.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    enum Helper: CaseIterable {
        case ryokan, trains

        var id: String { self == .ryokan ? "sa-ryokan" : "sa-trains" }
        var child: String { self == .ryokan ? "child-ryokan" : "child-trains" }
        var goal: String {
            switch self {
            case .ryokan:
                "Find a quiet ryokan near Kyoto Station for two adults on May 16–18 with a private bath, "
                    + "under ¥60,000 a night. Compare at most three and pick one."
            case .trains:
                "Work out the simplest train from Kyoto Station to Arashiyama on Saturday morning."
            }
        }

        var identity: [String: BighelpJSONValue] {
            ["subagent_id": .string(id), "child_session_id": .string(child), "goal": .string(goal),
             "parent_id": .string("fixture-runtime"), "model": .string("demo-model"),
             "task_count": .integer(2), "task_index": .integer(self == .ryokan ? 0 : 1)]
        }

        func tool(_ index: Int, _ name: String, _ preview: String) -> [String: BighelpJSONValue] {
            identity.merging(["tool_count": .integer(index), "tool_name": .string(name),
                              "tool_preview": .string(preview), "text": .string(preview)]) { $1 }
        }
    }
}

/// Answers the chat's recovery and serves each helper's saved session as far
/// as the script has got. No network, credentials or provider calls.
@MainActor
private final class SubagentCanvasFixtureRPC: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
    static let ryokanReply = "Hotel Kanra is the best fit: a 6-minute walk from Kyoto Station, a cypress bath in "
        + "the room and ¥52,000 a night. Yuzuya is full that weekend and Sakura has no private bath. "
        + "I saved the comparison to notes/ryokan-pick.md."

    var onEvent: ((DirectHermesEvent) -> Void)?
    /// How many of each helper's steps it has saved so far.
    var savedSteps: [String: Int] = [:]
    private(set) var didReadRyokanRecord = false

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        guard params["session_id"]?.string == "fixture-runtime" else { throw DirectHermesError.identityChanged }
        switch method {
        case "session.events.since":
            return .object(["epoch": .string("fixture-epoch"), "latest_seq": .integer(0),
                            "truncated": .boolean(false), "events": .array([]), "count": .integer(0)])
        case "session.activate":
            return .object([
                "session_id": .string("fixture-runtime"), "stored_session_id": .string("fixture-stored"),
                "running": .boolean(false),
                "messages": .array([.object([
                    "role": .string("user"), "row_id": .integer(1),
                    "text": .string("Plan a quiet weekend in Kyoto for May 16–18: a ryokan near the station "
                                    + "and how to get to Arashiyama."),
                ])]),
            ])
        case "session.control.read":
            return .object(["control": .object(["goal": .null, "loop": .null, "heartbeat": .null,
                                                "revision": .string("fixture"), "updated_at": .integer(0)])])
        case "subagent.list":
            return .object(["subagents": .array([])])
        default:
            throw DirectHermesError.invalidResponse
        }
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        let prefix = "/api/sessions/", suffix = "/messages"
        guard request.method == .get, request.path.hasPrefix(prefix), request.path.hasSuffix(suffix),
              request.query.contains(.init(name: "profile", value: "kai")) else {
            throw DirectHermesError.invalidResponse
        }
        let child = String(request.path.dropFirst(prefix.count).dropLast(suffix.count))
        if child == "child-ryokan" { didReadRyokanRecord = true }
        guard let steps = savedSteps[child] else { throw DirectHermesError.invalidResponse }
        let rows = Self.rows(child: child, steps: steps)
        return .object(["session_id": .string(child), "profile": .string("kai"), "messages": .array(rows),
                        "pagination": .object(["limit": .integer(100), "offset": .integer(0),
                                               "order": .string("latest"), "returned": .integer(rows.count)])])
    }

    func disconnect() async {}

    private static func rows(child: String, steps: Int) -> [BighelpJSONValue] {
        var rows: [BighelpJSONValue] = []
        func row(_ role: String, _ content: BighelpJSONValue, _ extra: [String: BighelpJSONValue] = [:]) {
            var value: [String: BighelpJSONValue] = [
                "id": .integer(rows.count + 1), "session_id": .string(child), "role": .string(role),
                "content": content, "timestamp": .number(1_778_900_000 + Double(rows.count) * 9),
                "tool_calls": .null, "tool_call_id": .null, "tool_name": .null,
            ]
            value.merge(extra) { $1 }
            rows.append(.object(value))
        }
        func call(_ id: String, _ name: String, _ arguments: String, text: String? = nil, result: String) {
            row("assistant", text.map(BighelpJSONValue.string) ?? .null, ["tool_calls": .array([.object([
                "id": .string(id), "type": .string("function"),
                "function": .object(["name": .string(name), "arguments": .string(arguments)]),
            ])])])
            row("tool", .string(result), ["tool_call_id": .string(id), "tool_name": .string(name)])
        }
        if child == "child-ryokan" {
            row("user", .string(SubagentCanvasFixture.Helper.ryokan.goal))
            call("r1", "read_file", #"{"path":"notes/kyoto-trip.md"}"#,
                 text: "Starting from the trip notes.",
                 result: "Dates: May 16–18. Two adults. Budget ¥60,000 a night. Shortlist: Kanra, Yuzuya, Sakura.")
            if steps >= 2 {
                call("r2", "web_extract", #"{"urls":["https://ryokan-kanra.example/rooms"]}"#,
                     text: "Two are booked out or lack a private bath; checking Kanra's rooms.",
                     result: "Deluxe room with cypress bath: ¥52,000 per night, available May 16–18.")
            }
            if steps >= 3 {
                call("r3", "write_file", #"{"path":"notes/ryokan-pick.md","content":"Kanra"}"#,
                     result: "Wrote notes/ryokan-pick.md")
            }
            if steps >= 4 { row("assistant", .string(ryokanReply)) }
        } else {
            row("user", .string(SubagentCanvasFixture.Helper.trains.goal))
            call("t1", "web_search", #"{"query":"kyoto station to arashiyama"}"#,
                 result: "JR Sagano Line, about 15 minutes; Randen tram via Shijo-Omiya.")
            if steps >= 2 {
                call("t2", "web_extract", #"{"urls":["https://trains.example/sagano"]}"#,
                     result: "Saturday trains every 15 minutes from 7:05.")
            }
        }
        return rows
    }
}

@MainActor
private final class EmptySubagentCanvasVault: DirectHermesCredentialVault {
    func load() throws -> DirectHermesSavedConnection? { nil }
    func save(_ connection: DirectHermesSavedConnection) throws { throw DirectHermesError.invalidResponse }
    func delete() throws {}
}
#endif
