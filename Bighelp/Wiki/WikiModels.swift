import CryptoKit
import Foundation

struct WikiOwner: Codable, Hashable, Sendable {
    enum Authority: Hashable, Sendable {
        case link(accountID: String, hostID: String, deviceID: String, authorizationEpoch: String)
        case native(endpointID: String, providerID: String, principalID: String)
    }

    let authority: Authority
    let profileID: String

    init(accountID: String, hostID: String, profileID: String, deviceID: String, authorizationEpoch: String) {
        authority = .link(accountID: accountID, hostID: hostID, deviceID: deviceID, authorizationEpoch: authorizationEpoch)
        self.profileID = profileID
    }

    private init(authority: Authority, profileID: String) {
        self.authority = authority
        self.profileID = profileID
    }

    static func native(authority: WorkspaceAuthority, profileID: String) throws -> Self {
        guard authority.kind == .direct, let provider = authority.providerID else { throw WikiError.ownerChanged }
        let owner = Self(authority: .native(endpointID: authority.endpointIdentity,
            providerID: provider, principalID: authority.principalID), profileID: profileID)
        guard owner.isValid else { throw WikiError.ownerChanged }
        return owner
    }

    var isNative: Bool {
        if case .native = authority { return true }
        return false
    }

    private var identityBytes: Data {
        let fields: [String]
        switch authority {
        case .link(let account, let host, let device, let epoch):
            fields = ["link", account, host, profileID, device, epoch]
        case .native(let endpoint, let provider, let principal):
            fields = ["native", endpoint, provider, principal, profileID]
        }
        return Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identityBytes == rhs.identityBytes }
    func hash(into hasher: inout Hasher) { hasher.combine(identityBytes) }

    /// A local storage namespace, not a bighelp account or credential.
    var accountID: String {
        switch authority {
        case .link(let accountID, _, _, _): accountID
        case .native(let endpoint, let provider, let principal):
            "native-wiki-" + WikiLimits.digest(Data(
                ["native-wiki-principal-v1", endpoint, provider, principal].map { "\($0.utf8.count):\($0)" }.joined().utf8
            ))
        }
    }

    var hostID: String {
        switch authority {
        case .link(_, let hostID, _, _): hostID
        case .native(let endpoint, _, _): endpoint
        }
    }

    var deviceID: String? {
        if case .link(_, _, let deviceID, _) = authority { return deviceID }
        return nil
    }

    var authorizationEpoch: String? {
        if case .link(_, _, _, let epoch) = authority { return epoch }
        return nil
    }

    var isValid: Bool {
        switch authority {
        case .link(let account, let host, let device, let epoch):
            [account, host, profileID, device, epoch].allSatisfy {
                !$0.isEmpty && $0.utf8.count <= 512 && $0.allSatisfy(\.isASCII)
                    && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }
        case .native(let endpoint, let provider, let principal):
            !profileID.isEmpty && profileID.utf8.count <= 128
                && profileID == profileID.trimmingCharacters(in: .whitespacesAndNewlines)
                && !profileID.contains("/") && !profileID.contains("\\")
                && !profileID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && (try? WorkspaceAuthority.direct(endpointIdentity: endpoint, providerID: provider, userID: principal)) != nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, hostID, profileID, deviceID, authorizationEpoch
        case authorityKind, endpointID, providerID, principalID
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let profile = try values.decode(String.self, forKey: .profileID)
        if values.contains(.authorityKind) {
            guard try values.decode(String.self, forKey: .authorityKind) == "native_principal",
                  !values.contains(.accountID), !values.contains(.hostID),
                  !values.contains(.deviceID), !values.contains(.authorizationEpoch) else {
                throw WikiError.invalidResponse
            }
            let endpoint = try values.decode(String.self, forKey: .endpointID)
            let authority = try WorkspaceAuthority.direct(endpointIdentity: endpoint,
                providerID: values.decode(String.self, forKey: .providerID),
                userID: values.decode(String.self, forKey: .principalID))
            guard authority.endpointIdentity == endpoint else { throw WikiError.invalidResponse }
            self = try .native(authority: authority, profileID: profile)
        } else {
            guard !values.contains(.endpointID), !values.contains(.providerID), !values.contains(.principalID) else {
                throw WikiError.invalidResponse
            }
            self.init(accountID: try values.decode(String.self, forKey: .accountID),
                hostID: try values.decode(String.self, forKey: .hostID), profileID: profile,
                deviceID: try values.decode(String.self, forKey: .deviceID),
                authorizationEpoch: try values.decode(String.self, forKey: .authorizationEpoch))
            guard isValid else { throw WikiError.invalidResponse }
        }
    }

    func encode(to encoder: any Encoder) throws {
        guard isValid else { throw WikiError.invalidResponse }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(profileID, forKey: .profileID)
        switch authority {
        case .link(let account, let host, let device, let epoch):
            // Preserve the exact legacy shape used to derive existing protected filenames.
            try values.encode(account, forKey: .accountID)
            try values.encode(host, forKey: .hostID)
            try values.encode(device, forKey: .deviceID)
            try values.encode(epoch, forKey: .authorizationEpoch)
        case .native(let endpoint, let provider, let principal):
            try values.encode("native_principal", forKey: .authorityKind)
            try values.encode(endpoint, forKey: .endpointID)
            try values.encode(provider, forKey: .providerID)
            try values.encode(principal, forKey: .principalID)
        }
    }
}

struct WikiRoot: Codable, Hashable, Identifiable, Sendable {
    let wikiId: String
    let name: String
    let writable: Bool
    let sourceKind: String
    let generation: String
    var folderPath: String? = nil
    /// Absent on older hosts: existing revision-checked edits still work.
    var supportsCreation: Bool? = nil
    var id: String { wikiId }
    var allowsEditing: Bool { writable && sourceKind == "files" }
    func matchesGrant(_ other: WikiRoot) -> Bool {
        wikiId == other.wikiId && name == other.name && writable == other.writable
            && sourceKind == other.sourceKind && generation == other.generation
            && (folderPath == nil || other.folderPath == nil || folderPath == other.folderPath)
    }
}

struct WikiConnection: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let owner: WikiOwner
    var name: String
    let root: WikiRoot
    var readOnly: Bool

