import CryptoKit
import os
import Foundation
import Security

struct BighelpManagedNotificationCredentials: Equatable {
    let deviceID: String
    let authorizationEpoch: Int
    let signingPrivateKey: P256.Signing.PrivateKey

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.deviceID == rhs.deviceID
            && lhs.authorizationEpoch == rhs.authorizationEpoch
            && lhs.signingPrivateKey.rawRepresentation == rhs.signingPrivateKey.rawRepresentation
    }

    var subscriberScope: String { "notification-instance" }

    func headers(method: String, path: String, body: Data, timestamp: Int, nonce: String) throws -> [String: String] {
        let digest = BighelpLinkBase64URL.encode(Data(SHA256.hash(data: body)))
        let transcript = [
            "loopdy-notification-device-v1", method.uppercased(), path, deviceID,
            String(timestamp), nonce, String(authorizationEpoch), digest,
        ].joined(separator: "\n")
        let signature = try signingPrivateKey.signature(for: Data(transcript.utf8))
        return [
            "x-loopdy-notification-installation": deviceID,
            "x-loopdy-timestamp": String(timestamp),
            "x-loopdy-nonce": nonce,
            "x-loopdy-authorization-epoch": String(authorizationEpoch),
            "x-loopdy-signature": BighelpLinkBase64URL.encode(signature.rawRepresentation),
        ]
    }
}

struct BighelpNotificationBootstrapIntent: Equatable {
    let installationID: String
    let requestID: String
    let signingPrivateKey: P256.Signing.PrivateKey
    let body: Data
    let timestamp: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.installationID == rhs.installationID && lhs.requestID == rhs.requestID
            && lhs.signingPrivateKey.rawRepresentation == rhs.signingPrivateKey.rawRepresentation
            && lhs.body == rhs.body && lhs.timestamp == rhs.timestamp
    }

    func refreshed(now: Int) throws -> Self {
        try Self.make(installationID: installationID, signingPrivateKey: signingPrivateKey, now: now)
    }

    static func make(
        installationID: String = UUID().uuidString.lowercased(),
        signingPrivateKey: P256.Signing.PrivateKey = .init(),
        now: Int = Int(Date().timeIntervalSince1970)
    ) throws -> Self {
        let requestID = UUID().uuidString.lowercased()
        let nonce = randomBase64URL(count: 24)
        let publicKey = signingPrivateKey.publicKey.spkiBase64URL
        let transcript = [
            "loopdy-notification-bootstrap-v1", "POST", BighelpNotificationBrokerClient.bootstrapPath,
            installationID, requestID, String(now), nonce, publicKey,
        ].joined(separator: "\n")
        let proof = try signingPrivateKey.signature(for: Data(transcript.utf8))
        let object: [String: Any] = [
            "version": 1,
            "installationId": installationID,
            "requestId": requestID,
            "publicKeySPKI": publicKey,
            "timestamp": now,
            "nonce": nonce,
            "proof": BighelpLinkBase64URL.encode(proof.rawRepresentation),
        ]
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return Self(installationID: installationID, requestID: requestID,
                    signingPrivateKey: signingPrivateKey, body: body, timestamp: now)
    }

    private static func randomBase64URL(count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return BighelpLinkBase64URL.encode(Data(bytes))
    }
}

enum BighelpNotificationIdentityRecord: Equatable {
    case pending(BighelpNotificationBootstrapIntent)
    case active(BighelpManagedNotificationCredentials)
}

enum BighelpNotificationIdentityLoad: Equatable {
    case none
    case current(BighelpNotificationIdentityRecord)
    case orphaned(BighelpNotificationIdentityRecord)
    /// Saved, but it can't be read back (damaged, or from an older build). Its key is lost, so
    /// the registration it made can't be cancelled from this device.
    case unreadable
}

/// What turning notifications off did with this device's identity.
enum BighelpNotificationIdentityErasure: Equatable {
    /// The notification service cancelled it, then it was deleted here.
    case revoked
    /// Nothing was saved.
    case nothingSaved
    /// It couldn't be read, so it was deleted here only; the service may still hold the old one.
    case removedHereOnly
}

@MainActor
protocol BighelpNotificationIdentityVault: AnyObject {
    func load() throws -> BighelpNotificationIdentityLoad
    func save(_ record: BighelpNotificationIdentityRecord) throws
    func delete() throws
}

@MainActor
final class BighelpNotificationKeychainIdentityVault: BighelpNotificationIdentityVault {
    private struct Stored: Codable {
        enum State: String, Codable { case pending, active }
        let version: Int
        let state: State
        let installationMarker: String
        let installationID: String
        let requestID: String?
        let authorizationEpoch: Int?
        let signingPrivateKey: String
        let bootstrapBody: Data?
        let bootstrapTimestamp: Int?
    }

