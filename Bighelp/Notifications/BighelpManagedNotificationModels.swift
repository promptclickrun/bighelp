import CryptoKit
import Foundation

/// Fixed managed-notification wire types. No server key or identity secret.
struct BighelpManagedGrant: Codable, Equatable, Sendable {
    let grantId: String
    let instanceId: String?
    let hostKeyId: String
    let hostPublicKey: String
    let authorizationEpoch: Int
    let profile: String
    let eventTypes: [String]
    let createdAt: Int
    let expiresAt: Int
    let revision: Int
    let provider: String
    let subscriberScope: String
    let state: String

    func validate() throws {
        guard ManagedNotificationValidation.uuid(grantId),
              ManagedNotificationValidation.profile(profile),
              provider == "buzzkit", ["account", "notification-instance"].contains(subscriberScope),
              (instanceId.map(ManagedNotificationValidation.uuid) ?? (subscriberScope == "account")),
              (subscriberScope != "notification-instance" || instanceId != nil),
              ["issued", "active", "revoked"].contains(state),
              !eventTypes.isEmpty, eventTypes.count <= ManagedNotificationValidation.eventTypes.count, Set(eventTypes).count == eventTypes.count,
              Set(eventTypes).isSubset(of: ManagedNotificationValidation.eventTypes),
              createdAt > 0, expiresAt > createdAt, expiresAt - createdAt <= 2_592_000,
              expiresAt <= 9_999_999_999,
              (1...9_007_199_254_740_991).contains(revision),
              authorizationEpoch > 0 else {
            throw DirectHermesError.invalidResponse
        }
        try ManagedNotificationValidation.publicKey(hostPublicKey, keyID: hostKeyId)

    }

    func sameAuthority(as other: Self) -> Bool {
        grantId == other.grantId && instanceId == other.instanceId
            && hostKeyId == other.hostKeyId && hostPublicKey == other.hostPublicKey
            && authorizationEpoch == other.authorizationEpoch && profile == other.profile
            && Set(eventTypes) == Set(other.eventTypes) && provider == other.provider
            && subscriberScope == other.subscriberScope
            && createdAt == other.createdAt && expiresAt == other.expiresAt && revision == other.revision
    }
}

struct BighelpManagedGrantIntent: Codable, Equatable, Sendable {
    let version: Int
    let idempotencyKey: String
    let instanceId: String?
    let hostPublicKey: String
    let hostKeyId: String
    let profile: String
    let eventTypes: [String]
    let expiresAt: Int
}

/// Legacy Link APNs recipient projection. The BuzzKit managed path does not use it.
struct BighelpManagedRecipient: Equatable, Sendable {
    /// nil until a signed grant establishes the server-selected tenant. The
    /// existing APNs acknowledgement does not expose a tenant coordinate.
    let tenantID: String?
    let deviceID: String
    let publicKey: String
    let keyID: String
    let revision: Int
    let leaseExpires: Int

}

struct BighelpManagedCapabilities: Decodable, Sendable {
    struct Producers: Decodable, Sendable {
        let sessionCompletion: Bool
        let sessionFailure: Bool
        let richLiveActivity: Bool
        let nativeApproval: Bool
        let nativeClarification: Bool
    }
    let version: Int
    let hostKeyId: String
    let hostPublicKey: String
    let managedEnrollmentSupported: Bool
    let supportedEventTypes: [String]?
    let richLiveActivitySupported: Bool?
    let producerCapabilities: Producers
    /// Present when the host seals notification content for this phone's key.
    let sealedAlerts: SealedAlerts?
    struct SealedAlerts: Decodable, Sendable { let version: Int }
    var supportsSealedAlerts: Bool { sealedAlerts?.version == 2 }
    /// Alert choices this phone can set on the host (plugin 3.4.9+).
    let preferences: Preferences?
    struct Preferences: Decodable, Sendable { let peerChats: Bool? }
    var supportsPeerChatPreference: Bool { preferences?.peerChats == true }
    var supportsCompletionEnrollment: Bool {
        guard let supportedEventTypes else { return false }
        return Set(supportedEventTypes).isSuperset(of: ManagedNotificationValidation.eventTypes)
    }
    /// The complete four-category grant is requested as one immutable authority.
    /// Older partial grants are rotated only from an explicit enable action.
    var enrollmentEventTypes: Set<String> {
        guard let supportedEventTypes else { return [] }
        return ManagedNotificationValidation.eventTypes.intersection(Set(supportedEventTypes))
    }
    func validate() throws {
        guard version == 1 else { throw DirectHermesError.invalidResponse }
        try ManagedNotificationValidation.publicKey(hostPublicKey, keyID: hostKeyId)
    }
}

