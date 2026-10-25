import CryptoKit
import Foundation
import BuzzKit

/// Grant/profile/session owner. Never registers a native token through legacy Link.
@MainActor
final class BighelpManagedLiveActivityRegistrar: BighelpLiveActivityRegistering {
    enum RegistrationError: Error { case canonicalTurnRequired, ownerChanged, pendingOriginalRequest }
    private let service: BighelpManagedNotificationService
    private let host: BighelpConfiguredHost
    private let grant: BighelpManagedGrant
    private let credentials: BighelpManagedNotificationCredentials
    private let environment: BighelpLinkPushEnvironment
    private let topic: String
    private var inFlight = Set<String>()
    var onRegistrationConfirmed: (@MainActor () -> Void)?

    init(service: BighelpManagedNotificationService, host: BighelpConfiguredHost, grant: BighelpManagedGrant,
         environment: BighelpLinkPushEnvironment, topic: String) throws {
        self.service = service; self.host = host; self.grant = grant
        credentials = try service.credentials(for: host)
        self.environment = environment; self.topic = topic
    }

    func register(_ registration: BighelpLiveActivityRegistration) async throws {
        try check()
        guard inFlight.insert(registration.activityID).inserted else { throw RegistrationError.pendingOriginalRequest }
        defer { inFlight.remove(registration.activityID) }
        guard var owner = service.ledger.activity(registration.activityID), matches(owner), !owner.retired,
              coordinatorReference(owner.opaqueSessionID) == registration.sessionReference,
              registration.revision > 0, registration.timestamp > 0,
              registration.leaseExpires > registration.timestamp,
              registration.leaseExpires - registration.timestamp <= 28_800,
              !registration.pushToken.isEmpty, registration.pushToken.utf8.count <= 512,
              registration.pushToken.utf8.count.isMultiple(of: 2),
              registration.pushToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RegistrationError.ownerChanged
        }
        // No epoch/sequence projection ID is sent as a host turn. Without real
        // correlation, a delayed token could bind the NEXT turn and mislead users.
        guard let turnID = owner.canonicalTurnID, ManagedNotificationValidation.coordinate(turnID) else {
            throw RegistrationError.canonicalTurnRequired
        }
        let lease = min(registration.leaseExpires, grant.expiresAt)
        let groupID = BighelpActivityGroupDriver.physicalID(owner.nativeActivityID)
        var fields: [String: BighelpJSONValue] = [
            "version": .integer(groupID == nil ? 2 : 3), "profile": .string(owner.profile), "sessionId": .string(owner.storedSessionID),
            "sessionReference": .string(ManagedNotificationValidation.sessionReference(profile: owner.profile, session: owner.storedSessionID)),
            "attributesType": .string("LoopdySessionActivityAttributes"),
            "revision": .integer(registration.revision), "timestamp": .integer(registration.timestamp), "leaseExpires": .integer(lease)
        ]
        if let groupID {
            fields["groupId"] = .string(BighelpManagedActivityDriver.relayID(groupID))
            fields["rowId"] = .string(owner.opaqueSessionID)
            guard let rowRevision = BighelpActivityGroupDriver.rowRevision(owner.nativeActivityID) else {
                throw RegistrationError.ownerChanged
            }
            fields["rowRevision"] = .integer(rowRevision)
        }
        let body = try ManagedNotificationValidation.data(BighelpJSONValue.object(fields))
        var intent: BighelpManagedActivityRequest
        if let existing = try service.activityKeys.load(registration.activityID) {
            guard matches(existing.owner), existing.pendingRevocationBody == nil else { throw RegistrationError.ownerChanged }
            if existing.revision == registration.revision {
                guard existing.registrationBody == body else { throw RegistrationError.pendingOriginalRequest }
                intent = existing
            } else {
                guard existing.registrationConfirmed, registration.revision == existing.revision + 1 else {
                    throw RegistrationError.pendingOriginalRequest
                }
                intent = makeIntent(owner, registration, body: body)
            }
        } else {
            guard registration.revision == 1 else { throw RegistrationError.ownerChanged }
            intent = makeIntent(owner, registration, body: body)
        }
        try service.activityKeys.save(intent) // token + original bytes BEFORE send
        // From the first possibly accepted request onward, native content writes
        // are suppressed. This also covers a lost mobile registration response.
        owner.remoteOwned = true; try service.ledger.save(owner)
        if !intent.registrationConfirmed {
            let response: BighelpJSONValue
            do {
                response = try await service.accountAPI().managedNotificationRequest(path: path(owner), method: "PUT",
                    body: intent.registrationBody, credentials: credentials)
            } catch BighelpLinkAPIError.requestFailed(_, let code) where code == "notification_activity_group_ended" {
                await service.activityRuntime?.invalidatePhysicalActivity(for: owner)
                throw RegistrationError.ownerChanged
            } catch let error as BighelpLinkAPIError where Self.refusesForGood(error) {
                // The service said no, so it holds nothing for this card and can never push to it. Give the
                // card back to this phone, or it stays frozen and never ends. The saved request stays, so the
                // next foreground replays the same bytes. A lost reply or an outage is NOT this: those keep
                // the card with the service, because it may have taken the request.
                owner.remoteOwned = false; try? service.ledger.save(owner)
                BighelpLiveActivityLog.note(.registrationRefused)
                throw error
            }
            try check()
            guard service.ledger.activity(owner.relayActivityID)?.retired == false else { throw RegistrationError.ownerChanged }
            try validateActivity(response, owner: owner, revision: registration.revision, lease: lease, status: "active")
            guard let token = Self.tokenData(registration.pushToken) else { throw RegistrationError.ownerChanged }
            let direct = service.pushRegistrar
            let targetID = BighelpPushRegistrar.targetID(nativeActivityID: owner.nativeActivityID, relayActivityID: owner.relayActivityID)
            if let groupID {
                guard let runtime = service.activityRuntime else { throw RegistrationError.ownerChanged }
                let capturedOwner = owner
                try await runtime.physicalTokenRegistrar.register(physicalID: BighelpManagedActivityDriver.relayID(groupID),
                    currentToken: { runtime.currentPushToken(for: capturedOwner) },
                    isCurrent: { (try? self.check()) != nil && self.service.ledger.activity(capturedOwner.relayActivityID)?.retired == false },
                    send: { id, current in
                        try await BuzzKit.activities.register(id: id, token: current, attributesType: "LoopdySessionActivityAttributes")
                        // Also directly, for sending straight to Apple. The shared card's token goes under its
                        // group ID (the `groupId` sent above, as BuzzKit has it), never a per-turn or per-chat
                        // alias. On its own task: it never fails or delays this registration.
                        Task { await direct?.registerActivity(id: targetID, token: current) }
                    })
            } else {
                try await BuzzKit.activities.register(id: owner.relayActivityID, token: token,
                    attributesType: "LoopdySessionActivityAttributes")
                // An individual (version 2) registration keeps its own activity's ID.
                Task { await direct?.registerActivity(id: targetID, token: token) }
            }
        }
        // An already acknowledged unchanged registration need not replay an old
        // mobile timestamp. The host PUT below performs CURRENT cloud readback of
        // the persisted exact activity/session owner before confirming subscription.
        let client = try service.client(for: host)
        let subscribed = try await client.request("/enrollments/\(grant.grantId)/live-activities/\(owner.relayActivityID)", method: "PUT", body: [
            "version": .integer(1), "profile": .string(owner.profile), "sessionId": .string(owner.storedSessionID),
            "sessionReference": .string(ManagedNotificationValidation.sessionReference(profile: owner.profile, session: owner.storedSessionID)),
            "leaseExpires": .integer(lease), "turnId": .string(turnID)
        ], isCurrent: { (try? self.check()) != nil && self.service.ledger.activity(owner.relayActivityID)?.retired == false })
        try check()
        guard let object = subscribed.object, object["activityId"]?.string == owner.relayActivityID,
              object["grantId"]?.string == grant.grantId, object["state"]?.string == "subscribed",
              object["sessionReference"]?.string == ManagedNotificationValidation.sessionReference(profile: owner.profile, session: owner.storedSessionID),
              service.ledger.activity(owner.relayActivityID)?.retired == false else { throw RegistrationError.ownerChanged }
        guard let current = try service.activityKeys.load(owner.relayActivityID), current == intent else { throw RegistrationError.ownerChanged }
        intent.registrationConfirmed = true; try service.activityKeys.save(intent)
        onRegistrationConfirmed?()
    }

    func revoke(_ revocation: BighelpLiveActivityRevocation) async throws {
        try check()
        guard let owner = service.ledger.activity(revocation.activityID), matches(owner),
              var intent = try service.activityKeys.load(revocation.activityID) else {
            // No token was ever sent (e.g. canonical native turn unavailable).
            return
        }
        guard inFlight.insert(revocation.activityID).inserted else { throw RegistrationError.pendingOriginalRequest }
        defer { inFlight.remove(revocation.activityID) }
        let proposed = try ManagedNotificationValidation.data(BighelpJSONValue.object([
            "version": .integer(2), "revision": .integer(max(revocation.revision, intent.revision + 1)),
            "timestamp": .integer(revocation.timestamp)]))
        if intent.pendingRevocationBody == nil { intent.pendingRevocationBody = proposed; try service.activityKeys.save(intent) }
        guard let body = intent.pendingRevocationBody,
              let values = try JSONDecoder().decode(BighelpJSONValue.self, from: body).object,
              let revision = values["revision"]?.integer else { throw RegistrationError.ownerChanged }
        let response: BighelpJSONValue?
        do {
            response = try await service.accountAPI().managedNotificationRequest(path: path(owner), method: "DELETE",
                body: body, credentials: credentials)
        } catch BighelpLinkAPIError.requestFailed(let status, let code)
                    where status == 404 && code == "notification_activity_unknown" {
            // The service never stored this card, usually because it refused the registration. There is
            // nothing to revoke, and asking again can only fail again. 409 and every other answer still
            // keep the revocation pending.
            response = nil
        }
        try check()
        if let response {
            try validateActivity(response, owner: owner, revision: revision, lease: nil, status: "revoked")
            BighelpLiveActivityLog.note(.revocationConfirmed)
        } else {
            BighelpLiveActivityLog.note(.revocationGone)
        }
        if BighelpActivityGroupDriver.physicalID(owner.nativeActivityID) == nil {
            try await BuzzKit.activities.end(id: owner.relayActivityID)
            // The shared card's address goes when the physical card ends (`onPhysicalEnded`), not with a row.
            let direct = service.pushRegistrar, relayID = owner.relayActivityID
            Task { await direct?.removeActivity(id: relayID) }
        }
        // Host removal only stops this local subscription; it is NOT revocation.
        let client = try service.client(for: host)
        _ = try await client.request("/enrollments/\(grant.grantId)/live-activities/\(owner.relayActivityID)", method: "DELETE", body: nil,
            isCurrent: { (try? self.check()) != nil })
        try check()
        var retired = owner; retired.retired = true; try service.ledger.save(retired)
        try service.activityKeys.remove(owner.relayActivityID)
    }

    /// Returns true only when an exact persisted pending revoke was completed.
    func resumePendingRevocation(_ owner: BighelpManagedActivityOwner) async throws -> Bool {
        try check()
        guard matches(owner), let request = try service.activityKeys.load(owner.relayActivityID),
              let body = request.pendingRevocationBody else { return false }
        guard let object = try JSONDecoder().decode(BighelpJSONValue.self, from: body).object,
              object["version"]?.integer == 2, let revision = object["revision"]?.integer,
              let timestamp = object["timestamp"]?.integer else { throw RegistrationError.ownerChanged }
        try await revoke(.init(activityID: owner.relayActivityID, revision: revision, timestamp: timestamp))
        return true
    }

    func restoreRegistration(_ owner: BighelpManagedActivityOwner) throws -> BighelpLiveActivityRegistration? {
        try check()
        guard matches(owner), !owner.retired, let intent = try service.activityKeys.load(owner.relayActivityID),
              matches(intent.owner), intent.pendingRevocationBody == nil else { return nil }
        return BighelpLiveActivityRegistration(activityID: owner.relayActivityID, sessionReference: intent.coordinatorReference,
            pushToken: intent.pushToken, revision: intent.revision, timestamp: intent.timestamp, leaseExpires: intent.leaseExpires)
    }
    private func makeIntent(_ owner: BighelpManagedActivityOwner, _ registration: BighelpLiveActivityRegistration,
                            body: Data) -> BighelpManagedActivityRequest {
        BighelpManagedActivityRequest(owner: owner, registrationBody: body,
            coordinatorReference: registration.sessionReference, pushToken: registration.pushToken,
            revision: registration.revision, timestamp: registration.timestamp, leaseExpires: registration.leaseExpires,
            pendingRevocationBody: nil, registrationConfirmed: false)
    }
    /// The service looked at the request and refused it. Timeouts, rate limits and 5xx are outages: retry.
    private static func refusesForGood(_ error: BighelpLinkAPIError) -> Bool {
        guard case .requestFailed(let status, _) = error else { return false }
        return (400..<500).contains(status) && ![408, 425, 429].contains(status)
    }
    private func check() throws {
        try service.requireCurrent(host, credentials: credentials)
        guard let current = service.ledger.record(host: host, profile: grant.profile), current.enabled,
              !current.revokePending, current.grant == grant else { throw RegistrationError.ownerChanged }
    }
    private func matches(_ owner: BighelpManagedActivityOwner) -> Bool {
        owner.accountScope == host.notificationScope && owner.accountID == (try? host.notificationAccountID()) && owner.hostConnectionID == host.hostConnectionID
            && owner.grantID == grant.grantId && owner.profile == grant.profile
            && owner.opaqueSessionID == ManagedNotificationValidation.nativeSessionID(host: host, profile: owner.profile, session: owner.storedSessionID)
    }
    private func path(_ owner: BighelpManagedActivityOwner) -> String {
        BighelpManagedNotificationService.root + "/\(grant.grantId)/live-activities/\(owner.relayActivityID)"
    }
    private func validateActivity(_ response: BighelpJSONValue, owner: BighelpManagedActivityOwner,
                                  revision: Int, lease: Int?, status: String) throws {
        guard let activity = response.object?["activity"]?.object,
              activity["grantId"]?.string == owner.grantID, activity["activityId"]?.string == owner.relayActivityID,
              activity["sessionReference"]?.string == ManagedNotificationValidation.sessionReference(profile: owner.profile, session: owner.storedSessionID),
              activity["revision"]?.integer == revision, activity["status"]?.string == status,
              lease == nil || activity["leaseExpires"]?.integer == lease else { throw DirectHermesError.invalidResponse }
    }
    private func coordinatorReference(_ opaque: String) -> String {
        BighelpLinkBase64URL.encode(Data(SHA256.hash(data: Data(opaque.utf8))))
    }
    private static func tokenData(_ value: String) -> Data? {
        guard !value.isEmpty, value.utf8.count <= 512, value.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data(); var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            data.append(byte); index = end
        }
        return data
    }
}