    private let service: String
    private let account = "notification-identity-v2"
    private let markerFile: URL

    init(
        service: String = "app.loopdy.mobile.notification-identity",
        markerFile: URL = BighelpManagedNotificationLedger.storageRoot.appending(path: "installation-marker-v1")
    ) {
        self.service = service
        self.markerFile = markerFile
    }

    func load() throws -> BighelpNotificationIdentityLoad {
        // A Keychain that won't answer (a locked phone) is an error; a record that won't read isn't.
        let stored: Stored
        do {
            guard let value = try loadStored() else { return .none }
            stored = value
        } catch is DecodingError {
            return .unreadable
        }
        let record: BighelpNotificationIdentityRecord
        do {
            record = try decode(stored)
        } catch {
            return .unreadable
        }
        guard let marker = try readMarker(), marker == stored.installationMarker else {
            return .orphaned(record)
        }
        return .current(record)
    }

    func save(_ record: BighelpNotificationIdentityRecord) throws {
        let marker = try currentOrNewMarker()
        let stored: Stored
        switch record {
        case .pending(let intent):
            stored = Stored(version: 2, state: .pending, installationMarker: marker,
                installationID: intent.installationID, requestID: intent.requestID,
                authorizationEpoch: nil,
                signingPrivateKey: BighelpLinkBase64URL.encode(intent.signingPrivateKey.rawRepresentation),
                bootstrapBody: intent.body, bootstrapTimestamp: intent.timestamp)
        case .active(let credentials):
            stored = Stored(version: 2, state: .active, installationMarker: marker,
                installationID: credentials.deviceID, requestID: nil,
                authorizationEpoch: credentials.authorizationEpoch,
                signingPrivateKey: BighelpLinkBase64URL.encode(credentials.signingPrivateKey.rawRepresentation),
                bootstrapBody: nil, bootstrapTimestamp: nil)
        }
        let data = try JSONEncoder().encode(stored)
        guard data.count <= 32_768 else { throw DirectHermesError.messageTooLarge }
        let query = keychainQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status != errSecSuccess {
            guard status == errSecDuplicateItem,
                  SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                throw DirectHermesError.secureStorageUnavailable
            }
        }
        guard case .current(let readback) = try load(), readback == record else {
            throw DirectHermesError.secureStorageUnavailable
        }
    }

    func delete() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DirectHermesError.secureStorageUnavailable
        }
        if FileManager.default.fileExists(atPath: markerFile.path) {
            try FileManager.default.removeItem(at: markerFile)
        }
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func loadStored() throws -> Stored? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, data.count <= 32_768 else {
            throw DirectHermesError.secureStorageUnavailable
        }
        return try JSONDecoder().decode(Stored.self, from: data)
    }

    private func decode(_ stored: Stored) throws -> BighelpNotificationIdentityRecord {
        guard stored.version == 2, ManagedNotificationValidation.uuid(stored.installationID),
              ManagedNotificationValidation.uuid(stored.installationMarker) else {
            throw DirectHermesError.savedConnectionInvalid
        }
        let key = try P256.Signing.PrivateKey(
            rawRepresentation: BighelpLinkBase64URL.decode(stored.signingPrivateKey)
        )
        switch stored.state {
        case .pending:
            guard let requestID = stored.requestID, ManagedNotificationValidation.uuid(requestID),
                  let body = stored.bootstrapBody, body.count <= 16_384,
                  let timestamp = stored.bootstrapTimestamp, timestamp > 0 else {
                throw DirectHermesError.savedConnectionInvalid
            }
            return .pending(.init(installationID: stored.installationID, requestID: requestID,
                                  signingPrivateKey: key, body: body, timestamp: timestamp))
        case .active:
            guard let epoch = stored.authorizationEpoch, epoch > 0 else {
                throw DirectHermesError.savedConnectionInvalid
            }
            return .active(.init(deviceID: stored.installationID,
                                 authorizationEpoch: epoch, signingPrivateKey: key))
        }
    }

    private func readMarker() throws -> String? {
        guard FileManager.default.fileExists(atPath: markerFile.path) else { return nil }
        let values = try markerFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 64 else {
            throw DirectHermesError.savedConnectionInvalid
        }
        return try String(contentsOf: markerFile, encoding: .utf8)
    }

    private func currentOrNewMarker() throws -> String {
        if let marker = try readMarker() { return marker }
        let marker = UUID().uuidString.lowercased()
        let directory = markerFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                         .posixPermissions: 0o700])
        try Data(marker.utf8).write(to: markerFile,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerFile.path)
        return marker
    }
}

