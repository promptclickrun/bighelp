import CryptoKit
import Foundation
import Security

/// End-to-end sealed notification content (managed alerts, version 2).
///
/// The host encrypts each notification's title, text and avatar for this phone's
/// key and signs it with its notification key. The notification service and
/// BuzzKit only forward opaque bytes. The format mirrors the bighelp plugin's
/// `sealed_alerts.py`; `BighelpTests/Fixtures/sealed-alert-v2-vector.json` is shared by both.
enum BighelpSealedAlert {
    enum Failure: Error, Equatable {
        case invalidPayload, untrustedSender, keyUnavailable, authenticationFailed, invalidPlaintext
    }

    struct Envelope: Equatable, Sendable {
        let grantID: String
        let eventID: String
        let recipientKeyID: String
        let senderKeyID: String
        let issued: Int
        let ephemeralPublicKey: Data
        let salt: Data
        let nonce: Data
        let ciphertext: Data
        let tag: Data
        let signature: Data
    }

    struct Avatar: Codable, Equatable, Sendable {
        let mimeType: String
        let sha256: String
        let cipherSha256: String
        let key: String
        let nonce: String
    }

    struct Content: Codable, Equatable, Sendable {
        let v: Int
        let eventId: String
        let eventType: String
        let title: String
        let body: String
        let avatar: Avatar?
    }

    // MARK: Parsing

    static func envelope(_ value: Any?) throws -> Envelope {
        guard let object = value as? [String: Any],
              Set(object.keys) == ["v", "grantId", "eventId", "recipientKeyId", "senderKeyId", "issued",
                                   "ephemeralPublicKey", "salt", "nonce", "ciphertext", "tag", "signature"],
              (object["v"] as? NSNumber)?.intValue == 2,
              let grantID = line(object["grantId"]), let eventID = line(object["eventId"]),
              let recipientKeyID = line(object["recipientKeyId"]), let senderKeyID = line(object["senderKeyId"]),
              let issued = (object["issued"] as? NSNumber)?.intValue, issued > 0,
              let ephemeral = bytes(object["ephemeralPublicKey"], count: 65), ephemeral.first == 0x04,
              let salt = bytes(object["salt"], count: 32), let nonce = bytes(object["nonce"], count: 12),
              let ciphertext = bytes(object["ciphertext"]), !ciphertext.isEmpty, ciphertext.count <= 4_096,
              let tag = bytes(object["tag"], count: 16), let signature = bytes(object["signature"], count: 64)
        else { throw Failure.invalidPayload }
        return Envelope(grantID: grantID, eventID: eventID, recipientKeyID: recipientKeyID, senderKeyID: senderKeyID,
                        issued: issued, ephemeralPublicKey: ephemeral, salt: salt, nonce: nonce,
                        ciphertext: ciphertext, tag: tag, signature: signature)
    }

    // MARK: Opening

    /// Checks the host's signature, then decrypts. `senderPublicKey` is the host
    /// key the phone pinned for this grant (X9.63, 65 bytes).
    static func open(_ envelope: Envelope, recipient: P256.KeyAgreement.PrivateKey,
                     senderPublicKey: Data) throws -> Content {
        guard keyID(recipient.publicKey.x963Representation) == envelope.recipientKeyID else {
            throw Failure.keyUnavailable
        }
        guard keyID(senderPublicKey) == envelope.senderKeyID,
              let sender = try? P256.Signing.PublicKey(x963Representation: senderPublicKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: envelope.signature)
        else { throw Failure.untrustedSender }
        let aad = self.aad(envelope)
        guard sender.isValidSignature(signature, for: signatureInput(aad: aad, envelope: envelope)) else {
            throw Failure.untrustedSender
        }
        guard let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeralPublicKey),
              let shared = try? recipient.sharedSecretFromKeyAgreement(with: ephemeral) else {
            throw Failure.keyUnavailable
        }
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: envelope.salt,
            sharedInfo: Data("loopdy-sealed-alert-key-v2\0".utf8) + Data(SHA256.hash(data: aad)),
            outputByteCount: 32)
        guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope.nonce),
                                                ciphertext: envelope.ciphertext, tag: envelope.tag),
              let packed = try? AES.GCM.open(box, using: key, authenticating: aad) else {
            throw Failure.authenticationFailed
        }
        guard packed.count <= 16_384,
              let plaintext = try? (packed as NSData).decompressed(using: .zlib) as Data,
              plaintext.count <= 65_536,
              let content = try? JSONDecoder().decode(Content.self, from: plaintext),
              content.v == 2, content.eventId == envelope.eventID,
              !content.title.isEmpty, !content.body.isEmpty
        else { throw Failure.invalidPlaintext }
        return content
    }

    /// The avatar image from its encrypted bytes, checked against both hashes.
    static func openAvatar(_ blob: Data, avatar: Avatar, grantID: String) throws -> Data {
        guard hex(SHA256.hash(data: blob)) == avatar.cipherSha256, blob.count > 16,
              let keyBytes = BighelpNotificationBase64URL.decodeCanonical(avatar.key), keyBytes.count == 32,
              let nonce = BighelpNotificationBase64URL.decodeCanonical(avatar.nonce), nonce.count == 12,
              let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                                ciphertext: blob.dropLast(16), tag: blob.suffix(16)),
              let image = try? AES.GCM.open(box, using: SymmetricKey(data: keyBytes),
                                            authenticating: Data("loopdy-sealed-avatar-v2\n\(grantID)\n\(avatar.sha256)".utf8)),
              hex(SHA256.hash(data: image)) == avatar.sha256
        else { throw Failure.authenticationFailed }
        return image
    }

    // MARK: Format

    static func keyID(_ publicKey: Data) -> String {
        BighelpNotificationBase64URL.encode(Data(SHA256.hash(data: publicKey)))
    }

    static func aad(_ envelope: Envelope) -> Data {
        Data(["loopdy-sealed-alert-v2", envelope.grantID, envelope.eventID, envelope.recipientKeyID,
              envelope.senderKeyID, String(envelope.issued)].joined(separator: "\n").utf8)
    }

    static func signatureInput(aad: Data, envelope: Envelope) -> Data {
        let parts = ["loopdy-sealed-alert-signature-v2", hex(SHA256.hash(data: aad))]
            + [envelope.ephemeralPublicKey, envelope.salt, envelope.nonce, envelope.ciphertext, envelope.tag]
                .map(BighelpNotificationBase64URL.encode)
        return Data(parts.joined(separator: "\n").utf8)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func line(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256, !text.contains("\n") else { return nil }
        return text
    }

    private static func bytes(_ value: Any?, count: Int? = nil) -> Data? {
        guard let text = value as? String, let data = BighelpNotificationBase64URL.decodeCanonical(text) else { return nil }
        if let count, data.count != count { return nil }
        return data
    }
}

