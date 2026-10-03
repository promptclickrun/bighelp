import Foundation
import Testing
@testable import Bighelp

/// The Usage page's store: one read per range, kept while it's fresh, the last
/// result kept when a refresh fails, and Tokens first when nothing cost money.
@MainActor
struct UsageStoreTests {
    private static func host(cost: Double, tokens: Int = 1_000, failure: String? = nil) throws -> HostUsage {
        let usage: [String: BighelpJSONValue] = [
            "daily": .array([.object([
                "day": .string("2026-10-03"), "input_tokens": .integer(tokens), "output_tokens": .integer(0),
                "estimated_cost": .number(cost), "sessions": .integer(1),
            ])]),
        ]
        let report = try HermesUsageReport(usage: usage, models: nil, activity: nil)
        return HostUsage(id: "home", name: "Home Hermes",
                         agents: failure == nil ? [AgentUsage(id: "default", name: "Ada", report: report)] : [],
                         failure: failure)
    }

    @Test func readsEachRangeOnceWhileItsFresh() async throws {
        var now = Date(timeIntervalSince1970: 1_791_028_800)
        let reader = ScriptedUsageReader()
        reader.result = [try Self.host(cost: 2)]
        let store = UsageStore(now: { now })
        store.configure(reader: reader, scope: "home")
        #expect(store.isAvailable)

        await store.load(refresh: false)
        #expect(store.state == .loaded && store.summary?.totals.cost == 2)
        #expect(reader.reads == [30], "Thirty days to start")

        await store.select(.week)
        #expect(reader.reads == [30, 7])
        await store.select(.month)
        #expect(reader.reads == [30, 7], "A range read a moment ago shows again without asking")
        #expect(store.summary?.totals.cost == 2)

        now = now.addingTimeInterval(6 * 60)
        await store.select(.week)
        #expect(reader.reads == [30, 7, 7], "Older than five minutes: read again")
        await store.load(refresh: true)
        #expect(reader.reads == [30, 7, 7, 7], "Refresh always reads")
    }

    @Test func aFailedRefreshKeepsWhatWasOnScreen() async throws {
        let reader = ScriptedUsageReader()
        reader.result = [try Self.host(cost: 2)]
        let store = UsageStore()
        store.configure(reader: reader, scope: "home")
        await store.load(refresh: false)

        reader.result = [try Self.host(cost: 0, failure: "Couldn't reach this host.")]
        await store.load(refresh: true)
        #expect(store.summary?.totals.cost == 2, "The last result stays")
        #expect(store.state == .unavailable("Couldn't refresh. Showing the last result."))
        #expect(!store.isRefreshing)
    }

    @Test func aComputerThatCantBeReadSaysWhyWhenNothingElseShows() async throws {
        let reader = ScriptedUsageReader()
        reader.result = [try Self.host(cost: 0, failure: "Couldn't reach this host.")]
        let store = UsageStore()
        store.configure(reader: reader, scope: "home")
        await store.load(refresh: false)
        #expect(store.state == .unavailable("Couldn't reach this host."))
        #expect(store.summary == nil)
    }

    @Test func tokensComeFirstWhenNothingCostMoney() async throws {
        let reader = ScriptedUsageReader()
        reader.result = [try Self.host(cost: 0)]
        let store = UsageStore()
        store.configure(reader: reader, scope: "home")
        await store.load(refresh: false)
        #expect(store.metric == .tokens, "Subscriptions report no cost; Tokens has something to show")

        let picked = UsageStore()
        picked.configure(reader: reader, scope: "home")
        picked.choose(.cost)
        await picked.load(refresh: false)
        #expect(picked.metric == .cost, "A choice the person made stays")
    }

    @Test func anotherComputerStartsOver() async throws {
        let reader = ScriptedUsageReader()
        reader.result = [try Self.host(cost: 2)]
        let store = UsageStore()
        store.configure(reader: reader, scope: "home")
        await store.load(refresh: false)
        store.focus = "agent:home/default"

        store.configure(reader: reader, scope: "home")
        #expect(store.summary != nil && store.focus != nil, "The same computer keeps what's on screen")
        store.configure(reader: reader, scope: "studio")
        #expect(store.summary == nil && store.focus == nil && store.state == .idle)
        store.configure(reader: nil, scope: nil)
        #expect(!store.isAvailable)
    }
}

@MainActor
private final class ScriptedUsageReader: UsageReading {
    var result: [HostUsage] = []
    var reads: [Int] = []

    func read(days: Int, refresh: Bool) async -> [HostUsage] {
        reads.append(days)
        return result
    }
}
