#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
@preconcurrency import ActivityKit
#endif
import CryptoKit
import BuzzKit
import Foundation
import OSLog

struct BighelpLiveActivityRegistration: Equatable, Sendable {
    let activityID: String
    let sessionReference: String
    let pushToken: String
    let revision: Int
    let timestamp: Int
    let leaseExpires: Int
}

struct BighelpLiveActivityRevocation: Equatable, Sendable {
    let activityID: String
    let revision: Int
    let timestamp: Int
}

struct BighelpLiveActivitySnapshot {
    let nativeActivityID: String
    let attributes: LoopdySessionActivityAttributes
    let state: LoopdySessionActivityAttributes.ContentState
    let pushToken: Data?
}

@MainActor
protocol BighelpLiveActivityRegistering: AnyObject {
    func register(_ registration: BighelpLiveActivityRegistration) async throws
    func revoke(_ revocation: BighelpLiveActivityRevocation) async throws
}

@MainActor
protocol BighelpLiveActivityDriving: AnyObject {
    /// Returns activities that survived an app relaunch. The default
    /// implementation keeps non-ActivityKit drivers source-compatible while
    /// making the capability dynamically dispatch through the existential.
    func existingActivities() -> [BighelpLiveActivitySnapshot]
    func start(
        attributes: LoopdySessionActivityAttributes,
        state: LoopdySessionActivityAttributes.ContentState
    ) throws -> String
    func update(
        id: String,
        state: LoopdySessionActivityAttributes.ContentState
    ) async
    func end(
        id: String,
        state: LoopdySessionActivityAttributes.ContentState
    ) async
    func currentPushToken(id: String) -> Data?
    func pushTokenUpdates(id: String) -> AsyncStream<Data>
    func dismiss(id: String, state: LoopdySessionActivityAttributes.ContentState) async
}

extension BighelpLiveActivityDriving {
    /// Returns native activities that survived an app relaunch. Drivers that
    /// cannot enumerate their platform activities intentionally return an
    /// empty list; restoration remains an optional capability of the driver.
    func existingActivities() -> [BighelpLiveActivitySnapshot] { [] }
    func dismiss(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        await end(id: id, state: state)
    }
}

