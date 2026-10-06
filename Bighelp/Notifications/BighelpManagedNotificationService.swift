import Foundation

struct BighelpManagedNotificationSetupError: Error, LocalizedError, Equatable, Sendable {
    enum Stage: String, Equatable, Sendable {
        case providerBootstrap
        case providerIdentity
        case notificationPermission
        case deviceRegistration
        case providerReadiness
    }

    let stage: Stage
    let code: String?

    init(stage: Stage, code: String? = nil) {
        self.stage = stage
        self.code = code
    }

    /// The diagnostic code is appended when present so a failing stage names
    /// its failure mode in user-visible messages and logs.
    var errorDescription: String? {
        let base: String = switch stage {
        case .providerBootstrap:
            "Notification setup is unavailable. Update bighelp and try again."
        case .providerIdentity:
            "Notification setup failed. Try again."
        case .notificationPermission:
            "Allow notifications for bighelp in Settings, then try again."
        case .deviceRegistration:
            "bighelp could not register this device for notifications. Check notification access and try again."
        case .providerReadiness:
            "The notification provider has not confirmed this device yet. Try again."
        }
        if let code { return "\(base) (code: \(code))" }
        return base
    }
}

/// Where Turn off notifications is, for its progress line.
enum BighelpNotificationTurnOffStep: Equatable, Sendable {
    case hosts, service, device
}

struct BighelpNotificationTurnOffResult: Equatable, Sendable {
    /// Hosts that couldn't delete their copy yet. They can no longer send
    /// notifications, and bighelp asks them again later.
    let unreachableHosts: [String]
}

@MainActor
protocol BighelpManagedNotificationProvider: AnyObject {
    func identify(accountAPI: any BighelpManagedNotificationAccountAPI, credentials: BighelpManagedNotificationCredentials) async throws
    func registerCurrentDevice() async throws
    func refreshProviderReadiness(
        accountAPI: any BighelpManagedNotificationAccountAPI,
        credentials: BighelpManagedNotificationCredentials,
        requiringCurrentRegistration: Bool
    ) async throws -> BighelpBuzzKitProviderReadiness
    func retireIdentityForLocalErasure() async
}
extension BighelpBuzzKitRuntime: BighelpManagedNotificationProvider {}

@MainActor
final class BighelpManagedNotificationService: HostNotificationSetupServing {
    typealias HostClientFactory = @MainActor (BighelpConfiguredHost) throws -> any DirectHostNotificationServing
    private let buzzKit: any BighelpManagedNotificationProvider
    private let identity: BighelpNotificationIdentityCoordinator
    private let api: any BighelpManagedNotificationAccountAPI
    private let requestPermission: @MainActor () async throws -> Bool
    let registry: BighelpHostRegistry
    let ledger: BighelpManagedNotificationLedger
    let activityKeys: BighelpManagedActivityKeychain

    private let hostClient: HostClientFactory
    private let now: () -> Date
    private let sealedRecipientKeys: BighelpNotificationRecipientKeyStore
    private let sealedSenders: BighelpSealedAlertSenderStore
    private let defaults: UserDefaults
    private var enrolling = Set<String>()
    private var revocationInFlight = false
    private var opening: UUID?
    private var retiredHosts = Set<String>()
    var activityRuntime: BighelpManagedNativeActivityRuntime?

    /// Main's exact admitted projection seam. A raw event callback after model
    /// application is not enough to reconstruct parent final/turn ownership.
    var nativeEventObserver: (@MainActor (BighelpConfiguredHost, DirectHermesEvent) async -> Void)?

    init(identity: BighelpNotificationIdentityCoordinator, api: any BighelpManagedNotificationAccountAPI,
         requestPermission: @escaping @MainActor () async throws -> Bool,
         registry: BighelpHostRegistry, ledger: BighelpManagedNotificationLedger,
         activityKeys: BighelpManagedActivityKeychain = BighelpManagedActivityKeychain(),
         hostClient: @escaping HostClientFactory, now: @escaping () -> Date = Date.init,
         buzzKit: any BighelpManagedNotificationProvider = BighelpBuzzKitRuntime.shared,
         sealedRecipientKeys: BighelpNotificationRecipientKeyStore = BighelpSealedAlertRecipient.store,
         sealedSenders: BighelpSealedAlertSenderStore = BighelpSealedAlertSenderStore(),
         defaults: UserDefaults = .standard) {
        self.buzzKit = buzzKit
        self.defaults = defaults
        self.sealedRecipientKeys = sealedRecipientKeys; self.sealedSenders = sealedSenders
        self.identity = identity; self.api = api
        self.requestPermission = requestPermission
        self.registry = registry; self.ledger = ledger; self.activityKeys = activityKeys
        self.hostClient = hostClient; self.now = now
    }

