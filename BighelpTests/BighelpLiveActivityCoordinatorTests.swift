import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BighelpLiveActivityCoordinatorTests {

    @Test func clarificationAccessibilityIdentifiersUseTheProvidedSurfacePrefix() {
        let identifiers = DashboardClarificationAccessibilityIdentifiers(
            prefix: "chat.active-card"
        )

        #expect(identifiers.card(itemID: "clarify-1") ==
            "chat.active-card.clarification.card.clarify-1")
        #expect(identifiers.choice("Production") ==
            "chat.active-card.clarification.choice.Production")
        #expect(identifiers.sendSelected ==
            "chat.active-card.clarification.send-selected")
        #expect(identifiers.customResponse ==
            "chat.active-card.clarification.custom-response")
        #expect(identifiers.submitCustom ==
            "chat.active-card.clarification.submit-custom")
        #expect(identifiers.expired ==
            "chat.active-card.clarification.expired")
        #expect(identifiers.countdown ==
            "chat.active-card.clarification.countdown")
    }

    @Test func oneActivityFollowsAWholeSessionAndRegistersItsPushToken() async throws {
        let driver = LiveActivityDriverStub(token: Data([0x01, 0x02, 0xFE]))
        let registrar = LiveActivityRegistrarStub()
        let coordinator = BighelpLiveActivityCoordinator(
            driver: driver,
            registrar: registrar,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        await coordinator.receive(
            event(kind: .reasoning, lifecycle: .running, title: "Reasoning"),
            sessionTitle: "Weekend plans",
            agentID: "juno",
            agentName: "Juno"
        )
        await coordinator.receive(
            event(kind: .tool, lifecycle: .running, title: "Checking weather"),
            sessionTitle: "Weekend plans",
            agentID: "juno",
            agentName: "Juno"
        )

        #expect(driver.started.count == 1)
        #expect(driver.updated.count == 2)
        #expect(registrar.registrations.count == 1)
        #expect(registrar.registrations[0].pushToken == "0102fe")
        #expect(registrar.registrations[0].sessionReference.count == 43)
        #expect(registrar.registrations[0].revision == 1)
    }

    @Test func finalAssistantMessageCompletesAndRevokesTheMatchingActivity() async {
        let driver = LiveActivityDriverStub(token: Data([0x01]))
        let registrar = LiveActivityRegistrarStub()
        let coordinator = BighelpLiveActivityCoordinator(
            driver: driver,
            registrar: registrar,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )
        await coordinator.receive(
            event(kind: .reasoning, lifecycle: .running, title: "Reasoning"),
            sessionTitle: "Weekend plans",
            agentID: "juno",
            agentName: "Juno"
        )

        await coordinator.finish(
            sessionID: "session_live_activity_0001",
            agentName: "Juno",
            succeeded: true
        )

        #expect(driver.ended.count == 1)
        #expect(driver.ended[0].state.phase == .completed)
        #expect(registrar.revocations.count == 1)
        #expect(registrar.revocations[0].revision == 2)
        #expect(coordinator.activeSessionIDs.isEmpty)
    }

    @Test func accountBoundaryEndsAndRevokesEveryActiveSession() async {
        let driver = LiveActivityDriverStub(token: Data([0x01]))
        let registrar = LiveActivityRegistrarStub()
        let coordinator = BighelpLiveActivityCoordinator(
            driver: driver,
            registrar: registrar,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )
        await coordinator.receive(
            event(kind: .reasoning, lifecycle: .running, title: "Reasoning"),
            sessionTitle: "Private account work",
            agentID: "juno",
            agentName: "Juno"
        )

        await coordinator.resetForAccountBoundary()

        #expect(driver.ended.count == 1)
        #expect(driver.ended[0].state.phase == .failed)
        #expect(registrar.revocations.count == 1)
        #expect(coordinator.activeSessionIDs.isEmpty)
    }

    @Test func failedRegistrationIsRetriedWithTheSameRevisionAndNotDuplicated() async {
        let driver = LiveActivityDriverStub(token: Data([0x01]))
        let registrar = LiveActivityRegistrarStub()
        registrar.registrationFailuresRemaining = 1
        let coordinator = BighelpLiveActivityCoordinator(
            driver: driver,
            registrar: registrar,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        await coordinator.receive(
            event(kind: .reasoning, lifecycle: .running, title: "Reasoning"),
            sessionTitle: "Retry registration",
            agentID: "juno",
            agentName: "Juno"
        )
        #expect(registrar.registrations.map(\.revision) == [1])
        #expect(coordinator.pendingOperationCount == 1)
        let failedRegistration = registrar.registrations[0]

        await coordinator.flushPendingOperations()
        #expect(registrar.registrations.map(\.revision) == [1, 1])
        #expect(registrar.registrations[1] == failedRegistration)
        #expect(coordinator.pendingOperationCount == 0)

        await coordinator.receive(
            event(kind: .tool, lifecycle: .running, title: "Checking weather"),
            sessionTitle: "Retry registration",
            agentID: "juno",
            agentName: "Juno"
        )
        #expect(registrar.registrations.map(\.revision) == [1, 1])
    }

    @Test func rotatedPushTokenSupersedesAPendingFailedRegistration() async {
        let driver = LiveActivityDriverStub(token: Data([0x01]))
        let registrar = LiveActivityRegistrarStub()
        registrar.registrationFailuresRemaining = 1
        let coordinator = BighelpLiveActivityCoordinator(
            driver: driver,
            registrar: registrar,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        await coordinator.receive(
            event(kind: .reasoning, lifecycle: .running, title: "Reasoning"),
            sessionTitle: "Rotated push token",
            agentID: "juno",
            agentName: "Juno"
        )
        #expect(registrar.registrations.map(\.pushToken) == ["01"])
        #expect(coordinator.pendingOperationCount == 1)

        driver.emitPushToken(Data([0x02]))
        for _ in 0..<10 { await Task.yield() }
        await coordinator.flushPendingOperations()

        #expect(registrar.registrations.map(\.pushToken) == ["01", "02"])
        #expect(registrar.registrations.map(\.revision) == [1, 1])
        #expect(coordinator.pendingOperationCount == 0)
    }

    @Test func failedRevocationIsRetriedWithoutAdvancingRevisionTwice() async {
        let driver = LiveActivityDriverStub(token: Data([0x01]))
        let registrar = LiveActivityRegistrarStub()
        registrar.revocationFailuresRemaining = 1
        let coordinator = BighelpLiveActivityCoordinator(
            driver: driver,
            registrar: registrar,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        await coordinator.receive(
            event(kind: .reasoning, lifecycle: .running, title: "Reasoning"),
            sessionTitle: "Retry revocation",
            agentID: "juno",
            agentName: "Juno"
        )
        await coordinator.finish(
            sessionID: "session_live_activity_0001",
            agentName: "Juno",
            succeeded: true
        )

        #expect(registrar.revocations.map(\.revision) == [2])
        #expect(coordinator.pendingOperationCount == 1)
        let failedRevocation = registrar.revocations[0]

        await coordinator.flushPendingOperations()
        #expect(registrar.revocations.map(\.revision) == [2, 2])
        #expect(registrar.revocations[1] == failedRevocation)
        #expect(coordinator.pendingOperationCount == 0)
    }

    @Test func pendingOperationsAreDiscardedAtAnAccountBoundary() async {
        let driver = LiveActivityDriverStub(token: Data([0x01]))
        let registrar = LiveActivityRegistrarStub()
        registrar.registrationFailuresRemaining = 1
        let coordinator = BighelpLiveActivityCoordinator(
            driver: driver,
            registrar: registrar,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        await coordinator.receive(
            event(kind: .reasoning, lifecycle: .running, title: "Reasoning"),
            sessionTitle: "Old account",
            agentID: "juno",
            agentName: "Juno"
        )
        #expect(coordinator.pendingOperationCount == 1)

        await coordinator.resetForAccountBoundary()
        #expect(coordinator.pendingOperationCount == 0)

        await coordinator.flushPendingOperations()
        #expect(registrar.registrations.map(\.revision) == [1])
    }

    @Test func accountResetQuarantinesARegistrationThatFinishesAfterReset() async {
        let driver = LiveActivityDriverStub(token: Data([0x01]))
        let registrar = BlockingLiveActivityRegistrar()
        let coordinator = BighelpLiveActivityCoordinator(
            driver: driver,
            registrar: registrar,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        let receiving = Task {
            await coordinator.receive(
                event(kind: .reasoning, lifecycle: .running, title: "Reasoning"),
                sessionTitle: "Old account work",
                agentID: "juno",
                agentName: "Juno"
            )
        }
        while !registrar.didBeginRegistration {
            await Task.yield()
        }

        let reset = Task {
            await coordinator.resetForAccountBoundary()
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        registrar.resumeRegistration()

        await receiving.value
        await reset.value

        #expect(coordinator.activeSessionIDs.isEmpty)
        #expect(coordinator.pendingOperationCount == 0)
        #expect(driver.ended.count == 1)
        #expect(driver.updated.isEmpty)
        #expect(registrar.revocations.isEmpty)
    }

    @Test func relaunchRestoresAnActiveNativeActivityWithoutStartingADuplicate() async throws {
        let attributes = try #require(
            LoopdySessionActivityAttributes.make(
                sessionID: "session_live_activity_restored",
                sessionTitle: "Restored work",
                agentID: "juno",
                agentName: "Juno"
            )
        )
        let state = LoopdySessionActivityAttributes.ContentState.initial(
            agentName: "Juno",
            timestamp: 1_788_000_001
        )
        let driver = LiveActivityDriverStub(token: Data([0x01]))
        driver.restored = [
            BighelpLiveActivitySnapshot(
                nativeActivityID: "native-activity-restored",
                attributes: attributes,
                state: state,
                pushToken: Data([0x01])
            ),
        ]
        let coordinator = BighelpLiveActivityCoordinator(
            driver: driver,
            registrar: LiveActivityRegistrarStub(),
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )

        #expect(coordinator.activeSessionIDs == Set(["session_live_activity_restored"]))
        #expect(driver.started.isEmpty)

        await coordinator.receive(
            event(
                sessionID: "session_live_activity_restored",
                kind: .tool,
                lifecycle: .running,
                title: "Checking weather"
            ),
            sessionTitle: "Restored work",
            agentID: "juno",
            agentName: "Juno"
        )

        #expect(driver.started.isEmpty)
        #expect(driver.updated.count == 1)
        #expect(coordinator.activeSessionIDs == Set(["session_live_activity_restored"]))
    }

    private func event(
        sessionID: String = "session_live_activity_0001",
        kind: ChatActivityKind,
        lifecycle: ChatActivityLifecycle,
        title: String
    ) -> ChatActivityEvent {
        ChatActivityEvent(
            eventID: "event_live_activity_0001",
            sessionID: sessionID,
            turnID: "turn_live_0001",
            kind: kind,
            lifecycle: lifecycle,
            title: title,
            summary: nil,
            detail: nil,
            occurredAt: 1_788_000_001,
            durationMilliseconds: nil,
            toolCallID: kind == .tool ? "tool_live_activity_0001" : nil,
            subagentID: kind == .subagent ? "subagent_live_activity_0001" : nil,
            botRunID: kind == .botHandoff ? "bot_live_activity_0001" : nil,
            memberID: kind == .botHandoff ? "member_live_activity_0001" : nil
        )
    }

    private static func attentionNotification() throws -> BighelpLinkNotificationEvent {
        try JSONDecoder().decode(
            BighelpLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "attention.required:clarify_0001",
                  "eventType": "attention.required",
                  "agentId": "juno",
                  "agentName": "Juno",
                  "sessionId": "session_live_activity_0001",
                  "title": "Juno has a question",
                  "body": "Deploy with secret token alpha-123?",
                  "sentAt": 1788000001
                }
                """.utf8
            )
        )
    }
}

@MainActor
private final class NotificationReceiptDashboardSource: DashboardDataSource {
    private(set) var loadCount = 0

    func loadDashboard() async throws -> DashboardSnapshot {
        loadCount += 1
        return DashboardSnapshot(
            inbox: [],
            attentionItems: loadCount == 1 ? [] : [
                DashboardAttentionItem(
                    id: "attention.required:clarify_0001",
                    title: "Juno has a question",
                    detail: "Waiting for your answer",
                    urgency: .important,
                    sessionID: "session_live_activity_0001",
                    agentID: "juno"
                ),
            ],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private final class SuspendedNotificationDashboardSource: DashboardDataSource {
    private let gate: NotificationLiveActivityGate

    init(gate: NotificationLiveActivityGate) {
        self.gate = gate
    }

    func loadDashboard() async throws -> DashboardSnapshot {
        await gate.run()
        return DashboardSnapshot(
            inbox: [],
            attentionItems: [],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private final class NotificationLiveActivityGate {
    private(set) var started = false
    private(set) var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        finished = true
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class LiveActivityDriverStub: BighelpLiveActivityDriving {
    struct Started {
        let attributes: LoopdySessionActivityAttributes
        let state: LoopdySessionActivityAttributes.ContentState
    }
    struct Updated {
        let id: String
        let state: LoopdySessionActivityAttributes.ContentState
    }

    let token: Data?
    var started: [Started] = []
    var updated: [Updated] = []
    var ended: [Updated] = []
    var restored: [BighelpLiveActivitySnapshot] = []
    private var tokenUpdateContinuation: AsyncStream<Data>.Continuation?

    init(token: Data?) {
        self.token = token
    }

    func start(
        attributes: LoopdySessionActivityAttributes,
        state: LoopdySessionActivityAttributes.ContentState
    ) throws -> String {
        started.append(Started(attributes: attributes, state: state))
        return "native-activity-0001"
    }

    func update(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        updated.append(Updated(id: id, state: state))
    }

    func end(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        ended.append(Updated(id: id, state: state))
    }

    func currentPushToken(id: String) -> Data? { token }

    func pushTokenUpdates(id: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            tokenUpdateContinuation = continuation
        }
    }

    func existingActivities() -> [BighelpLiveActivitySnapshot] { restored }

    func emitPushToken(_ token: Data) {
        tokenUpdateContinuation?.yield(token)
    }
}

@MainActor
private final class LiveActivityRegistrarStub: BighelpLiveActivityRegistering {
    var registrations: [BighelpLiveActivityRegistration] = []
    var revocations: [BighelpLiveActivityRevocation] = []
    var registrationFailuresRemaining = 0
    var revocationFailuresRemaining = 0

    func register(_ registration: BighelpLiveActivityRegistration) async throws {
        registrations.append(registration)
        if registrationFailuresRemaining > 0 {
            registrationFailuresRemaining -= 1
            throw StubError.transient
        }
    }

    func revoke(_ revocation: BighelpLiveActivityRevocation) async throws {
        revocations.append(revocation)
        if revocationFailuresRemaining > 0 {
            revocationFailuresRemaining -= 1
            throw StubError.transient
        }
    }

    private enum StubError: Error { case transient }
}

@MainActor
private final class BlockingLiveActivityRegistrar: BighelpLiveActivityRegistering {
    private var registrationContinuation: CheckedContinuation<Void, any Error>?
    private(set) var didBeginRegistration = false
    private(set) var revocations: [BighelpLiveActivityRevocation] = []

    func register(_ registration: BighelpLiveActivityRegistration) async throws {
        didBeginRegistration = true
        try await withCheckedThrowingContinuation { continuation in
            registrationContinuation = continuation
        }
    }

    func resumeRegistration() {
        registrationContinuation?.resume()
        registrationContinuation = nil
    }

    func revoke(_ revocation: BighelpLiveActivityRevocation) async throws {
        revocations.append(revocation)
    }
}