@MainActor
final class BighelpLiveActivityCoordinator {
    private final class ActiveSession {
        let nativeActivityID: String
        let relayActivityID: String
        let attributes: LoopdySessionActivityAttributes
        var state: LoopdySessionActivityAttributes.ContentState
        var work: BighelpLiveActivityWorkReducer
        var stateRevision = 0
        var publicationInFlight = false
        var registrationInFlight = false
        var restoredWithoutRegistration = false
        var allowsLegacyFinish = true
        var deferredPushToken: Data?
        var revision = 0
        var pushToken: Data?
        var tokenTask: Task<Void, Never>?
        var closeInFlight = false
        var closeWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            nativeActivityID: String,
            relayActivityID: String,
            attributes: LoopdySessionActivityAttributes,
            state: LoopdySessionActivityAttributes.ContentState
        ) {
            self.nativeActivityID = nativeActivityID
            self.relayActivityID = relayActivityID
            self.attributes = attributes
            self.state = state
            self.work = BighelpLiveActivityWorkReducer(restoredChildCount: state.activeSubagentCount)
        }
    }

    private enum PendingOperation {
        case registration(BighelpLiveActivityRegistration, session: ActiveSession)
        case revocation(BighelpLiveActivityRevocation)

        var key: String {
            switch self {
            case let .registration(registration, _):
                return "register:\(registration.activityID)"
            case let .revocation(revocation):
                return "revoke:\(revocation.activityID)"
            }
        }
    }

    private let driver: any BighelpLiveActivityDriving
    private let registrar: any BighelpLiveActivityRegistering
    private let now: () -> Date
    private var active: [String: ActiveSession] = [:]
    private var pending: [String: PendingOperation] = [:]
    private var notificationTasks: [UUID: Task<Void, Never>] = [:]
    private var legacyIngressTask: Task<Void, Never>?
    private var legacyIngressID: UUID?
    private var lifecycleGeneration = 0
    private var resettingAccount = false
    private struct RetiredTurn: Hashable {
        let sessionID: String
        let turnID: String
    }
    private var retiredTurns: Set<RetiredTurn> = []
    private var retiredOrder: [RetiredTurn] = []

    init(
        driver: any BighelpLiveActivityDriving,
        registrar: any BighelpLiveActivityRegistering,
        now: @escaping () -> Date = Date.init
    ) {
        self.driver = driver
        self.registrar = registrar
        self.now = now
        restoreExistingActivities()
    }

    var activeSessionIDs: Set<String> {
        Set(active.keys)
    }

    /// The number of relay operations waiting for a later connectivity window.
    ///
    /// Registration and revocation failures are intentionally retained as the
    /// exact request that failed. The next activity event or an app lifecycle
    /// callback should call `flushPendingOperations()` to retry them.
    var pendingOperationCount: Int { pending.count }

    @discardableResult
    func scheduleNotificationReceive(
        _ event: ChatActivityEvent,
        sessionTitle: String,
        agentID: String,
        agentName: String,
        after preparation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let taskID = UUID()
        let generation = lifecycleGeneration
        let task = Task { @MainActor [weak self] in
            await preparation()
            guard let self else { return }
            defer { self.notificationTasks[taskID] = nil }
            guard
                !Task.isCancelled,
                generation == self.lifecycleGeneration
            else { return }
            await self.receive(
                event,
                sessionTitle: sessionTitle,
                agentID: agentID,
                agentName: agentName
            )
        }
        notificationTasks[taskID] = task
        return task
    }

    /// Reclaims active native activities after the app process is recreated.
    /// ActivityKit owns the native activity's lifetime, so no second native
    /// activity is requested. The relay revision is intentionally left at
    /// zero until the exact account-owned registration is supplied through
    /// reconcileRestoredRegistration; a token is not a registration revision.
    func restoreExistingActivities() {
        guard !resettingAccount else { return }
        for snapshot in driver.existingActivities() {
            guard
                !snapshot.state.phase.isTerminal,
                active[snapshot.attributes.sessionID] == nil,
                active.count < 64
            else { continue }
            let session = ActiveSession(
                nativeActivityID: snapshot.nativeActivityID,
                relayActivityID: Self.relayActivityID(snapshot.nativeActivityID),
                attributes: snapshot.attributes,
                state: snapshot.state
            )
            session.pushToken = snapshot.pushToken
            session.restoredWithoutRegistration = true
            session.allowsLegacyFinish = false
            active[snapshot.attributes.sessionID] = session
            observePushTokens(for: session)
        }
    }

    /// Retries failed relay operations once using their original revision and
    /// payload. A failed retry remains queued for the next lifecycle/event
    /// window; no unbounded background retry task is created here.
    func flushPendingOperations() async {
        guard !resettingAccount else { return }
        let generation = lifecycleGeneration
        await flushPendingOperations(generation: generation)
    }

    /// Supply an exact persisted/authoritatively read-back request under the
    /// CURRENT account/host. Same-token restore retries these bytes and revision;
    /// it must not manufacture revision 1 merely because ActivityKit has a token.
    func reconcileRestoredRegistration(_ registration: BighelpLiveActivityRegistration) async {
        guard !resettingAccount,
              let session = active.values.first(where: { $0.relayActivityID == registration.activityID }),
              session.restoredWithoutRegistration, !session.closeInFlight,
              registration.sessionReference == Self.sessionReference(session.attributes.sessionID),
              registration.revision > 0, registration.timestamp > 0,
              registration.leaseExpires > Int(now().timeIntervalSince1970),
              registration.leaseExpires > registration.timestamp,
              registration.leaseExpires - registration.timestamp <= 28_800,
              let token = Self.data(fromHex: registration.pushToken), !token.isEmpty,
              token == session.pushToken else { return }
        let operation = PendingOperation.registration(registration, session: session)
        if let existing = pending[operation.key] {
            guard case let .registration(request, owner) = existing,
                  owner === session, request == registration else { return }
        } else {
            pending[operation.key] = operation
        }
        await flushPendingOperations(generation: lifecycleGeneration)
    }

    private func flushPendingOperations(generation: Int) async {
        guard !pending.isEmpty else { return }

        for operation in Array(pending.values) {
            guard generation == lifecycleGeneration else { return }
            switch operation {
            case let .registration(registration, session):
                guard case let .registration(queued, owner)? = pending[operation.key],
                      owner === session, queued == registration else { continue }
                guard
                    active[session.attributes.sessionID] === session,
                    !session.closeInFlight,
                    session.revision < registration.revision
                else {
                    pending.removeValue(forKey: operation.key)
                    continue
                }

                guard !session.registrationInFlight else { continue }
                session.registrationInFlight = true
                defer { finishRegistrationAttempt(session, generation: generation) }
                do {
                    try await registrar.register(registration)
                    guard generation == lifecycleGeneration else { return }
                    guard active[session.attributes.sessionID] === session, !session.closeInFlight else {
                        await revokeLateRegistration(registration, generation: generation)
                        continue
                    }
                    session.pushToken = Self.data(fromHex: registration.pushToken)
                    session.revision = registration.revision
                    session.restoredWithoutRegistration = false
                    if case let .registration(current, owner)? = pending[operation.key],
                       owner === session, current == registration {
                        pending.removeValue(forKey: operation.key)
                    }
                } catch {
                    // Keep the exact request for a later event/lifecycle retry.
                }

            case let .revocation(revocation):
                guard case let .revocation(queued)? = pending[operation.key],
                      queued == revocation else { continue }
                do {
                    try await registrar.revoke(revocation)
                    guard generation == lifecycleGeneration else { return }
                    if case let .revocation(current)? = pending[operation.key], current == revocation {
                        pending.removeValue(forKey: operation.key)
                    }
                } catch {
                    // Keep the exact request for a later event/lifecycle retry.
                }
            }
        }
    }

    /// Legacy Link only. The authenticated wire wrapper preserves the producer's
    /// exact reason_<digest>/turn_<digest> identity pair. Generic/native reasoning
    /// events do not pass through this adapter and never imply parent completion.
    /// Serialize ingress before the first await so registration cannot reorder
    /// start/end. Account resets invalidate queued events, not just current work.
    @discardableResult
    func scheduleLegacyLinkReceive(
        _ event: BighelpLinkActivityEvent,
        sessionTitle: String,
        agentID: String,
        agentName: String
    ) -> Task<Void, Never> {
        guard !resettingAccount, notificationTasks.count < 512,
              event.agentID == nil || event.agentID == agentID else { return Task {} }
        let generation = lifecycleGeneration
        let previous = legacyIngressTask
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.notificationTasks[taskID] = nil
                if self.legacyIngressID == taskID {
                    self.legacyIngressID = nil
                    self.legacyIngressTask = nil
                }
            }
            guard !Task.isCancelled, !self.resettingAccount,
                  generation == self.lifecycleGeneration else { return }
            await self.receive(event.chatEvent, sessionTitle: sessionTitle,
                               agentID: agentID, agentName: agentName)
            guard !Task.isCancelled, !self.resettingAccount,
                  generation == self.lifecycleGeneration,
                  self.active[event.chatEvent.sessionID]?.attributes.agentID == agentID,
                  let outcome = Self.legacyHookOutcome(event) else { return }
            await self.finish(sessionID: event.chatEvent.sessionID,
                              turnID: event.chatEvent.turnID, outcome: outcome)
        }
        legacyIngressTask = task
        legacyIngressID = taskID
        notificationTasks[taskID] = task
        return task
    }

    private static func legacyHookOutcome(_ wire: BighelpLinkActivityEvent) -> BighelpLiveActivityOutcome? {
        let event = wire.chatEvent
        guard event.kind == .reasoning, event.turnID.hasPrefix("turn_") else { return nil }
        let digest = event.turnID.dropFirst("turn_".count)
        guard digest.utf8.count == 24,
              digest.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              event.eventID == "reason_" + digest else { return nil }
        switch event.lifecycle {
        case .succeeded: return .succeeded
        // Legacy failed reasoning conflates failure and interruption. End with
        // neutral Stopped copy; never invent a more specific outcome from text.
        case .failed: return .cancelled
        default: return nil
        }
    }

    /// Only feed admitted live work, never historical rows. Use one coordinator
    /// per authorized host/account scope; session IDs are exact within that scope.
    func receive(
        _ event: ChatActivityEvent,
        sessionTitle: String,
        agentID: String,
        agentName: String
    ) async {
        guard !resettingAccount, event.lifecycle != .recorded else { return }
        let generation = lifecycleGeneration
        await flushPendingOperations(generation: generation)
        guard generation == lifecycleGeneration, !resettingAccount,
              !retiredTurns.contains(RetiredTurn(sessionID: event.sessionID, turnID: event.turnID)) else { return }
        let session: ActiveSession
        var created = false
        if let current = active[event.sessionID], !current.closeInFlight {
            guard current.attributes.agentID == agentID,
                  current.work.accept(event) else { return }
            session = current
        } else {
            // A solitary late stop/final must never start a new activity.
            guard !event.lifecycle.isTerminal, active.count < 64, pending.count < 512,
                  let attributes = LoopdySessionActivityAttributes.make(
                    sessionID: event.sessionID,
                    sessionTitle: sessionTitle,
                    agentID: agentID,
                    agentName: agentName
                  ) else { return }
            var work = BighelpLiveActivityWorkReducer()
            guard work.accept(event) else { return }
            let initial = LoopdySessionActivityAttributes.ContentState.initial(
                agentName: attributes.agentName, timestamp: max(1, event.occurredAt)
            )
            let nativeID: String
            do { nativeID = try driver.start(attributes: attributes, state: initial) }
            catch {
                Logger(subsystem: "app.loopdy.mobile", category: "LiveActivity")
                    .error("Could not start Live Activity: \(String(describing: error), privacy: .private)")
                return
            }
            session = ActiveSession(
                nativeActivityID: nativeID,
                relayActivityID: Self.relayActivityID(nativeID),
                attributes: attributes,
                state: initial
            )
            session.work = work
            session.allowsLegacyFinish = !retiredOrder.contains(where: { $0.sessionID == event.sessionID })
            active[event.sessionID] = session
            observePushTokens(for: session)
            created = true
        }
        session.state = session.work.project(
            previous: session.state, event: event,
            agentName: session.attributes.agentName, timestamp: event.occurredAt
        )
        session.stateRevision += 1
        let revision = session.stateRevision
        if created, let token = driver.currentPushToken(id: session.nativeActivityID) {
            await register(token, for: session, generation: generation)
        }
        guard generation == lifecycleGeneration,
              active[event.sessionID] === session,
              session.stateRevision == revision else { return }
        await publish(session, generation: generation)
    }

    /// Compatibility only: ignored after restoration or a known replacement.
    /// New composition MUST pass the actual turnID to the correlated overload.
    func finish(sessionID: String, agentName: String, succeeded: Bool) async {
        guard let session = active[sessionID], session.allowsLegacyFinish,
              let turnID = session.work.legacyFinishTurnID else { return }
        await finish(sessionID: sessionID, turnID: turnID, agentName: agentName, succeeded: succeeded)
    }

    func finish(sessionID: String, turnID: String, agentName: String, succeeded: Bool) async {
        await finish(sessionID: sessionID, turnID: turnID, outcome: succeeded ? .succeeded : .failed)
    }

    /// An authoritative PARENT turn end, not a reasoning/tool/message segment.
    /// Cancellation has neutral copy while keeping the v1 phase vocabulary.
    func finish(sessionID: String, turnID: String, outcome: BighelpLiveActivityOutcome) async {
        guard !resettingAccount, let session = active[sessionID], !session.closeInFlight else { return }
        let generation = lifecycleGeneration
        guard session.work.finish(turnID: turnID, outcome: outcome) else { return }
        // Old cohort outcomes are retained but cannot change the new parent UI.
        guard session.work.currentTurnID == turnID else { return }
        session.state = session.work.project(
            previous: session.state, agentName: session.attributes.agentName,
            timestamp: Int(now().timeIntervalSince1970)
        )
        session.stateRevision += 1
        await publish(session, generation: generation)
    }

    /// Reconcile an authenticated FULL current roster after reconnect/restoration.
    /// Preserve original parent turns for surviving children from older cohorts.
    /// Does not start activities or infer parent completion from an empty roster.
    func reconcileWork(
        sessionID: String,
        turnID: String,
        activeChildren: Set<BighelpLiveActivityChild>,
        timestamp: Int
    ) async {
        guard !resettingAccount, let session = active[sessionID], !session.closeInFlight,
              session.work.reconcile(turnID: turnID, children: activeChildren, timestamp: timestamp) else { return }
        session.state = session.work.project(
            previous: session.state, agentName: session.attributes.agentName, timestamp: timestamp
        )
        session.stateRevision += 1
        await publish(session, generation: lifecycleGeneration)
    }

    /// Attention may only attach to the exact current turn. Do not manufacture a
    /// turnID from a notification/request ID. Unmapped attention stays alert-only.
    func setWaiting(sessionID: String, turnID: String, timestamp: Int) async {
        guard !resettingAccount, let session = active[sessionID], !session.closeInFlight,
              session.work.currentTurnID == turnID, session.work.isCurrentParentActive,
              timestamp >= session.state.timestamp, !session.state.phase.isTerminal else { return }
        session.state = .init(
            phase: .waiting, currentAction: "Needs your attention", progress: 0,
            completedSteps: session.state.completedSteps,
            activeSubagentCount: session.state.activeSubagentCount, latestTool: nil,
            timestamp: max(session.state.timestamp, max(1, timestamp))
        )
        session.stateRevision += 1
        await publish(session, generation: lifecycleGeneration)
    }

    private func publish(_ session: ActiveSession, generation: Int) async {
        guard !session.publicationInFlight else { return }
        session.publicationInFlight = true
        defer { session.publicationInFlight = false }
        while generation == lifecycleGeneration,
              active[session.attributes.sessionID] === session, !session.closeInFlight {
            let revision = session.stateRevision
            let projected = session.state
            if projected.phase.isTerminal {
                await close(sessionID: session.attributes.sessionID, session: session, state: projected)
                return
            }
            await driver.update(id: session.nativeActivityID, state: projected)
            // Drain the latest reentrant change rather than stale captured state.
            if session.stateRevision == revision { return }
        }
    }

    func resetForAccountBoundary() async {
        guard !resettingAccount else { return }
        resettingAccount = true
        defer { resettingAccount = false }
        // Close native activities while the current account is still in scope,
        // then discard every remaining relay operation. Never retry or carry an
        // old-account request into another account's credential context.
        lifecycleGeneration += 1
        let staleNotificationTasks = Array(notificationTasks.values)
        notificationTasks.removeAll()
        legacyIngressTask = nil
        legacyIngressID = nil
        for task in staleNotificationTasks {
            task.cancel()
        }
        let retiring = Array(active)
        active.removeAll()
        for (sessionID, session) in retiring {
            let final = LoopdySessionActivityAttributes.ContentState(
                phase: .failed, currentAction: BighelpActivityStatus.stopped,
                progress: 100, completedSteps: session.state.completedSteps,
                activeSubagentCount: 0, latestTool: nil,
                timestamp: max(1, Int(now().timeIntervalSince1970))
            )
            await close(sessionID: sessionID, session: session, state: final, immediately: true)
        }
        pending.removeAll()
        retiredTurns.removeAll()
        retiredOrder.removeAll()
    }

    private func close(
        sessionID: String,
        session: ActiveSession,
        state: LoopdySessionActivityAttributes.ContentState,
        immediately: Bool = false
    ) async {
        if session.closeInFlight {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.closeWaiters.append(continuation)
            }
            if immediately {
                await close(sessionID: sessionID, session: session, state: state, immediately: true)
            }
            return
        }
        session.closeInFlight = true
        let generation = lifecycleGeneration
        for turnID in session.work.turnIDs {
            let key = RetiredTurn(sessionID: sessionID, turnID: turnID)
            if retiredTurns.insert(key).inserted { retiredOrder.append(key) }
        }
        while retiredOrder.count > 512 {
            retiredTurns.remove(retiredOrder.removeFirst())
        }
        defer {
            session.closeInFlight = false
            let waiters = session.closeWaiters
            session.closeWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        session.tokenTask?.cancel()
        session.tokenTask = nil
        session.state = state
        if immediately {
            await driver.dismiss(id: session.nativeActivityID, state: state)
        } else {
            await driver.end(id: session.nativeActivityID, state: state)
        }
        guard generation == lifecycleGeneration else { return }
        if session.revision > 0 {
            let timestamp = Int(now().timeIntervalSince1970)
            let nextRevision = session.revision + 1
            let revocation = BighelpLiveActivityRevocation(
                activityID: session.relayActivityID,
                revision: nextRevision,
                timestamp: timestamp
            )
            do {
                try await registrar.revoke(revocation)
            } catch {
                if generation == lifecycleGeneration {
                    pending[PendingOperation.revocation(revocation).key] = .revocation(revocation)
                }
            }
            guard generation == lifecycleGeneration else { return }
            session.revision = nextRevision
        }
        removePendingRegistration(for: session)
        if active[sessionID] === session {
            active.removeValue(forKey: sessionID)
        }
    }

    private func observePushTokens(for session: ActiveSession) {
        let stream = driver.pushTokenUpdates(id: session.nativeActivityID)
        session.tokenTask = Task { @MainActor [weak self, weak session] in
            for await token in stream {
                guard let self, let session, !Task.isCancelled else { return }
                let generation = self.lifecycleGeneration
                await self.register(token, for: session, generation: generation)
            }
        }
    }

    private func register(
        _ token: Data,
        for session: ActiveSession,
        generation: Int
    ) async {
        guard generation == lifecycleGeneration,
              active[session.attributes.sessionID] === session,
              !session.closeInFlight, !token.isEmpty else { return }
        if session.registrationInFlight || session.restoredWithoutRegistration {
            session.deferredPushToken = token
            return
        }
        guard
            generation == lifecycleGeneration,
            active[session.attributes.sessionID] === session,
            !session.closeInFlight,
            !session.restoredWithoutRegistration,
            !session.registrationInFlight,
            !token.isEmpty,
            session.pushToken != token
        else { return }
        let timestamp = Int(now().timeIntervalSince1970)
        let nextRevision = session.revision + 1
        let registration = BighelpLiveActivityRegistration(
            activityID: session.relayActivityID,
            sessionReference: Self.sessionReference(session.attributes.sessionID),
            pushToken: token.map { String(format: "%02x", $0) }.joined(),
            revision: nextRevision,
            timestamp: timestamp,
            leaseExpires: timestamp + 28_800
        )
        // A token callback can repeat while the relay is unavailable. Keep one
        // exact request per activity so a retry cannot advance a revision twice.
        let operation = PendingOperation.registration(registration, session: session)
        if case let .registration(existing, existingSession)? = pending[operation.key] {
            guard existingSession === session else { return }
            if existing.pushToken != registration.pushToken {
                // ActivityKit may rotate a token while the previous registration
                // is still waiting for connectivity. The relay has not accepted
                // that revision, so retain the newest token at the same revision.
                pending[operation.key] = operation
            }
            return
        }
        session.registrationInFlight = true
        defer { finishRegistrationAttempt(session, generation: generation) }
        do {
            try await registrar.register(registration)
            guard generation == lifecycleGeneration else { return }
            guard active[session.attributes.sessionID] === session, !session.closeInFlight else {
                await revokeLateRegistration(registration, generation: generation)
                return
            }
            session.pushToken = token
            session.revision = nextRevision
        } catch {
            guard
                generation == lifecycleGeneration,
                active[session.attributes.sessionID] === session,
                !session.closeInFlight
            else { return }
            pending[operation.key] = operation
        }
    }

    private func finishRegistrationAttempt(_ session: ActiveSession, generation: Int) {
        session.registrationInFlight = false
        guard let token = session.deferredPushToken else { return }
        session.deferredPushToken = nil
        guard generation == lifecycleGeneration,
              active[session.attributes.sessionID] === session, !session.closeInFlight else { return }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            await self.register(token, for: session, generation: generation)
        }
    }

    private func revokeLateRegistration(_ registration: BighelpLiveActivityRegistration, generation: Int) async {
        guard generation == lifecycleGeneration, !resettingAccount else { return }
        let revocation = BighelpLiveActivityRevocation(
            activityID: registration.activityID, revision: registration.revision + 1,
            timestamp: max(1, Int(now().timeIntervalSince1970))
        )
        do {
            try await registrar.revoke(revocation)
        } catch {
            guard generation == lifecycleGeneration, !resettingAccount else { return }
            pending[PendingOperation.revocation(revocation).key] = .revocation(revocation)
        }
    }

    private func removePendingRegistration(for session: ActiveSession) {
        let key = "register:\(session.relayActivityID)"
        if case let .registration(_, owner)? = pending[key], owner === session {
            pending.removeValue(forKey: key)
        }
    }

    private static func data(fromHex string: String) -> Data? {
        guard string.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func sessionReference(_ sessionID: String) -> String {
        BighelpLinkBase64URL.encode(Data(SHA256.hash(data: Data(sessionID.utf8))))
    }

    private static func relayActivityID(_ nativeID: String) -> String {
        "activity_" + BighelpLinkBase64URL.encode(
            Data(SHA256.hash(data: Data(nativeID.utf8)))
        )
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
/// ActivityKit deadlocks when push tokens are read from several threads while it delivers one
/// (a 2.3.0 (22) watchdog kill). Token reads and token streams go through BuzzKit's serial lane,
/// never the main thread; the current token comes from the last one that lane delivered.
@MainActor
final class BighelpActivityKitDriver: BighelpLiveActivityDriving {
    private var known: [String: Activity<LoopdySessionActivityAttributes>] = [:]
    private var tokens: [String: Data] = [:]

    private struct Handle: @unchecked Sendable {
        let activity: Activity<LoopdySessionActivityAttributes>
    }

    func start(
        attributes: LoopdySessionActivityAttributes,
        state: LoopdySessionActivityAttributes.ContentState
    ) throws -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ActivityError.disabled
        }
        let activity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(
                state: state,
                staleDate: Date(timeIntervalSince1970: TimeInterval(state.timestamp + 120))
            ),
            pushType: .token
        )
        known[activity.id] = activity
        if state.sessions != nil {
            let old = Activity<LoopdySessionActivityAttributes>.activities.filter {
                $0.id != activity.id && $0.attributes.sessionID.hasPrefix("native-")
            }
            Task { @MainActor in
                for previous in old { await previous.end(nil, dismissalPolicy: .immediate) }
            }
        }
        return activity.id
    }

    func update(
        id: String,
        state: LoopdySessionActivityAttributes.ContentState
    ) async {
        guard let activity = activity(id: id) else { return }
        await activity.update(
            ActivityContent(
                state: state,
                staleDate: Date(timeIntervalSince1970: TimeInterval(state.timestamp + 120))
            )
        )
    }

    func end(
        id: String,
        state: LoopdySessionActivityAttributes.ContentState
    ) async {
        guard let activity = activity(id: id) else { return }
        await activity.end(
            ActivityContent(
                state: state,
                staleDate: Date(timeIntervalSince1970: TimeInterval(state.timestamp + 120))
            ),
            dismissalPolicy: .after(Date().addingTimeInterval(30))
        )
        known.removeValue(forKey: id)
    }

    func currentPushToken(id: String) -> Data? {
        tokens[id]
    }

    /// A card the host ended while bighelp was in the background can stay on the
    /// Lock Screen for hours; its reply is already a notification. Opening the
    /// app clears the finished ones.
    static func dismissFinishedActivities() async {
        for activity in Activity<LoopdySessionActivityAttributes>.activities
        where activity.activityState == .ended || activity.content.state.phase.isTerminal {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func dismiss(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        guard let activity = activity(id: id) else { return }
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        known.removeValue(forKey: id)
        tokens.removeValue(forKey: id)
    }

    func pushTokenUpdates(id: String) -> AsyncStream<Data> {
        guard let activity = activity(id: id) else {
            return AsyncStream { $0.finish() }
        }
        let handle = Handle(activity: activity)
        return AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                if let current = await ActivityKitSerialAccess.read({ handle.activity.pushToken }) {
                    self?.tokens[id] = current
                    continuation.yield(current)
                }
                let updates = await ActivityKitSerialAccess.iterate { handle.activity.pushTokenUpdates }
                while let token = await updates.next() {
                    guard !Task.isCancelled else { break }
                    self?.tokens[id] = token
                    continuation.yield(token)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func existingActivities() -> [BighelpLiveActivitySnapshot] {
        Activity<LoopdySessionActivityAttributes>.activities.compactMap { activity in
            guard (activity.activityState == .active || activity.activityState == .stale),
                  !activity.content.state.phase.isTerminal else { return nil }
            return BighelpLiveActivitySnapshot(
                nativeActivityID: activity.id,
                attributes: activity.attributes,
                state: activity.content.state,
                pushToken: tokens[activity.id]
            )
        }
    }

    private func activity(id: String) -> Activity<LoopdySessionActivityAttributes>? {
        if let known = known[id] { return known }
        guard let restored = Activity<LoopdySessionActivityAttributes>.activities.first(where: {
            $0.id == id
        }) else { return nil }
        known[id] = restored
        return restored
    }

    private enum ActivityError: Error {
        case disabled
    }
}
#else
/// Vision Pro has no Live Activities: nothing starts, so nothing needs a push token.
@MainActor
final class BighelpActivityKitDriver: BighelpLiveActivityDriving {
    private enum ActivityError: Error { case unsupported }

    func start(attributes: LoopdySessionActivityAttributes,
               state: LoopdySessionActivityAttributes.ContentState) throws -> String {
        throw ActivityError.unsupported
    }
    func update(id: String, state: LoopdySessionActivityAttributes.ContentState) async {}
    func end(id: String, state: LoopdySessionActivityAttributes.ContentState) async {}
    func currentPushToken(id: String) -> Data? { nil }
    func pushTokenUpdates(id: String) -> AsyncStream<Data> { AsyncStream { $0.finish() } }
}
#endif
