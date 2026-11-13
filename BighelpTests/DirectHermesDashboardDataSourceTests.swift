import Foundation
import Testing
@testable import Bighelp

@MainActor
@Suite(.serialized)
struct DirectHermesDashboardDataSourceTests {
    @Test func nativeApprovalIsPresentedAndRespondedThroughInjectedOwner() async throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let approval = DirectHermesDashboardApproval.hostedRoom(
            HermesBotModePendingApproval(
                roomID: "room-1", memberID: "member-1", taskID: "task-1",
                executionGeneration: 3, requestID: "request-1", command: "terminal",
                description: "Run the checked command.", choices: [.once, .deny]
            ),
            roomName: "Release room", agentName: "Builder", createdAt: now
        )
        var submitted: (String, ApprovalDecision)?
        let source = try DirectHermesDashboardDataSource(
            authority: authority(), sessions: { [] }, agents: { [] },
            approvals: { [approval] },
            approvalResponder: { approval, decision in
                submitted = (approval.id, decision)
            },
            defaults: isolatedDefaults(), now: { now }
        )

        let snapshot = try await source.loadDashboard()
        let item = try #require(snapshot.attentionItems.first)
        #expect(item.id == "native.approval.\(approval.id)")
        #expect(item.approvalID == approval.id)
        #expect(item.sessionID == "hermes-room:room-1")
        #expect(item.interaction.isStructuredDecision)
        if case .approval(let request) = item.interaction {
            #expect(Set(request.allowedDecisions) == [.once, .deny])
            #expect(request.expiresAt == .distantFuture)
        } else {
            Issue.record("Expected a native approval interaction")
        }

        let loaded = try await source.loadApproval(id: approval.id)
        #expect(loaded.request.action == "terminal")
        #expect(loaded.request.requester == "Builder")
        _ = try await source.submit(request: loaded.request, decision: .once)
        #expect(submitted?.0 == approval.id)
        #expect(submitted?.1 == .once)
    }

    @Test func aRemovedItemStaysRemovedForItsComputerOnly() async throws {
        let defaults = isolatedDefaults()
        let authority = try authority()
        let otherAuthority = try WorkspaceAuthority.direct(
            endpointIdentity: "https://other-native.example", providerID: "default", userID: "user"
        )
        let question = DirectHermesDashboardClarification(
            id: "question-1", sessionID: "session-1", question: "Which channel?",
            createdAt: Date(timeIntervalSince1970: 29_900)
        )
        func makeSource(for authority: WorkspaceAuthority) -> DirectHermesDashboardDataSource {
            DirectHermesDashboardDataSource(
                authority: authority, sessions: { [] }, agents: { [] },
                clarifications: { [question] },
                defaults: defaults, now: { Date(timeIntervalSince1970: 30_000) }
            )
        }

        let first = makeSource(for: authority)
        let id = try #require((await first.loadDashboard()).attentionItems.first?.id)
        try await first.dismissDashboardEvent(id: id)
        #expect((try await first.loadDashboard()).attentionItems.isEmpty)

        // A new launch reads what was removed back from the device.
        #expect((try await makeSource(for: authority).loadDashboard()).attentionItems.isEmpty)
        #expect((try await makeSource(for: otherAuthority).loadDashboard()).attentionItems.count == 1)
    }

    @Test func staleSelectedHostCannotReadOrMutateNativeDashboardProjection() async throws {
        var current = true
        let source = try DirectHermesDashboardDataSource(
            authority: authority(), sessions: { [] }, agents: { [] },
            defaults: isolatedDefaults(), isCurrentOwner: { current }
        )
        current = false

        await #expect(throws: WorkspaceClientError.ownerChanged) {
            _ = try await source.loadDashboard()
        }
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await source.dismissDashboardEvent(id: "native.clarification.owned")
        }
    }

    private func authority() throws -> WorkspaceAuthority {
        try .direct(endpointIdentity: "https://native.example", providerID: "default", userID: "user")
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "loopdy.direct-dashboard-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
