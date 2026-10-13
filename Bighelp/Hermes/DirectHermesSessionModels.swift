import Foundation

enum DirectHermesSessionError: Error, Equatable, Sendable {
    case invalidResponse
    case historyChanged
    case canonicalMissing(profileID: String, knownID: String)
    case creationPersistenceRequired
    case creationUnconfirmed(profileID: String)
    case creationInProgress(profileID: String)
    case sessionNotPersisted
    case workspaceNotConfirmed
    case nativeRowDeletionOnly
    case modelNotConfirmed(String)
}

extension DirectHermesSessionError: LocalizedError {
    /// What people see when a chat can't be started or opened, instead of a bare "Try again".
    var errorDescription: String? {
        switch self {
        case .creationUnconfirmed:
            "This agent's last new chat didn't finish setting up on your computer. Try again in a moment."
        case .creationInProgress:
            "A new chat with this agent is already starting."
        case .workspaceNotConfirmed:
            "Your computer didn't start the chat in this agent's project folder. Check the project in Projects, then try again."
        case .canonicalMissing:
            "This agent's own chat couldn't be found on your computer."
        case .creationPersistenceRequired, .sessionNotPersisted:
            "bighelp couldn't keep track of the new chat. Try again."
        case .invalidResponse, .historyChanged:
            "Your computer answered in a way bighelp didn't expect. Try again."
        case .nativeRowDeletionOnly:
            "This chat can only be deleted here, not changed."
        case .modelNotConfirmed(let model):
            "Your computer didn't start the session on \(model). Check this agent's models, then try again."
        }
    }
}

enum DirectHermesSessionDurability: String, Codable, Equatable, Sendable {
    case draft
    case persisted
}

struct DirectHermesResolvedSession: Equatable, Sendable {
    let record: SessionRecord
    let coordinate: WorkspaceSessionCoordinate
    let durability: DirectHermesSessionDurability
    let canonicalRegistryID: String?
    let cwd: String?
    var catalog: DirectHermesCatalogCoordinate? = nil
}

struct DirectHermesCatalogCoordinate: Equatable, Sendable {
    let owner: WorkspaceOwner
    let profileID: String
    let rowID: String
    let lineageRootID: String?
    let lineageIDs: [String]?
    var canonicalRegistryID: String? = nil
}

struct DirectHermesNativeRowDeletionReceipt: Equatable, Sendable {
    let owner: WorkspaceOwner
    let profileID: String
    let rowID: String
    let alreadyAbsent: Bool
    /// The endpoint does not attest complete conversation/lineage erasure.
    let mayRetainOtherHistory = true
}

enum DirectHermesCanonicalChatResolution: Equatable, Sendable {
    case resolved(DirectHermesResolvedSession)
    /// A successful exact registry lookup was empty. This is not permission
    /// to create except through an explicitly authorized first-birth flow.
    case notCreated(profileID: String)
}

struct DirectHermesSessionCreationState: Codable, Equatable, Sendable {
    enum Purpose: String, Codable, Sendable {
        case ordinary
        case firstCanonical
    }
    enum Phase: String, Codable, Sendable {
        case createRequested
        case created
        case titleRequested
        case awaitingRegistry
        case complete
        case canonicalResolved
    }
    let schemaVersion: Int
    let intentID: String
    let scopeID: String
    let profileID: String
    let purpose: Purpose
    let connectionGeneration: UUID
    var phase: Phase
    var storedSessionID: String?
    var runtimeSessionID: String?
    var requestedCWD: String?
    var canonicalRegistryID: String?

    func validated(for owner: WorkspaceOwner) throws -> Self {
        guard schemaVersion == 1, scopeID == owner.cacheScopeID,
              UUID(uuidString: intentID) != nil else { throw WorkspaceClientError.invalidResponse }
        try DirectHermesSessionValidation.coordinate(profileID, maximum: 128)
        if let storedSessionID { try DirectHermesSessionValidation.coordinate(storedSessionID) }
        if let runtimeSessionID { try DirectHermesSessionValidation.coordinate(runtimeSessionID) }
        if let requestedCWD { try DirectHermesSessionValidation.hostPath(requestedCWD) }
        if let canonicalRegistryID { try DirectHermesSessionValidation.coordinate(canonicalRegistryID) }
        let validCoordinates: Bool
        if phase == .canonicalResolved {
            validCoordinates = purpose == .firstCanonical && canonicalRegistryID != nil
                && ((storedSessionID == nil) == (runtimeSessionID == nil))
        } else if phase == .createRequested {
            validCoordinates = storedSessionID == nil && runtimeSessionID == nil
        } else {
            validCoordinates = storedSessionID != nil && runtimeSessionID != nil
        }
        guard validCoordinates else {
            throw WorkspaceClientError.invalidResponse
        }
        return self
    }
}