/// Filters ALL native operations and restoration through durable exact ownership.
/// This wrapper must also exclude `native-` IDs from the legacy Link driver at
/// App composition, so Link can never adopt a native host's ActivityKit record.
@MainActor
final class BighelpManagedActivityDriver: BighelpLiveActivityDriving {
    private let underlying: any BighelpLiveActivityDriving
    private let ledger: BighelpManagedNotificationLedger
    private let activityKeys: BighelpManagedActivityKeychain
    private let host: BighelpConfiguredHost
    private let grantID: String
    private let profile: String
    private let sessionID: String
    private let opaqueID: String
    private let localTurnID: String
    private var canonicalTurnID: String?
    private let firstObservedAt: Int
    private let initialState: LoopdySessionActivityAttributes.ContentState?
    private(set) var isRetired = false
    private var tokenContinuations: [String: AsyncStream<Data>.Continuation] = [:]

    /// Release actual system token rotation only after the original registration
    /// was reconciled. Unknown requests keep their original revision and bytes.
    func registrationConfirmed() {
        guard !isRetired else { return }
        for (id, continuation) in tokenContinuations {
            if owner(id) != nil, let token = underlying.currentPushToken(id: id) { continuation.yield(token) }
        }
    }
    private func canYield(_ token: Data, nativeID: String) -> Bool {
        do {
            guard let request = try activityKeys.load(Self.relayID(nativeID)) else { return true }
            return request.pendingRevocationBody == nil && (request.registrationConfirmed || Self.tokenData(request.pushToken) == token)
        } catch { return false }
    }

