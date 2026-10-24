import CryptoKit
import Foundation
import Testing
@testable import Bighelp

/// The real notification service, its real hooks and the real signer, against the fake Worker of
/// `PushRegistrarTests`: what an update does for a phone that already has notifications.
@MainActor struct PushEnrollmentIntegrationTests {
    private static let token = Data(repeating: 0x5A, count: 32)

    @MainActor private final class Vault: BighelpNotificationIdentityVault {
        var value: BighelpNotificationIdentityLoad = .none
        func load() throws -> BighelpNotificationIdentityLoad { value }
        func save(_ record: BighelpNotificationIdentityRecord) throws { value = .current(record) }
        func delete() throws { value = .none }
    }

    /// BuzzKit's side, which stays as it is: it identifies and does nothing else here.
    @MainActor private final class Provider: BighelpManagedNotificationProvider {
        private(set) var identifications = 0
        func identify(accountAPI: any BighelpManagedNotificationAccountAPI,
                      credentials: BighelpManagedNotificationCredentials) async throws { identifications += 1 }
        func registerCurrentDevice() async throws {}
        func refreshProviderReadiness(accountAPI: any BighelpManagedNotificationAccountAPI,
                                      credentials: BighelpManagedNotificationCredentials,
                                      requiringCurrentRegistration: Bool) async throws -> BighelpBuzzKitProviderReadiness {
            throw DirectHermesError.notConnected
        }
        func retireIdentityForLocalErasure() async {}
    }

    @MainActor private final class Rig {
        let worker = PushRegistrarTests.FakeWorker()
        let clock = PushRegistrarTests.TestClock()
        let vault = Vault()
        let provider = Provider()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "bighelp.test.push-enrollment." + UUID().uuidString
        let defaults: UserDefaults
        let sealedKeys = BighelpNotificationRecipientKeyStore(accessGroup: nil, account: "test." + UUID().uuidString)
        let sealedSenders = BighelpSealedAlertSenderStore(accessGroup: nil, service: "app.loopdy.test.sealed." + UUID().uuidString)
        let service: BighelpManagedNotificationService
        let integration: BighelpManagedNotificationIntegration
        let registrar: BighelpPushRegistrar
        let installationID = UUID().uuidString.lowercased()
        @MainActor private final class Flags {
            var authorized = true
            var registerRequests = 0
        }
        private let flags = Flags()
        var authorized: Bool {
            get { flags.authorized }
            set { flags.authorized = newValue }
        }
        var registerRequests: Int { flags.registerRequests }

        init(hasInstallation: Bool = true) throws {
            defaults = UserDefaults(suiteName: suite)!
            let key = P256.Signing.PrivateKey()
            worker.publicKey = key.publicKey
            worker.installationID = installationID
            if hasInstallation {
                vault.value = .current(.active(.init(deviceID: installationID, authorizationEpoch: 1, signingPrivateKey: key)))
            }
            let broker = BighelpNotificationBrokerClient(transport: worker, now: { [clock] in clock.now })
            let registry = BighelpHostRegistry(root: root.appending(path: "hosts"),
                                               keychainService: "app.loopdy.test." + UUID().uuidString)
            service = BighelpManagedNotificationService(
                identity: BighelpNotificationIdentityCoordinator(vault: vault, broker: broker), api: broker,
                requestPermission: { true }, registry: registry,
                ledger: try BighelpManagedNotificationLedger(root: root.appending(path: "ledger")),
                activityKeys: BighelpManagedActivityKeychain(service: "app.loopdy.test.activities." + UUID().uuidString),
                hostClient: { _ in throw DirectHermesError.notConnected }, buzzKit: provider,
                sealedRecipientKeys: sealedKeys, sealedSenders: sealedSenders, defaults: defaults)
            service.activityRuntime = BighelpManagedNativeActivityRuntime(
                service: service, environment: .sandbox, topic: "app.loopdy.test")
            let flags = flags
            registrar = BighelpPushRegistrar(
                api: broker, credentials: { [weak service] in service?.installationCredentials() },
                isTurningOff: { [weak service] in service?.turnOffPending ?? true },
                isAuthorized: { flags.authorized }, environment: { .sandbox }, appVersion: "2.7.0(160)",
                registerForRemoteNotifications: { flags.registerRequests += 1 },
                mutedTopics: { ["scheduled-tasks-deliveries"] },
                defaults: defaults, now: { [clock] in clock.now })
            service.pushRegistrar = registrar
            integration = BighelpManagedNotificationIntegration(service: service)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? sealedKeys.remove(); try? sealedSenders.removeAll()
            try? FileManager.default.removeItem(at: root)
            BighelpBuzzKitRuntime.shared.forgetPushToken()
        }

