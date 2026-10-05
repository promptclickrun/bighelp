import BuzzKit
import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import Bighelp

@MainActor struct ManagedNotificationServiceTests {
    @Test func turnOffDeletesHostServiceAndDeviceDataLeavingNothingBehind() async throws {
        let fixture = try Fixture(notificationDeviceID: UUID().uuidString.lowercased())
        defer { fixture.cleanup() }
        fixture.hostAPI.sealedAlerts = true
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        let grant = try #require(fixture.account.grant?.grantId)
        let installation = try fixture.service.credentials(for: fixture.host).deviceID
        #expect(try fixture.sealedKeys.load() != nil)
        #expect(try !fixture.sealedSenders.load().isEmpty)
        #expect(fixture.service.hasNotificationData)

        var steps: [BighelpNotificationTurnOffStep] = []
        let result = try await fixture.service.turnOffNotifications { steps.append($0) }

        #expect(result.unreachableHosts.isEmpty)
        #expect(steps == [.hosts, .service, .device])
        #expect(fixture.hostAPI.removedGrants == [grant], "The host deletes its copy")
        #expect(fixture.account.grant?.state == "revoked")
        #expect(fixture.transport.revokedInstallations == [installation],
                "Revoking the installation makes the Worker delete the BuzzKit subscriber")
        #expect(fixture.provider.retirements == 1, "BuzzKit's own identity is retired")
        #expect(fixture.identityVault.value == .none)
        #expect(fixture.ledger.enrollments.isEmpty && fixture.ledger.activities.isEmpty)
        #expect(try fixture.sealedKeys.load() == nil, "The sealed-alert key is gone")
        #expect(try fixture.sealedSenders.load().isEmpty, "Pinned host keys are gone")
        #expect(fixture.host.notificationBinding == nil)
        #expect(fixture.host.notificationState == .notConfigured)
        #expect(!fixture.service.turnOffPending)
        #expect(!fixture.service.hasNotificationData)
        #expect(fixture.service.hostsAwaitingCleanup.isEmpty)
        let reloaded = try BighelpManagedNotificationLedger(root: fixture.root.appending(path: "ledger"))
        #expect(reloaded.enrollments.isEmpty, "Nothing comes back after relaunch")
    }

    @Test func turnOffFinishesWithAnOfflineHostAndRemovesItsCopyLater() async throws {
        let fixture = try Fixture(notificationDeviceID: UUID().uuidString.lowercased())
        defer { fixture.cleanup() }
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        let grant = try #require(fixture.account.grant?.grantId)
        fixture.hostAPI.offline = true

        let result = try await fixture.service.turnOffNotifications()

        #expect(result.unreachableHosts == ["Host"])
        #expect(fixture.account.grant?.state == "revoked", "The offline host can't send anything")
        #expect(fixture.transport.revokedInstallations.count == 1)
        #expect(fixture.identityVault.value == .none)
        #expect(fixture.service.hostsAwaitingCleanup == ["Host"])
        #expect(fixture.service.hasNotificationData)

        fixture.hostAPI.offline = false
        #expect(await fixture.service.retryPendingHostCleanups().isEmpty)
        #expect(fixture.hostAPI.removedGrants == [grant])
        #expect(fixture.service.hostsAwaitingCleanup.isEmpty)
        #expect(!fixture.service.hasNotificationData)
    }

    @Test func turnOffThatTheServiceDidNotConfirmNeverReidentifiesAndCanFinish() async throws {
        let fixture = try Fixture(notificationDeviceID: UUID().uuidString.lowercased())
        defer { fixture.cleanup() }
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        fixture.transport.installationRevokeFails = true

        await #expect(throws: (any Error).self) { try await fixture.service.turnOffNotifications() }
        #expect(fixture.service.turnOffPending)
        #expect(fixture.identityVault.value != .none, "Kept to sign the retry")
        let identifications = fixture.provider.identifiedDeviceIDs.count
        _ = try await fixture.service.refreshNotificationIdentity()
        #expect(fixture.provider.identifiedDeviceIDs.count == identifications,
                "Launch recovery must not identify BuzzKit again mid turn-off")

        fixture.transport.installationRevokeFails = false
        _ = try await fixture.service.turnOffNotifications()
        #expect(!fixture.service.turnOffPending)
        #expect(fixture.identityVault.value == .none)
        #expect(!fixture.service.hasNotificationData)
    }

    @Test func notificationsTurnOnAgainFromScratchAfterTurnOff() async throws {
        let original = UUID().uuidString.lowercased()
        let fixture = try Fixture(notificationDeviceID: original)
        defer { fixture.cleanup() }
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        _ = try await fixture.service.turnOffNotifications()

        let result = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })

        guard case .enabled = result else {
            Issue.record("Notifications did not turn on again")
            return
        }
        let renewed = try #require(fixture.host.notificationBinding?.deviceID)
        #expect(renewed != original, "A brand-new notification installation")
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.enabled == true)
        #expect(fixture.account.grant?.state == "active")
    }

    @Test func refreshUsesReadOnlyProviderStatusWhileEnrollmentRequiresCurrentRegistrationReadback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.refreshNotificationRuntime()
        #expect(fixture.provider.registrationRequirements == [false])
        #expect(fixture.provider.registrations == 0)
        #expect(fixture.account.postBodies.isEmpty)
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        #expect(fixture.provider.registrationRequirements == [false, true])
        #expect(fixture.provider.registrations == 1)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.enabled == true)
    }

    @Test func enrollmentUsesTheDedicatedNotificationInstallationWithoutAnAccountBinding() async throws {
        let fixture = try Fixture(notificationDeviceID: "fixture-notification-installation")
        defer { fixture.cleanup() }

        let result = try await fixture.service.enroll(
            host: fixture.host,
            connection: fixture.connection,
            isCurrent: { true }
        )

        guard case .enabled = result else {
            Issue.record("Linked host enrollment did not enable")
            return
        }
        #expect(fixture.host.notificationBinding?.deviceID == "fixture-notification-installation")
        #expect(fixture.host.notificationScope != fixture.host.accountScope)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.accountID
                == "fixture-notification-installation")
        #expect(fixture.bindingRequests == 0, "The retired bighelp account is never bound")
    }

    @Test func explicitSetupReplacesRevokedProviderIdentityAndCompletesEnrollment() async throws {
        let original = UUID().uuidString.lowercased()
        let fixture = try Fixture(notificationDeviceID: original)
        defer { fixture.cleanup() }
        fixture.provider.identifyErrors = [
            BighelpManagedNotificationSetupError(
                stage: .providerIdentity,
                code: "notification_credentials_revoked"
            ),
        ]

        let result = try await fixture.service.enroll(
            host: fixture.host,
            connection: fixture.connection,
            isCurrent: { true }
        )

        guard case .enabled = result else {
            Issue.record("Enrollment did not recover the revoked provider identity")
            return
        }
        #expect(fixture.provider.identifiedDeviceIDs.count == 2)
        #expect(fixture.provider.identifiedDeviceIDs[0] == original)
        #expect(fixture.provider.identifiedDeviceIDs[1] != original)
        #expect(fixture.host.notificationBinding?.deviceID == fixture.provider.identifiedDeviceIDs[1])
    }

    @Test func currentSubscriptionReadbackFailurePreventsGrantAndLedgerEnablement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.provider.readinessError = DirectHermesError.invalidResponse

        do {
            _ = try await fixture.service.enroll(
                host: fixture.host,
                connection: fixture.connection,
                isCurrent: { true }
            )
            Issue.record("Enrollment must require provider confirmation of the current subscription")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .providerReadiness)
        }

        #expect(fixture.provider.registrations == 1)
        #expect(fixture.provider.registrationRequirements == [true])
        #expect(fixture.account.postBodies.isEmpty)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.enabled != true)
        #expect(!fixture.hostAPI.sawPinnedClaim)
    }

    @Test func deniedPermissionStopsBeforeRegistrationOrHostMutation() async throws {
        let fixture = try Fixture(permissionGranted: false)
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
            Issue.record("Denied permission must stop setup")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .notificationPermission)
        }
        #expect(fixture.provider.registrations == 0)
        #expect(fixture.account.postBodies.isEmpty)
        #expect(!fixture.hostAPI.sawPinnedClaim)
    }

    @Test func notificationCompositionRecoversAndInstallsHooksOnlyOnce() throws {
        let fixture = try Fixture(independent: true)
        defer { fixture.cleanup() }
        var apnsInstalls = 0
        var openInstalls = 0
        var attempts = 0
        let composition = BighelpManagedNotificationComposition(
            isFixture: false, registry: fixture.registry,
            applicationHooks: .init(installAPNSToken: { _ in apnsInstalls += 1 },
                                    installAPNSFailure: { _ in },
                                    installWake: { _ in },
                                    installManagedOpen: { _ in openInstalls += 1 }),
            makeIntegration: {
                attempts += 1
                if attempts == 1 { throw DirectHermesError.secureStorageUnavailable }
                return BighelpManagedNotificationIntegration(service: fixture.service)
            }
        )
        #expect(composition.service == nil)
        #expect(fixture.registry.notificationSetup != nil)
        #expect(composition.loadFailureKind == .protectedStorageUnavailable)
        #expect(composition.retryAfterProtectedDataBecomesAvailable())
        #expect(composition.service === fixture.service)
        #expect(fixture.registry.notificationSetupError == nil)
        for _ in 0..<4 { #expect(composition.retryAfterForeground()) }
        #expect(attempts == 2)
        #expect(composition.rootHookInstallationCount == 1)
        #expect(apnsInstalls == 1 && openInstalls == 1)
        let owner = try #require(composition.captureOwner())
        fixture.registry.bind(deviceID: "replacement-account", authorizationEpoch: 2)
        #expect(composition.isCurrent(owner), "Link identity changes do not retire an independent host")
        fixture.registry.useLinkedWorkspace()
        #expect(!composition.isCurrent(owner))
    }

    @Test func revokedCredentialsRetryReidentifiesWithFreshCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.provider.identifyErrors = [
            BighelpManagedNotificationSetupError(stage: .providerIdentity, code: "notification_credentials_revoked")
        ]
        let result = try await fixture.service.enroll(
            host: fixture.host, connection: fixture.connection, isCurrent: { true })
        guard case .enabled = result else {
            Issue.record("Enrollment must succeed after the revoked-credential retry")
            return
        }
        #expect(fixture.provider.identifiedDeviceIDs.count == 2,
                "The first identify must fail revoked, the retry must identify with replacement credentials")
        #expect(Set(fixture.provider.identifiedDeviceIDs).count == 2,
                "The retry must use fresh credentials, not the revoked ones")
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.enabled == true)
    }

    @Test func notificationCompositionInstallsLinkWakeAndFailureHooks() async throws {
        let fixture = try Fixture(independent: true)
        defer { fixture.cleanup() }
        var wakeHandler: BighelpLinkWakeCenter.Handler?
        var failureHandler: BighelpAPNSTokenHookCenter.FailureHandler?
        let composition = BighelpManagedNotificationComposition(
            isFixture: false, registry: fixture.registry,
            applicationHooks: .init(
                installAPNSToken: { _ in },
                installAPNSFailure: { failureHandler = $0 },
                installWake: { wakeHandler = $0 },
                installManagedOpen: { _ in }),
            makeIntegration: { BighelpManagedNotificationIntegration(service: fixture.service) }
        )
        #expect(composition.rootHookInstallationCount == 1)
        #expect(failureHandler != nil,
                "The APNs failure hook must be installed so didFailToRegister reaches the runtime")
        let handler = try #require(wakeHandler, "The Link wake handler must be installed")
        // Route a real wake payload through the center: a handled wake must no
        // longer report .failed.
        let center = BighelpLinkWakeCenter()
        center.install(handler)
        let result = await center.receive([
            "aps": ["content-available": 1],
            "loopdy_link": ["version": 2, "type": "wake", "frameId": "fixture_frame_0001"]
        ])
        #expect(result == .noData)
    }

    @Test func wakeDuringRealProviderRegistrationDoesNotReidentifyEnrollment() async throws {
        let sdk = WakeSDK()
        let runtime = BighelpBuzzKitRuntime(testingSDK: sdk)
        let fixture = try Fixture(independent: true, providerOverride: runtime)
        defer { fixture.cleanup() }
        fixture.service.activityRuntime = BighelpManagedNativeActivityRuntime(
            service: fixture.service, environment: .sandbox, topic: "app.loopdy.mobile")
        var wake: BighelpLinkWakeCenter.Handler?
        let composition = BighelpManagedNotificationComposition(
            isFixture: false, registry: fixture.registry,
            applicationHooks: .init(installAPNSToken: { _ in }, installAPNSFailure: { _ in },
                installWake: { wake = $0 }, installManagedOpen: { _ in }),
            makeIntegration: { BighelpManagedNotificationIntegration(service: fixture.service) })
        let handler = try #require(wake)
        sdk.onRegister = {
            runtime.noteAPNSToken(Data([1, 2]))
            let hasNewData = try await handler()
            #expect(hasNewData == false)
        }
        let result = try await composition.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        guard case .enabled = result else { Issue.record("Wake interrupted explicit enrollment"); return }
        #expect(sdk.identifications == 1, "A wake cannot reset the in-flight provider generation")
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.enabled == true)
    }

    @Test func failedNotificationCompositionHasBoundedAutomaticAndExplicitRetry() async throws {
        let fixture = try Fixture(independent: true)
        defer { fixture.cleanup() }
        let composition = BighelpManagedNotificationComposition(
            isFixture: false, registry: fixture.registry,
            maximumAutomaticAttempts: 3,
            applicationHooks: .init(installAPNSToken: { _ in }, installAPNSFailure: { _ in },
                                    installWake: { _ in }, installManagedOpen: { _ in }),
            makeIntegration: { throw DirectHermesError.savedConnectionInvalid }
        )
        for _ in 0..<5 { _ = composition.retryAfterForeground() }
        #expect(composition.constructionAttemptCount == 3)
        #expect(composition.loadFailureKind == .savedStateRejected)
        await #expect(throws: (any Error).self) {
            _ = try await composition.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        }
        #expect(composition.constructionAttemptCount == 4)
        #expect(composition.service == nil)
        #expect(fixture.account.requests.isEmpty)
        #expect(fixture.ledger.enrollments.isEmpty)
    }

    @Test func openingChatBeforeNotificationOptInIsANoOp() async throws {
        let fixture = try Fixture(independent: true)
        defer { fixture.cleanup() }
        #expect(throws: (any Error).self) { try fixture.service.credentials(for: fixture.host) }
        let rpc = UnenrolledChatRPC()
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: fixture.host.principalIdentity,
            profile: "default", runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
            drafts: .init(root: fixture.root.appending(path: "drafts")))
        defer { client.suspend() }
        let model = ChatModel(conversationID: "saved", client: client)
        let chat = DirectHermesChat(id: "saved", client: client, model: model)
        try await fixture.service.onChatOpened(host: fixture.host, chat: chat)
        #expect(fixture.account.requests.isEmpty)
        #expect(rpc.requests.isEmpty)
        #expect(fixture.registry.notificationSetupError == nil)
    }

    @MainActor private final class UnenrolledChatRPC: DirectHermesRPC {
        var onEvent: ((DirectHermesEvent) -> Void)?
        var requests: [String] = []
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            requests.append(method)
            throw DirectHermesError.invalidResponse
        }
        func disconnect() async {}
    }

    @Test func explicitNotificationEnrollmentNeverChangesIndependentChatAuthority() async throws {
        let fixture = try Fixture(independent: true)
        defer { fixture.cleanup() }
        let selected = fixture.registry.selectedHostID
        let generation = fixture.registry.generation
        #expect(throws: (any Error).self) { try fixture.service.credentials(for: fixture.host) }
        #expect(fixture.account.requests.isEmpty)
        let result = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        guard case .enabled = result else { Issue.record("Optional enrollment failed"); return }
        let updated = try #require(fixture.registry.selectedHost)
        #expect(updated.accountID == nil)
        #expect(fixture.registry.accountID == nil)
        #expect(fixture.registry.connectionMode == .independent)
        #expect(fixture.registry.selectedHostID == selected)
        #expect(fixture.registry.generation == generation)
        #expect(fixture.ledger.record(host: updated, profile: "default")?.enabled == true)
        fixture.service.retireForAccountBoundary()
        #expect(fixture.registry.selectedHostID == selected)
        #expect(fixture.registry.connectionMode == .independent)
    }
    @Test func enrollmentPersistsGrantBeforeClaimAndVerifiesReadbackWithoutLinkChat() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        guard case .enabled = result else { Issue.record("Enrollment not enabled"); return }
        #expect(fixture.hostAPI.sawPinnedClaim)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.enabled == true)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.grant?.eventTypes == ManagedNotificationValidation.eventTypes.sorted())
        #expect(fixture.account.postBodies.count == 1)
        #expect(!fixture.account.requests.contains { $0.contains("socket") || $0.contains("pairing") })
    }

    @Test func approvalCapableHostRequestsAndPinsExplicitApprovalAuthority() async throws {
        let fixture = try Fixture(approvalSupported: true)
        defer { fixture.cleanup() }
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        let body = try #require(fixture.account.postBodies.first)
        let intent = try JSONDecoder().decode(BighelpManagedGrantIntent.self, from: body)
        #expect(Set(intent.eventTypes) == ManagedNotificationValidation.eventTypes)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.grant?.eventTypes.contains("approval.required") == true)
    }

    @Test func addingHostCapabilityDoesNotUpgradeExistingGrant() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        fixture.hostAPI.supportedEvents.append("future.unknown")
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        #expect(fixture.account.postBodies.count == 1)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.grant?.eventTypes == ManagedNotificationValidation.eventTypes.sorted())
    }

    @Test func partialHostCapabilitiesCannotClaimFullNotificationReadiness() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.hostAPI.supportedEvents = ["session.completed", "session.failed"]
        let result = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        guard case .prerequisitesRequired = result else { Issue.record("Partial host cannot enroll all categories"); return }
        #expect(fixture.account.postBodies.isEmpty)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.enabled != true)
    }

    @Test func cloudCannotExpandApprovalBeyondRequestedAuthority() async throws {
        let fixture = try Fixture(approvalSupported: true)
        defer { fixture.cleanup() }
        fixture.account.eventTypesOverride = ManagedNotificationValidation.eventTypes.sorted() + ["private.unsupported"]
        do {
            _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
            Issue.record("Expanded grant must be rejected")
        } catch {}
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.grant == nil)
    }

    @Test func firstChatSubscribesBeforeLazyProducersHaveRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.hostAPI.producerLoaded = false
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        let client = try DirectHermesConversationClient(rpc: IdleRPC(), hostIdentity: fixture.host.principalIdentity,
            profile: "default", runtimeID: "runtime", storedID: "stored", title: "Fixture", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: fixture.root.appending(path: "drafts")))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        try await fixture.service.onChatOpened(host: fixture.host, chat: DirectHermesChat(id: client.conversationID, client: client, model: model))
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.subscriptions.contains("stored") == true)
    }

    /// Peer chats (agents talking to each other) alert only when this phone turned them on: the
    /// choice reaches the host when a chat opens, once, and again only when it changes.
    @Test func peerChatChoiceReachesTheHostOnceAndWhenItChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: BighelpPeerChatAlerts.key)
        defer { defaults.set(previous, forKey: BighelpPeerChatAlerts.key) }
        defaults.set(false, forKey: BighelpPeerChatAlerts.key)
        fixture.hostAPI.peerChatPreference = true
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        let client = try DirectHermesConversationClient(rpc: IdleRPC(), hostIdentity: fixture.host.principalIdentity,
            profile: "default", runtimeID: "runtime", storedID: "stored", title: "Fixture", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: fixture.root.appending(path: "drafts")))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        let chat = DirectHermesChat(id: client.conversationID, client: client, model: model)

        try await fixture.service.onChatOpened(host: fixture.host, chat: chat)
        try await fixture.service.onChatOpened(host: fixture.host, chat: chat)
        #expect(fixture.hostAPI.peerChatPuts == [false], "Sent once")
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.peerChatsAlert == false)

        defaults.set(true, forKey: BighelpPeerChatAlerts.key)
        await fixture.service.applyAlertPreferences()
        #expect(fixture.hostAPI.peerChatPuts == [false, true], "Turning it on reaches the host at once")
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.peerChatsAlert == true)
    }

    /// Workflow alert switches go with Peer chats, only to computers whose plugin has them.
    @Test func workflowAlertChoicesReachComputersThatHaveThem() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = UserDefaults.standard
        let keys = [BighelpPeerChatAlerts.key] + BighelpWorkflowAlerts.Kind.allCases.map(\.key)
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.removeObject(forKey: key) }
        fixture.hostAPI.peerChatPreference = true
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })

        // An older plugin: only Peer chats goes.
        await fixture.service.applyAlertPreferences()
        #expect(fixture.hostAPI.workflowPuts.isEmpty)

        fixture.hostAPI.workflowPreference = true
        defaults.set(false, forKey: BighelpWorkflowAlerts.Kind.succeeded.key)
        await fixture.service.applyAlertPreferences()
        #expect(fixture.hostAPI.workflowPuts == [["needsYou": true, "succeeded": false, "failed": true, "cancelled": true]])
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.workflowAlertsSent?["succeeded"] == false)
        await fixture.service.applyAlertPreferences()
        #expect(fixture.hostAPI.workflowPuts.count == 1, "Sent only when it changes")
    }

    /// Quiet Hours go to the computer when notifications turn on, again only when they change,
    /// and again when the device is in another time zone.
    @Test func quietHoursReachTheComputerOnEnrollmentAndWhenTheyChange() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.hostAPI.quietHoursSupported = true
        var night = BighelpQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        night.save(fixture.defaults)
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        let grant = try #require(fixture.account.grant?.grantId)
        let zone = BighelpQuietHours.timeZoneID()
        #expect(fixture.hostAPI.quietHoursPuts == [night.body(grantID: grant, timeZone: zone)], "Sent on enrollment")
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.quietHoursSent
            == .init(quietHours: night, timeZone: zone))

        #expect(await fixture.service.applyQuietHours() == BighelpQuietHoursSyncResult())
        #expect(fixture.hostAPI.quietHoursPuts.count == 1, "Unchanged: not sent again")

        night.startMinute = 23 * 60
        night.save(fixture.defaults)
        #expect(await fixture.service.applyQuietHours().note == nil)
        #expect(fixture.hostAPI.quietHoursPuts.last == night.body(grantID: grant, timeZone: zone), "Sent on change")

        night.enabled = false
        night.save(fixture.defaults)
        _ = await fixture.service.applyQuietHours()
        #expect(fixture.hostAPI.quietHoursPuts.last?["enabled"] == .boolean(false), "Turning it off reaches the computer")

        var record = try #require(fixture.ledger.record(host: fixture.host, profile: "default"))
        record.quietHoursSent = .init(quietHours: night, timeZone: zone == "Asia/Tokyo" ? "Europe/Berlin" : "Asia/Tokyo")
        try fixture.ledger.save(record)
        _ = await fixture.service.applyQuietHours()
        #expect(fixture.hostAPI.quietHoursPuts.count == 4, "Another time zone: sent again")
        #expect(fixture.hostAPI.quietHoursPuts.last?["timeZone"] == .string(zone))
    }

    @Test func aComputerWithAnOlderPluginIsNamedForAPluginUpdate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        BighelpQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60).save(fixture.defaults)
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        let result = await fixture.service.applyQuietHours()
        #expect(result.needsPluginUpdate == [fixture.host.name])
        #expect(result.note == "Quiet Hours needs a plugin update on \(fixture.host.name).")
        #expect(fixture.hostAPI.quietHoursPuts.isEmpty)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.enabled == true,
                "Notifications stay on without Quiet Hours")
    }

    @Test func aComputerThatCanNotBeReachedIsNotCalledOutdated() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.hostAPI.quietHoursSupported = true
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        BighelpQuietHours(enabled: true, startMinute: 21 * 60, endMinute: 6 * 60).save(fixture.defaults)
        fixture.hostAPI.offline = true
        #expect(await fixture.service.applyQuietHours() == BighelpQuietHoursSyncResult())
        fixture.hostAPI.offline = false
        _ = await fixture.service.applyQuietHours()
        #expect(fixture.hostAPI.quietHoursPuts.last?["startMinute"] == .integer(21 * 60), "Sent once it's back")
    }

    @Test func anOlderPluginIsNeverAskedAboutPeerChats() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        let client = try DirectHermesConversationClient(rpc: IdleRPC(), hostIdentity: fixture.host.principalIdentity,
            profile: "default", runtimeID: "runtime", storedID: "stored", title: "Fixture", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: fixture.root.appending(path: "drafts")))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        try await fixture.service.onChatOpened(host: fixture.host, chat: DirectHermesChat(id: client.conversationID, client: client, model: model))
        await fixture.service.applyAlertPreferences()
        #expect(fixture.hostAPI.peerChatPuts.isEmpty)
    }

    @Test func sealedAlertHostGetsThisPhonesKeyDirectlyAndOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.hostAPI.sealedAlerts = true
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        let key = try BighelpSealedAlertRecipient.key(store: fixture.sealedKeys)
        #expect(fixture.hostAPI.recipientKeys == [BighelpSealedAlertRecipient.publicKey(key)])
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.sealedRecipientKeyID
            == BighelpSealedAlert.keyID(key.publicKey.x963Representation))
        let grant = fixture.account.template
        let sender = try #require(try fixture.sealedSenders.sender(grantID: grant.grantId))
        #expect(sender.hostPublicKey == grant.hostPublicKey && sender.hostKeyID == grant.hostKeyId)

        // Opening a chat keeps the key the host already has.
        let client = try DirectHermesConversationClient(rpc: IdleRPC(), hostIdentity: fixture.host.principalIdentity,
            profile: "default", runtimeID: "runtime", storedID: "stored", title: "Fixture", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: fixture.root.appending(path: "drafts")))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        try await fixture.service.onChatOpened(host: fixture.host, chat: DirectHermesChat(id: client.conversationID, client: client, model: model))
        #expect(fixture.hostAPI.recipientKeys.count == 1)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.subscriptions.contains("stored") == true)

        // Removing the host forgets which key may sign its alerts.
        try fixture.service.removeLocalEnrollment(host: fixture.host)
        #expect(try fixture.sealedSenders.sender(grantID: grant.grantId) == nil)
    }

    @Test func alertsForTheChatOnScreenAreRecognizedByTheirThread() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(rpc: IdleRPC(), hostIdentity: "host", profile: "nova",
            runtimeID: "runtime", storedID: "20260927_010203_abcdef", title: "Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root.appending(path: "drafts")))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        let thread = ManagedNotificationValidation.sessionReference(profile: "nova", session: "20260927_010203_abcdef")
        let visible = BighelpVisibleChats.shared
        #expect(!visible.isShowing(thread: thread))
        visible.appeared(model)
        #expect(visible.isShowing(thread: thread))
        #expect(!visible.isShowing(thread: ManagedNotificationValidation.sessionReference(profile: "nova", session: "other")))
        #expect(!visible.isShowing(thread: ""))
        visible.disappeared(model)
        #expect(!visible.isShowing(thread: thread))
    }

    @Test func hostWithoutSealedAlertsNeverGetsAKey() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        #expect(fixture.hostAPI.recipientKeys.isEmpty)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.sealedRecipientKeyID == nil)
        #expect(try fixture.sealedSenders.load().isEmpty)
    }

    @Test(arguments: [false, true])
    func independentChatSubscribesUsingItsNativeAuthorityOnlyAfterOptIn(dashboard: Bool) async throws {
        let fixture = try Fixture(independent: true, dashboard: dashboard)
        defer { fixture.cleanup() }
        try fixture.registry.credentialVault(for: fixture.host).save(fixture.connection)
        let authority = try dashboard
            ? WorkspaceAuthority.dashboard(endpointIdentity: fixture.connection.endpoint.identity)
            : WorkspaceAuthority.direct(endpointIdentity: fixture.connection.endpoint.identity,
                providerID: "basic", userID: "person")
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let coordinate = try WorkspaceSessionCoordinate(owner: owner, profileID: "default", sessionID: "native-chat",
            storedSessionID: "stored", runtimeSessionID: "runtime")
        let client = try DirectHermesConversationClient(rpc: IdleRPC(), hostIdentity: authority.cacheScopeID,
            profile: "default", runtimeID: "runtime", storedID: "stored", title: "Fixture", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: fixture.root.appending(path: "drafts")), workspaceSession: coordinate)
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        let chat = DirectHermesChat(id: client.conversationID, client: client, model: model)
        #expect(fixture.service.ownsChat(host: fixture.host, client: client))
        #expect(fixture.account.requests.isEmpty)
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        let boundHost = try #require(fixture.registry.hosts.first)
        try await fixture.service.onChatOpened(host: boundHost, chat: chat)
        #expect(fixture.ledger.record(host: boundHost, profile: "default")?.subscriptions.contains("stored") == true)
        #expect(fixture.registry.connectionMode == .independent)
        #expect(fixture.registry.hosts.first?.accountID == nil)
    }

    @MainActor private final class IdleRPC: DirectHermesRPC {
        var onEvent: ((DirectHermesEvent) -> Void)?
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            throw DirectHermesError.notConnected
        }
        func disconnect() async {}
    }

    @Test func lostCreateReceiptRecoversFromListWithoutSecondCreate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.account.loseFirstCreate = true
        do { _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true }); Issue.record("Expected lost reply") }
        catch {}
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.creationBody != nil)
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        #expect(fixture.account.postBodies.count == 1)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.enabled == true)
    }

    @Test func hostRemovalPersistsRevocationBeforeDeletingTrust() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.enroll(host: fixture.host, connection: fixture.connection, isCurrent: { true })
        try fixture.service.removeLocalEnrollment(host: fixture.host)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.revokePending == true)
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.enabled == false)
        try await fixture.service.reconcilePendingRevocations()
        #expect(fixture.ledger.record(host: fixture.host, profile: "default")?.revokePending == false)
        #expect(fixture.account.grant?.state == "revoked")
    }

    @MainActor private final class Account: BighelpManagedNotificationAccountAPI {
        var eventTypesOverride: [String]?
        var grant: BighelpManagedGrant?
        var postBodies: [Data] = []
        var requests: [String] = []
        var loseFirstCreate = false
        let template: BighelpManagedGrant
        init(_ template: BighelpManagedGrant) { self.template = template }
        func managedNotificationRequest(path: String, method: String, body: Data?, credentials: BighelpManagedNotificationCredentials) async throws -> BighelpJSONValue {
            requests.append(path)
            if path == BighelpManagedNotificationService.root + "/buzzkit/identity" {
                return .object(["version": .integer(2), "identity": .object([
                    "externalId": .string("notify_" + String(repeating: "a", count: 43)),
                    "identityHash": .string(String(repeating: "b", count: 64))])])
            }
            if path == BighelpManagedNotificationService.root + "/buzzkit/status" {
                return .object(["version": .integer(2), "readiness": .object([
                    "configured": .boolean(true),
                    "pushCredentials": .array([.object(["environment": .string("sandbox"), "status": .string("active")])]),
                    "subscriber": .object(["identified": .boolean(true), "verified": .boolean(true),
                        "activeIOSPushEnvironments": .array([.string("sandbox")]),
                        "currentDevice": .object(["matched": .boolean(true), "environment": .string("sandbox"),
                            "enabled": .boolean(true), "active": .boolean(true), "subscriptionId": .string("wake-subscription")])]),
                    "topicSlugs": .array(BighelpBuzzKitTopic.allCases.map { .string($0.rawValue) })])])
            }
            if method == "POST" {
                postBodies.append(try #require(body))
                let intent = try JSONDecoder().decode(BighelpManagedGrantIntent.self, from: #require(body))
                grant = BighelpManagedGrant(grantId: template.grantId, instanceId: template.instanceId, hostKeyId: template.hostKeyId, hostPublicKey: template.hostPublicKey,
                    authorizationEpoch: template.authorizationEpoch, profile: template.profile, eventTypes: eventTypesOverride ?? template.eventTypes,
                    createdAt: intent.expiresAt - 2_592_000, expiresAt: intent.expiresAt, revision: 1,
                    provider: "buzzkit", subscriberScope: template.subscriberScope, state: "active")
                if loseFirstCreate { loseFirstCreate = false; throw DirectHermesError.disconnected(outcomeUnknown: true) }
            }
            if method == "DELETE", let value = grant {
                grant = BighelpManagedGrant(grantId: value.grantId, instanceId: value.instanceId, hostKeyId: value.hostKeyId, hostPublicKey: value.hostPublicKey,
                    authorizationEpoch: value.authorizationEpoch, profile: value.profile,
                    eventTypes: value.eventTypes, createdAt: value.createdAt, expiresAt: value.expiresAt, revision: value.revision+1,
                    provider: "buzzkit", subscriberScope: "account", state: "revoked")
            }
            if method == "GET" { return .object(["version":.integer(1),"grants":.array(try [grant].compactMap{$0}.map(Self.value))]) }
            return .object(["version":.integer(1),"grant":try Self.value(#require(grant))])
        }
        static func value(_ grant: BighelpManagedGrant) throws -> BighelpJSONValue {
            try JSONDecoder().decode(BighelpJSONValue.self, from: JSONEncoder().encode(grant))
        }
    }
    @MainActor private final class Host: DirectHostNotificationServing {
        let account: Account; let trust: BighelpNotificationHostTrustStore
        var sawPinnedClaim = false
        var hasPersistedGrant: () -> Bool = { false }
        var producerLoaded = true
        var supportedEvents = ManagedNotificationValidation.eventTypes.sorted()
        var sealedAlerts = false
        var peerChatPreference = false
        var workflowPreference = false
        var workflowPuts: [[String: Bool]] = []
        var peerChatPuts: [Bool] = []
        var quietHoursSupported = false
        var quietHoursPuts: [[String: BighelpJSONValue]] = []
        var recipientKeys: [String] = []
        init(_ account: Account, _ trust: BighelpNotificationHostTrustStore) { self.account=account;self.trust=trust }
        var offline = false
        var removedGrants: [String] = []
        func request(_ suffix: String, method: String, body: [String: BighelpJSONValue]?, isCurrent: @escaping @MainActor () -> Bool) async throws -> BighelpJSONValue {
            guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
            if offline { throw DirectHermesError.notConnected }
            if method == "DELETE", suffix.hasPrefix("/enrollments/"), !suffix.dropFirst(13).contains("/") {
                // The plugin's remove(): deletes the grant's subscriptions, pending
                // alerts, Live Activities, recipient key and avatar keys.
                let grant = String(suffix.dropFirst(13))
                removedGrants.append(grant)
                return .object(["version": .integer(1), "state": .string("removed"), "grantId": .string(grant)])
            }
            if suffix == "/capabilities" { return .object(["version":.integer(1),"hostKeyId":.string(account.template.hostKeyId),
                "hostPublicKey":.string(account.template.hostPublicKey),"managedEnrollmentSupported":.boolean(true),
                "supportedEventTypes":.array(supportedEvents.map(BighelpJSONValue.string)),
                "richLiveActivitySupported":.boolean(true),
                "sealedAlerts":sealedAlerts ? .object(["version":.integer(2)]) : .null,
                "preferences":peerChatPreference ? .object(["peerChats":.boolean(true),
                                                            "workflows":.boolean(workflowPreference)]) : .null,
                "producerCapabilities":.object(["sessionCompletion":.boolean(producerLoaded),"sessionFailure":.boolean(producerLoaded),"richLiveActivity":.boolean(producerLoaded),"nativeApproval":.boolean(supportedEvents.contains("approval.required")),"nativeClarification":.boolean(false)])]) }
            if suffix.hasSuffix("/preferences"), method == "PUT", let wanted = body?["peerChats"]?.boolean {
                peerChatPuts.append(wanted)
                var answer: [String: BighelpJSONValue] = ["version":.integer(1),"peerChats":.boolean(wanted)]
                // Like plugin 3.7.0: workflow switches are kept and sent back.
                if let workflows = body?["workflows"]?.object {
                    guard workflowPreference else { throw WorkspaceClientError.rejected(code: "invalid_request") }
                    workflowPuts.append(workflows.compactMapValues(\.boolean))
                    answer["workflows"] = .object(workflows)
                }
                return .object(answer)
            }
            if suffix.hasSuffix("/recipient-key"), method == "PUT", let key = body?["publicKey"]?.string {
                recipientKeys.append(key)
                let raw = try #require(BighelpNotificationBase64URL.decodeCanonical(key))
                return .object(["version":.integer(1),"recipientKeyId":.string(BighelpSealedAlert.keyID(raw))])
            }
            if suffix.hasSuffix("/sessions"), let body {
                let profile = try #require(body["profile"]?.string)
                let session = try #require(body["sessionId"]?.string)
                return .object(["version":.integer(1),"grantId":.string(account.template.grantId),
                    "profile":.string(profile),"sessionId":.string(session),"enabled":.boolean(true),
                    "sessionReference":.string(ManagedNotificationValidation.sessionReference(profile:profile,session:session))])
            }
            if suffix == "/enroll" { sawPinnedClaim = hasPersistedGrant() }
            return .object(["version":.integer(1),"grant":try Account.value(#require(account.grant))])
        }
        /// Like the plugin: only a context that lists the feature has the route.
        func nativeRequest(_ path: String, feature: String, body: [String: BighelpJSONValue],
                           isCurrent: @escaping @MainActor () -> Bool) async throws -> BighelpJSONValue {
            guard isCurrent() else { throw DirectHermesError.secureStorageChanged }
            if offline { throw DirectHermesError.notConnected }
            guard quietHoursSupported, feature == BighelpQuietHours.feature, path == BighelpQuietHours.route else {
                throw DirectHostNotificationError.featureUnavailable
            }
            quietHoursPuts.append(body)
            var window = body
            let grant = window.removeValue(forKey: "grantId") ?? .null
            return .object(["version": .integer(1), "grantId": grant, "quietHours": .object(window), "quietNow": .boolean(false)])
        }
    }
    @MainActor private final class Provider: BighelpManagedNotificationProvider {
        var retirements = 0
        var onRetirement: (@MainActor () async -> Void)?
        func retireIdentityForLocalErasure() async {
            retirements += 1
            await onRetirement?()
        }
        var registrations = 0
        var registrationRequirements: [Bool] = []
        var readinessError: (any Error)?
        var identifyErrors: [any Error] = []
        var identifiedDeviceIDs: [String] = []
        func identify(accountAPI: any BighelpManagedNotificationAccountAPI, credentials: BighelpManagedNotificationCredentials) async throws {
            identifiedDeviceIDs.append(credentials.deviceID)
            if !identifyErrors.isEmpty { throw identifyErrors.removeFirst() }
        }
        func registerCurrentDevice() async throws { registrations += 1 }
        func refreshProviderReadiness(accountAPI: any BighelpManagedNotificationAccountAPI,
                                      credentials: BighelpManagedNotificationCredentials,
                                      requiringCurrentRegistration: Bool) async throws -> BighelpBuzzKitProviderReadiness {
            registrationRequirements.append(requiringCurrentRegistration)
            return try await refreshProviderReadiness(accountAPI: accountAPI, credentials: credentials)
        }
        func refreshProviderReadiness(accountAPI: any BighelpManagedNotificationAccountAPI, credentials: BighelpManagedNotificationCredentials) async throws -> BighelpBuzzKitProviderReadiness {
            if let readinessError { throw readinessError }
            return .init(configured: true, pushCredentials: [.init(environment: "sandbox", status: "active", validatedAt: nil, lastError: nil)],
                  subscriber: .init(identified: true, verified: true, activeIOSPushEnvironments: ["sandbox"],
                    currentDevice: .init(matched: true, environment: "sandbox", enabled: true, active: true, subscriptionId: "fixture-subscription")),
                  topicSlugs: BighelpBuzzKitTopic.allCases.map(\.rawValue))
        }
    }
    @MainActor private final class WakeSDK: BighelpAwaitableBuzzKitSDK {
        var isConfigured = true
        var externalID = ""
        var identifications = 0
        var onRegister: (@MainActor () async throws -> Void)?
        func identify(_ externalId: String, identityHash: String) { externalID = externalId; identifications += 1 }
        func identifyAndWait(_ externalId: String, identityHash: String) async throws { identify(externalId, identityHash: identityHash) }
        func logout() {}
        func logoutAndWait() async throws {}
        func notificationPermission() async -> UNAuthorizationStatus { .authorized }
        func registerForPush() async throws { try await onRegister?() }
        func registerPushSubscription(deviceToken: Data) async throws -> BuzzKit.PushSubscriptionRegistration {
            .init(id: "wake-subscription", externalId: externalID,
                endpoint: deviceToken.map { String(format: "%02x", $0) }.joined(), environment: .sandbox)
        }
        func migrateLegacyPreferences() async throws {}
        func observeActivities() {}
    }

    @MainActor private final class MemoryIdentityVault: BighelpNotificationIdentityVault {
        var value: BighelpNotificationIdentityLoad = .none
        func load() throws -> BighelpNotificationIdentityLoad { value }
        func save(_ record: BighelpNotificationIdentityRecord) throws { value = .current(record) }
        func delete() throws { value = .none }
    }
    @MainActor private final class NoNetworkTransport: BighelpLinkHTTPTransport {
        private(set) var bindingRequests = 0
        var installationRevokeFails = false
        private(set) var revokedInstallations: [String] = []

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if request.httpMethod == "POST",
               request.url?.path == BighelpNotificationBrokerClient.bootstrapPath,
               let requestBody = request.httpBody,
               let object = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
               let installationID = object["installationId"] as? String,
               let url = request.url,
               let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil) {
                let body = try JSONSerialization.data(withJSONObject: [
                    "version": 2,
                    "credential": [
                        "scope": "notification-only",
                        "installationId": installationID,
                        "authorizationEpoch": 1,
                    ],
                ])
                return (body, response)
            }
            if request.httpMethod == "POST",
               request.url?.path == "/v1/notifications/installations/current/account-binding",
               request.value(forHTTPHeaderField: "x-loopdy-notification-installation") != nil,
               request.value(forHTTPHeaderField: "x-loopdy-account-device-id") == "fixture-mobile",
               let requestBody = request.httpBody,
               let object = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
               object["version"] as? Int == 1,
               let grantID = object["grantId"] as? String,
               let url = request.url,
               let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) {
                bindingRequests += 1
                let body = try JSONSerialization.data(withJSONObject: [
                    "version": 2,
                    "binding": ["installationId": request.value(
                        forHTTPHeaderField: "x-loopdy-notification-installation"
                    )!, "grantId": grantID, "state": "active"],
                ])
                return (body, response)
            }
            if request.httpMethod == "DELETE",
               request.url?.path == BighelpNotificationBrokerClient.currentInstallationPath,
               installationRevokeFails, let url = request.url,
               let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil) {
                // The Worker when BuzzKit doesn't confirm deleting the subscriber.
                let body = try JSONSerialization.data(withJSONObject: [
                    "version": 2, "error": ["code": "notification_cleanup_unavailable"],
                ])
                return (body, response)
            }
            if request.httpMethod == "DELETE",
               request.url?.path == BighelpNotificationBrokerClient.currentInstallationPath,
               let installationID = request.value(forHTTPHeaderField: "x-loopdy-notification-installation"),
               let url = request.url,
               let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) {
                revokedInstallations.append(installationID)
                let body = try JSONSerialization.data(withJSONObject: [
                    "version": 2,
                    "installation": ["installationId": installationID, "state": "revoked"],
                ])
                return (body, response)
            }
            Issue.record("Unexpected network request in isolated notification fixture")
            throw DirectHermesError.invalidResponse
        }
    }
    @MainActor private final class Fixture {
        let root: URL; let registry: BighelpHostRegistry; private let storedHost: BighelpConfiguredHost
        var host: BighelpConfiguredHost { registry.hosts.first { $0.id == storedHost.id } ?? storedHost }
        let connection: DirectHermesSavedConnection; let ledger: BighelpManagedNotificationLedger
        let trust: BighelpNotificationHostTrustStore; let service: BighelpManagedNotificationService
        let sealedKeys = BighelpNotificationRecipientKeyStore(accessGroup: nil, account: "test." + UUID().uuidString)
        let sealedSenders = BighelpSealedAlertSenderStore(accessGroup: nil, service: "app.loopdy.test.sealed." + UUID().uuidString)
        let account: Account; let hostAPI: Host
        private let notificationTransport: NoNetworkTransport
        var bindingRequests: Int { notificationTransport.bindingRequests }
        var transport: NoNetworkTransport { notificationTransport }
        let defaultsSuite: String
        let defaults: UserDefaults
        let identityVault = MemoryIdentityVault()
        let provider = Provider()
        init(approvalSupported: Bool = false, independent: Bool = false, dashboard: Bool = false,
             permissionGranted: Bool = true, notificationDeviceID: String? = nil,
             providerOverride: (any BighelpManagedNotificationProvider)? = nil) throws {
            root=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
            let suite = "bighelp.test.notifications." + UUID().uuidString
            defaultsSuite = suite
            defaults = UserDefaults(suiteName: suite)!
            let deviceID = "fixture-mobile"
            registry=BighelpHostRegistry(root:root.appending(path:"hosts"),keychainService:"app.loopdy.test."+UUID().uuidString)
            registry.bind(deviceID:deviceID,authorizationEpoch:1)
            if independent { registry.useIndependentWorkspace() }
            let endpoint=try DirectHermesEndpoint(address:"https://host.example")
            connection = dashboard
                ? DirectHermesSavedConnection(endpoint: endpoint, authentication: .dashboardSession(token: "fixture-session", automatic: true))
                : DirectHermesSavedConnection(endpoint:endpoint,authentication:.bearer(accessToken:UUID().uuidString,refreshToken:nil,expiresAt:nil),provider:"basic",userID:"person")
            let host=BighelpConfiguredHost(id:UUID(),accountScope:try #require(registry.accountScope),accountID:independent ? nil : deviceID,endpoint:endpoint,principalIdentity:connection.identity,name:"Host", connectionMode: independent ? .independent : nil)
            storedHost = host
            struct Snapshot: Encodable { let version:Int; let hosts:[BighelpConfiguredHost];let selected:UUID? }
            let hostRoot = root.appending(path: independent ? "hosts-independent" : "hosts")
            try FileManager.default.createDirectory(at:hostRoot,withIntermediateDirectories:true)
            try JSONEncoder().encode(Snapshot(version: independent ? 2 : 1,hosts:[host],selected:host.id)).write(to:hostRoot.appending(path:host.accountScope+".json"))
            registry.retryLoading()
            registry.workspace(for:host).selectedProfile="default"
            let hostKey=P256.Signing.PrivateKey().publicKey.x963Representation
            let hostKeyID=BighelpNotificationBase64URL.encode(Data(SHA256.hash(data:hostKey)))
            let template=BighelpManagedGrant(grantId:UUID().uuidString.lowercased(),instanceId:host.hostConnectionID.lowercased(),hostKeyId:hostKeyID,hostPublicKey:BighelpNotificationBase64URL.encode(hostKey),
                authorizationEpoch:1,profile:"default",eventTypes:ManagedNotificationValidation.eventTypes.sorted(),
                createdAt:1_800_000_000,expiresAt:1_800_010_000,revision:1,provider:"buzzkit",subscriberScope:"notification-instance",state:"active")
            account=Account(template)
            trust=BighelpNotificationHostTrustStore(accessGroup:nil,service:"app.loopdy.test.trust."+UUID().uuidString)
            let hostClient=Host(account,trust)
            // All four notification categories are required by the current enrollment contract.
            hostAPI=hostClient
            ledger=try BighelpManagedNotificationLedger(root:root.appending(path:"ledger"))
            let localLedger = ledger
            let localHostID = host.id
            let localRegistry = registry
            hostClient.hasPersistedGrant = {
                guard let current = localRegistry.hosts.first(where: { $0.id == localHostID }) else { return false }
                return localLedger.record(host: current, profile: "default")?.grant != nil
            }
            let noNetwork = NoNetworkTransport()
            notificationTransport = noNetwork
            let broker = BighelpNotificationBrokerClient(transport: noNetwork)
            identityVault.value = .current(.active(.init(
                deviceID: notificationDeviceID ?? deviceID,
                authorizationEpoch: 1,
                signingPrivateKey: P256.Signing.PrivateKey()
            )))
            let identity = BighelpNotificationIdentityCoordinator(vault: identityVault, broker: broker)
            service=BighelpManagedNotificationService(identity:identity,api:account,requestPermission:{permissionGranted},registry:registry,ledger:ledger,
                activityKeys:BighelpManagedActivityKeychain(service:"app.loopdy.test.activities."+UUID().uuidString),hostClient:{_ in hostClient},now:{Date(timeIntervalSince1970:1_800_000_100)},buzzKit:providerOverride ?? provider,
                sealedRecipientKeys:sealedKeys,sealedSenders:sealedSenders,defaults:defaults)
        }
        func cleanup(){ defaults.removePersistentDomain(forName: defaultsSuite); try? trust.removeAll(); try? sealedKeys.remove(); try? sealedSenders.removeAll(); registry.bind(deviceID:nil,authorizationEpoch:nil); try? FileManager.default.removeItem(at:root) }
    }
}