    init(underlying: any BighelpLiveActivityDriving, ledger: BighelpManagedNotificationLedger,
         activityKeys: BighelpManagedActivityKeychain, host: BighelpConfiguredHost,
         grantID: String, profile: String, sessionID: String, localTurnID: String,
         canonicalTurnID: String?, firstObservedAt: Int, initialState: LoopdySessionActivityAttributes.ContentState? = nil) {
        self.underlying = underlying; self.ledger = ledger; self.activityKeys = activityKeys; self.host = host; self.grantID = grantID
        self.profile = profile; self.sessionID = sessionID; self.localTurnID = localTurnID
        self.canonicalTurnID = canonicalTurnID; self.firstObservedAt = firstObservedAt; self.initialState = initialState
        opaqueID = ManagedNotificationValidation.nativeSessionID(host: host, profile: profile, session: sessionID)
    }
    func promote(to turn: String, state: LoopdySessionActivityAttributes.ContentState) async throws {
        guard canonicalTurnID == nil, !isRetired else { return }
        for var owner in ledger.activities where matches(owner) && !owner.retired {
            guard !owner.remoteOwned, try activityKeys.load(owner.relayActivityID) == nil else {
                throw DirectHermesError.identityChanged
            }
            owner.canonicalTurnID = turn
            try ledger.promote(owner)
            canonicalTurnID = turn
            await underlying.update(id: owner.nativeActivityID, state: state)
        }
        canonicalTurnID = turn
    }