    func enroll(host: BighelpConfiguredHost, connection: DirectHermesSavedConnection,
                isCurrent: @escaping @MainActor () -> Bool) async throws -> HostNotificationSetupResult {
        var host = host
        // Turning notifications on again replaces an unfinished turn-off.
        defaults.removeObject(forKey: Self.turnOffPendingKey)
        var credentials = try await identity.resolveForEnrollment()
        guard isCurrent(), registry.accountScope == host.accountScope,
              let current = registry.hosts.first(where: { $0.id == host.id }),
              current.principalIdentity == host.principalIdentity else {
            registry.notificationSetupError = "The selected Hermes instance changed while notification identity was being prepared."
            return .prerequisitesRequired
        }
        host = current
        func persistBinding() throws {
            let binding = BighelpHostNotificationBinding(
                deviceID: credentials.deviceID,
                authorizationEpoch: credentials.authorizationEpoch
            )
            if host.notificationBinding != nil && host.notificationBinding != binding {
                try removeLocalEnrollment(host: host)
            }
            host.notificationBinding = binding
            try registry.update(host)
        }
        try persistBinding()
        retiredHosts.remove(host.notificationScope + ":" + host.hostConnectionID)
        try requireCurrent(host, credentials: credentials)
        try ledger.pruneExpiredRevocations(accountScope: host.notificationScope, now: timestamp)
        let profile = registry.workspace(for: host).selectedProfile
        guard ManagedNotificationValidation.profile(profile), connection.endpoint == host.endpoint,
              host.owns(connection) else { throw DirectHermesError.identityChanged }
        let key = BighelpManagedNotificationLedger.key(scope: host.notificationScope, host: host.hostConnectionID, profile: profile)
        guard enrolling.insert(key).inserted else { throw DirectHermesError.tooManyRequests }
        defer { enrolling.remove(key) }
        @MainActor func check() throws {
            try requireCurrent(host, credentials: credentials)
            guard isCurrent(), registry.workspace(for: host).selectedProfile == profile else { throw DirectHermesError.secureStorageChanged }
        }
        try check()
        do {
            try await buzzKit.identify(accountAPI: api, credentials: credentials)
        } catch let error as BighelpManagedNotificationSetupError
            where error.stage == .providerIdentity && error.code == "notification_credentials_revoked" {
            credentials = try await identity.replaceRevokedForEnrollment(expected: credentials)
            try persistBinding()
            retiredHosts.remove(host.notificationScope + ":" + host.hostConnectionID)
            try requireCurrent(host, credentials: credentials)
            try await buzzKit.identify(accountAPI: api, credentials: credentials)
        }
        try check()
        // This is called only by the explicit setup Enable action, never startup.
        let permissionGranted = try await providerOperation(stage: .notificationPermission) {
            try await requestPermission()
        }
        try check()
        guard permissionGranted else {
            throw BighelpManagedNotificationSetupError(stage: .notificationPermission)
        }
        try check()
        try await providerOperation(stage: .deviceRegistration) {
            try await buzzKit.registerCurrentDevice()
        }
        try check()
        // Explicit enablement requires both this attempt's current registration
        // and provider status readback for that exact subscription before any
        // host grant can be created or claimed.
        _ = try await providerOperation(stage: .providerReadiness) {
            try await buzzKit.refreshProviderReadiness(
                accountAPI: api,
                credentials: credentials,
                requiringCurrentRegistration: true
            )
        }
        try check()
        let client = try hostClient(host)
        let capabilities: BighelpManagedCapabilities
        do {
            capabilities = try ManagedNotificationValidation.decode(BighelpManagedCapabilities.self,
                from: await client.request("/capabilities", method: "GET", body: nil, isCurrent: { (try? check()) != nil }))
        } catch DirectHostNotificationError.backendRestartRequired { try check(); return .backendRestartRequired }
        try check(); try capabilities.validate()
        guard capabilities.managedEnrollmentSupported, capabilities.supportsCompletionEnrollment else { return .prerequisitesRequired }
        var record = ledger.record(host: host, profile: profile) ?? BighelpManagedEnrollmentRecord(
            accountScope: host.notificationScope, accountID: credentials.deviceID, hostConnectionID: host.hostConnectionID,
            profile: profile, creationBody: nil, enrollmentID: UUID().uuidString.lowercased(), grant: nil,
            richLiveActivitySupported: (capabilities.richLiveActivitySupported ?? capabilities.producerCapabilities.richLiveActivity),
            enabled: false, revokePending: false, subscriptions: [])
        if record.revokePending {
            try await reconcilePendingRevocations(); try check()
            guard let recovered = ledger.record(host: host, profile: profile), !recovered.revokePending else {
                throw DirectHermesError.secureStorageChanged
            }
            record = recovered
        }
        if let pin = record.grant {
            guard pin.hostPublicKey == capabilities.hostPublicKey, pin.hostKeyId == capabilities.hostKeyId else {
                throw DirectHermesError.identityChanged
            }
        }
        var listed = try await list(credentials)
        try check()
        for stale in listed where stale.hostPublicKey == capabilities.hostPublicKey
            && stale.hostKeyId == capabilities.hostKeyId && stale.profile == profile
            && stale.state != "revoked" && stale.expiresAt <= timestamp {
            record.grant = stale; record.enabled = false; record.revokePending = true
            try ledger.save(record)
            let body = try ManagedNotificationValidation.data(BighelpJSONValue.object([
                "version": .integer(2), "expectedRevision": .integer(stale.revision)]))
            let deleted = try ManagedNotificationValidation.grant(await api.managedNotificationRequest(
                path: Self.root + "/" + stale.grantId, method: "DELETE", body: body, credentials: credentials))
            try check()
            guard deleted.grantId == stale.grantId, deleted.state == "revoked" else { throw DirectHermesError.invalidResponse }
            listed = try await list(credentials); try check()
            guard listed.contains(where: { $0.grantId == stale.grantId && $0.state == "revoked" }) else {
                throw DirectHermesError.invalidResponse
            }
            record.grant = nil; record.creationBody = nil; record.revokePending = false
            record.subscriptions = []; record.enrollmentID = UUID().uuidString.lowercased()
            try ledger.save(record)
        }
        if let old = record.grant, listed.contains(where: { $0.grantId == old.grantId && $0.state == "revoked" }) {
            record.grant = nil; record.creationBody = nil; record.subscriptions = []; record.enabled = false
            record.enrollmentID = UUID().uuidString.lowercased(); try ledger.save(record)
        }
        // An earlier release could persist enabled metadata for the legacy topic
        // layout. Explicit opt-in authorizes replacing that grant; loading saved
        // metadata or opening Settings never widens an existing authority.
        let expectedEvents = capabilities.enrollmentEventTypes
        let obsolete = listed.filter {
            $0.hostPublicKey == capabilities.hostPublicKey && $0.hostKeyId == capabilities.hostKeyId
                && $0.profile == profile && $0.authorizationEpoch == credentials.authorizationEpoch
                && $0.state != "revoked" && $0.expiresAt > timestamp
                && ($0.instanceId != host.hostConnectionID.lowercased() || Set($0.eventTypes) != expectedEvents)
        }
        guard obsolete.count <= 1 else { throw DirectHermesError.invalidResponse }
        if let stale = obsolete.first {
            record.grant = stale; record.enabled = false; record.revokePending = true
            try ledger.save(record)
            let body = try ManagedNotificationValidation.data(BighelpJSONValue.object([
                "version": .integer(2), "expectedRevision": .integer(stale.revision)]))
            let deleted = try ManagedNotificationValidation.grant(await api.managedNotificationRequest(
                path: Self.root + "/" + stale.grantId, method: "DELETE", body: body, credentials: credentials))
            try check()
            guard deleted.grantId == stale.grantId, deleted.state == "revoked" else {
                throw DirectHermesError.invalidResponse
            }
            listed = try await list(credentials); try check()
            guard listed.contains(where: { $0.grantId == stale.grantId && $0.state == "revoked" }) else {
                throw DirectHermesError.invalidResponse
            }
            record.grant = nil; record.creationBody = nil; record.revokePending = false
            record.subscriptions = []; record.enrollmentID = UUID().uuidString.lowercased()
            try ledger.save(record)
        }
        let matches = listed.filter { $0.hostPublicKey == capabilities.hostPublicKey && $0.hostKeyId == capabilities.hostKeyId
            && $0.profile == profile && $0.authorizationEpoch == credentials.authorizationEpoch
            && $0.state != "revoked" && $0.expiresAt > timestamp
            && $0.instanceId == host.hostConnectionID.lowercased()
            && ManagedNotificationValidation.validEnrollmentEventTypes($0.eventTypes) }
        guard matches.count <= 1 else { throw DirectHermesError.invalidResponse }
        var grant: BighelpManagedGrant
        if let existing = matches.first {
            if let pinned = record.grant, pinned.expiresAt > timestamp, pinned.grantId != existing.grantId {
                throw DirectHermesError.identityChanged
            }
            if let pinned = record.grant, !pinned.sameAuthority(as: existing) {
                throw DirectHermesError.identityChanged
            }
            if let frozen = record.creationBody {
                let intent = try JSONDecoder().decode(BighelpManagedGrantIntent.self, from: frozen)
                guard Set(intent.eventTypes) == Set(existing.eventTypes), intent.expiresAt == existing.expiresAt else {
                    throw DirectHermesError.identityChanged
                }
            }
            grant = existing
        } else {
            if record.creationBody == nil {
                let intent = BighelpManagedGrantIntent(version: 3, idempotencyKey: UUID().uuidString.lowercased(),
                    instanceId: host.hostConnectionID.lowercased(),
                    hostPublicKey: capabilities.hostPublicKey, hostKeyId: capabilities.hostKeyId, profile: profile,
                    eventTypes: capabilities.enrollmentEventTypes.sorted(),
                    expiresAt: timestamp + 2_592_000)
                record.creationBody = try ManagedNotificationValidation.data(intent)
                try check(); try ledger.save(record) // durable BEFORE cloud mutation
            }
            guard let body = record.creationBody else { throw DirectHermesError.savedConnectionInvalid }
            let intent = try JSONDecoder().decode(BighelpManagedGrantIntent.self, from: body)
            guard intent.version == 3, ManagedNotificationValidation.uuid(intent.idempotencyKey),
                  intent.instanceId == host.hostConnectionID.lowercased(),
                  intent.hostPublicKey == capabilities.hostPublicKey, intent.hostKeyId == capabilities.hostKeyId,
                  intent.profile == profile, ManagedNotificationValidation.validEnrollmentEventTypes(intent.eventTypes) else {
                throw DirectHermesError.identityChanged
            }
            // Unknown outcome retains these exact bytes; never generates a new key.
            grant = try ManagedNotificationValidation.grant(await api.managedNotificationRequest(
                path: Self.root, method: "POST", body: body, credentials: credentials))
            try check()
            guard Set(grant.eventTypes) == Set(intent.eventTypes), grant.expiresAt == intent.expiresAt else {
                throw DirectHermesError.identityChanged
            }
        }
        record.richLiveActivitySupported = (capabilities.richLiveActivitySupported ?? capabilities.producerCapabilities.richLiveActivity)
        try validate(grant, host: host, profile: profile, credentials: credentials)
        guard grant.hostKeyId == capabilities.hostKeyId, grant.hostPublicKey == capabilities.hostPublicKey else {
            throw DirectHermesError.identityChanged
        }

        // A grant cannot silently migrate between two configured local hosts.
        guard !ledger.enrollments.contains(where: { $0.grant?.grantId == grant.grantId
            && ($0.accountScope != host.notificationScope || $0.hostConnectionID != host.hostConnectionID) }) else {
            throw DirectHermesError.identityChanged
        }
        record.grant = grant
        try ledger.save(record)
        let claimed = try ManagedNotificationValidation.grant(await client.request("/enroll", method: "POST",
            body: ["version": .integer(1), "idempotencyKey": .string(record.enrollmentID), "grantId": .string(grant.grantId)],
            isCurrent: { (try? check()) != nil }))
        try check()
        guard grant.sameAuthority(as: claimed), claimed.state == "active" else { throw DirectHermesError.invalidResponse }
        let observed = try ManagedNotificationValidation.grant(await client.request("/enrollments/" + grant.grantId,
            method: "GET", body: nil, isCurrent: { (try? check()) != nil }))
        try check()
        guard claimed == observed else { throw DirectHermesError.invalidResponse }
        grant = observed; record.grant = grant; record.enabled = true
        record.creationBody = nil
        try ledger.save(record)
        if capabilities.supportsSealedAlerts {
            try await registerSealedRecipient(host: host, profile: profile, grant: grant, client: client,
                                              isCurrent: { (try? check()) != nil })
            try check()
        }
        // Quiet Hours never hold up notifications: an older plugin or a miss now is
        // retried when a chat opens or the setting changes.
        _ = try? await syncQuietHours(host: host, profile: profile, grant: grant, client: client,
                                      isCurrent: { (try? check()) != nil })
        try check()
        // Enrollment from Settings can occur after the selected chat was already
        // opened. Subscribe that exact authenticated session now; later chats use
        // the normal onChatOpened hook.
        if let chat = registry.workspace(for: host).selectedChat {
            try await onChatOpened(host: host, chat: chat)
            try check()
        }
        return .enabled
    }

