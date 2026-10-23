import Foundation
import Testing
@testable import Bighelp

/// Taps from notifications, widgets and Shortcuts wait for the full list after the app
/// returns. A remote host answers each request after a pause, so the list asks for its
/// pages and folders a few at a time, and still reads every answer in the host's order.
@MainActor
struct DirectHermesCatalogListConcurrencyTests {
    @MainActor
    private final class SlowHost {
        var inFlight = 0
        var maximum = 0
        var failingOffsets: Set<Int> = []
        var failingFolders: Set<String> = []
        var rows: [String: [BighelpJSONValue]] = [:]
        /// Hermes' `total` can disagree with `has_more`.
        var reportedTotal: [String: Int] = [:]
        var sendsTotal = true
        /// Hermes 0.21.x sends no `has_more` and adds pinned chats to every page.
        var sendsHasMore = true
        var pinnedOnEveryPage: BighelpJSONValue?
        var beforeAnswer: (@MainActor (WorkspaceOperation, [String: BighelpJSONValue]) -> Void)?

        func answer(_ operation: WorkspaceOperation,
                    _ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
            beforeAnswer?(operation, payload)
            inFlight += 1
            maximum = max(maximum, inFlight)
            defer { inFlight -= 1 }
            try await Task.sleep(for: .milliseconds(15))
            let profile = try #require(payload["profile"]?.string)
            if operation == .projectsForCwd {
                let cwd = try #require(payload["cwd"]?.string)
                if failingFolders.contains(cwd) { throw WorkspaceClientError.invalidRequest }
                return ["cwd": .string(cwd), "project": .object(DirectHermesSessionCatalogClientTests.project(
                    id: "p" + cwd.replacingOccurrences(of: "/", with: "_"), name: cwd))]
            }
            let offset = try #require(payload["offset"]?.integer)
            if failingOffsets.contains(offset) { throw WorkspaceClientError.invalidRequest }
            let all = rows[profile] ?? []
            var rows = Array(all.dropFirst(offset).prefix(100))
            if let pinnedOnEveryPage { rows.append(pinnedOnEveryPage) }
            var page: [String: BighelpJSONValue] = [
                "sessions": .array(rows), "offset": .integer(offset), "limit": .integer(100),
            ]
            if sendsTotal { page["total"] = .integer(reportedTotal[profile] ?? all.count) }
            if sendsTotal, sendsHasMore { page["has_more"] = .boolean(offset + 100 < all.count) }
            return page
        }
    }

    private static func profiles(_ names: [String]) -> [String: BighelpJSONValue] {
        ["profiles": .array(names.map {
            .object(["name": .string($0), "display_name": .string($0.capitalized), "canonical_session": .null])
        })]
    }

    private static func folder(_ profile: String, _ index: Int) -> String { "/work/\(profile)/\(index % 3)" }

    private static func rows(_ profile: String, count: Int) -> [BighelpJSONValue] {
        (0..<count).map {
            DirectHermesSessionCatalogClientTests.session(id: "\(profile)-\($0)", profile: profile,
                                                          cwd: folder(profile, $0))
        }
    }

