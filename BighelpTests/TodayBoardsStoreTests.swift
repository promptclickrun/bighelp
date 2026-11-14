import Foundation
import Testing
@testable import Bighelp

/// Today's Feed, Ideas and Goals across bots: which bots are read, how often, and what stays.
@MainActor
struct TodayBoardsStoreTests {
    /// A board client like the plugin's: one bot's board per call, or an error for that bot.
    @MainActor
    private final class Client: AgentBoardClient {
        var boards: [String: [AgentBoardItem]]
        var failing: Set<String> = []
        private(set) var reads: [String] = []
        /// Runs while a bot's read is on its way back, for what happens in the meantime.
        var duringRead: ((String) -> Void)?
        let supportsFeedback = true

        init(_ boards: [String: [AgentBoardItem]] = [:]) { self.boards = boards }

        func items(agentID: String) async throws -> [AgentBoardItem] {
            reads.append(agentID)
            if failing.contains(agentID) { throw WorkspaceClientError.invalidRequest }
            let answer = boards[agentID] ?? []
            duringRead?(agentID)
            return answer
        }

        func update(agentID: String, itemID: String, change: AgentBoardChange) async throws -> AgentBoardItem {
            throw WorkspaceClientError.invalidRequest
        }
        func markRead(agentID: String, itemIDs: [String]) async throws {}
        func promote(agentID: String, itemID: String) async throws -> AgentBoardItem { throw WorkspaceClientError.invalidRequest }
        func picture(agentID: String, itemID: String, index: Int) async throws -> Data { Data() }
        func activity(agentID: String) async throws -> [AgentActivityEntry] { [] }
        func approvals(agentID: String) async throws -> [AgentApprovalEntry] { [] }
        func identity(agentID: String) async throws -> AgentIdentityDocuments {
            AgentIdentityDocuments(soul: .init(), memory: .init(), user: .init())
        }
    }