    func ownsChat(host: BighelpConfiguredHost, client: DirectHermesConversationClient) -> Bool {
        guard let authority = client.nativeWorkspaceAuthority else {
            return !host.isIndependent && client.journal.owner?.hostIdentity == host.principalIdentity
        }
        guard let saved = try? registry.credentialVault(for: host).load(),
              saved.identity == host.principalIdentity, saved.endpoint == host.endpoint,
              let expected = saved.workspaceAuthority else { return false }
        return authority == expected && client.journal.owner?.hostIdentity == expected.cacheScopeID
    }

    /// Subscription begins only after the actual native chat has opened/recovered.
    func onChatOpened(host: BighelpConfiguredHost, chat: DirectHermesChat) async throws {
        let profile = chat.client.profile; let session = chat.client.storedID
        // Ordinary chat opening is not notification opt-in. Do not require a
        // notification identity or contact either service without a live grant.
        guard ManagedNotificationValidation.coordinate(session),
              var record = ledger.record(host: host, profile: profile), record.enabled, !record.revokePending,
              let grant = record.grant, grant.state == "active", grant.expiresAt > timestamp else { return }
        let credentials = try self.credentials(for: host)
        guard ownsChat(host: host, client: chat.client) else { return }
        let client = try hostClient(host)
        let loaded = try ManagedNotificationValidation.decode(BighelpManagedCapabilities.self,
            from: await client.request("/capabilities", method: "GET", body: nil,
                isCurrent: { (try? self.requireCurrent(host, credentials: credentials)) != nil }))
        try loaded.validate()
        guard loaded.hostKeyId == grant.hostKeyId, loaded.hostPublicKey == grant.hostPublicKey,
              loaded.managedEnrollmentSupported, loaded.supportsCompletionEnrollment else {
            throw DirectHermesError.notConnected
        }
        if loaded.supportsSealedAlerts {
            // Grants made before the host could seal alerts start sealing here.
            try await registerSealedRecipient(host: host, profile: profile, grant: grant, client: client,
                                              isCurrent: { (try? self.requireCurrent(host, credentials: credentials)) != nil })
            try requireCurrent(host, credentials: credentials)
            guard let refreshed = ledger.record(host: host, profile: profile) else { return }
            record = refreshed
        }
        if loaded.supportsPeerChatPreference {
            try await syncAlertPreferences(host: host, profile: profile, grant: grant, client: client,
                                           workflows: loaded.supportsWorkflowAlertPreferences,
                                           isCurrent: { (try? self.requireCurrent(host, credentials: credentials)) != nil })
            try requireCurrent(host, credentials: credentials)
        }
        // Also catches a device that moved to another time zone since it last sent them.
        _ = try? await syncQuietHours(host: host, profile: profile, grant: grant, client: client,
                                      isCurrent: { (try? self.requireCurrent(host, credentials: credentials)) != nil })
        try requireCurrent(host, credentials: credentials)
        let value = try await client.request("/enrollments/\(grant.grantId)/sessions", method: "PUT", body: [
            "version": .integer(1), "profile": .string(profile), "sessionId": .string(session), "enabled": .boolean(true)
        ], isCurrent: { (try? self.requireCurrent(host, credentials: credentials)) != nil })
        try requireCurrent(host, credentials: credentials)
        guard let object = value.object, object["grantId"]?.string == grant.grantId,
              object["profile"]?.string == profile, object["sessionId"]?.string == session,
              object["sessionReference"]?.string == ManagedNotificationValidation.sessionReference(profile: profile, session: session),
              object["enabled"]?.boolean == true, chat.client.storedID == session,
              let current = ledger.record(host: host, profile: profile), current.enabled,
              current.grant == grant, !current.revokePending else { throw DirectHermesError.invalidResponse }
        record = current; record.subscriptions.insert(session); try ledger.save(record)
    }