    private static func workspace(_ host: SlowHost, names: [String]) throws -> SessionWorkspaceStub {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Self.profiles(names)
            case .sessionsList, .projectsForCwd: return try await host.answer(operation, payload)
            default: throw WorkspaceClientError.invalidRequest
            }
        }
        return workspace
    }

    @Test func aFullListAsksForItsPagesAndFoldersAFewAtATime() async throws {
        let host = SlowHost()
        let counts = ["alpha": 250, "beta": 40, "gamma": 120, "delta": 5]
        let names = ["alpha", "beta", "gamma", "delta"]
        for name in names { host.rows[name] = Self.rows(name, count: counts[name]!) }
        let workspace = try Self.workspace(host, names: names)

        let records = try await DirectHermesSessionCatalogClientTests.client(workspace).list()

        let expected = names.flatMap { name in (0..<counts[name]!).map { (name, $0) } }
        #expect(records.map(\.remoteStoredID) == expected.map { "\($0.0)-\($0.1)" },
                "The list keeps the host's order, agent by agent and page by page.")
        #expect(records.map(\.workspaceName) == expected.map { Self.folder($0.0, $0.1) })
        #expect(workspace.calls.filter { $0.operation == .sessionsList }.count == 3 + 1 + 2 + 1)
        #expect(workspace.calls.filter { $0.operation == .projectsForCwd }.count == 4 * 3,
                "Each agent's folder is still looked up once.")
        #expect(host.maximum > 1, "Pages and folders must not wait for each other one by one.")
        #expect(host.maximum <= 4, "A host gets at most four of the list's requests at once.")
    }

    @Test func aPageAfterTheEndTheHostReportsIsNeverUsed() async throws {
        let host = SlowHost()
        host.rows["alpha"] = Self.rows("alpha", count: 200)
        // `total` says three pages; `has_more` ends the list after two.
        host.reportedTotal["alpha"] = 300
        host.failingOffsets = [200]
        let workspace = try Self.workspace(host, names: ["alpha"])

        let records = try await DirectHermesSessionCatalogClientTests.client(workspace).list()

        #expect(records.count == 200)
    }

    @Test func aHostWithoutTotalsStillListsEveryPage() async throws {
        let host = SlowHost()
        host.sendsTotal = false
        host.rows["alpha"] = Self.rows("alpha", count: 230)
        host.rows["beta"] = Self.rows("beta", count: 3)
        let workspace = try Self.workspace(host, names: ["alpha", "beta"])

        let records = try await DirectHermesSessionCatalogClientTests.client(workspace).list()

        #expect(records.map(\.remoteStoredID) == (0..<230).map { "alpha-\($0)" } + (0..<3).map { "beta-\($0)" })
    }

    @Test func aPageThatFailsStillFailsTheList() async throws {
        let host = SlowHost()
        host.rows["alpha"] = Self.rows("alpha", count: 250)
        host.rows["beta"] = Self.rows("beta", count: 10)
        host.failingOffsets = [100]
        let workspace = try Self.workspace(host, names: ["alpha", "beta"])

        await #expect(throws: (any Error).self) {
            _ = try await DirectHermesSessionCatalogClientTests.client(workspace).list()
        }
    }

    @Test func aFolderThatFailsForAListedChatStillFailsTheList() async throws {
        let host = SlowHost()
        host.rows["alpha"] = Self.rows("alpha", count: 6)
        host.failingFolders = [Self.folder("alpha", 1)]
        let workspace = try Self.workspace(host, names: ["alpha"])

        await #expect(throws: (any Error).self) {
            _ = try await DirectHermesSessionCatalogClientTests.client(workspace).list()
        }
    }

    @Test func pinnedChatsOnEveryPageOfAnOlderHermesShowOnce() async throws {
        let host = SlowHost()
        host.sendsHasMore = false
        host.pinnedOnEveryPage = DirectHermesSessionCatalogClientTests.session(id: "pinned", pinned: true)
        host.rows["alpha"] = Self.rows("alpha", count: 250)
        let workspace = try Self.workspace(host, names: ["alpha"])

        let records = try await DirectHermesSessionCatalogClientTests.client(workspace).list()

        #expect(records.map(\.remoteStoredID)
                == (0..<100).map { "alpha-\($0)" } + ["pinned"] + (100..<250).map { "alpha-\($0)" })
    }

    @Test func aNewerListStopsTheOlderOne() async throws {
        let host = SlowHost()
        host.rows["alpha"] = Self.rows("alpha", count: 250)
        host.rows["beta"] = Self.rows("beta", count: 20)
        let workspace = try Self.workspace(host, names: ["alpha", "beta"])
        let client = DirectHermesSessionCatalogClientTests.client(workspace)

        let older = Task { try await client.list() }
        try await Task.sleep(for: .milliseconds(20))
        let newer = try await client.list()

        #expect(newer.count == 270)
        await #expect(throws: CancellationError.self) { _ = try await older.value }
    }

    @Test func anotherComputerMidListFailsIt() async throws {
        let host = SlowHost()
        host.rows["alpha"] = Self.rows("alpha", count: 250)
        let workspace = try Self.workspace(host, names: ["alpha"])
        let replacement = WorkspaceOwner(authority: try .fixture(id: "native-session-other"),
                                         authenticationGeneration: UUID(), connectionGeneration: UUID())
        host.beforeAnswer = { operation, payload in
            if operation == .sessionsList, payload["offset"]?.integer == 100 { workspace.owner = replacement }
        }
        let client = DirectHermesSessionCatalogClientTests.client(workspace)

        do {
            _ = try await client.list()
            Issue.record("A list must not finish with another computer's answers.")
        } catch WorkspaceClientError.ownerChanged {
        }
    }

    @Test func aFolderOfAChatTheListLeavesOutNeverFailsIt() async throws {
        let host = SlowHost()
        var archived = DirectHermesSessionCatalogClientTests.session(id: "archived", cwd: "/broken").object!
        archived["archived"] = .boolean(true)
        host.rows["alpha"] = Self.rows("alpha", count: 4) + [.object(archived)]
        host.failingFolders = ["/broken"]
        let workspace = try Self.workspace(host, names: ["alpha"])

        let records = try await DirectHermesSessionCatalogClientTests.client(workspace).list()

        #expect(records.map(\.remoteStoredID) == (0..<4).map { "alpha-\($0)" },
                "Someone archived it, so the list leaves it out, and its folder doesn't matter.")
    }
}