    init(id: UUID = UUID(), owner: WikiOwner, name: String, root: WikiRoot, readOnly: Bool = true) {
        self.id = id
        self.owner = owner
        self.name = name
        self.root = root
        self.readOnly = readOnly
    }

    var allowsEditing: Bool { !readOnly && root.allowsEditing }
}

struct WikiEntry: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let path: String
    let kind: String
    let size: Int?
    var id: String { path }
    var isDirectory: Bool { kind == "directory" }
}

struct WikiDirectory: Codable, Equatable, Sendable {
    let wikiId: String
    let path: String
    let parent: String?
    let revision: String
    let offset: Int
    let limit: Int
    let total: Int
    let entries: [WikiEntry]
    let nextOffset: Int?
}

struct WikiFilePage: Codable, Sendable {
    let wikiId: String
    let path: String
    let availability: String
    let size: Int
    let offset: Int
    let data: String?
    let text: String?
    let revision: String?
    let nextOffset: Int?
    let maxFileBytes: Int?
}

enum WikiSearchMode: String, Codable, CaseIterable, Sendable {
    case name, content
    var title: String { self == .name ? "File names" : "Contents" }
}

struct WikiSearchMatch: Codable, Hashable, Identifiable, Sendable {
    let path: String
    let title: String
    let snippet: String?
    let revision: String
    var id: String { path }
}

struct WikiSearchPage: Codable, Sendable {
    let wikiId: String
    let query: String
    let mode: WikiSearchMode
    let matches: [WikiSearchMatch]
    let nextOffset: Int?
    let isComplete: Bool
    let indexedAt: Double?
}

struct WikiBytes: Sendable {
    let data: Data
    let revision: String
}

/// Original bytes are authoritative. A leading BOM and CRLF survive a no-op edit.
struct WikiDocument: Codable, Equatable, Identifiable, Sendable {
    let owner: WikiOwner
    let connection: WikiConnection
    let path: String
    let baseRevision: String
    let originalBytes: Data
    let originalSource: String
    let fetchedAt: Date

    var id: String { "\(connection.id.uuidString)/\(path)" }
    var root: WikiRoot { connection.root }
    var title: String { (path as NSString).lastPathComponent }
    var canEdit: Bool { connection.allowsEditing && originalBytes.count <= WikiLimits.editBytes }
    var isNewFile: Bool {
        WikiLimits.validGeneration(root.generation)
            && baseRevision == "wiki-new-v1:" + root.generation && originalBytes.isEmpty
    }

