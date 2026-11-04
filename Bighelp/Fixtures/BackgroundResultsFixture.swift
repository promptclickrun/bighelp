#if DEBUG
import Foundation
import SwiftUI

/// `-test-background-results`: a chat where helpers and a background command report back,
/// read from rows shaped as a Hermes host saves them (`DirectHermesHistoryProjection`), so
/// the cards, the work trail under them and the details sheet show as they do with a host.
/// Made-up content only.
@MainActor
struct BackgroundResultsFixtureView: View {
    static let launchArgument = "-test-background-results"
    static let sessionID = "demo-background-results"

    @State private var model: ChatModel?

    var body: some View {
        Group {
            if let model {
                ChatView(model: model, agentName: "Kai", agentRole: "Design agent")
            } else {
                ProgressView("Preparing the background results demo")
            }
        }
        .task {
            guard model == nil else { return }
            model = Self.makeModel()
        }
    }

    static func makeModel() -> ChatModel? {
        guard let rows = try? Self.rows.map({ try DirectHermesHistoryRow($0, sessionID: Self.sessionID) }),
              let projection = try? DirectHermesHistoryProjection(
                rows: rows, appID: Self.sessionID, profileID: "kai", source: nil, sourceOrderBase: 0) else { return nil }
        return ChatModel(conversationID: Self.sessionID, client: ConversationFixtureClient(),
                         initialItems: projection.messages,
                         initialActivityEvents: projection.activityEvents(sessionID: Self.sessionID))
    }

    private static let packs = """
    [ASYNC DELEGATION BATCH COMPLETE — deleg_demo-1]
    A background fan-out unit you dispatched earlier — 3 subagent(s) — has finished; its consolidated results are below.

    Dispatched: 2026-11-03 17:44:23 (12m2s ago)
    Role: leaf   Model: demo-model   Total duration: 722.4s

    --- ✓ TASK 1/3: Draw a 15-character robots avatar pack as one-color shapes with no background  (status=completed, api_calls=22, 553.45s) ---
    {"pack":"packs/robots.json","characters":15,"verified":"Every character changes fully with a new color."}

    --- ✓ TASK 2/3: Draw a 12-character birds avatar pack in the same style  (status=completed, api_calls=18, 610.2s) ---
    {"pack":"packs/birds.json","characters":12,"verified":"All 12 show on light and dark."}

    --- ✗ TASK 3/3: Draw a 10-character plants avatar pack in the same style  (status=failed, 41.5s) ---
    (failed: could not read packs/plants-brief.json)
    """

    private static let build = """
    [IMPORTANT: Background process proc_demo exited (exit code 1).
    Command: npm run build
    Output:
    error: Missing icon assets/plants.svg]
    """

    private static let rows: [BighelpJSONValue] = [
        row(1, "user", "Draw three avatar packs in the background: robots, birds and plants."),
        row(2, "assistant", "On it. Three helpers are drawing them now. I'll check their work when they're done."),
        row(3, "user", packs, kind: ChatBackgroundResult.helpersKind, metadata: [
            "display_text": .string("Subagent Tasks Finished with Issues: Draw packs (3 tasks)"),
            "task_count": .integer(3), "completed_count": .integer(2), "failed_count": .integer(1),
            "duration_seconds": .number(722.4),
        ]),
        row(4, "assistant", "", toolCall: ("call-1", "read_file", #"{"path":"packs/robots.json"}"#)),
        row(5, "tool", #"{"characters":15}"#, toolResultFor: ("call-1", "read_file")),
        row(6, "assistant", "Robots and birds are ready. The plants helper couldn't read its brief. Should I start it again?"),
        row(7, "user", build, kind: ChatBackgroundResult.commandKind, metadata: [
            "display_text": .string("Background Process Failed (exit 1): npm run build"),
        ]),
        row(8, "assistant", "The build failed because the plants icon is missing. I'll add it with the plants pack."),
    ]

    private static func row(
        _ id: Int, _ role: String, _ content: String, kind: String? = nil, metadata: [String: BighelpJSONValue]? = nil,
        toolCall: (id: String, name: String, arguments: String)? = nil,
        toolResultFor result: (id: String, name: String)? = nil
    ) -> BighelpJSONValue {
        var value: [String: BighelpJSONValue] = [
            "id": .integer(id), "session_id": .string(sessionID), "role": .string(role),
            "content": .string(content), "timestamp": .number(1_793_000_000 + Double(id) * 60),
            "tool_calls": .null, "tool_call_id": .null, "tool_name": .null,
        ]
        if let kind { value["display_kind"] = .string(kind) }
        if let metadata { value["display_metadata"] = .object(metadata) }
        if let toolCall {
            value["tool_calls"] = .array([.object([
                "id": .string(toolCall.id), "type": .string("function"),
                "function": .object(["name": .string(toolCall.name), "arguments": .string(toolCall.arguments)]),
            ])])
        }
        if let result {
            value["tool_call_id"] = .string(result.id)
            value["tool_name"] = .string(result.name)
        }
        return .object(value)
    }
}
#endif