@MainActor
final class BighelpNotificationBrokerClient: BighelpManagedNotificationAccountAPI {
    nonisolated static let bootstrapPath = "/v1/notifications/bootstrap"
    static let currentInstallationPath = "/v1/notifications/installations/current"

    private let transport: any BighelpLinkHTTPTransport
    private let now: () -> Date
    private let nonce: () -> String
    private let baseURL = URL(string: "https://link.loopdy.app")!

    init(
        transport: any BighelpLinkHTTPTransport = BighelpManagedAccountTransport(),
        now: @escaping () -> Date = Date.init,
        nonce: @escaping () -> String = { BighelpLinkBase64URL.encode(BighelpNotificationBrokerClient.randomBytes(count: 24)) }
    ) {
        self.transport = transport
        self.now = now
        self.nonce = nonce
    }

    func bootstrap(_ intent: BighelpNotificationBootstrapIntent) async throws -> BighelpManagedNotificationCredentials {
        let response = try await request(path: Self.bootstrapPath, method: "POST", body: intent.body, headers: [:])
        guard response.object?["version"]?.integer == 2,
              let credential = response.object?["credential"]?.object,
              credential["scope"]?.string == "notification-only",
              credential["installationId"]?.string == intent.installationID,
              let epoch = credential["authorizationEpoch"]?.integer, epoch == 1 else {
            throw DirectHermesError.invalidResponse
        }
        return .init(deviceID: intent.installationID,
                     authorizationEpoch: epoch, signingPrivateKey: intent.signingPrivateKey)
    }

    func revokeInstallation(_ credentials: BighelpManagedNotificationCredentials) async throws {
        let response = try await signedRequest(
            path: Self.currentInstallationPath, method: "DELETE", body: Data(), credentials: credentials
        )
        guard response.object?["version"]?.integer == 2,
              response.object?["installation"]?.object?["installationId"]?.string == credentials.deviceID,
              response.object?["installation"]?.object?["state"]?.string == "revoked" else {
            throw DirectHermesError.invalidResponse
        }
    }

    func managedNotificationRequest(path: String, method: String, body: Data?,
                                    credentials: BighelpManagedNotificationCredentials) async throws -> BighelpJSONValue {
        return try await signedRequest(path: path, method: method, body: body ?? Data(), credentials: credentials)
    }

    private func signedRequest(path: String, method: String, body: Data,
                               credentials: BighelpManagedNotificationCredentials) async throws -> BighelpJSONValue {
        guard path == Self.currentInstallationPath || path == BighelpManagedNotificationService.root
                || path.hasPrefix(BighelpManagedNotificationService.root + "/"),
              !path.contains(".."), !path.contains("%"), !path.contains("?"), !path.contains("#"),
              path.utf8.count <= 512, body.count <= 262_144,
              ["GET", "POST", "PUT", "DELETE"].contains(method), method != "GET" || body.isEmpty else {
            throw BighelpLinkAPIError.invalidConfiguration
        }
        let timestamp = Int(now().timeIntervalSince1970)
        let proof = try credentials.headers(
            method: method, path: path, body: body, timestamp: timestamp, nonce: nonce()
        )
        return try await request(path: path, method: method, body: body, headers: proof)
    }

