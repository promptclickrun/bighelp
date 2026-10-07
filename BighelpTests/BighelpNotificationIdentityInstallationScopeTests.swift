import CryptoKit
import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BighelpNotificationIdentityInstallationScopeTests {
    @Test
    func enrollmentBootstrapsANotificationOnlyInstallation() async throws {
        let notificationVault = MemoryNotificationIdentityVault()
        let transport = NotificationBootstrapTransport()
        let coordinator = makeCoordinator(notificationVault: notificationVault, transport: transport)

        let credentials = try await coordinator.resolveForEnrollment()
        let again = try await coordinator.resolveForEnrollment()

        #expect(credentials.subscriberScope == "notification-instance")
        #expect(again == credentials)
        #expect(transport.requestOrder == ["bootstrap"])
        #expect(try coordinator.current() == credentials)
    }
    @Test
    func explicitEnrollmentReplacesOnlyAnAuthoritativelyRevokedInstallation() async throws {
        let revoked = BighelpManagedNotificationCredentials(
            deviceID: UUID().uuidString.lowercased(),
            authorizationEpoch: 1,
            signingPrivateKey: P256.Signing.PrivateKey()
        )
        let notificationVault = MemoryNotificationIdentityVault(value: .current(.active(revoked)))
        let transport = NotificationBootstrapTransport()
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            transport: transport
        )

        let replacement = try await coordinator.replaceRevokedForEnrollment(expected: revoked)

        #expect(replacement.deviceID != revoked.deviceID)
        #expect(replacement.authorizationEpoch == 1)
        #expect(transport.bootstrapRequests == 1)
        #expect(try coordinator.current() == replacement)
    }

    @Test
    func concurrentEnrollmentResolutionsShareOneBootstrap() async throws {
        let notificationVault = MemoryNotificationIdentityVault()
        let transport = NotificationBootstrapTransport()
        transport.suspendBootstrapResponses()
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            transport: transport
        )

        let first = Task { @MainActor in try await coordinator.resolveForEnrollment() }
        await transport.waitForBootstrapRequests(1)

        let secondStarted = IdentityOperationStartSignal()
        let second = Task { @MainActor in
            secondStarted.signal()
            return try await coordinator.resolveForEnrollment()
        }
        await secondStarted.wait()

        let requestsWhileFirstWasSuspended = transport.bootstrapRequests
        transport.resumeAllBootstrapResponses()
        let firstCredentials = try await first.value
        let secondCredentials = try await second.value

        #expect(requestsWhileFirstWasSuspended == 1,
                "A concurrent resolver must join or wait for the suspended bootstrap")
        #expect(transport.bootstrapRequests == 1)
        #expect(firstCredentials == secondCredentials)
        #expect(try coordinator.current() == firstCredentials)
    }

    @Test
    func eraseWaitsForSuspendedBootstrapAndLeavesNoActiveIdentity() async throws {
        let notificationVault = MemoryNotificationIdentityVault()
        let transport = NotificationBootstrapTransport()
        transport.suspendBootstrapResponses()
        let coordinator = makeCoordinator(
            notificationVault: notificationVault,
            transport: transport
        )

        let resolution = Task { @MainActor in try await coordinator.resolveForEnrollment() }
        await transport.waitForBootstrapRequests(1)

        let eraseStarted = IdentityOperationStartSignal()
        let erasure = Task { @MainActor in
            eraseStarted.signal()
            try await coordinator.erase()
        }
        await eraseStarted.wait()

        let requestsWhileResolutionWasSuspended = transport.bootstrapRequests
        if requestsWhileResolutionWasSuspended == 1 {
            transport.resumeBootstrapResponse(at: 0)
            _ = try await resolution.value
            try await erasure.value
        } else {
            // Drive the old race deterministically: erasure's recovery finishes
            // and deletes first, then the original resolver completes and saves.
            transport.resumeBootstrapResponse(at: 1)
            try await erasure.value
            transport.resumeBootstrapResponse(at: 0)
            _ = try await resolution.value
        }

        #expect(requestsWhileResolutionWasSuspended == 1,
                "Erasure must serialize behind an already-started bootstrap")
        #expect(notificationVault.value == .none,
                "A bootstrap started before erasure must not restore active credentials afterward")
        #expect(try coordinator.current() == nil)
    }

    @Test
    func versionLessIdentityErrorBodyStillSurfacesServerCode() async throws {
        let transport = IdentityErrorTransport()
        let broker = BighelpNotificationBrokerClient(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            nonce: { "fixture-nonce" }
        )
        let credentials = BighelpManagedNotificationCredentials(
            deviceID: UUID().uuidString.lowercased(),
            authorizationEpoch: 1,
            signingPrivateKey: P256.Signing.PrivateKey()
        )

        do {
            _ = try await broker.managedNotificationRequest(
                path: BighelpManagedNotificationService.root + "/buzzkit/identity",
                method: "GET",
                body: nil,
                credentials: credentials
            )
            Issue.record("Expected the identity request to fail")
        } catch let error as BighelpLinkAPIError {
            guard case .requestFailed(let status, let code) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(status == 410)
            #expect(code == "notification_credentials_revoked",
                    "The revoked-credentials code must survive so enrollment can retry with fresh credentials")
        }
    }

    // MARK: An unreadable saved identity (#254)

    /// On a TestFlight iPhone, setup and turn-off both stopped at "BighelpLinkCryptoError" right after
    /// the Keychain read: the saved identity couldn't be read, and nothing went past it.
    @Test
    func setupStartsFreshWhenTheSavedIdentityCantBeRead() async throws {
        let notificationVault = MemoryNotificationIdentityVault(value: .unreadable)
        let transport = NotificationBootstrapTransport()
        let coordinator = makeCoordinator(notificationVault: notificationVault, transport: transport)

        let credentials = try await coordinator.resolveForEnrollment()

        #expect(transport.requestOrder == ["bootstrap"], "A new identity registers; nothing else is asked")
        #expect(try coordinator.current() == credentials)
    }

    @Test
    func turnOffRemovesAnUnreadableIdentityAndSaysTheOldOneWasntCancelled() async throws {
        let notificationVault = MemoryNotificationIdentityVault(value: .unreadable)
        let transport = NotificationBootstrapTransport()
        let coordinator = makeCoordinator(notificationVault: notificationVault, transport: transport)

        let erasure = try await coordinator.erase()

        #expect(erasure == .removedHereOnly, "Without its key, the old registration can't be cancelled from here")
        #expect(transport.requestOrder.isEmpty)
        #expect(notificationVault.value == .none)
    }

    @Test
    func turnOffCancelsAReadableIdentity() async throws {
        let notificationVault = MemoryNotificationIdentityVault()
        let transport = NotificationBootstrapTransport()
        let coordinator = makeCoordinator(notificationVault: notificationVault, transport: transport)
        _ = try await coordinator.resolveForEnrollment()

        #expect(try await coordinator.erase() == .revoked)
        #expect(try await coordinator.erase() == .nothingSaved)
    }

    /// A damaged record in the real Keychain vault reads as unreadable instead of stopping setup.
    @Test
    func theKeychainVaultReportsADamagedRecordAsUnreadable() throws {
        let service = "app.loopdy.mobile.tests.notification-identity.\(UUID().uuidString)"
        let marker = FileManager.default.temporaryDirectory.appending(path: "marker-\(UUID().uuidString)")
        let vault = BighelpNotificationKeychainIdentityVault(service: service, markerFile: marker)
        defer { try? vault.delete() }
        let installation = UUID().uuidString.lowercased()
        let damaged = """
        {"version":2,"state":"active","installationMarker":"\(UUID().uuidString.lowercased())",
         "installationID":"\(installation)","authorizationEpoch":1,"signingPrivateKey":"not a key!"}
        """
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "notification-identity-v2",
                                    kSecValueData as String: Data(damaged.utf8)]
        #expect(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)

        #expect(try vault.load() == .unreadable)
        try vault.delete()
        #expect(try vault.load() == .none)

        // A good record still reads back after the damaged one is gone.
        let key = P256.Signing.PrivateKey()
        let credentials = BighelpManagedNotificationCredentials(deviceID: installation, authorizationEpoch: 1,
                                                               signingPrivateKey: key)
        try vault.save(.active(credentials))
        #expect(try vault.load() == .current(.active(credentials)))
    }

    /// Base64url is checked byte by byte: Foundation's CharacterSet rejected valid text on one iPhone
    /// (the build 77 avatar colors), and a saved key that won't decode stops notification setup.
    @Test
    func base64URLRoundTripsAndRefusesOtherText() throws {
        for count in [0, 1, 2, 3, 32, 65] {
            let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
            if count == 0 { continue }
            #expect(try BighelpLinkBase64URL.decode(BighelpLinkBase64URL.encode(data)) == data)
        }
        let key = P256.Signing.PrivateKey()
        #expect(try BighelpLinkBase64URL.decode(BighelpLinkBase64URL.encode(key.rawRepresentation)) == key.rawRepresentation)
        for bad in ["", "a", "abc=", "ab+c", "ab/c", "ab c", "abcé", "abc\n"] {
            #expect(throws: BighelpLinkCryptoError.invalidBase64URL) { try BighelpLinkBase64URL.decode(bad) }
        }
    }

    private func makeCoordinator(
        notificationVault: MemoryNotificationIdentityVault,
        transport: NotificationBootstrapTransport
    ) -> BighelpNotificationIdentityCoordinator {
        let broker = BighelpNotificationBrokerClient(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            nonce: { "fixture-nonce" }
        )
        return BighelpNotificationIdentityCoordinator(
            vault: notificationVault,
            broker: broker,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }
}