    init(connection: WikiConnection, path: String, bytes: WikiBytes, fetchedAt: Date = Date()) throws {
        let source = String(decoding: bytes.data, as: UTF8.self)
        guard Data(source.utf8) == bytes.data else {
            throw WikiError.invalidUTF8
        }
        self.owner = connection.owner
        self.connection = connection
        self.path = path
        self.baseRevision = bytes.revision
        self.originalBytes = bytes.data
        self.originalSource = source
        self.fetchedAt = fetchedAt
    }

    func bytes(for source: String) -> Data {
        // Swift String equality is canonically equivalent, not byte equality.
        // Encode the actual working scalars even for canonically equivalent edits.
        Data(source.utf8)
    }
}

enum WikiSavePhase: String, Codable, Sendable {
    case receiving, prepared, committing, committed, conflict, failed, indeterminate
}

struct WikiSaveResponse: Codable, Equatable, Sendable {
    let operationId: String
    let status: WikiSavePhase
    let nextOffset: Int?
    let totalBytes: Int?
    let revision: String?
    let errorCode: String?
}

struct WikiPendingSave: Codable, Identifiable, Sendable {
    let operationId: String
    let document: WikiDocument
    let workingSource: String
    let sha256: String
    var phase: WikiSavePhase
    var nextOffset: Int
    var admitted = false
    var committedRevision: String?
    var currentDocument: WikiDocument?
    var failure: String?
    var id: String { operationId }
    var bytes: Data { document.bytes(for: workingSource) }
    var hasLaterExternalChange: Bool {
        guard let committedRevision, let currentDocument else { return false }
        return currentDocument.baseRevision != committedRevision
    }
    var verifiedCommitted: Bool {
        phase == .committed && failure == nil && currentDocument != nil && !hasLaterExternalChange
            && currentDocument?.originalBytes == bytes
    }
}

enum WikiLimits {
    static func validateFolderPath(_ value: String) throws {
        guard value.hasPrefix("/"), value != "/", value.utf8.count <= 4_096,
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw WikiError.invalidPath }
    }

    static let readBytes = 8 * 1_024 * 1_024
    static let editBytes = 1_024 * 1_024
    static let chunkBytes = 65_536
    static let pageEntries = 100
    static let maxConnections = 32
    static let maxPendingSaves = 8
    static let maxImagePixels = 16_000_000
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func validGeneration(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func validRevision(_ value: String, generation: String? = nil) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "wiki-v1" && validGeneration(String(parts[1]))
            && (generation == nil || parts[1] == generation!) && parts[2].count == 64
            && parts[2].allSatisfy { "0123456789abcdef".contains($0) }
    }
}

enum WikiError: Error, LocalizedError, Equatable {
    case unavailable, ownerChanged, invalidResponse, invalidPath, invalidUTF8, oversized, readOnly, creationUnsupported
    case remote(String), quota, ambiguous, incompleteIndex, unsafeImage, recoveryRequired, imageBudget, resultBudget