    private func request(path: String, method: String, body: Data, headers: [String: String]) async throws -> BighelpJSONValue {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == "https", url.host == "link.loopdy.app", url.port == nil else {
            throw BighelpLinkAPIError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await transport.data(for: request)
        guard response.url == url, !(300...399).contains(response.statusCode), data.count <= 262_144 else {
            throw BighelpLinkAPIError.invalidResponse
        }
        try DirectHermesWire.validateNesting(data)
        // Check the HTTP status before the envelope version. Error bodies are
        // not guaranteed to carry a version, and gating on it first discards
        // the server's error code (e.g. notification_credentials_revoked),
        // which defeats the revoked-credential retry in enroll().
        guard (200..<300).contains(response.statusCode) else {
            let value = try? JSONDecoder().decode(BighelpJSONValue.self, from: data)
            let code = value?.object?["error"]?.object?["code"]?.string
                ?? value?.object?["error"]?.string ?? "managed_notification_request_failed"
            throw BighelpLinkAPIError.requestFailed(status: response.statusCode, code: code)
        }
        let value = try JSONDecoder().decode(BighelpJSONValue.self, from: data)
        guard let version = value.object?["version"]?.integer, version == 1 || version == 2 else {
            throw BighelpLinkAPIError.invalidResponse
        }
        return value
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

@MainActor
final class BighelpNotificationIdentityCoordinator {
    private let vault: any BighelpNotificationIdentityVault
    private let broker: BighelpNotificationBrokerClient
    private let now: () -> Date
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(vault: any BighelpNotificationIdentityVault,
         broker: BighelpNotificationBrokerClient, now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.broker = broker
        self.now = now
    }

    func current() throws -> BighelpManagedNotificationCredentials? {
        switch try vault.load() {
        case .current(.active(let credentials)): return credentials
        case .current(.pending(_)), .orphaned(_), .none, .unreadable: return nil
        }
    }

    func resolveForEnrollment() async throws -> BighelpManagedNotificationCredentials {
        try await serialized {
            try await self.resolveForEnrollmentUnserialized()
        }
    }

    /// Explicit setup may replace credentials only after the provider has
    /// authoritatively rejected this exact installation as revoked.
    func replaceRevokedForEnrollment(
        expected: BighelpManagedNotificationCredentials
    ) async throws -> BighelpManagedNotificationCredentials {
        try await serialized {
            guard case .current(.active(let current)) = try self.vault.load(),
                  current == expected else {
                throw DirectHermesError.secureStorageChanged
            }
            try self.vault.delete()
            let intent = try BighelpNotificationBootstrapIntent.make(
                now: Int(self.now().timeIntervalSince1970)
            )
            try self.vault.save(.pending(intent))
            return try await self.complete(intent)
        }
    }

    @discardableResult
    func erase() async throws -> BighelpNotificationIdentityErasure {
        try await serialized {
            try await self.eraseUnserialized()
        }
    }

    private func resolveForEnrollmentUnserialized() async throws -> BighelpManagedNotificationCredentials {
        switch try vault.load() {
        case .current(.active(let credentials)):
            return credentials
        case .current(.pending(let intent)):
            return try await complete(intent)
        case .orphaned(let record):
            let credentials: BighelpManagedNotificationCredentials
            switch record {
            case .active(let value): credentials = value
            case .pending(let intent): credentials = try await recover(intent, persistRefresh: false)
            }
            try await broker.revokeInstallation(credentials)
            try vault.delete()
        case .unreadable:
            // Its key is lost: start over with a new identity. Only notification data goes.
            Self.log.notice("Notification identity: the saved one can't be read; starting a new one")
            try vault.delete()
        case .none:
            break
        }
        let intent = try BighelpNotificationBootstrapIntent.make(now: Int(now().timeIntervalSince1970))
        try vault.save(.pending(intent))
        return try await complete(intent)
    }

    private func eraseUnserialized() async throws -> BighelpNotificationIdentityErasure {
        let erasure: BighelpNotificationIdentityErasure
        switch try vault.load() {
        case .current(.active(let credentials)), .orphaned(.active(let credentials)):
            try await broker.revokeInstallation(credentials)
            erasure = .revoked
        case .current(.pending(let intent)):
            let credentials = try await recover(intent)
            try await broker.revokeInstallation(credentials)
            erasure = .revoked
        case .orphaned(.pending(let intent)):
            let credentials = try await recover(intent, persistRefresh: false)
            try await broker.revokeInstallation(credentials)
            erasure = .revoked
        case .unreadable:
            Self.log.notice("Notification identity: the saved one can't be read; deleting it on this device only")
            erasure = .removedHereOnly
        case .none:
            erasure = .nothingSaved
        }
        try vault.delete()
        return erasure
    }

    private static let log = Logger(subsystem: "app.loopdy.mobile", category: "notification-identity")

    private func serialized<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        await acquireOperationFence()
        defer {
            releaseOperationFence()
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquireOperationFence() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationFence() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private func complete(_ intent: BighelpNotificationBootstrapIntent) async throws -> BighelpManagedNotificationCredentials {
        let credentials = try await recover(intent)
        try vault.save(.active(credentials))
        return credentials
    }

    private func recover(
        _ intent: BighelpNotificationBootstrapIntent,
        persistRefresh: Bool = true
    ) async throws -> BighelpManagedNotificationCredentials {
        do {
            return try await broker.bootstrap(intent)
        } catch BighelpLinkAPIError.requestFailed(_, let code)
            where ["notification_bootstrap_stale", "notification_bootstrap_replayed"].contains(code) {
            let refreshed = try intent.refreshed(now: Int(now().timeIntervalSince1970))
            if persistRefresh { try vault.save(.pending(refreshed)) }
            return try await broker.bootstrap(refreshed)
        }
    }
}
