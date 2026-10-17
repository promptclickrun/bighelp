import Foundation

extension ConversationFixtures {
    /// `-test-agent-talk`: agents messaging each other. A finished turn where
    /// Avery asks Mina (travel) and Jordan (home) with `hermes -p … chat`, its
    /// other work folded away; a message Jordan sends in; and a turn still
    /// running, where Mina is looking for a hotel. Made-up plans and prices.
    static var agentTalkPreview: SessionRecord {
        let sessionID = "demo-finance"
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let start = Date().addingTimeInterval(-900)
        func human(_ id: String, _ text: String, _ order: Int, at seconds: TimeInterval) -> TimelineItem {
            TimelineItem(id: id, role: .human, sender: .user(snapshot: .init(name: "You")), content: .message(text),
                         metadata: .init(delivery: "Saved", timestamp: start.addingTimeInterval(seconds),
                                         sourceOrder: order))
        }
        func reply(_ id: String, _ text: String, _ order: Int, at seconds: TimeInterval) -> TimelineItem {
            TimelineItem(id: id, role: .assistant, sender: agent, content: .message(text),
                         metadata: .init(delivery: "Saved", timestamp: start.addingTimeInterval(seconds),
                                         sourceOrder: order))
        }
        func json(_ value: Any) -> String {
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        func tool(_ id: String, _ turn: String, _ arguments: [String: Any], _ order: Int, output: String? = nil,
                  name: String = "terminal", ms: Int? = nil) -> ChatActivityEvent {
            ChatActivityEvent(eventID: id, sessionID: sessionID, turnID: turn, kind: .tool,
                              lifecycle: output == nil ? .running : .succeeded, title: name, summary: nil,
                              detail: nil, occurredAt: order, durationMilliseconds: ms, toolCallID: "call-\(id)",
                              toolName: name, arguments: json(arguments),
                              result: output.map { json(["output": $0, "exit_code": 0, "error": NSNull()]) },
                              sourceOrder: order)
        }
        let items = [
            human("talk-q1", "Can we afford a long weekend in Lisbon in March?", 10, at: 0),
            reply("talk-a1", "Yes. The trip and Biscuit's sitter come to about **$3,340**, and the travel fund "
                  + "has **$4,100**, so you'd keep about $760.", 50, at: 96),
            human("talk-in", "Message from 🤖 Jordan Lee (@home): The furnace check is booked for Friday at 9 AM. "
                  + "Can you add $180 to this month's home budget?", 60, at: 400),
            reply("talk-a2", "Done. I added $180 for Friday's furnace check to October's home budget.", 70, at: 412),
            human("talk-q2", "Ask Mina if there's a cheaper hotel.", 80, at: 600),
        ]
        let activity = [
            tool("talk-t1", "talk-turn-1", ["path": "budget/2026.csv"], 20, output: "", name: "read_file", ms: 300),
            tool("talk-t2", "talk-turn-1", ["command": "hermes -p travel chat -Q --oneshot -q " + Self.shellQuoted(
                Self.agentTalkTripQuestion)], 30,
                 output: "Message from 🤖 Mina Shah (@travel):\n\nAbout $3,100 for two: flights from Boston $1,380, "
                    + "a hotel in Alfama $1,120 for 4 nights, and $600 for food and trains.\n\n"
                    + "session_id: \(Self.agentTalkTripSession)", ms: 38_000),
            tool("talk-t3", "talk-turn-1", ["command": "hermes -p home chat -Q --oneshot -q " + Self.shellQuoted(
                "Message from Avery Park (@finance): Can someone look after Biscuit from March 12 to 16?")], 40,
                 output: "Yes. Sam from the neighbor list can do March 12 to 16 for $240.\n\n"
                    + "session_id: 20261012_101620_d4e5f6", ms: 21_000),
            tool("talk-t4", "talk-turn-1", ["command": "python3 budget.py --add 3340 --fund travel"], 45,
                 output: "travel fund: 4100.00\nafter trip: 760.00", ms: 900),
            tool("talk-t5", "talk-turn-3", ["command": "hermes -p travel chat -Q --oneshot -q " + Self.shellQuoted(
                Self.agentTalkHotelQuestion)], 90),
        ]
        return SessionRecord(id: sessionID, kind: .direct, agentIDs: ["finance"], title: "Lisbon in March",
                             items: items, activityEvents: activity,
                             activityVisibility: .init(showReasoning: false, showToolCalls: true),
                             isActive: true, hasAcceptedMessage: true)
    }

    static let agentTalkTripQuestion = "Message from Avery Park (@finance): What would 4 nights in Lisbon in "
        + "mid-March cost for two, flights from Boston included?"
    static let agentTalkHotelQuestion = "Message from Avery Park (@finance): Is there a hotel under $200 a night "
        + "near Alfama for March 12 to 16?"
    static let agentTalkTripSession = "20261012_101500_a1b2c3"

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Demo mode's stand-in for the plugin's agent-talk feed: Mina is searching
/// the web for the running hotel question, and her trip estimate shows what
/// she did.
@MainActor
final class DemoAgentTalkReader: AgentTalkReading {
    func runs(agentID: String, sessionID: String, calls: [AgentTalkRunQuery]) async -> [AgentTalkRun]? {
        [
            AgentTalkRun(agentID: "travel", sessionID: ConversationFixtures.agentTalkTripSession,
                         messageHash: AgentTalkMessageHash.hash(ConversationFixtures.agentTalkTripQuestion),
                         startedAt: Date().addingTimeInterval(-800), isWorking: false, toolName: nil),
            AgentTalkRun(agentID: "travel", sessionID: "20261012_103000_c7d8e9",
                         messageHash: AgentTalkMessageHash.hash(ConversationFixtures.agentTalkHotelQuestion),
                         startedAt: Date().addingTimeInterval(-20), isWorking: true, toolName: "web_search"),
        ]
    }

    func steps(agentID: String, sessionID: String) async -> [String]? {
        guard sessionID == ConversationFixtures.agentTalkTripSession else { return [] }
        return ["Searched the web", "Read flights.example.com", "Ran a command"]
    }
}
