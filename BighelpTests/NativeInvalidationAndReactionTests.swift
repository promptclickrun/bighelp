import Foundation
import Testing
@testable import Bighelp

@MainActor
struct NativeInvalidationAndReactionTests {
    @Test func emptyCanonicalSessionsKeepTheirVerifiedOwnerUntilPublished() {
        var record = SessionRecord(id: "chat", kind: .direct, agentIDs: ["default"], title: "Bot Chat")
        #expect(NativeWorkspaceSessionBridge.preservesUnpublishedCanonical(record, wasCreated: false, durability: .persisted))
        record.hasAcceptedMessage = true
        #expect(!NativeWorkspaceSessionBridge.preservesUnpublishedCanonical(record, wasCreated: false, durability: .persisted))
        #expect(NativeWorkspaceSessionBridge.preservesUnpublishedCanonical(record, wasCreated: true, durability: .persisted))
        #expect(NativeWorkspaceSessionBridge.preservesUnpublishedCanonical(record, wasCreated: false, durability: .draft))
    }

    @Test func sessionInvalidationsCoalesceAndRetainOneTrailingRefresh() async throws {
        let source = try makeSource()
        var refreshes = 0
        var release: CheckedContinuation<Void, Never>?
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source }, refreshSessions: { _ in
            refreshes += 1
            if refreshes == 1 { await withCheckedContinuation { release = $0 } }
        }, refreshScheduledTasks: { _ in Issue.record("Sessions event refreshed cron") }, publish: { _, _ in })
        defer { coordinator.suspend() }
        let event = try decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"sessions.changed","session_id":"","payload":{}}}"#)
        #expect(coordinator.receive(event, source: source))
        #expect(coordinator.receive(event, source: source))
        for _ in 0..<100 where release == nil { await Task.yield() }
        guard let held = release else { Issue.record("Initial refresh did not start"); return }
        #expect(refreshes == 1)
        #expect(coordinator.receive(event, source: source))
        held.resume()
        for _ in 0..<100 where refreshes < 2 { await Task.yield() }
        #expect(refreshes == 2)
    }

    @Test func resumeProgressIsExactSessionTransientStateNotCatalogWork() throws {
        let source = try makeSource()
        var notices: [NativeWorkspaceInvalidationNotice] = []
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source },
            refreshSessions: { _ in Issue.record("Resume progress refreshed sessions") },
            refreshScheduledTasks: { _ in Issue.record("Resume progress refreshed cron") },
            publish: { _, notice in notices.append(notice) })
        defer { coordinator.suspend() }
        let loading = try decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"session.resume_progress","session_id":"runtime-A","payload":{"phase":"history","status":"loading"}}}"#)
        let done = try decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"session.resume_progress","session_id":"runtime-A","payload":{"phase":"history","status":"complete","message_count":42}}}"#)
        _ = coordinator.receive(loading, source: source)
        _ = coordinator.receive(loading, source: source)
        _ = coordinator.receive(done, source: source)
        #expect(notices.count == 2)
        guard case .resumeProgress(let first) = notices.first, case .resumeProgress(let last) = notices.last else {
            Issue.record("Missing progress pair"); return
        }
        #expect(first.requestID == last.requestID)
        #expect(first.runtimeSessionID == "runtime-A")
        #expect(last.state == .complete(messageCount: 42))
    }

    /// The feed belongs to the connection, not to whichever agent it last opened: a change that names
    /// another agent (a chat opened from a notification switched agents) still reaches the screens.
    @Test func changesFromAnotherAgentStillReachTheScreens() throws {
        let source = try makeSource()
        var notices: [NativeWorkspaceInvalidationNotice] = []
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source },
            refreshSessions: { _ in }, refreshScheduledTasks: { _ in },
            publish: { _, notice in notices.append(notice) })
        defer { coordinator.suspend() }
        let platforms = try decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"platforms.changed","session_id":"","payload":{},"profile":"alfie"}}"#)
        #expect(coordinator.receive(platforms, source: source))
        #expect(notices == [.platformsChanged])
    }

    @Test func reactionIdentityUsesOnlyCanonicalDecimalRowSuffix() {
        #expect(NativeMessageReactionRowIdentity.rowID(from: "saved:row:42") == 42)
        for invalid in ["42", "saved:row:", "saved:row:42:extra", "saved:row:４２", "saved:row:-1"] {
            #expect(NativeMessageReactionRowIdentity.rowID(from: invalid) == nil)
        }
    }

    private func makeSource() throws -> NativeWorkspaceEventSource {
        let owner = WorkspaceOwner(authority: try .direct(endpointIdentity: "https://fixture.example.test", providerID: "test", userID: "invalidation"),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        return .init(hostID: UUID(), owner: owner, servingProfileID: "default")
    }

    private func decode(_ text: String) throws -> DirectHermesEvent {
        guard case .event(let event) = try DirectHermesWire.decode(Data(text.utf8)).first else {
            throw DirectHermesError.invalidResponse
        }
        return event
    }
}