    /// Peer chats (agents talking to each other) alert this phone only when it turned them on; each
    /// kind of workflow alert unless it turned that off (hosts with `preferences.workflows`).
    /// Sent only when the host's confirmed choices differ from this phone's.
    private func syncAlertPreferences(host: BighelpConfiguredHost, profile: String, grant: BighelpManagedGrant,
                                      client: any DirectHostNotificationServing, workflows: Bool,
                                      isCurrent: @escaping @MainActor () -> Bool) async throws {
        let wanted = BighelpPeerChatAlerts.isOn
        let wantedWorkflows = workflows ? BighelpWorkflowAlerts.current : nil
        let record = ledger.record(host: host, profile: profile)
        guard record?.peerChatsAlert != wanted
                || (wantedWorkflows != nil && record?.workflowAlertsSent != wantedWorkflows) else { return }
        var body: [String: BighelpJSONValue] = ["version": .integer(1), "peerChats": .boolean(wanted)]
        if let wantedWorkflows { body["workflows"] = .object(wantedWorkflows.mapValues(BighelpJSONValue.boolean)) }
        let value = try await client.request("/enrollments/\(grant.grantId)/preferences", method: "PUT", body: body,
                                             isCurrent: isCurrent)
        let confirmed = value.object?["workflows"]?.object?.compactMapValues(\.boolean)
        guard isCurrent(), value.object?["peerChats"]?.boolean == wanted,
              wantedWorkflows == nil || confirmed == wantedWorkflows,
              var current = ledger.record(host: host, profile: profile), current.grant == grant else {
            throw DirectHermesError.invalidResponse
        }
        current.peerChatsAlert = wanted
        if let wantedWorkflows { current.workflowAlertsSent = wantedWorkflows }
        try ledger.save(current)
    }

    /// Settings › Notifications › Peer chats or Workflows changed: tell every computer with notifications on.
    /// A computer that can't be reached now gets it the next time a chat opens there.
    func applyAlertPreferences() async {
        for record in ledger.enrollments where record.enabled && !record.revokePending {
            guard let grant = record.grant, grant.state == "active", grant.expiresAt > timestamp,
                  let host = registry.hosts.first(where: {
                      $0.hostConnectionID == record.hostConnectionID && $0.notificationScope == record.accountScope
                  }),
                  let credentials = try? self.credentials(for: host),
                  let client = try? hostClient(host) else { continue }
            let isCurrent: @MainActor () -> Bool = { (try? self.requireCurrent(host, credentials: credentials)) != nil }
            guard let raw = try? await client.request("/capabilities", method: "GET", body: nil, isCurrent: isCurrent),
                  let loaded = try? ManagedNotificationValidation.decode(BighelpManagedCapabilities.self, from: raw),
                  loaded.supportsPeerChatPreference else { continue }
            try? await syncAlertPreferences(host: host, profile: record.profile, grant: grant, client: client,
                                            workflows: loaded.supportsWorkflowAlertPreferences, isCurrent: isCurrent)
        }
    }

