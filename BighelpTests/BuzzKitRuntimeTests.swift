import BuzzKit
import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import Bighelp

@MainActor struct BuzzKitRuntimeTests {
    @Test func activityObservationIsInstalledOnceAcrossIdentityRefreshAndReidentify() async throws {
        let fixture = Fixture()
        #expect(fixture.runtime.configureIfPossible())
        try await fixture.identify()
        try await fixture.identify()
        #expect(fixture.sdk.activityObservations == 1)

        fixture.runtime.logout()
        fixture.runtime.noteAPNSToken(Data([0x01, 0x02]))
        try await fixture.identify()
        #expect(fixture.sdk.activityObservations == 1)
    }

    @Test func refreshRestoresReadinessWithoutRegisteringAgain() async throws {
        let fixture = Fixture()
        try await fixture.identify()
        try await fixture.runtime.registerCurrentDevice()
        _ = try await fixture.refresh(requiringRegistration: true)
        #expect(fixture.sdk.registrations == 1)
        for _ in 0..<2 {
            try await fixture.identify()
            _ = try await fixture.refresh(requiringRegistration: false)
            #expect(fixture.runtime.state == .ready(externalId: fixture.api.externalID, activePushRegistrations: 1))
        }
        #expect(fixture.sdk.registrations == 1)
        #expect(fixture.api.statusBodies.allSatisfy {
            $0["tokenHash"]?.string == fixture.tokenHash && $0["environment"]?.string == "sandbox"
        })
        do {
            _ = try await fixture.refresh(requiringRegistration: true)
            Issue.record("Read-only refresh must not establish explicit registration proof")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .deviceRegistration)
        }
    }

    @Test func freshReadbackDoesNotAuthorizeEnrollmentWithoutRegistration() async throws {
        let fixture = Fixture()
        try await fixture.identify()
        _ = try await fixture.refresh(requiringRegistration: false)
        #expect(fixture.sdk.registrations == 0)
        do {
            _ = try await fixture.refresh(requiringRegistration: true)
            Issue.record("Explicit enrollment requires registration")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .deviceRegistration)
        }
    }

    @Test(arguments: ["environment", "topics", "device", "credential"])
    func incompleteReadbackNeverBecomesReady(defect: String) async throws {
        let fixture = Fixture()
        fixture.api.defect = defect
        try await fixture.identify()
        let readiness = try await fixture.refresh(requiringRegistration: false)
        #expect(!readiness.isReady(environment: "sandbox"))
        #expect(fixture.runtime.state == .identitySubmitted(externalId: fixture.api.externalID))
        #expect(fixture.sdk.registrations == 0)
    }

    @Test func identityFailureSurfacesServerCodeForRevokedRetry() async throws {
        let fixture = Fixture()
        fixture.api.identityError = BighelpLinkAPIError.requestFailed(
            status: 410, code: "notification_credentials_revoked")
        do {
            try await fixture.identify()
            Issue.record("A revoked identity must fail")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .providerIdentity)
            #expect(error.code == "notification_credentials_revoked",
                    "The server code must survive so enroll() can retry with fresh credentials")
        }
    }

    @Test func identityTransportFailureCarriesDiagnosticCode() async throws {
        let fixture = Fixture()
        fixture.api.identityError = BighelpLinkAPIError.invalidResponse
        do {
            try await fixture.identify()
            Issue.record("An invalid identity response must fail")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .providerIdentity)
            #expect(error.code == "identity_invalid_response")
        }
    }

    @Test func readinessBackendFailureSurfacesStatusAndCode() async throws {
        let fixture = Fixture()
        try await fixture.identify()
        fixture.api.statusError = BighelpLinkAPIError.requestFailed(
            status: 503, code: "missing_identity_secret")
        do {
            _ = try await fixture.refresh(requiringRegistration: false)
            Issue.record("A failed readiness request must throw")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .providerReadiness)
            #expect(error.code == "link_backend_503_missing_identity_secret")
        }
    }

    @Test(arguments: [
        ("environment", "readiness_no_active_push_credential_sandbox"),
        ("credential", "readiness_no_active_push_credential_sandbox"),
        ("device", "readiness_device_unmatched"),
        ("topics", "readiness_topics_incomplete"),
        ("unverified", "readiness_subscriber_unverified"),
        ("unidentified", "readiness_subscriber_unidentified"),
    ])
    func explicitReadinessNamesTheUnmetPrerequisite(defect: String, code: String) async throws {
        let fixture = Fixture()
        try await fixture.identify()
        try await fixture.runtime.registerCurrentDevice()
        fixture.api.defect = defect
        do {
            _ = try await fixture.refresh(requiringRegistration: true)
            Issue.record("An incomplete readback must fail explicit enrollment readiness")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .providerReadiness)
            #expect(error.code == code)
        }
    }

    @Test func apnsRegistrationFailureFailsFastWithRealError() async throws {
        let fixture = Fixture()
        try await fixture.identify()
        fixture.sdk.onRegister = nil
        let operation = Task { try await fixture.runtime.registerCurrentDevice() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.sdk.registrations == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(fixture.sdk.registrations == 1)
        fixture.runtime.noteAPNsRegistrationFailure(URLError(.notConnectedToInternet))
        do {
            try await operation.value
            Issue.record("A failed APNs registration must throw")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .deviceRegistration)
            #expect(error.code == "apns_registration_failed")
        }
        #expect(fixture.sdk.exactTokens.isEmpty)
    }

    @Test(arguments: [false, true])
    func sdkThrownRegistrationErrorPreservesFreshAPNsFailure(freshFailure: Bool) async throws {
        let fixture = Fixture()
        try await fixture.identify()
        // Without a cached token the real SDK throws BuzzKitError.network
        // after the delegate failure, before bighelp reaches its own token wait.
        fixture.sdk.onRegister = {
            if freshFailure {
                fixture.runtime.noteAPNsRegistrationFailure(URLError(.notConnectedToInternet))
            }
            throw BuzzKitError.network(underlying: URLError(.notConnectedToInternet))
        }
        do {
            try await fixture.runtime.registerCurrentDevice()
            Issue.record("Failed SDK registration cannot enroll")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .deviceRegistration)
            #expect(error.code == (freshFailure ? "apns_registration_failed" : "buzzkit_device_registration_failed"))
        }
        #expect(fixture.sdk.exactTokens.isEmpty)
    }

    @Test func tokenAfterSixSecondsOutlastsOldWaitAndIgnoresStaleFailure() async throws {
        let fixture = Fixture()
        try await fixture.identify()
        fixture.runtime.noteAPNsRegistrationFailure(URLError(.notConnectedToInternet))
        fixture.sdk.onRegister = nil
        let operation = Task { try await fixture.runtime.registerCurrentDevice() }
        try await Task.sleep(for: .seconds(6))
        fixture.runtime.noteAPNSToken(Data([0x03]))
        try await operation.value
        #expect(fixture.sdk.exactTokens == [Data([0x03])])
    }

    @Test(arguments: [false, true])
    func staleReadbackCannotPublishAfterLogoutOrTokenRotation(rotateToken: Bool) async throws {
        let fixture = Fixture()
        try await fixture.identify()
        fixture.api.onStatus = {
            if rotateToken { fixture.runtime.noteAPNSToken(Data([0x03])) }
            else { fixture.runtime.logout() }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await fixture.refresh(requiringRegistration: false)
        }
        #expect(fixture.runtime.providerReadiness == nil)
        #expect(fixture.sdk.registrations == 0)
    }

    @Test func readinessRejectsDifferentCredentialsBeforeProviderRequest() async throws {
        let fixture = Fixture()
        try await fixture.identify()
        let other = BighelpManagedNotificationCredentials(deviceID: "other",
            authorizationEpoch: 1, signingPrivateKey: P256.Signing.PrivateKey())
        do {
            _ = try await fixture.runtime.refreshProviderReadiness(accountAPI: fixture.api, credentials: other)
            Issue.record("A different identity cannot borrow readiness")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .providerIdentity)
        }
        #expect(fixture.api.statusBodies.isEmpty)
    }

    @Test func bootstrapAndPermissionFailuresStayProviderScoped() async throws {
        let fixture = Fixture()
        fixture.sdk.isConfigured = false
        do {
            try await fixture.identify()
            Issue.record("An unconfigured fake must not configure the live SDK")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .providerBootstrap)
        }
        fixture.sdk.isConfigured = true
        fixture.sdk.permission = .denied
        try await fixture.identify()
        do {
            try await fixture.runtime.registerCurrentDevice()
            Issue.record("Denied permission must not register")
        } catch let error as BighelpManagedNotificationSetupError {
            #expect(error.stage == .notificationPermission)
        }
        #expect(fixture.sdk.registrations == 0)
    }

    @Test func cachedTokenWaitsForFreshCallbackBeforeExactRegistration() async throws {
        let fixture = Fixture()
        try await fixture.identify()
        fixture.sdk.onRegister = nil
        let operation = Task { try await fixture.runtime.registerCurrentDevice() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.sdk.registrations == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(fixture.sdk.registrations == 1)
        #expect(fixture.sdk.exactTokens.isEmpty)
        fixture.runtime.noteAPNSToken(Data([0x03]))
        try await operation.value
        #expect(fixture.sdk.exactTokens == [Data([0x03])])
        _ = try await fixture.refresh(requiringRegistration: true)
    }

    @Test func sameTokenFreshCallbackStillQualifies() async throws {
        let fixture = Fixture()
        try await fixture.identify()
        try await fixture.runtime.registerCurrentDevice()
        #expect(fixture.sdk.exactTokens == [Data([0x01, 0x02])])
        _ = try await fixture.refresh(requiringRegistration: true)
    }

    @Test func cancellationBeforeAPNsCallbackCannotPublishRegistration() async throws {
        let fixture = Fixture()
        try await fixture.identify()
        fixture.sdk.onRegister = nil
        let operation = Task { try await fixture.runtime.registerCurrentDevice() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.sdk.registrations == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(fixture.sdk.exactTokens.isEmpty)
        fixture.runtime.noteAPNSToken(Data([0x03]))
        #expect(fixture.runtime.providerReadiness == nil)
    }

    @Test(arguments: ["identity", "token", "environment"])
    func exactSDKReceiptMustMatchCurrentOwner(defect: String) async throws {
        let fixture = Fixture()
        try await fixture.identify()
        fixture.sdk.registrationDefect = defect
        do { try await fixture.runtime.registerCurrentDevice(); Issue.record("Foreign registration was accepted") }
        catch let error as BighelpManagedNotificationSetupError { #expect(error.stage == .deviceRegistration) }
        #expect(fixture.runtime.providerReadiness == nil)
    }

    @Test func tokenRotationDuringExactRegistrationCannotPublishProof() async throws {
        let fixture = Fixture()
        try await fixture.identify()
        fixture.sdk.onExactRegistration = { fixture.runtime.noteAPNSToken(Data([0x03])) }
        await #expect(throws: CancellationError.self) { try await fixture.runtime.registerCurrentDevice() }
        #expect(fixture.runtime.providerReadiness == nil)
    }

    @MainActor private final class SDK: BighelpAwaitableBuzzKitSDK {
        var isConfigured = true
        var permission: UNAuthorizationStatus = .authorized
        var registrations = 0
        var externalID = ""
        var logoutCount = 0
        var activityObservations = 0
        var exactTokens: [Data] = []
        var onRegister: (() throws -> Void)?
        var onExactRegistration: (() -> Void)?
        var registrationDefect: String?
        func identify(_ externalId: String, identityHash: String) { externalID = externalId }
        func identifyAndWait(_ externalId: String, identityHash: String) async throws {
            identify(externalId, identityHash: identityHash)
        }
        func logout() { logoutCount += 1; externalID = "" }
        func logoutAndWait() async throws { logout() }
        func registerPushSubscription(deviceToken: Data) async throws -> BuzzKit.PushSubscriptionRegistration {
            exactTokens.append(deviceToken)
            onExactRegistration?()
            return .init(
                id: "fixture-subscription",
                externalId: registrationDefect == "identity" ? "other" : externalID,
                endpoint: registrationDefect == "token"
                    ? "other"
                    : deviceToken.map { String(format: "%02x", $0) }.joined(),
                environment: registrationDefect == "environment" ? .production : .sandbox
            )
        }
        func notificationPermission() async -> UNAuthorizationStatus { permission }
        func registerForPush() async throws { registrations += 1; try onRegister?() }
        func migrateLegacyPreferences() async throws {}
        func observeActivities() { activityObservations += 1 }
    }

    @MainActor private final class Account: BighelpManagedNotificationAccountAPI {
        let externalID = "notify_" + String(repeating: "a", count: 43)
        var defect: String?
        var identityError: (any Error)?
        var statusError: (any Error)?
        var statusBodies: [[String: BighelpJSONValue]] = []
        var onStatus: (() -> Void)?
        func managedNotificationRequest(path: String, method: String, body: Data?,
                                        credentials: BighelpManagedNotificationCredentials) async throws -> BighelpJSONValue {
            if path == BighelpManagedNotificationService.root + "/buzzkit/identity" {
                if let identityError { throw identityError }
                #expect(method == "GET" && body == nil)
                return .object(["version": .integer(2), "identity": .object([
                    "externalId": .string(externalID), "identityHash": .string(String(repeating: "b", count: 64))
                ])])
            }
            #expect(path == BighelpManagedNotificationService.root + "/buzzkit/status" && method == "POST")
            if let statusError { throw statusError }
            let requestBody = try #require(body)
            let decoded = try JSONDecoder().decode(BighelpJSONValue.self, from: requestBody)
            statusBodies.append(try #require(decoded.object))
            onStatus?()
            let environment = defect == "environment" ? "production" : "sandbox"
            let topics = defect == "topics" ? [] : BighelpBuzzKitTopic.allCases.map(\.rawValue)
            return .object(["version": .integer(2), "readiness": .object([
                "configured": .boolean(true),
                "pushCredentials": .array([.object(["environment": .string(environment),
                    "status": .string(defect == "credential" ? "invalid" : "active")])]),
                "subscriber": .object([
                    "identified": .boolean(defect != "unidentified"), "verified": .boolean(defect != "unverified"),
                    "activeIOSPushEnvironments": .array([.string(environment)]),
                    "currentDevice": .object(["matched": .boolean(defect != "device"),
                        "environment": .string(environment), "enabled": .boolean(true), "active": .boolean(true),
                        "subscriptionId": .string("fixture-subscription")])
                ]),
                "topicSlugs": .array(topics.map(BighelpJSONValue.string))
            ])])
        }
    }

    @MainActor private final class Fixture {
        let sdk = SDK()
        let api = Account()
        let runtime: BighelpBuzzKitRuntime
        let credentials = BighelpManagedNotificationCredentials(deviceID: "fixture-device",
            authorizationEpoch: 1, signingPrivateKey: P256.Signing.PrivateKey())
        let tokenHash = SHA256.hash(data: Data("0102".utf8)).map { String(format: "%02x", $0) }.joined()
        init() {
            runtime = BighelpBuzzKitRuntime(testingSDK: sdk)
            runtime.noteAPNSToken(Data([0x01, 0x02]))
            sdk.onRegister = { [weak runtime] in runtime?.noteAPNSToken(Data([0x01, 0x02])) }
        }
        func identify() async throws { try await runtime.identify(accountAPI: api, credentials: credentials) }
        func refresh(requiringRegistration: Bool) async throws -> BighelpBuzzKitProviderReadiness {
            try await runtime.refreshProviderReadiness(accountAPI: api, credentials: credentials,
                requiringCurrentRegistration: requiringRegistration)
        }
    }
}