@MainActor
private final class MemoryNotificationIdentityVault: BighelpNotificationIdentityVault {
    var value: BighelpNotificationIdentityLoad

    init(value: BighelpNotificationIdentityLoad = .none) {
        self.value = value
    }

    func load() throws -> BighelpNotificationIdentityLoad { value }
    func save(_ record: BighelpNotificationIdentityRecord) throws { value = .current(record) }
    func delete() throws { value = .none }
}

@MainActor
private final class NotificationBootstrapTransport: BighelpLinkHTTPTransport {
    private(set) var bootstrapRequests = 0
    private(set) var requestOrder: [String] = []
    private var shouldSuspendBootstrapResponses = false
    private var bootstrapResponseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var bootstrapRequestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func suspendBootstrapResponses() {
        shouldSuspendBootstrapResponses = true
    }

    func waitForBootstrapRequests(_ count: Int) async {
        guard bootstrapRequests < count else { return }
        await withCheckedContinuation { continuation in
            bootstrapRequestWaiters.append((count, continuation))
        }
    }

    func resumeBootstrapResponse(at index: Int) {
        bootstrapResponseContinuations.removeValue(forKey: index)?.resume()
    }

    func resumeAllBootstrapResponses() {
        shouldSuspendBootstrapResponses = false
        let continuations = Array(bootstrapResponseContinuations.values)
        bootstrapResponseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == BighelpNotificationBrokerClient.currentInstallationPath,
           request.httpMethod == "DELETE",
           let url = request.url,
           let installationID = request.value(forHTTPHeaderField: "x-loopdy-notification-installation"),
           let response = HTTPURLResponse(
             url: url,
             statusCode: 200,
             httpVersion: "HTTP/1.1",
             headerFields: ["Content-Type": "application/json"]
           ) {
            let responseBody = try JSONSerialization.data(withJSONObject: [
                "version": 2,
                "installation": ["installationId": installationID, "state": "revoked"],
            ], options: [.sortedKeys])
            return (responseBody, response)
        }
        guard request.url?.path == BighelpNotificationBrokerClient.bootstrapPath,
              request.httpMethod == "POST",
              let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let installationID = object["installationId"] as? String,
              let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw DirectHermesError.invalidResponse
        }
        let requestIndex = bootstrapRequests
        bootstrapRequests += 1
        requestOrder.append("bootstrap")
        let readyWaiters = bootstrapRequestWaiters.filter { bootstrapRequests >= $0.0 }
        bootstrapRequestWaiters.removeAll { bootstrapRequests >= $0.0 }
        readyWaiters.forEach { $0.1.resume() }
        if shouldSuspendBootstrapResponses {
            await withCheckedContinuation { continuation in
                bootstrapResponseContinuations[requestIndex] = continuation
            }
        }
        let responseBody = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "credential": [
                "scope": "notification-only",
                "installationId": installationID,
                "authorizationEpoch": 1,
            ],
        ], options: [.sortedKeys])
        return (responseBody, response)
    }
}

@MainActor
private final class IdentityErrorTransport: BighelpLinkHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 410,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        // Error bodies are not guaranteed to carry an envelope version.
        let body = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "notification_credentials_revoked"],
        ])
        return (body, response)
    }
}

@MainActor
private final class IdentityOperationStartSignal {
    private var didStart = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        didStart = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !didStart else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
