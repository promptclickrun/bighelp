import Foundation
import Testing
@testable import Bighelp

/// An Activities item's read-out, from the plugin's `agents/today/detail`.
@MainActor
struct AgentTodayDetailTests {
    private let listed = AgentTodayItem(id: "delegation:abc", kind: .subagent, title: "Compare hotels", state: .running,
                                        startedAt: Date(timeIntervalSince1970: 1_794_091_440))

    private func json(_ text: String) throws -> BighelpJSONValue {
        try JSONDecoder().decode(BighelpJSONValue.self, from: Data(text.utf8))
    }

    @Test func aSubagentsStepsKeepTheirOrderAndUnreadableOnesAreLeftOut() throws {
        let detail = AgentTodayDetail(json: try json("""
            {"item": {"id": "delegation:abc", "kind": "subagent", "title": "Compare hotels", "state": "done",
                      "startedAt": 1794091440, "endedAt": 1794091740},
             "subagent": {"goal": "Compare hotels near Alfama", "summary": "**Three** picks", "future": 1,
                          "steps": [
                            {"at": 1794091442, "kind": "tool", "tool": "web_search", "preview": "alfama", "state": "done"},
                            {"kind": "tool"},
                            {"kind": "dance", "preview": "?"},
                            {"at": 1794091450, "kind": "message", "preview": "Six places fit."},
                            {"at": 1794091460, "kind": "tool", "tool": "read_file", "preview": "notes.md", "state": "failed"}
                          ]}}
            """), listed: listed)
        #expect(detail.item.state == .done, "The read-out has the newest state")
        guard case .subagent(let subagent) = detail.body else { Issue.record("Not a subagent"); return }
        #expect(subagent.steps.map(\.kind) == [.tool, .message, .tool])
        #expect(subagent.steps.map(\.tool) == ["web_search", nil, "read_file"])
        #expect(subagent.steps.last?.state == .failed)
        #expect(subagent.summary == "**Three** picks")
        #expect(!subagent.stepsTruncated)
    }

    @Test func anotherItemsRowOrNoRowKeepsTheListedOne() throws {
        let other = AgentTodayDetail(json: try json(#"{"item": {"id": "other", "kind": "command", "title": "x"}}"#),
                                     listed: listed)
        #expect(other.item == listed)
        #expect(other.body == .none)
        #expect(AgentTodayDetail(json: .null, listed: listed).item == listed)
    }

    @Test func commandOutputKeepsItsLinesAndJSONIsLaidOut() throws {
        let detail = AgentTodayDetail(json: try json(#"""
            {"command": {"command": "npm run dev", "exitCode": 2, "output": "\n  ready on :3000\nError: x\n",
                         "outputTruncated": true}}
            """#), listed: listed)
        guard case .command(let command) = detail.body else { Issue.record("Not a command"); return }
        #expect(command.output == "  ready on :3000\nError: x", "Indentation stays, empty edges go")
        #expect(command.exitCode == 2)
        #expect(command.outputTruncated)
        #expect(command.readableOutput == command.output)
        let json = AgentTodayDetail.Command(command: nil, exitCode: 0, output: #"{"b":1,"a":[true]}"#,
                                            outputTruncated: false)
        #expect(json.readableOutput == "{\n  \"a\" : [\n    true\n  ],\n  \"b\" : 1\n}")
    }

    @Test func aRoutineLeadsWithItsResponse() {
        let run = AgentTodayDetail.Scheduled(job: "Morning brief", status: "ok", output: """
            # Cron Job: Morning brief

            ## Prompt

            Write my brief.

            ## Response

            **Good morning.** Sunny.
            """, error: nil)
        #expect(run.response?.answer == "**Good morning.** Sunny.")
        #expect(run.response?.record?.hasPrefix("# Cron Job: Morning brief") == true)
        let plain = AgentTodayDetail.Scheduled(job: nil, status: nil, output: "Just text", error: nil)
        #expect(plain.response?.answer == "Just text")
        #expect(plain.response?.record == nil)
    }

    @Test func anOlderPluginSaysToUpdate() async {
        let model = AgentTodayDetailModel(item: listed, agentID: "nova", client: nil)
        #expect(model.phase == .unsupported)
        let demo = AgentTodayDetailModel(item: listed, agentID: "nova", client: DemoAgentBoardClient())
        await demo.refresh()
        #expect(demo.phase == .loaded(AgentTodayDetail(item: listed, body: .none)))
    }
}