    var errorDescription: String? {
        switch self {
        case .unavailable: "Wiki is unavailable for this host. Connect a compatible, authorized host to use Wiki."
        case .creationUnsupported: "This host does not support creating Wiki files. Update its bighelp plugin and reconnect. Existing file editing is still available."
        case .ownerChanged: "The Wiki identity, host or authorization changed. Reopen Wiki for the current owner."
        case .invalidResponse: "The host returned an invalid or inconsistent Wiki response. Nothing was silently truncated."
        case .invalidPath: "This link is outside the authorized Wiki or is not a supported document path."
        case .invalidUTF8: "This file is not valid UTF-8 Markdown. Its bytes were not converted."
        case .oversized: "This file exceeds the supported Wiki byte limit. It was not truncated."
        case .readOnly: "This Wiki is read only. Generated, mirrored and exported sources cannot be edited. Reconnect a writable folder to edit; your draft is retained."
        case .remote(let code):
            switch code {
            case "READ_ONLY": "The host refused this write. Your draft is retained; export a copy or ask the host owner about permissions and file metadata."
            case "WIKI_NOT_ALLOWED", "INVALID_GRANT", "UNAUTHORIZED", "FORBIDDEN", "ROOT_NOT_ALLOWED", "WIKI_NOT_FOUND", "ACCESS_DENIED": "This folder is unavailable for this identity and profile. Retry the connection or choose another folder."
            case "WIKI_AUTHORITY_CONFLICT": "This folder is registered under a different Wiki authority. Disconnect it there or choose another folder. bighelp will not adopt that registration."
            case "FOLDER_SUGGESTIONS_UNAVAILABLE": "Folder suggestions are unavailable on this connection. Enter the exact folder path to connect."
            case "OPERATION_UNCONFIRMED": "The host did not confirm this operation. Check its existing save status before retrying."
            case "OPERATION_CONFLICT": "This operation ID belongs to different content. Review the retained draft and save status before continuing."
            case "LOCAL_DISCONNECT_CLEANUP_FAILED": "Disconnected on Hermes, but local cleanup could not finish. Older local preferences cannot restore host access. Reopen Wiki to retry local cleanup."
            case "REVISION_STALE", "REVISION_CONFLICT", "CONFLICT": "The source or its grant changed. Reload the current version; your draft is retained."
            case "WIKI_UNAVAILABLE": "Wiki is unavailable on this host. Update its bighelp plugin and reconnect."
            case "STATE_UNAVAILABLE", "STATE_BUSY": "The host Wiki storage is unavailable. Retry or ask the host owner to check its private storage permissions."
            case "unsupported_operation", "UNSUPPORTED_OPERATION", "OPERATION_UNSUPPORTED", "UNSUPPORTED_CAPABILITY", "CAPABILITY_UNSUPPORTED": "This host does not support connecting Wiki folders. Update its bighelp plugin and reconnect."
            case "WIKI_OWNER_REQUIRED", "WIKI_OWNER_CHANGED": "The Wiki host authorization changed. Reopen Wiki for the current host."
            case "WIKI_AMBIGUOUS": "This folder has multiple Wiki registrations. Ask the host owner to resolve the duplicate registrations."
            case "SECRET_SCAN_BLOCKED": "The host blocked this file because it may contain credentials. Review it on your host before opening it here."
            case "PATH_NOT_FOUND": "This Wiki path was not found."
            case "OPERATION_NOT_FOUND": "The host has no record of this operation. Keep the same draft and operation ID; do not assume it was saved."
            default: "The host could not complete the Wiki request. Retry when the host is available; your draft is retained."
            }
        case .quota: "Local Wiki recovery storage is full. Export or explicitly discard resolved drafts before starting another save."
        case .ambiguous: "More than one page matches this link. Choose the intended page."
        case .incompleteIndex: "The search index is incomplete. Choose a listed page or browse to the exact path."
        case .unsafeImage: "This image is unsupported or exceeds safe decoded image limits."
        case .imageBudget: "This page has reached its four-image load budget. Reopen the page to load a different image."
        case .resultBudget: "The visible result budget has been reached. Results are incomplete; narrow the search or open a subfolder."
        case .recoveryRequired: "This file has a pending save. Check its status or explicitly resolve it before starting another operation."
        }
    }

    static func saveMessage(_ error: Error) -> String {
        switch safe(error) {
        case .readOnly, .remote("READ_ONLY"):
            return "Your host won’t allow changes to this file. Check its write permission, then retry. Your edits are still here."
        case .ownerChanged:
            return "The account or host changed. Reopen this file from Wiki."
        case .remote("REVISION_STALE"), .remote("REVISION_CONFLICT"), .remote("CONFLICT"):
            return "This file changed on your host. Reopen it to review both versions. Your edits are still here."
        default:
            return "Couldn’t save to your host. Retry when it’s available. Your edits are still here."
        }
    }

    static func safe(_ error: Error) -> WikiError {
        if let error = error as? WikiError { return error }
        if let socketError = error as? BighelpLinkLiveSocketError, socketError == .hostUpdateRequired {
            return .remote("UNSUPPORTED_OPERATION")
        }
        if case BighelpLinkWorkspaceClientError.remote(_, let code, _) = error {
            return .remote(code ?? "UNAVAILABLE")
        }
        if let error = error as? WorkspaceClientError {
            switch error {
            case .ownerChanged, .authenticationRequired: return .ownerChanged
            case .invalidRequest, .invalidResponse: return .invalidResponse
            case .conflict: return .remote("REVISION_STALE")
            case .outcomeUnknown: return .remote("OPERATION_UNCONFIRMED")
            case .capacityExceeded: return .oversized
            case .rejected(let code): return .remote(code ?? "UNAVAILABLE")
            case .unavailable, .transportUnavailable: return .unavailable
            }
        }
        return .unavailable
    }
}