    func existingActivities() -> [BighelpLiveActivitySnapshot] {
        guard !isRetired else { return [] }
        return underlying.existingActivities().compactMap { snapshot in
            guard snapshot.attributes.sessionID == opaqueID, let owner = self.owner(snapshot.nativeActivityID) else { return nil }
            // Restore the saved request's token first, even if ActivityKit rotated
            // while the app was dead. The live token stream below queues rotation
            // behind exact original-revision reconciliation in the coordinator.
            do {
                if let request = try activityKeys.load(owner.relayActivityID),
                   request.owner.nativeActivityID == owner.nativeActivityID,
                   request.owner.accountScope == owner.accountScope,
                   request.owner.grantID == owner.grantID,
                   let token = Self.tokenData(request.pushToken) {
                    return BighelpLiveActivitySnapshot(nativeActivityID: snapshot.nativeActivityID,
                        attributes: snapshot.attributes, state: snapshot.state, pushToken: token)
                }
            } catch { return nil } // protected/corrupt Keychain is not no record
            return snapshot
        }
    }
    func start(attributes: LoopdySessionActivityAttributes, state: LoopdySessionActivityAttributes.ContentState) throws -> String {
        guard !isRetired, attributes.sessionID == opaqueID else { throw DirectHermesError.secureStorageChanged }
        let nativeID = try underlying.start(attributes: attributes, state: initialState ?? state)
        let relayID = Self.relayID(nativeID)
        do {
            try ledger.save(BighelpManagedActivityOwner(accountScope: host.notificationScope, accountID: host.notificationAccountID(),
                hostConnectionID: host.hostConnectionID, grantID: grantID, profile: profile, storedSessionID: sessionID,
                opaqueSessionID: opaqueID, nativeActivityID: nativeID, relayActivityID: relayID,
                canonicalTurnID: canonicalTurnID, localTurnID: localTurnID, firstObservedAt: firstObservedAt,
                remoteOwned: false, retired: false))
        } catch {
            // Never expose a token for an unpersisted native owner.
            Task { await underlying.dismiss(id: nativeID, state: state) }
            throw error
        }
        return nativeID
    }
    func update(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        guard !isRetired, let owner = owner(id), writesLocally(owner) else { return }
        await underlying.update(id: id, state: state)
    }
    func end(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        guard !isRetired, let owner = owner(id), writesLocally(owner) else { return }
        await underlying.end(id: id, state: state)
    }
    /// A local-only card is this phone's to write. A card the service may hold is not, and neither is one
    /// that waits for its first registration. The exception is a card whose registration the service
    /// refused: nothing else can ever update or end it, so it goes back to this phone.
    private func writesLocally(_ owner: BighelpManagedActivityOwner) -> Bool {
        !owner.remoteOwned && (canonicalTurnID == nil || registrationRefused)
    }
    /// True from the service's refusal until a registration is confirmed. The saved request that was sent
    /// is still unconfirmed, and no request may have been accepted (`remoteOwned` is off).
    var registrationRefused: Bool {
        guard canonicalTurnID != nil, !isRetired else { return false }
        return ledger.activities.contains { owner in
            guard matches(owner), !owner.retired, !owner.remoteOwned,
                  let request = (try? activityKeys.load(owner.relayActivityID)) ?? nil else { return false }
            return !request.registrationConfirmed && request.pendingRevocationBody == nil
        }
    }
    func dismiss(id: String, state: LoopdySessionActivityAttributes.ContentState) async {
        guard owner(id, includeRetired: true) != nil else { return }
        await underlying.dismiss(id: id, state: state)
    }
    func currentPushToken(id: String) -> Data? {
        guard !isRetired, owner(id) != nil else { return nil }
        return underlying.currentPushToken(id: id)
    }
    func pushTokenUpdates(id: String) -> AsyncStream<Data> {
        guard !isRetired, owner(id) != nil else { return AsyncStream { $0.finish() } }
        let source = underlying.pushTokenUpdates(id: id)
        return AsyncStream { continuation in
            tokenContinuations[id]?.finish()
            tokenContinuations[id] = continuation
            if let token = underlying.currentPushToken(id: id), canYield(token, nativeID: id) { continuation.yield(token) }
            let task = Task { @MainActor [weak self] in
                for await token in source {
                    guard let self, !self.isRetired, self.owner(id) != nil, !Task.isCancelled else { break }
                    if self.canYield(token, nativeID: id) { continuation.yield(token) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func retire() {
        let snapshots = underlying.existingActivities().filter { owner($0.nativeActivityID, includeRetired: true) != nil }
        isRetired = true
        for continuation in tokenContinuations.values { continuation.finish() }
        tokenContinuations.removeAll()
        BighelpLiveActivityLog.note(.driverRetired, count: snapshots.count)
        for snapshot in snapshots { Task { await underlying.dismiss(id: snapshot.nativeActivityID, state: snapshot.state) } }
    }
    var remoteOwned: Bool { ledger.activities.contains { matches($0) && $0.remoteOwned && !$0.retired } }
    private func owner(_ nativeID: String, includeRetired: Bool = false) -> BighelpManagedActivityOwner? {
        guard let owner = ledger.activity(Self.relayID(nativeID)), owner.nativeActivityID == nativeID,
              matches(owner), includeRetired || !owner.retired else { return nil }
        return owner
    }
    private func matches(_ owner: BighelpManagedActivityOwner) -> Bool {
        owner.accountScope == host.notificationScope && owner.hostConnectionID == host.hostConnectionID
            && owner.grantID == grantID && owner.profile == profile && owner.storedSessionID == sessionID
            && owner.opaqueSessionID == opaqueID && owner.localTurnID == localTurnID && owner.canonicalTurnID == canonicalTurnID
    }
    private static func tokenData(_ value: String) -> Data? {
        guard !value.isEmpty, value.utf8.count <= 512, value.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data(); var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            data.append(byte); index = end
        }
        return data
    }
    static func relayID(_ nativeID: String) -> String {
        "activity_" + BighelpLinkBase64URL.encode(Data(SHA256.hash(data: Data(nativeID.utf8))))
    }
}