    /// Quiet Hours: the window this device keeps and its own time zone, so the computer
    /// skips alerts by the device's clock. Sent only when the computer's confirmed copy differs.
    /// Returns false when the computer's plugin doesn't have Quiet Hours yet.
    @discardableResult
    private func syncQuietHours(host: BighelpConfiguredHost, profile: String, grant: BighelpManagedGrant,
                                client: any DirectHostNotificationServing,
                                isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        let wanted = BighelpQuietHours.Sent(quietHours: BighelpQuietHours.load(defaults),
                                            timeZone: BighelpQuietHours.timeZoneID())
        let sent = ledger.record(host: host, profile: profile)?.quietHoursSent
        // A host without a window already sends everything: off and never sent needs no request.
        guard sent != wanted, sent != nil || wanted.quietHours.enabled else { return true }
        let value: BighelpJSONValue
        do {
            value = try await client.nativeRequest(
                BighelpQuietHours.route, feature: BighelpQuietHours.feature,
                body: wanted.quietHours.body(grantID: grant.grantId, timeZone: wanted.timeZone), isCurrent: isCurrent)
        } catch DirectHostNotificationError.featureUnavailable {
            return false
        }
        let confirmed = value.object?["quietHours"]?.object
        guard isCurrent(), value.object?["grantId"]?.string == grant.grantId,
              confirmed?["enabled"]?.boolean == wanted.quietHours.enabled,
              confirmed?["startMinute"]?.integer == wanted.quietHours.startMinute,
              confirmed?["endMinute"]?.integer == wanted.quietHours.endMinute,
              confirmed?["timeZone"]?.string == wanted.timeZone,
              var current = ledger.record(host: host, profile: profile), current.grant == grant else {
            throw DirectHermesError.invalidResponse
        }
        current.quietHoursSent = wanted
        try ledger.save(current)
        return true
    }

    /// Settings › Notifications › Quiet Hours changed: tell every computer with notifications on.
    /// A computer that can't be reached now gets it the next time a chat opens there.
    func applyQuietHours() async -> BighelpQuietHoursSyncResult {
        var outdated: [String] = []
        for record in ledger.enrollments where record.enabled && !record.revokePending {
            guard let grant = record.grant, grant.state == "active", grant.expiresAt > timestamp,
                  let host = registry.hosts.first(where: {
                      $0.hostConnectionID == record.hostConnectionID && $0.notificationScope == record.accountScope
                  }),
                  let credentials = try? self.credentials(for: host),
                  let client = try? hostClient(host) else { continue }
            let isCurrent: @MainActor () -> Bool = { (try? self.requireCurrent(host, credentials: credentials)) != nil }
            if (try? await syncQuietHours(host: host, profile: record.profile, grant: grant, client: client,
                                          isCurrent: isCurrent)) == false, !outdated.contains(host.name) {
                outdated.append(host.name)
            }
        }
        return BighelpQuietHoursSyncResult(needsPluginUpdate: outdated)
    }


    /// Gives the host this phone's sealed-alert key, directly and never through the
    /// notification service, and pins the host key that signs the sealed alerts.
    private func registerSealedRecipient(host: BighelpConfiguredHost, profile: String, grant: BighelpManagedGrant,
                                         client: any DirectHostNotificationServing,
                                         isCurrent: @escaping @MainActor () -> Bool) async throws {
        let key = try BighelpSealedAlertRecipient.key(store: sealedRecipientKeys)
        let keyID = BighelpSealedAlert.keyID(key.publicKey.x963Representation)
        let sender = BighelpSealedAlertSender(grantID: grant.grantId, hostKeyID: grant.hostKeyId,
                                              hostPublicKey: grant.hostPublicKey, expiresAt: grant.expiresAt)
        // Trust first: an alert sealed the moment the key lands must already open.
        try sealedSenders.upsert(sender, now: timestamp)
        guard ledger.record(host: host, profile: profile)?.sealedRecipientKeyID != keyID else { return }
        let value = try await client.request("/enrollments/\(grant.grantId)/recipient-key", method: "PUT", body: [
            "version": .integer(1), "publicKey": .string(BighelpSealedAlertRecipient.publicKey(key))
        ], isCurrent: isCurrent)
        guard isCurrent(), value.object?["recipientKeyId"]?.string == keyID,
              var current = ledger.record(host: host, profile: profile), current.grant == grant else {
            throw DirectHermesError.invalidResponse
        }
        current.sealedRecipientKeyID = keyID
        try ledger.save(current)
    }

    /// This device's grants on a computer that can send it sealed alerts straight
    /// away while bighelp is open: on, current, with its key registered and the
    /// computer's signing key pinned here.
    func liveAlertGrants(host: BighelpConfiguredHost) -> [BighelpLiveAlertListener.Grant] {
        ledger.enrollments.compactMap { record -> BighelpLiveAlertListener.Grant? in
            guard record.accountScope == host.notificationScope, record.hostConnectionID == host.hostConnectionID,
                  record.enabled, !record.revokePending, let grant = record.grant, grant.state == "active",
                  grant.expiresAt > timestamp, let keyID = record.sealedRecipientKeyID,
                  (try? sealedSenders.sender(grantID: grant.grantId, now: timestamp)) != nil else { return nil }
            return BighelpLiveAlertListener.Grant(grantID: grant.grantId, recipientKeyID: keyID)
        }
    }

    func receive(host: BighelpConfiguredHost, event: DirectHermesEvent) async {
        guard (try? credentials(for: host)) != nil else { return }
        await nativeEventObserver?(host, event)
    }

    /// The event coordinate comes from the BuzzKit/APNs payload, but authority is
    /// re-established from the local grant ledger and authenticated host readback.
    /// The computer an alert came from, from what's saved on the phone (its grant), without asking it.
    func host(forEvent eventID: String, eventType: String) -> BighelpConfiguredHost? {
        let pieces = eventID.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, ManagedNotificationValidation.eventTypes.contains(eventType) else { return nil }
        let matches = ledger.enrollments.filter { record in
            record.enabled && !record.revokePending && record.grant?.grantId == String(pieces[0])
                && record.grant?.eventTypes.contains(eventType) == true
        }
        guard matches.count == 1, let record = matches.first else { return nil }
        return registry.hosts.first {
            $0.notificationScope == record.accountScope && $0.hostConnectionID == record.hostConnectionID
        }
    }