struct BighelpManagedEventDetail: Decodable, Equatable, Sendable {
    struct Agent: Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let avatarSha256: String
    }
    struct Content: Decodable, Equatable, Sendable {
        let kind: String
        let text: String
    }
    let eventId: String
    let eventType: String
    let profile: String
    let sessionId: String
    let turnId: String
    let occurredAt: Int
    let agent: Agent
    let content: Content
}

@MainActor
protocol BighelpManagedNotificationAccountAPI: AnyObject {
    /// Exact frozen bytes use either retained legacy mobile proof or the restricted
    /// notification-only proof. Neither path accepts an account bearer.
    func managedNotificationRequest(path: String, method: String, body: Data?,
                                    credentials: BighelpManagedNotificationCredentials) async throws -> BighelpJSONValue
}

enum ManagedNotificationValidation {
    static let completionEventTypes: Set<String> = ["session.completed", "session.failed"]
    static let eventTypes = completionEventTypes.union([
        "scheduled.completed", "scheduled.failed",
        "approval.required", "clarification.required",
        "subagent.completed", "subagent.failed",
    ])
    static func validEnrollmentEventTypes(_ values: [String]) -> Bool {
        let types = Set(values)
        return types.count == values.count && types == eventTypes
    }
    static func uuid(_ value: String) -> Bool {
        value.utf8.count == 36 && value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }
    static func coordinate(_ value: String, maximum: Int = 180) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }
    static func profile(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }
    static func publicKey(_ value: String, keyID: String) throws {
        guard let data = BighelpNotificationBase64URL.decodeCanonical(value), data.count == 65,
              (try? P256.Signing.PublicKey(x963Representation: data)) != nil,
              BighelpNotificationBase64URL.encode(Data(SHA256.hash(data: data))) == keyID else {
            throw DirectHermesError.invalidResponse
        }
    }
    static func sessionReference(profile: String, session: String) -> String {
        BighelpNotificationBase64URL.encode(Data(SHA256.hash(data: Data((profile + "\0" + session).utf8))))
    }
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func nativeSessionID(host: BighelpConfiguredHost, profile: String, session: String) -> String {
        "native-" + digest([host.notificationScope, host.hostConnectionID, profile, session].joined(separator: "\0"))
    }
    /// A notification or Live Activity link names this scoped digest. A chat's
    /// own ID (`native-session-v1:…`, what widgets link to) starts the same way.
    static func isOpaqueSessionID(_ id: String) -> Bool {
        guard id.hasPrefix("native-") else { return false }
        let digest = id.utf8.dropFirst("native-".utf8.count)
        return digest.count == 64 && digest.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 262_144 else { throw DirectHermesError.messageTooLarge }
        return data
    }
    static func decode<T: Decodable>(_ type: T.Type, from value: BighelpJSONValue) throws -> T {
        try DirectHermesWire.validateValueSize(value, limit: 262_144)
        return try JSONDecoder().decode(type, from: data(value))
    }
    static func grant(_ response: BighelpJSONValue) throws -> BighelpManagedGrant {
        guard let object = response.object, Set(object.keys) == ["version", "grant"],
              object["version"]?.integer == 1, let value = object["grant"] else { throw DirectHermesError.invalidResponse }
        let grant = try decode(BighelpManagedGrant.self, from: value)
        try grant.validate(); return grant
    }
    static func grants(_ response: BighelpJSONValue) throws -> [BighelpManagedGrant] {
        guard let object = response.object, Set(object.keys) == ["version", "grants"],
              object["version"]?.integer == 1, let values = object["grants"]?.array, values.count <= 256 else {
            throw DirectHermesError.invalidResponse
        }
        let grants = try values.map { value in
            let grant = try decode(BighelpManagedGrant.self, from: value); try grant.validate(); return grant
        }
        guard Set(grants.map(\.grantId)).count == grants.count else { throw DirectHermesError.invalidResponse }
        return grants
    }
}