        /// The hook starts the send in the background; wait for the Worker to see it.
        func waitForPuts(_ count: Int) async {
            for _ in 0..<500 where worker.puts.count < count { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    @Test func updatingAnExistingPhoneEnrollsItAtLaunchWithoutAnyAction() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        // Launch: the app's usual foreground recovery runs. It asks iOS for the token.
        try await rig.integration.hooks.recoverForeground { true }
        #expect(rig.registerRequests == 1)
        #expect(rig.provider.identifications == 1, "BuzzKit's own launch work is unchanged")
        // iOS answers through the app delegate's hook: BuzzKit gets it, and so does the registrar.
        rig.integration.hooks.didRegisterAPNSToken(Self.token)
        await rig.waitForPuts(1)
        let put = try #require(rig.worker.puts.first)
        #expect(put.path == "/v1/notifications/push-target")
        #expect(put.body["token"] as? String == String(repeating: "5a", count: 32))
        #expect(put.body["environment"] as? String == "sandbox")
        #expect(put.body["mutedTopics"] as? [String] == ["scheduled-tasks-deliveries"])
        #expect(rig.worker.badSignatures == 0)
        #expect(rig.registrar.state.alert?.installationID == rig.installationID)
        // The next launch, same token: nothing more is sent.
        try await rig.integration.hooks.recoverForeground { true }
        rig.integration.hooks.didRegisterAPNSToken(Self.token)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.worker.puts.count == 1)
    }

    @Test func aPhoneThatNeverTurnedNotificationsOnStaysQuiet() async throws {
        let rig = try Rig(hasInstallation: false)
        defer { rig.cleanup() }
        try await rig.integration.hooks.recoverForeground { true }
        rig.integration.hooks.didRegisterAPNSToken(Self.token)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.registerRequests == 0)
        #expect(rig.worker.calls.isEmpty)
    }

    @Test func anUpdatedPhoneAgainstAnOlderWorkerKeepsWorkingAndSaysNothing() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        rig.worker.mode = .notDeployed
        try await rig.integration.hooks.recoverForeground { true }
        rig.integration.hooks.didRegisterAPNSToken(Self.token)
        await rig.waitForPuts(1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.registrar.state.unavailableUntil == rig.clock.now.addingTimeInterval(24 * 3600))
        #expect(rig.registrar.state.lastErrorCode == nil)
        #expect(rig.service.registry.notificationSetupError == nil, "Nothing shown")
        #expect(rig.provider.identifications == 1, "BuzzKit's registration still ran")
    }

    @Test func turningNotificationsOffRemovesTheAddressesBeforeTheInstallation() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try await rig.integration.hooks.recoverForeground { true }
        rig.integration.hooks.didRegisterAPNSToken(Self.token)
        await rig.waitForPuts(1)
        #expect(rig.worker.targets["alert"] != nil)

        _ = try await rig.service.turnOffNotifications()
        #expect(rig.worker.targets.isEmpty)
        #expect(rig.worker.deletes.map(\.path) == [
            BighelpPushRegistrar.pushTargetPath, BighelpPushRegistrar.liveActivityTargetPath,
            BighelpNotificationBrokerClient.currentInstallationPath,
        ])
        #expect(rig.worker.revokedInstallations == [rig.installationID])
        #expect(rig.vault.value == .none)
        #expect(rig.registrar.state == BighelpPushRegistrar.State())
        #expect(rig.worker.badSignatures == 0)

        // With no installation left, the next launch asks for nothing.
        let asked = rig.registerRequests
        try await rig.integration.hooks.recoverForeground { true }
        #expect(rig.registerRequests == asked)
    }
}
