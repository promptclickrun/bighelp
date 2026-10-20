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
        }, refreshScheduledTasks: { _ in Issue.record("Sessions event refreshed cron") }, publish: { _, _ in },
            minimumSessionsRefreshGap: .zero)
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

    @Test func aBurstOfSessionChangesAfterARefreshWaitsForTheGapAndReadsOnce() async throws {
        let source = try makeSource()
        var started: [ContinuousClock.Instant] = []
        var ended: [ContinuousClock.Instant] = []
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source }, refreshSessions: { _ in
            started.append(.now)
            ended.append(.now)
        }, refreshScheduledTasks: { _ in Issue.record("Sessions event refreshed cron") }, publish: { _, _ in },
            minimumSessionsRefreshGap: .milliseconds(200))
        defer { coordinator.suspend() }
        let event = try sessionsChanged()
        #expect(coordinator.receive(event, source: source))
        for _ in 0..<100 where started.isEmpty { await Task.yield() }
        #expect(started.count == 1, "The first change reads at once.")
        for _ in 0..<3 { #expect(coordinator.receive(event, source: source)) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(started.count == 1, "Runs finishing back to back don't each read the list.")
        #expect(coordinator.receive(event, source: source), "A change during the wait")
        try await Task.sleep(for: .milliseconds(400))
        #expect(started.count == 2, "The burst, and what came during the wait, become one read after the gap.")
        if started.count == 2 { #expect(started[1] - ended[0] >= .milliseconds(200)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(started.count == 2, "Nothing is read again for changes the last read already covered.")
    }

    @Test func aScheduledTaskChangeDoesNotWaitBehindTheSessionsGap() async throws {
        let source = try makeSource()
        var sessionReads: [ContinuousClock.Instant] = []
        var cronReads: [ContinuousClock.Instant] = []
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { source },
            refreshSessions: { _ in sessionReads.append(.now) },
            refreshScheduledTasks: { _ in cronReads.append(.now) }, publish: { _, _ in },
            minimumSessionsRefreshGap: .milliseconds(300))
        defer { coordinator.suspend() }
        #expect(coordinator.receive(try sessionsChanged(), source: source))
        for _ in 0..<100 where sessionReads.isEmpty { await Task.yield() }
        #expect(coordinator.receive(try sessionsChanged(), source: source))
        try await Task.sleep(for: .milliseconds(50))
        let cronAt = ContinuousClock.now
        #expect(coordinator.receive(try decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"cron.changed","session_id":"","payload":{}}}"#), source: source))
        try await Task.sleep(for: .milliseconds(100))
        #expect(cronReads.count == 1, "Scheduled tasks are read while the sessions gap is still running.")
        if let read = cronReads.first { #expect(read - cronAt < .milliseconds(100)) }
        #expect(sessionReads.count == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sessionReads.count == 2, "The sessions read still comes, after its gap.")
        if sessionReads.count == 2 { #expect(sessionReads[1] - sessionReads[0] >= .milliseconds(300)) }
    }

    @Test func aReadFinishingAfterAHostSwitchDoesNotDelayTheNewHostsFirstRead() async throws {
        let first = try makeSource()
        let second = try makeSource()
        var current = first
        var reads: [NativeWorkspaceEventSource] = []
        var release: CheckedContinuation<Void, Never>?
        let coordinator = NativeWorkspaceInvalidationCoordinator(currentSource: { current }, refreshSessions: { source in
            if source == first { await withCheckedContinuation { release = $0 } }
            reads.append(source)
        }, refreshScheduledTasks: { _ in }, publish: { _, _ in }, minimumSessionsRefreshGap: .seconds(2))
        defer { coordinator.suspend() }
        #expect(coordinator.receive(try sessionsChanged(), source: first))
        for _ in 0..<100 where release == nil { await Task.yield() }
        guard let held = release else { Issue.record("The first host's read did not start"); return }
        current = second
        coordinator.suspend()
        held.resume()
        for _ in 0..<100 where reads.isEmpty { await Task.yield() }
        #expect(reads == [first])
        let asked = ContinuousClock.now
        #expect(coordinator.receive(try sessionsChanged(), source: second))
        for _ in 0..<100 where reads.count < 2 { await Task.yield() }
        #expect(reads == [first, second], "The old read's late finish doesn't start a gap for the new host.")
        #expect(ContinuousClock.now - asked < .milliseconds(500))
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

    private func sessionsChanged() throws -> DirectHermesEvent {
        try decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"sessions.changed","session_id":"","payload":{}}}"#)
    }

    private func decode(_ text: String) throws -> DirectHermesEvent {
        guard case .event(let event) = try DirectHermesWire.decode(Data(text.utf8)).first else {
            throw DirectHermesError.invalidResponse
        }
        return event
    }
}