/// The ahead-of-time requests themselves.
@MainActor
struct DirectHermesCatalogPrefetchTests {
    @MainActor
    private final class Log {
        var begun: [Int] = []
        var isCurrent = true
        var inFlight = 0
        var maximum = 0
    }

    private static func key(_ index: Int) -> DirectHermesCatalogPrefetch.Key { .page(profile: "alpha", offset: index) }

    @Test func atMostFourRunAtOnceInTheOrderTheyWereAsked() async throws {
        let log = Log()
        let prefetch = DirectHermesCatalogPrefetch(fetch: { _, payload in
            let index = payload["index"]?.integer ?? -1
            log.begun.append(index)
            log.inFlight += 1
            log.maximum = max(log.maximum, log.inFlight)
            defer { log.inFlight -= 1 }
            try await Task.sleep(for: .milliseconds(10))
            return ["index": .integer(index)]
        }, isCurrent: { true })
        defer { prefetch.finish() }
        for index in 0..<9 { prefetch.start(Self.key(index), .sessionsList, ["index": .integer(index)]) }

        for index in 0..<9 {
            let answer = try await prefetch.value(Self.key(index), .sessionsList, ["index": .integer(index)])
            #expect(answer["index"]?.integer == index)
        }

        #expect(log.begun == Array(0..<9))
        #expect(log.maximum == DirectHermesCatalogPrefetch.width)
    }

    @Test func anAnswerReadOnceIsNotAskedForAgain() async throws {
        let log = Log()
        let prefetch = DirectHermesCatalogPrefetch(fetch: { _, _ in
            log.begun.append(0)
            return [:]
        }, isCurrent: { true })
        defer { prefetch.finish() }

        _ = try await prefetch.value(Self.key(0), .sessionsList, [:])
        prefetch.start(Self.key(0), .sessionsList, [:])
        try await Task.sleep(for: .milliseconds(20))

        #expect(log.begun.count == 1)
    }

    @Test func anAnswerAfterTheListIsDoneStartsNothing() async throws {
        let log = Log()
        let prefetch = DirectHermesCatalogPrefetch(fetch: { _, payload in
            let index = payload["index"]?.integer ?? -1
            log.begun.append(index)
            // A host that answers even after the request was cancelled.
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
            return [:]
        }, isCurrent: { true })
        prefetch.start(Self.key(0), .sessionsList, ["index": .integer(0)]) { [weak prefetch] _ in
            prefetch?.start(Self.key(1), .sessionsList, ["index": .integer(1)])
        }
        try await Task.sleep(for: .milliseconds(10))

        prefetch.finish()
        try await Task.sleep(for: .milliseconds(150))

        #expect(log.begun == [0])
    }

    @Test func nothingRunsForAListThatIsNoLongerCurrent() async throws {
        let log = Log()
        let prefetch = DirectHermesCatalogPrefetch(fetch: { _, _ in
            log.begun.append(0)
            return [:]
        }, isCurrent: { log.isCurrent })
        defer { prefetch.finish() }
        log.isCurrent = false

        await #expect(throws: CancellationError.self) {
            _ = try await prefetch.value(Self.key(0), .sessionsList, [:])
        }
        #expect(log.begun.isEmpty)
    }
}
