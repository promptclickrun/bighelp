import CryptoKit
import Foundation
import Testing
@testable import Bighelp

/// The plugin seals `Fixtures/sealed-alert-v2-vector.json` with test-only keys; the
/// phone must open it to exactly the same title, text and avatar.
struct BighelpSealedAlertTests {
    private struct Vector: Decodable {
        let recipientPrivateKey: String
        let recipientPublicKey: String
        let senderPublicKey: String
        let plaintext: BighelpSealedAlert.Content
        let avatarImage: String
        let avatarBlob: String
    }

    private let vector: Vector
    private let envelope: [String: Any]
    private let recipient: P256.KeyAgreement.PrivateKey

    init() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/sealed-alert-v2-vector.json"))
        vector = try JSONDecoder().decode(Vector.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        envelope = try #require(object?["envelope"] as? [String: Any])
        recipient = try P256.KeyAgreement.PrivateKey(rawRepresentation: Self.bytes(vector.recipientPrivateKey))
    }

    @Test func opensThePluginsVectorToTheSameContent() throws {
        #expect(BighelpSealedAlertRecipient.publicKey(recipient) == vector.recipientPublicKey)
        let opened = try BighelpSealedAlert.open(BighelpSealedAlert.envelope(envelope), recipient: recipient,
                                                 senderPublicKey: Self.bytes(vector.senderPublicKey))
        #expect(opened == vector.plaintext)
        #expect(opened.title == "Juno")
        #expect(opened.body.hasPrefix("Your flight to Denver"))
    }