    func openVerifiedEvent(eventID: String, eventType: String,
                           isCurrent: @escaping @MainActor () -> Bool) async throws -> DirectHermesChat {
        let pieces = eventID.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, ManagedNotificationValidation.uuid(String(pieces[0])), pieces[1].utf8.count == 64,
              pieces[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              ManagedNotificationValidation.eventTypes.contains(eventType) else { throw DirectHermesError.invalidResponse }
        let matches = ledger.enrollments.filter { record in
            record.enabled && !record.revokePending && record.grant?.grantId == String(pieces[0])
                && record.grant?.eventTypes.contains(eventType) == true
                && (record.grant?.expiresAt ?? 0) > timestamp
        }
        guard matches.count == 1, let record = matches.first,
              let host = registry.hosts.first(where: {
                  $0.notificationScope == record.accountScope
                      && $0.hostConnectionID == record.hostConnectionID
              }) else { throw DirectHermesError.invalidCredentials }
        let credentials = try self.credentials(for: host)
        let generation = registry.generation; let navigation = UUID(); opening = navigation
        defer { if opening == navigation { opening = nil } }
        @MainActor func check() throws {
            try requireCurrent(host, credentials: credentials)
            guard isCurrent(), opening == navigation, registry.generation == generation else { throw DirectHermesError.secureStorageChanged }
        }
        let client = try hostClient(host)
        guard let activeGrant = record.grant else { throw DirectHermesError.invalidCredentials }
        let response = try await client.request("/enrollments/\(activeGrant.grantId)/events/\(eventID)", method: "GET", body: nil,
            isCurrent: { (try? check()) != nil })
        try check()
        guard let value = response.object?["event"] else { throw DirectHermesError.invalidResponse }
        let detail = try ManagedNotificationValidation.decode(BighelpManagedEventDetail.self, from: value)
        let expectedContentKind = eventType == "approval.required" ? "approval"
            : eventType == "clarification.required" ? "clarification"
            : eventType.hasPrefix("scheduled.") ? "scheduled"
            : eventType.hasPrefix("subagent.") ? "subagent"
            : eventType == "session.failed" ? "failure" : "reply"
        guard detail.eventId == eventID, detail.eventType == eventType, detail.profile == record.profile,
              ManagedNotificationValidation.coordinate(detail.sessionId), ManagedNotificationValidation.coordinate(detail.turnId),
              detail.agent.id == detail.profile, !detail.agent.name.isEmpty, detail.agent.name.utf8.count <= 80,
              detail.agent.avatarSha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !detail.content.text.isEmpty, detail.content.text.count <= 1_600,
              detail.content.kind == expectedContentKind,
              detail.occurredAt >= (record.grant?.createdAt ?? Int.max),
              detail.occurredAt <= min(timestamp + 120, record.grant?.expiresAt ?? 0) else { throw DirectHermesError.invalidResponse }
        registry.select(host.id)
        guard registry.selectedHostID == host.id else { throw DirectHermesError.secureStorageChanged }
        let selectedGeneration = registry.generation
        let workspace = registry.workspace(for: host)
        if !workspace.isConnected { await workspace.reconnect() }
        try requireCurrent(host, credentials: credentials)
        guard isCurrent(), opening == navigation, registry.generation == selectedGeneration, registry.selectedHostID == host.id,
              workspace.isConnected else { throw DirectHermesError.notConnected }
        return try await workspace.visiting(profile: detail.profile) {
            await workspace.loadSessions()
            try requireCurrent(host, credentials: credentials)
            guard isCurrent(), opening == navigation, registry.generation == selectedGeneration,
                  workspace.selectedProfile == detail.profile,
                  let summary = workspace.sessions.first(where: { $0.storedID == detail.sessionId && $0.profile == detail.profile }),
                  summary.supportsNativeResume else { throw DirectHermesError.invalidResponse }
            await workspace.openSession(summary)
            try requireCurrent(host, credentials: credentials)
            guard isCurrent(), opening == navigation, registry.generation == selectedGeneration, registry.selectedHostID == host.id,
                  let chat = workspace.selectedChat, chat.client.profile == detail.profile,
                  chat.client.storedID == detail.sessionId else { throw DirectHermesError.invalidResponse }
            return chat
        }
    }

    /// Synchronous removal preserves cloud revoke intent before local retirement.
    /// Main may await revoke(host:) first; offline removal still stops local use.
    func removeLocalEnrollment(host: BighelpConfiguredHost) throws {
        let grants = ledger.enrollments.filter {
            $0.accountScope == host.notificationScope && $0.hostConnectionID == host.hostConnectionID
        }.compactMap { $0.grant?.grantId }
        try? sealedSenders.remove(grantIDs: Set(grants))
        try ledger.retire(host: host)
        retiredHosts.insert(host.notificationScope + ":" + host.hostConnectionID)
        activityRuntime?.retire(host: host)

    }

    func revoke(host: BighelpConfiguredHost) async throws {
        _ = try credentials(for: host)
        try removeLocalEnrollment(host: host)
        try await reconcilePendingRevocations()
    }

    /// Account-signed revocation needs no host credential/socket. Invoke on account
    /// readiness and explicit retry, including after a host was removed offline.
    func reconcilePendingRevocations() async throws {
        guard !revocationInFlight else { throw DirectHermesError.tooManyRequests }
        revocationInFlight = true; defer { revocationInFlight = false }
        guard let credentials = try identity.current() else { return }
        let scope = ManagedNotificationValidation.digest(credentials.deviceID + ":" + String(credentials.authorizationEpoch))
        for var record in ledger.enrollments where record.accountScope == scope && record.revokePending {
            if record.grant == nil, let originalBody = record.creationBody {
                // Resolve the original idempotency key, including a lost create
                // response. Never drop an unknown grant just because host removal
                // happened before its ID reached the phone.
                guard try identity.current() == credentials else { throw DirectHermesError.secureStorageChanged }
                let intent = try JSONDecoder().decode(BighelpManagedGrantIntent.self, from: originalBody)
                guard [2, 3].contains(intent.version), intent.profile == record.profile,
                      intent.instanceId == nil || intent.instanceId == record.hostConnectionID.lowercased() else {
                    throw DirectHermesError.savedConnectionInvalid
                }
                let candidates = try await list(credentials)
                guard try identity.current() == credentials else { throw DirectHermesError.secureStorageChanged }
                let matches = candidates.filter { $0.profile == intent.profile && $0.hostKeyId == intent.hostKeyId
                    && $0.hostPublicKey == intent.hostPublicKey && $0.expiresAt == intent.expiresAt
                    && (intent.instanceId == nil || $0.instanceId == intent.instanceId)
                    && $0.authorizationEpoch == credentials.authorizationEpoch }
                if matches.count == 1 { record.grant = matches[0] }
                else {
                    guard matches.isEmpty else { throw DirectHermesError.invalidResponse }
                    record.grant = try ManagedNotificationValidation.grant(await api.managedNotificationRequest(
                        path: Self.root, method: "POST", body: originalBody, credentials: credentials))
                    guard try identity.current() == credentials else { throw DirectHermesError.secureStorageChanged }
                }
                guard ledger.enrollments.contains(where: { $0.accountScope == record.accountScope
                    && $0.hostConnectionID == record.hostConnectionID && $0.profile == record.profile
                    && $0.revokePending && $0.creationBody == originalBody && $0.grant == nil }) else { continue }
                try ledger.save(record)
            }
            guard let grant = record.grant else { continue }
            guard try identity.current() == credentials else { throw DirectHermesError.secureStorageChanged }
            let body = try ManagedNotificationValidation.data(BighelpJSONValue.object([
                "version": .integer(2), "expectedRevision": .integer(grant.revision)]))
            let deleted = try ManagedNotificationValidation.grant(await api.managedNotificationRequest(
                path: Self.root + "/" + grant.grantId, method: "DELETE", body: body, credentials: credentials))
            guard try identity.current() == credentials, deleted.grantId == grant.grantId, deleted.state == "revoked" else {
                throw DirectHermesError.secureStorageChanged
            }
            let readback = try await list(credentials)
            guard try identity.current() == credentials, readback.contains(where: { $0.grantId == grant.grantId && $0.state == "revoked" }) else {
                throw DirectHermesError.invalidResponse
            }
            guard ledger.enrollments.contains(where: { $0.accountScope == record.accountScope
                && $0.hostConnectionID == record.hostConnectionID && $0.profile == record.profile
                && $0.revokePending && $0.grant?.grantId == grant.grantId }) else { continue }
            record.grant = deleted; record.revokePending = false; record.enabled = false; record.creationBody = nil
            try ledger.save(record)
            for owner in ledger.activities where owner.grantID == grant.grantId { try activityKeys.remove(owner.relayActivityID) }
        }
    }

    /// Fence old callbacks synchronously before changing registry/vault ownership.
    /// Cloud device/account revocation belongs to the existing account flow.
    func retireForAccountBoundary() {
        opening = nil
        for host in registry.hosts {
            retiredHosts.insert(host.notificationScope + ":" + host.hostConnectionID)
            activityRuntime?.retire(host: host)
        }
    }
    // MARK: Turn off notifications

    /// Anything left to turn off: an identity, grants, a host marked enabled,
    /// or a turn-off still finishing.
    var hasNotificationData: Bool {
        (try? identity.current()) != nil || !ledger.enrollments.isEmpty || turnOffPending
            || !pendingHostCleanups.isEmpty
            || registry.hosts.contains { $0.notificationBinding != nil || $0.notificationState != .notConfigured }
    }

    /// Settings › Notifications › Turn off. Leaves this device as if
    /// notifications were never turned on: every host deletes its copy, the
    /// notification service revokes every grant and this installation (which
    /// deletes the BuzzKit subscriber, its devices and preferences), and the
    /// keys, ledger and per-host flags on this device go. A host that can't be
    /// reached is listed and retried later; it can no longer send anything.
    func turnOffNotifications(
        progress: @MainActor (BighelpNotificationTurnOffStep) -> Void = { _ in }
    ) async throws -> BighelpNotificationTurnOffResult {
        // Durable first: until the service confirms, launch and foreground
        // recovery finish the turn-off instead of identifying again.
        defaults.set(true, forKey: Self.turnOffPendingKey)
        var cleanups = pendingHostCleanups
        for host in registry.hosts {
            let grants = ledger.enrollments.filter {
                $0.accountScope == host.notificationScope && $0.hostConnectionID == host.hostConnectionID
            }.compactMap { $0.grant?.grantId }
            if !grants.isEmpty { cleanups[host.id.uuidString, default: []].formUnion(grants) }
        }
        pendingHostCleanups = cleanups

        // This device stops using notifications at once.
        retireForAccountBoundary()
        for host in registry.hosts { try ledger.retire(host: host) }
        await activityRuntime?.resetForAccountBoundary()
        await buzzKit.retireIdentityForLocalErasure()

        progress(.hosts)
        let unreachable = await retryPendingHostCleanups()

        progress(.service)
        do {
            try await reconcilePendingRevocations()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Revoking the installation below revokes every grant it holds.
        }
        try await identity.erase()

        progress(.device)
        try ledger.erase()
        try? sealedRecipientKeys.remove()
        try? sealedSenders.removeAll()
        try? activityKeys.removeAll()
        for var host in registry.hosts where host.notificationBinding != nil || host.notificationState != .notConfigured {
            host.notificationBinding = nil
            host.notificationState = .notConfigured
            try registry.update(host)
        }
        retiredHosts.removeAll()
        defaults.removeObject(forKey: Self.turnOffPendingKey)
        return BighelpNotificationTurnOffResult(unreachableHosts: unreachable)
    }

    /// A turn-off the notification service hasn't confirmed yet.
    var turnOffPending: Bool { defaults.bool(forKey: Self.turnOffPendingKey) }

    /// Asks each host still holding this device's notification data to delete
    /// it. Returns the names of hosts that couldn't be reached; they stay on
    /// the list for the next try. Hosts no longer configured are dropped.
    @discardableResult
    func retryPendingHostCleanups() async -> [String] {
        var remaining: [String: Set<String>] = [:]
        var unreachable: [String] = []
        for (hostID, grants) in pendingHostCleanups.sorted(by: { $0.key < $1.key }) {
            guard let host = registry.hosts.first(where: { $0.id.uuidString == hostID }) else { continue }
            var left = Set<String>()
            for grant in grants.sorted() {
                do {
                    let client = try hostClient(host)
                    let removed = try await client.request("/enrollments/\(grant)", method: "DELETE", body: nil,
                                                           isCurrent: { true })
                    guard removed.object?["grantId"]?.string == grant,
                          removed.object?["state"]?.string == "removed" else { throw DirectHermesError.invalidResponse }
                } catch {
                    left.insert(grant)
                }
            }
            if !left.isEmpty {
                remaining[hostID] = left
                unreachable.append(host.name)
            }
        }
        pendingHostCleanups = remaining
        return unreachable
    }

    /// Names of hosts that still have to delete this device's notification data.
    var hostsAwaitingCleanup: [String] {
        let ids = Set(pendingHostCleanups.keys)
        return registry.hosts.filter { ids.contains($0.id.uuidString) }.map(\.name)
    }

    private var pendingHostCleanups: [String: Set<String>] {
        get {
            let stored = defaults.dictionary(forKey: Self.pendingHostCleanupKey) as? [String: [String]] ?? [:]
            return stored.reduce(into: [:]) { result, entry in
                guard UUID(uuidString: entry.key) != nil else { return }
                let grants = Set(entry.value.filter(ManagedNotificationValidation.uuid))
                if !grants.isEmpty { result[entry.key] = grants }
            }
        }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: Self.pendingHostCleanupKey) }
            else { defaults.set(newValue.mapValues { $0.sorted() }, forKey: Self.pendingHostCleanupKey) }
        }
    }

    static let turnOffPendingKey = "bighelp.notifications.turn-off-pending"
    static let pendingHostCleanupKey = "bighelp.notifications.pending-host-cleanup"

    func credentials(for host: BighelpConfiguredHost) throws -> BighelpManagedNotificationCredentials {
        guard let credentials = try identity.current() else { throw DirectHermesError.invalidCredentials }
        try requireCurrent(host, credentials: credentials); return credentials
    }
    func requireCurrent(_ host: BighelpConfiguredHost, credentials: BighelpManagedNotificationCredentials) throws {
        try Task.checkCancellation()
        guard try identity.current() == credentials, credentials.deviceID == (try host.notificationAccountID()),
              registry.accountScope == host.accountScope,
              host.notificationScope == ManagedNotificationValidation.digest(credentials.deviceID + ":" + String(credentials.authorizationEpoch)),
              !retiredHosts.contains(host.notificationScope + ":" + host.hostConnectionID),
              registry.hosts.contains(where: { $0.id == host.id && $0.principalIdentity == host.principalIdentity
                  && $0.notificationBinding == host.notificationBinding }) else {
            throw DirectHermesError.secureStorageChanged
        }
    }
    func client(for host: BighelpConfiguredHost) throws -> any DirectHostNotificationServing { try hostClient(host) }
    func accountAPI() -> any BighelpManagedNotificationAccountAPI { api }
    func notificationContextScope() -> String {
        guard let credentials = try? identity.current() else { return "automatic-notification-identity" }
        return ManagedNotificationValidation.digest(
            [credentials.subscriberScope, credentials.deviceID, String(credentials.authorizationEpoch)].joined(separator: "\0")
        )
    }
    func refreshNotificationIdentity() async throws -> BighelpNotificationRuntimeSnapshot {
        // Never identify again while a turn-off is finishing.
        guard !turnOffPending, let credentials = try identity.current() else {
            _ = BighelpBuzzKitRuntime.shared.configureIfPossible()
            return .current
        }
        try await providerOperation(stage: .providerIdentity) {
            try await buzzKit.identify(accountAPI: api, credentials: credentials)
        }
        try requireCurrentNotificationIdentity(credentials)
        return .current
    }
    func refreshNotificationRuntime() async throws -> BighelpNotificationRuntimeSnapshot {
        _ = try await refreshNotificationIdentity()
        guard let credentials = try identity.current() else { return .current }
        _ = try await providerOperation(stage: .providerReadiness) {
            try await buzzKit.refreshProviderReadiness(
                accountAPI: api,
                credentials: credentials,
                requiringCurrentRegistration: false
            )
        }
        try requireCurrentNotificationIdentity(credentials)
        return .current
    }
    func sendTestNotification() async throws -> BighelpNotificationTestReceipt {
        guard let credentials = try identity.current() else { throw DirectHermesError.invalidCredentials }
        let body = try ManagedNotificationValidation.data(BighelpJSONValue.object([
            "version": .integer(1), "requestId": .string(UUID().uuidString.lowercased()),
        ]))
        let response = try await api.managedNotificationRequest(
            path: Self.root + "/buzzkit/test", method: "POST", body: body, credentials: credentials
        )
        struct Envelope: Decodable { let version: Int; let test: BighelpNotificationTestReceipt }
        let result = try ManagedNotificationValidation.decode(Envelope.self, from: response)
        guard result.version == 1 else { throw DirectHermesError.invalidResponse }
        return result.test
    }
    private func list(_ credentials: BighelpManagedNotificationCredentials) async throws -> [BighelpManagedGrant] {
        try ManagedNotificationValidation.grants(await api.managedNotificationRequest(path: Self.root, method: "GET", body: nil, credentials: credentials))
    }
    private func validate(_ grant: BighelpManagedGrant, host: BighelpConfiguredHost, profile: String,
                          credentials: BighelpManagedNotificationCredentials) throws {
        try grant.validate()
        guard grant.authorizationEpoch == credentials.authorizationEpoch,
              grant.instanceId == host.hostConnectionID.lowercased(),
              grant.subscriberScope == credentials.subscriberScope,
              grant.profile == profile, grant.state != "revoked", grant.expiresAt > timestamp,
              ManagedNotificationValidation.validEnrollmentEventTypes(grant.eventTypes) else { throw DirectHermesError.invalidResponse }
    }
    private func providerOperation<Value>(
        stage: BighelpManagedNotificationSetupError.Stage,
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as BighelpManagedNotificationSetupError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BighelpManagedNotificationSetupError(stage: stage)
        }
    }
    private func requireCurrentNotificationIdentity(
        _ credentials: BighelpManagedNotificationCredentials
    ) throws {
        try Task.checkCancellation()
        guard try identity.current() == credentials else {
            throw DirectHermesError.secureStorageChanged
        }
    }
    private var timestamp: Int { Int(now().timeIntervalSince1970) }
    static let root = "/v1/notifications/host-grants"
}
