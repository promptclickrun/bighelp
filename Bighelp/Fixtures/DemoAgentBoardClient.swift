import Foundation

/// Demo-mode board: realistic Feed, Ideas, Goals, Activity and Approvals so the
/// app can be explored (and screenshotted) without a host.
@MainActor
final class DemoAgentBoardClient: AgentBoardClient {
    private var itemsByAgent: [String: [AgentBoardItem]] = [:]
    private let now: Date
    let supportsFeedback = true

    init(now: Date = .now) {
        self.now = now
    }

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    func items(agentID: String) async throws -> [AgentBoardItem] {
        if let items = itemsByAgent[agentID] { return items }
        let items = seed()
        itemsByAgent[agentID] = items
        return items
    }

    func update(agentID: String, itemID: String, change: AgentBoardChange) async throws -> AgentBoardItem {
        var items = try await self.items(agentID: agentID)
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw WorkspaceClientError.invalidRequest }
        if let rating = change.rating {
            items[index].rating = rating
            items[index].reason = rating == .down ? (change.reason ?? "") : ""
        }
        if let read = change.read { items[index].read = read }
        if let dismissed = change.dismissed { items[index].dismissed = dismissed }
        if let status = change.status { items[index].status = status }
        itemsByAgent[agentID] = items
        return items[index]
    }

    func markRead(agentID: String, itemIDs: [String]) async throws {
        var items = try await self.items(agentID: agentID)
        for index in items.indices where itemIDs.contains(items[index].id) { items[index].read = true }
        itemsByAgent[agentID] = items
    }

    func promote(agentID: String, itemID: String) async throws -> AgentBoardItem {
        var items = try await self.items(agentID: agentID)
        guard let index = items.firstIndex(where: { $0.id == itemID && $0.kind == .idea }) else {
            throw WorkspaceClientError.invalidRequest
        }
        items[index].dismissed = true
        let idea = items[index]
        let goal = AgentBoardItem(id: "goal-from-\(idea.id)", kind: .goal, title: idea.title, body: idea.body,
                                  icon: idea.icon, section: "goal", status: "active", source: "From an idea",
                                  read: false, createdAt: .now)
        items.insert(goal, at: 0)
        itemsByAgent[agentID] = items
        return goal
    }

    func picture(agentID: String, itemID: String, index: Int) async throws -> Data {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }

    func activity(agentID: String) async throws -> [AgentActivityEntry] {
        let rows: [(String, String, AgentActivityKind, Double)] = [
            ("Record grocery delivery", "Logged Saturday's grocery order to memory.", .memory, 18),
            ("Save porch photo", "Copied porch-left.jpg to the workspace.", .files, 21),
            ("Check the porch for the bag", "Looked at the porch camera; the bag is by the chair.", .seeing, 22),
            ("Find a quiet dinner spot", "Compared three Gion restaurants and booked one.", .web, 95),
            ("Draft the trip itinerary", "Wrote a three-day Kyoto plan to kyoto.md.", .files, 180),
            ("Update the budget sheet", "Ran the monthly totals script.", .coding, 60 * 26),
            ("Make a birthday card", "Generated two card designs.", .images, 60 * 27),
        ]
        return rows.enumerated().map { index, row in
            AgentActivityEntry(id: index + 1, sessionID: "demo-\(index)", title: row.0, request: row.0,
                               summary: row.1, kind: row.2, outcome: "done", createdAt: ago(row.3))
        }
    }

    func approvals(agentID: String) async throws -> [AgentApprovalEntry] {
        [
            AgentApprovalEntry(id: 3, sessionTitle: "Check front porch camera",
                               description: "Secure connection to the camera service",
                               command: "curl https://camera.example.com/latest.jpg", choice: "always",
                               createdAt: ago(60 * 6)),
            AgentApprovalEntry(id: 2, sessionTitle: "Take a screenshot",
                               description: "Capture your current screen", command: "screencapture -x",
                               choice: "session", createdAt: ago(60 * 26)),
            AgentApprovalEntry(id: 1, sessionTitle: "Clean up downloads",
                               description: "Delete files in a folder", command: "rm -rf ~/Downloads/old",
                               choice: "deny", createdAt: ago(60 * 50)),
        ]
    }

    func identity(agentID: String) async throws -> AgentIdentityDocuments {
        AgentIdentityDocuments(
            soul: .init(text: """
                # Who I am
                Warm, organized and a little witty. I keep things short, check before spending                 money, and always say what I did.
                """, updatedAt: ago(60 * 24 * 5)),
            memory: .init(text: """
                - Groceries arrive Saturdays; the bag goes by the porch chair.
                - Prefers window seats and quiet restaurants.
                - Sam's birthday is October 7.
                """, updatedAt: ago(60 * 3)),
            user: .init(text: "Lives in Austin. Morning person. Coffee, no sugar.", updatedAt: ago(60 * 24 * 12)))
    }

    private func seed() -> [AgentBoardItem] {
        [
            AgentBoardItem(id: "feed-1", kind: .feed, title: "Lisbon fares dropped 18% for October",
                           body: "Round trips for **October 9–16** are down to $412, the lowest in six weeks. "
                               + "Want me to hold two seats before they climb again?",
                           icon: "✈️", source: "Flight watch", read: false, createdAt: ago(35)),
            AgentBoardItem(id: "feed-2", kind: .feed, title: "Three stories worth your time tonight",
                           body: """
                               ### Tonight's picks
                               - A new battery chemistry **doubles** e-bike range
                               - The city approved the waterfront park
                               - Your favorite bakery opens a second shop on Saturday

                               > Worth a look before the weekend.
                               """,
                           icon: "📰", links: [.init(url: URL(string: "https://example.com/news")!, title: "Read more")],
                           source: "Evening news", createdAt: ago(60 * 4)),
            AgentBoardItem(id: "feed-3", kind: .feed, title: "Your week at a glance",
                           body: "Two dinners, one dentist visit Thursday at 9:30, and the plants need water "
                               + "Tuesday and Friday.", icon: "🗓️", source: "Monday brief", createdAt: ago(60 * 26)),
            AgentBoardItem(id: "idea-1", kind: .idea, title: "I can plan Sam's birthday dinner end to end",
                           body: """
                               Her birthday is in **12 days**. I can:
                               1. Shortlist three restaurants she'd like
                               2. Check who's free on the family calendar
                               3. Book the table
                               """,
                           icon: "🎂", section: "Family", read: false, createdAt: ago(60 * 2)),
            AgentBoardItem(id: "idea-2", kind: .idea, title: "I can make your sleep goal trackable again",
                           body: "Sleep data stopped arriving on September 11. I can find why, fix it if it's on "
                               + "my side, and send a short nightly check-in as a fallback.",
                           icon: "🌙", section: "Health", createdAt: ago(60 * 5)),
            AgentBoardItem(id: "idea-3", kind: .idea, title: "I can find a cheaper phone plan",
                           body: "You used under 4 GB a month this year. Two plans would save about $22 a month "
                               + "with the same coverage.", icon: "📱", section: "Money", createdAt: ago(60 * 30)),
            AgentBoardItem(id: "goal-1", kind: .goal, title: "Grocery delivery", icon: "🛒", section: "tracking",
                           status: "active", note: "Out for delivery; arriving between 5 and 6 pm.", createdAt: ago(40)),
            AgentBoardItem(id: "goal-2", kind: .goal, title: "Lawn care visit", icon: "🌿", section: "tracking",
                           status: "active", note: "Saturday 9–10 am on the family calendar; crew time not confirmed.",
                           createdAt: ago(60 * 20)),
            AgentBoardItem(id: "goal-3", kind: .goal, title: "8 hours of sleep on weeknights", icon: "😴",
                           section: "goal", status: "active", note: "Monday's nudge went out; next one Sunday at 10:30.",
                           createdAt: ago(60 * 70)),
            AgentBoardItem(id: "goal-4", kind: .goal, title: "Save $2,000 for the Lisbon trip", icon: "💶",
                           section: "goal", status: "active", note: "$1,340 saved; on pace for mid-October.",
                           createdAt: ago(60 * 90)),
        ]
    }
}