    @Test func opensTheEncryptedAvatar() throws {
        let avatar = try #require(vector.plaintext.avatar)
        let grantID = try #require(envelope["grantId"] as? String)
        let image = try BighelpSealedAlert.openAvatar(Self.bytes(vector.avatarBlob), avatar: avatar, grantID: grantID)
        let expected = try Self.bytes(vector.avatarImage)
        #expect(image == expected)
        var tampered = try Self.bytes(vector.avatarBlob)
        tampered[0] ^= 1
        #expect(throws: BighelpSealedAlert.Failure.authenticationFailed) {
            try BighelpSealedAlert.openAvatar(tampered, avatar: avatar, grantID: grantID)
        }
    }

    @Test func refusesAnyOtherSenderOrChangedField() throws {
        let sender = try Self.bytes(vector.senderPublicKey)
        let stranger = P256.Signing.PrivateKey().publicKey.x963Representation
        #expect(throws: BighelpSealedAlert.Failure.untrustedSender) {
            try BighelpSealedAlert.open(BighelpSealedAlert.envelope(envelope), recipient: recipient, senderPublicKey: stranger)
        }
        #expect(throws: BighelpSealedAlert.Failure.keyUnavailable) {
            try BighelpSealedAlert.open(BighelpSealedAlert.envelope(envelope), recipient: P256.KeyAgreement.PrivateKey(),
                                        senderPublicKey: sender)
        }
        for field in ["ciphertext", "tag", "salt", "nonce", "ephemeralPublicKey"] {
            var changed = envelope
            var raw = try Self.bytes(envelope[field] as? String ?? "")
            raw[raw.count - 1] ^= 1
            changed[field] = BighelpNotificationBase64URL.encode(raw)
            #expect(throws: BighelpSealedAlert.Failure.self, "\(field)") {
                try BighelpSealedAlert.open(BighelpSealedAlert.envelope(changed), recipient: recipient, senderPublicKey: sender)
            }
        }
        var later = envelope
        later["issued"] = 1_800_000_001
        #expect(throws: BighelpSealedAlert.Failure.untrustedSender) {
            try BighelpSealedAlert.open(BighelpSealedAlert.envelope(later), recipient: recipient, senderPublicKey: sender)
        }
        var extra = envelope
        extra["title"] = "Juno"
        #expect(throws: BighelpSealedAlert.Failure.invalidPayload) { try BighelpSealedAlert.envelope(extra) }
    }

    @Test func pushOpensOnlyWithThePinnedHostAndMatchingCoordinates() throws {
        let keys = BighelpNotificationRecipientKeyStore(accessGroup: nil, account: "test." + UUID().uuidString)
        let senders = BighelpSealedAlertSenderStore(accessGroup: nil, service: "app.loopdy.test.sealed." + UUID().uuidString)
        defer { try? keys.remove(); try? senders.removeAll() }
        try keys.save(recipient.rawRepresentation)
        let grantID = try #require(envelope["grantId"] as? String)
        let eventID = try #require(envelope["eventId"] as? String)
        func push(eventType: String = "session.completed", eventID: String = eventID) -> [AnyHashable: Any] {
            ["loopdy": ["version": 2, "eventId": eventID, "eventType": eventType, "grantId": grantID,
                        "sealed": envelope, "avatar": ["url": "https://example.com/avatar"]]]
        }

        let notification = try #require(BighelpSealedNotification(userInfo: push()))
        #expect(notification.avatarURL?.absoluteString == "https://example.com/avatar")
        // No pinned host for the grant yet: nothing opens.
        #expect(throws: BighelpSealedAlert.Failure.untrustedSender) { try notification.open(recipientKeys: keys, senders: senders) }

        let senderKeyID = try #require(envelope["senderKeyId"] as? String)
        try senders.upsert(BighelpSealedAlertSender(grantID: grantID, hostKeyID: senderKeyID,
                                                    hostPublicKey: vector.senderPublicKey, expiresAt: 1_800_000_100),
                           now: 1_790_000_000)
        #expect(try notification.open(recipientKeys: keys, senders: senders) == vector.plaintext)

        let relabeled = try #require(BighelpSealedNotification(userInfo: push(eventType: "session.failed")))
        #expect(throws: BighelpSealedAlert.Failure.invalidPlaintext) { try relabeled.open(recipientKeys: keys, senders: senders) }
        #expect(BighelpSealedNotification(userInfo: push(eventID: grantID + ":" + String(repeating: "0", count: 64))) == nil)
        #expect(BighelpSealedNotification(userInfo: ["loopdy": ["version": 2, "eventId": eventID]]) == nil)
    }

    /// Pushes sent straight to Apple carry the same alert plus `bk` and `bighelp_meta` (CONTRACTS §2);
    /// the phone opens them like any other.
    @Test func aDirectPushOpensLikeABuzzKitOne() throws {
        let keys = BighelpNotificationRecipientKeyStore(accessGroup: nil, account: "test." + UUID().uuidString)
        let senders = BighelpSealedAlertSenderStore(accessGroup: nil, service: "app.loopdy.test.sealed." + UUID().uuidString)
        defer { try? keys.remove(); try? senders.removeAll() }
        try keys.save(recipient.rawRepresentation)
        let grantID = try #require(envelope["grantId"] as? String)
        let eventID = try #require(envelope["eventId"] as? String)
        let senderKeyID = try #require(envelope["senderKeyId"] as? String)
        try senders.upsert(BighelpSealedAlertSender(grantID: grantID, hostKeyID: senderKeyID,
                                                    hostPublicKey: vector.senderPublicKey, expiresAt: 1_800_000_100),
                           now: 1_790_000_000)
        let direct: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "bighelp", "body": "placeholder"], "mutable-content": 1, "category": "BIGHELP_UPDATE"],
            "loopdy": ["version": 2, "eventId": eventID, "eventType": "session.completed", "grantId": grantID,
                       "sealed": envelope, "avatar": ["url": "https://example.com/avatar"]],
            "bk": ["deepLink": "loopdy:///dashboard?eventId=\(eventID)", "category": "BIGHELP_UPDATE", "actions": []],
            "bighelp_meta": ["v": 1, "path": "direct", "sentAt": 1_800_000_000_000],
        ]
        let notification = try #require(BighelpSealedNotification(userInfo: direct))
        #expect(try notification.open(recipientKeys: keys, senders: senders) == vector.plaintext)
    }

    private static func bytes(_ value: String) throws -> Data {
        guard let data = BighelpNotificationBase64URL.decodeCanonical(value) else { throw BighelpSealedAlert.Failure.invalidPayload }
        return data
    }
}