/// A sealed alert as it arrives in a push: `userInfo["loopdy"]` carries the
/// envelope, the event coordinates the app routes taps with, and where the
/// encrypted avatar can be downloaded.
struct BighelpSealedNotification: Sendable {
    let envelope: BighelpSealedAlert.Envelope
    let eventType: String
    let avatarURL: URL?
    /// The encrypted picture itself, when it came along (instant alerts, for a
    /// picture the phone didn't have yet). Pushes carry only `avatarURL`.
    var inlineAvatar: Data?

    init?(userInfo: [AnyHashable: Any]) {
        guard let payload = userInfo["loopdy"] as? [String: Any], let sealed = payload["sealed"],
              let envelope = try? BighelpSealedAlert.envelope(sealed),
              payload["eventId"] as? String == envelope.eventID,
              payload["grantId"] as? String == envelope.grantID,
              let eventType = payload["eventType"] as? String else { return nil }
        self.envelope = envelope
        self.eventType = eventType
        let url = ((payload["avatar"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
        avatarURL = url?.scheme == "https" ? url : nil
    }

    /// The title and text, only if the host this phone enrolled with sealed them for this key.
    func open(recipientKeys: BighelpNotificationRecipientKeyStore = BighelpSealedAlertRecipient.store,
              senders: BighelpSealedAlertSenderStore = BighelpSealedAlertSenderStore()) throws -> BighelpSealedAlert.Content {
        guard let sender = try senders.sender(grantID: envelope.grantID), sender.hostKeyID == envelope.senderKeyID,
              envelope.issued <= sender.expiresAt,
              let senderKey = BighelpNotificationBase64URL.decodeCanonical(sender.hostPublicKey) else {
            throw BighelpSealedAlert.Failure.untrustedSender
        }
        guard let raw = try recipientKeys.load(),
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            throw BighelpSealedAlert.Failure.keyUnavailable
        }
        let content = try BighelpSealedAlert.open(envelope, recipient: key, senderPublicKey: senderKey)
        guard content.eventType == eventType else { throw BighelpSealedAlert.Failure.invalidPlaintext }
        return content
    }

    /// The avatar as a temporary image file for the notification: from the phone's
    /// cache when this picture was opened before, otherwise downloaded and opened.
    func avatarFile(for content: BighelpSealedAlert.Content, session: URLSession = .shared,
                    cache: BighelpNotificationAvatarCache = .shared) async -> URL? {
        guard let avatar = content.avatar else { return nil }
        let fileExtension = switch avatar.mimeType {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/webp": "webp"
        default: ""
        }
        guard !fileExtension.isEmpty else { return nil }
        let image: Data
        if let cached = cache.image(sha256: avatar.sha256) {
            image = cached
        } else if let inlineAvatar,
                  let opened = try? BighelpSealedAlert.openAvatar(inlineAvatar, avatar: avatar, grantID: envelope.grantID) {
            cache.store(opened, sha256: avatar.sha256)
            image = opened
        } else {
            guard let avatarURL else { return nil }
            var request = URLRequest(url: avatarURL)
            request.timeoutInterval = 12
            guard let (blob, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, blob.count <= 2_000_000,
                  let opened = try? BighelpSealedAlert.openAvatar(blob, avatar: avatar, grantID: envelope.grantID)
            else { return nil }
            cache.store(opened, sha256: avatar.sha256)
            image = opened
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        guard (try? image.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)) != nil else { return nil }
        return file
    }
}

/// Opened agent pictures kept on the phone by their SHA-256, so later alerts
/// from the same agent attach the picture without a download. Entries are
/// checked against their hash on read; the newest 32 are kept.
struct BighelpNotificationAvatarCache: Sendable {
    static let appGroup = "group.app.loopdy.mobile.buzzkit"
    static let limit = 32

    let directory: URL?

    static var shared: BighelpNotificationAvatarCache {
        BighelpNotificationAvatarCache(directory: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("SealedAlertAvatars", isDirectory: true))
    }

    func image(sha256: String) -> Data? {
        guard let file = file(sha256), let data = try? Data(contentsOf: file) else { return nil }
        guard Self.hex(SHA256.hash(data: data)) == sha256.lowercased() else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return data
    }

    func store(_ image: Data, sha256: String) {
        guard let directory, let file = file(sha256),
              Self.hex(SHA256.hash(data: image)) == sha256.lowercased() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? image.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prune(directory)
    }

    /// The pictures kept here, by SHA-256. A host sending an alert straight to the
    /// app leaves these out.
    func hashes() -> [String] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return Array(files.filter { name in
            name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }.prefix(Self.limit))
    }

    private func file(_ sha256: String) -> URL? {
        guard let directory, sha256.utf8.count == 64, sha256.allSatisfy(\.isHexDigit) else { return nil }
        return directory.appendingPathComponent(sha256.lowercased())
    }

    private func prune(_ directory: URL) {
        let key = URLResourceKey.contentModificationDateKey
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [key]), files.count > Self.limit else { return }
        let newestFirst = files.sorted {
            let first = (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
            return first > second
        }
        for stale in newestFirst.dropFirst(Self.limit) { try? FileManager.default.removeItem(at: stale) }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// This phone's content key for sealed notifications (P-256), kept in the
/// notification keychain group so the notification extension can read it.
enum BighelpSealedAlertRecipient {
    static var store: BighelpNotificationRecipientKeyStore {
        BighelpNotificationRecipientKeyStore(account: BighelpNotificationRecipientKeyStore.sealedAlertAccount)
    }

    static func key(store: BighelpNotificationRecipientKeyStore = Self.store) throws
        -> P256.KeyAgreement.PrivateKey {
        if let raw = try store.load(), let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = P256.KeyAgreement.PrivateKey()
        try store.save(key.rawRepresentation)
        return key
    }

    static func publicKey(_ key: P256.KeyAgreement.PrivateKey) -> String {
        BighelpNotificationBase64URL.encode(key.publicKey.x963Representation)
    }
}

/// The host key pinned for each notification grant, straight from the host.
struct BighelpSealedAlertSender: Codable, Equatable, Sendable {
    let grantID: String
    let hostKeyID: String
    let hostPublicKey: String
    let expiresAt: Int
}

final class BighelpSealedAlertSenderStore: @unchecked Sendable {
    private static let mutationLock = NSLock()
    private let accessGroup: String?
    private let service: String
    private let account = "sealed-alert-senders-v2"

    init(accessGroup: String? = BighelpNotificationKeychainAccess.group,
         service: String = BighelpNotificationHostTrustStore.keychainService) {
        self.accessGroup = accessGroup
        self.service = service
    }

    func sender(grantID: String, now: Int = Int(Date().timeIntervalSince1970)) throws -> BighelpSealedAlertSender? {
        try load().first { $0.grantID == grantID && $0.expiresAt > now }
    }

    func upsert(_ sender: BighelpSealedAlertSender, now: Int = Int(Date().timeIntervalSince1970)) throws {
        Self.mutationLock.lock(); defer { Self.mutationLock.unlock() }
        let current = try load()
        if current.contains(sender) { return }
        let senders = current.filter { $0.grantID != sender.grantID && $0.expiresAt > now } + [sender]
        try save(Array(senders.suffix(64)))
    }

    func remove(grantIDs: Set<String>) throws {
        Self.mutationLock.lock(); defer { Self.mutationLock.unlock() }
        let current = try load()
        let kept = current.filter { !grantIDs.contains($0.grantID) }
        if kept != current { try save(kept) }
    }

    func removeAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BighelpRelayTrustError.keychain(status) }
    }

    func load() throws -> [BighelpSealedAlertSender] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw BighelpRelayTrustError.keychain(status) }
        return (try? JSONDecoder().decode([BighelpSealedAlertSender].self, from: data)) ?? []
    }

    private func save(_ senders: [BighelpSealedAlertSender]) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(senders),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw BighelpRelayTrustError.keychain(status) }
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        guard updated == errSecSuccess else { throw BighelpRelayTrustError.keychain(updated) }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