    /// A clock the test moves.
    @MainActor
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func post(_ id: String, minutesAgo: Double, clock: Clock, kind: AgentBoardItem.Kind = .feed) -> AgentBoardItem {
        AgentBoardItem(id: id, kind: kind, title: id, read: false, createdAt: clock.now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func shownBotsAreReadFirstAndAtMostTwentyFour() {
        let ids = (1...30).map { "bot\($0)" }
        let order = TodayBoardsStore.readOrder(botIDs: ids + ["bot2"], hiddenIDs: ["bot1", "bot3"])
        #expect(order.count == TodayBoardsStore.maximumBots)
        #expect(Array(order.prefix(3)) == ["bot2", "bot4", "bot5"])
        #expect(!order.contains("bot1"))
        #expect(Set(order).count == order.count)
        #expect(TodayBoardsStore.readOrder(botIDs: ["a", "b", "c"], hiddenIDs: ["a"]) == ["b", "c", "a"])
    }

    @Test func itReadsOneBotAfterAnotherAndMergesNewestFirst() async {
        let clock = Clock()
        let client = Client(["mina": [post("m1", minutesAgo: 30, clock: clock)],
                             "avery": [post("a1", minutesAgo: 5, clock: clock),
                                       post("a2", minutesAgo: 1, clock: clock, kind: .idea)]])
        let store = TodayBoardsStore(now: { clock.now })
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina", "avery"], hiddenIDs: ["mina"])
        #expect(client.reads == ["avery", "mina"])
        #expect(store.hasRead)
        #expect(store.tracksUnread)
        #expect(store.entries(.feed).map(\.id) == ["avery/a1", "mina/m1"])
        #expect(store.entries(.idea).map(\.id) == ["avery/a2"])
        #expect(store.entries(.feed, agentIDs: ["mina"]).map(\.id) == ["mina/m1"])
    }

    @Test func itReadsAtMostOnceAMinuteUnlessForced() async {
        let clock = Clock()
        let client = Client(["mina": []])
        let store = TodayBoardsStore(now: { clock.now })
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina"])
        clock.now += 30
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina"])
        #expect(client.reads.count == 1)
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina"], force: true)
        #expect(client.reads.count == 2)
        clock.now += 61
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina"])
        #expect(client.reads.count == 3)
    }

    @Test func aFailedReadKeepsWhatItHadAndDoesNotHoldOffTheNext() async {
        let clock = Clock()
        let client = Client(["mina": [post("m1", minutesAgo: 1, clock: clock)], "avery": []])
        let store = TodayBoardsStore(now: { clock.now })
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina", "avery"])
        client.failing = ["mina"]
        client.boards["avery"] = [post("a1", minutesAgo: 0, clock: clock)]
        clock.now += 61
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina", "avery"])
        #expect(store.entries(.feed).map(\.id) == ["avery/a1", "mina/m1"])
        // Only a read where every bot answered counts toward the minute.
        let before = client.reads.count
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina", "avery"])
        #expect(client.reads.count == before + 2)
    }

    @Test func eachComputerKeepsItsOwnBoards() async {
        let clock = Clock()
        let first = Client(["mina": [post("m1", minutesAgo: 1, clock: clock)]])
        let second = Client(["river": [post("r1", minutesAgo: 1, clock: clock)]])
        let store = TodayBoardsStore(now: { clock.now })
        await store.refresh(client: first, scope: "computer-1", botIDs: ["mina"])
        await store.refresh(client: second, scope: "computer-2", botIDs: ["river"])
        #expect(store.scope == "computer-2")
        #expect(store.entries(.feed).map(\.id) == ["river/r1"])
        // Back on the first computer within the minute: its last read shows, and it isn't read again.
        await store.refresh(client: first, scope: "computer-1", botIDs: ["mina"])
        #expect(store.entries(.feed).map(\.id) == ["mina/m1"])
        #expect(first.reads == ["mina"])
        // A new connection to the same computer is the same scope: the minute still holds.
        let reconnected = Client(["mina": []])
        await store.refresh(client: reconnected, scope: "computer-1", botIDs: ["mina"])
        #expect(reconnected.reads.isEmpty)
    }

    @Test func aReadWhereEveryBotFailedIsNotARead() async {
        let clock = Clock()
        let client = Client(["mina": [post("m1", minutesAgo: 1, clock: clock)], "avery": []])
        client.failing = ["mina", "avery"]
        let store = TodayBoardsStore(now: { clock.now })
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina", "avery"])
        // Today keeps its offline state instead of "Nothing yet".
        #expect(!store.hasRead)
        // Away and back to the same computer: still nothing was read.
        await store.refresh(client: client, scope: "computer-2", botIDs: ["mina"])
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina", "avery"])
        #expect(!store.hasRead)
        // The next read that works counts, and a later failure keeps it.
        client.failing = []
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina", "avery"], force: true)
        #expect(store.hasRead)
        client.failing = ["mina", "avery"]
        await store.refresh(client: client, scope: "computer-1", botIDs: ["mina", "avery"], force: true)
        #expect(store.hasRead)
        #expect(store.entries(.feed).map(\.id) == ["mina/m1"])
    }

    @Test func aPostClearedOnTheBotsOwnPageIsGoneFromTodayWithoutARead() async {
        let clock = Clock()
        let store = TodayBoardsStore(now: { clock.now })
        let first = post("m1", minutesAgo: 30, clock: clock), second = post("m2", minutesAgo: 5, clock: clock)
        let client = Client(["mina": [first, second]])
        await store.refresh(client: client, scope: "mac", botIDs: ["mina"])
        #expect(store.entries(.feed).map(\.item.id) == ["m2", "m1"])

        // The bot's own Feed page cleared the post and hands over what it shows now.
        var cleared = first
        cleared.dismissed = true
        store.take([cleared, second], agentID: "mina", scope: "mac")
        #expect(store.entries(.feed).map(\.item.id) == ["m2"], "Gone at once")
        #expect(client.reads == ["mina"], "No read was needed")

        // Coming back to Today within the minute reads nothing and keeps it gone.
        await store.refresh(client: client, scope: "mac", botIDs: ["mina"])
        #expect(store.entries(.feed).map(\.item.id) == ["m2"])
        #expect(client.reads == ["mina"])
    }

    @Test func aReadOnItsWayBackKeepsWhatTheBotsOwnPageChanged() async {
        let clock = Clock()
        let store = TodayBoardsStore(now: { clock.now })
        let first = post("m1", minutesAgo: 30, clock: clock), second = post("m2", minutesAgo: 5, clock: clock)
        let client = Client(["mina": [first, second], "avery": [post("a1", minutesAgo: 1, clock: clock)]])
        var cleared = first
        cleared.dismissed = true
        // The answer for mina left the computer before the clear; the page hands its copy over first.
        client.duringRead = { id in
            if id == "mina" { store.take([cleared, second], agentID: "mina", scope: "mac") }
        }
        await store.refresh(client: client, scope: "mac", botIDs: ["mina", "avery"])
        #expect(store.entries(.feed).map(\.item.id) == ["a1", "m2"], "The older answer doesn't bring the post back")
    }

    @Test func anotherComputersBoardIsTakenWithoutShowingHere() async {
        let clock = Clock()
        let store = TodayBoardsStore(now: { clock.now })
        let client = Client(["mina": [post("m1", minutesAgo: 30, clock: clock)]])
        await store.refresh(client: client, scope: "mac", botIDs: ["mina"])
        store.take([post("other", minutesAgo: 1, clock: clock)], agentID: "mina", scope: "studio")
        #expect(store.entries(.feed).map(\.item.id) == ["m1"])
    }

    @Test func answeredAndDismissedItemsStayOffToday() {
        let clock = Clock()
        var done = post("i1", minutesAgo: 1, clock: clock, kind: .idea)
        done.answer = "yes"
        var gone = post("i2", minutesAgo: 2, clock: clock, kind: .idea)
        gone.dismissed = true
        let open = post("i3", minutesAgo: 3, clock: clock, kind: .idea)
        let entries = TodayBoardsStore.entries(.idea, boards: ["mina": [done, gone, open]])
        #expect(entries.map(\.id) == ["mina/i3"])
    }
}
