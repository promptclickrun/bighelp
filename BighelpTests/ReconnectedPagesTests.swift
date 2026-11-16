import Foundation
import Testing
@testable import Bighelp

/// Kanban, Workflows and Usage are pushed pages, and the shell's root setup waits while a page covers
/// the root. A Today board kept the connection it was set up with, so after a reconnect the computer
/// refused each change (#987). These pages stay right (#1042): their clients take the connection in
/// use at each request, so a change made after a reconnect goes to the new connection with no setup
/// run in between. Each test here makes its client once, as the shell does, and never sets it up again.
@MainActor
struct ReconnectedPagesTests {
    /// A connection that records what it was asked and for which owner, and answers nothing.
    private final class Connection: WorkspaceOperationPerforming {
        var owner: WorkspaceOwner?
        var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
        private(set) var log: [(operation: WorkspaceOperation, owner: WorkspaceOwner)] = []

        init(authority: WorkspaceAuthority, signIn: UUID) {
            owner = WorkspaceOwner(authority: authority, authenticationGeneration: signIn, connectionGeneration: UUID())
        }

        func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                     owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
            log.append((operation, owner))
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    private let signIn = UUID()

    private func connections() throws -> (before: Connection, after: Connection) {
        let authority = try WorkspaceAuthority.fixture(id: "home")
        return (Connection(authority: authority, signIn: signIn), Connection(authority: authority, signIn: signIn))
    }

    @Test func aKanbanChangeAfterAReconnectAsksForTheNewConnectionsClient() async throws {
        let (before, after) = try connections()
        let host = try #require(before.owner?.authority)
        var owner = before.owner
        var asked: [WorkspaceOwner] = []
        let service = LiveKanbanService(host: host, currentOwner: { owner }, makeClient: { asked.append($0); return nil })

        _ = try? await service.boards()
        #expect(asked == [before.owner].compactMap { $0 })

        // The connection is closed: nothing is asked of the old one.
        owner = nil
        await #expect(throws: HermesKanbanError.self) { _ = try await service.move("t1", to: .done, board: "home") }
        #expect(asked.count == 1)

        // Back on a new connection to the same computer: the move asks for that connection's client.
        owner = after.owner
        _ = try? await service.move("t1", to: .done, board: "home")
        #expect(asked.last == after.owner)
        #expect(asked.count == 2)

        // Another computer is never served by this computer's board.
        owner = WorkspaceOwner(authority: try .fixture(id: "studio"), authenticationGeneration: UUID(), connectionGeneration: UUID())
        await #expect(throws: HermesKanbanError.self) { _ = try await service.boards() }
        #expect(asked.count == 2)
    }

    @Test func aWorkflowChangeAfterAReconnectGoesToTheNewConnection() async throws {
        let (before, after) = try connections()
        var current: Connection? = before
        let client = DirectHermesWorkflowsClient(currentWorkspace: { current }, reconnectWait: .milliseconds(10),
                                                 reconnectAttempts: 200)
        _ = try? await client.status()
        #expect(before.log.map(\.operation) == [.workflowsStatus])

        // The change is made while the connection is on its way back: it waits for it.
        current = nil
        let change = Task { @MainActor in try? await client.archive(workflowID: "wf") }
        try await Task.sleep(for: .milliseconds(60))
        #expect(before.log.count == 1 && after.log.isEmpty)
        current = after
        await change.value

        #expect(before.log.count == 1, "Nothing more is asked of the closed connection")
        #expect(after.log.map(\.operation) == [.workflowsArchive])
        #expect(after.log.first?.owner == after.owner)
    }

    @Test func usageReadAfterAReconnectGoesToTheNewConnection() async throws {
        let (before, after) = try connections()
        var current: Connection? = before
        let reader = LiveUsageReader(hostID: "home", hostName: "Home", currentWorkspace: { current },
                                     agents: { [("ada", "Ada")] }, fleet: nil)
        _ = await reader.read(days: 30, refresh: false)
        let asked = before.log.count
        #expect(asked > 0)

        current = after
        _ = await reader.read(days: 30, refresh: true)
        #expect(before.log.count == asked, "Nothing more is asked of the closed connection")
        #expect(!after.log.isEmpty)
        #expect(after.log.allSatisfy { $0.owner == after.owner })
    }

    @Test func aPlansRefreshAfterAReconnectGoesToTheNewConnection() async throws {
        let (before, after) = try connections()
        var current: Connection? = before
        let client = DirectHermesProviderUsageClient(currentWorkspace: { current }, reconnectWait: .milliseconds(10),
                                                     reconnectAttempts: 5)
        _ = try? await client.usage(agentID: "default", refresh: false)
        let asked = before.log.count
        #expect(asked > 0)

        current = after
        _ = try? await client.usage(agentID: "default", refresh: true)
        #expect(before.log.count == asked, "Nothing more is asked of the closed connection")
        #expect(!after.log.isEmpty)
        #expect(after.log.allSatisfy { $0.owner == after.owner })
        // The sign-in is the same, so the Usage page keeps what it shows through the reconnect.
        #expect(client.currentScope == after.owner.map { AnyHashable($0.signIn) })
    }

    /// Usage is the page that did fail (#1042): opened by its link with Bighelp closed, it is on screen
    /// before the sign-in is known, and the root's tasks wait under it, so both stores stayed without a
    /// computer to read. The fault is in when SwiftUI runs a task, which no unit test can make happen, so
    /// this checks the source, as the sheet rule does: the page itself sets both stores up.
    @Test func theUsagePageSetsUpBothOfItsStores() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repository.appending(path: "Bighelp/App/RootUsage.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "var usageDestination: some View {"))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let page = source[start.upperBound..<end.lowerBound]
        #expect(page.contains(".task(id: usageReaderKey)"), "What the bots used")
        #expect(page.contains(".task(id: providerUsageKey)"), "Plans and limits")
        #expect(source.contains("configureUsage(key)") && source.contains("configureProviderUsage(key)"))
    }
}