struct DirectHermesSessionListOptions: Equatable, Sendable {
    enum Archive: String, Sendable { case exclude, only, include }
    enum Order: String, Sendable { case created, recent }
    var archived: Archive = .exclude
    var order: Order = .created
    var sources: [String] = []
    var excludedSources: [String] = ["tool", "kanban", "bot_room"]
    var cwdPrefix: String?
}

struct DirectHermesSessionFlags: Equatable, Sendable {
    var archived: Bool?
    var hidden: Bool?
    var pinned: Bool?
    var unread: Bool?
}

struct DirectHermesSessionSearchResult: Identifiable, Equatable, Sendable {
    let record: SessionRecord
    let snippet: String
    var id: String { record.id }
}

/// App IDs preserve a cold-recoverable anchor while runtime/durable tips may
/// change. The encoded components are identities, never title or message text.
enum DirectHermesSessionIdentity {
    static let prefix = "native-session-v1"

    static func appID(owner: WorkspaceOwner, profileID: String, anchorID: String) throws -> String {
        try DirectHermesSessionValidation.coordinate(profileID, maximum: 128)
        try DirectHermesSessionValidation.coordinate(anchorID)
        return "\(prefix):\(owner.cacheScopeID):\(encode(profileID)):\(encode(anchorID))"
    }

    static func decode(_ appID: String, owner: WorkspaceOwner) throws -> (profileID: String, anchorID: String) {
        guard appID.utf8.count <= 4096 else { throw WorkspaceClientError.invalidRequest }
        let parts = appID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == Substring(prefix), parts[1] == Substring(owner.cacheScopeID),
              let profile = decodePart(String(parts[2])), let anchor = decodePart(String(parts[3])),
              try self.appID(owner: owner, profileID: profile, anchorID: anchor) == appID else {
            throw WorkspaceClientError.invalidRequest
        }
        return (profile, anchor)
    }

    static func key(_ value: String) -> String { encode(value) }

    private static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodePart(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 1024,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4)),
              let decoded = String(data: data, encoding: .utf8), encode(decoded) == value else { return nil }
        return decoded
    }
}

enum DirectHermesSessionValidation {
    static let maximumSessions = 10_000
    static let maximumHistoryRows = 50_000
    static let maximumHistoryBytes = 32 * 1024 * 1024

    static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func coordinate(_ value: String, maximum: Int = 512) throws {
        try WorkspaceAuthority.validateIdentifier(value, maximumBytes: maximum)
    }

    static func text(_ value: String, maximum: Int, allowsEmpty: Bool = true) throws -> String {
        guard value.utf8.count <= maximum, allowsEmpty || !value.isEmpty,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && !"\n\r\t".unicodeScalars.contains($0)
              }) else { throw WorkspaceClientError.invalidResponse }
        return value
    }

    static func hostPath(_ value: String) throws {
        try coordinate(value, maximum: 4096)
        guard value.hasPrefix("/") || value.hasPrefix("\\\\")
                || value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil else {
            throw WorkspaceClientError.invalidRequest
        }
    }

    static func string(_ value: BighelpJSONValue?, maximum: Int = 512) throws -> String {
        guard let value = value?.string else { throw WorkspaceClientError.invalidResponse }
        try coordinate(value, maximum: maximum)
        return value
    }

    static func optionalText(_ value: BighelpJSONValue?, maximum: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let string = value.string else { throw WorkspaceClientError.invalidResponse }
        return try text(string, maximum: maximum)
    }

    static func flag(_ value: BighelpJSONValue?) throws -> Bool? {
        switch value {
        case nil, .null: nil
        case .boolean(let flag): flag
        case .integer(0): false
        case .integer(1): true
        default: throw WorkspaceClientError.invalidResponse
        }
    }

    static func date(_ value: BighelpJSONValue?) throws -> Date? {
        guard let value, value != .null else { return nil }
        guard let seconds = value.number, seconds.isFinite, (0...253_402_300_799).contains(seconds) else {
            throw WorkspaceClientError.invalidResponse
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
