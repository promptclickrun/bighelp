import Foundation
import OSLog

// MARK: - What the host says about a draft

/// A draft's state on its computer (docs/IMAGE_DRAFTS.md › Parts).
enum ImageDraftState: String, Codable, CaseIterable, Sendable {
    case awaitingReview = "awaiting_review"
    case applying
    case saved
    case failed
    case outcomeUnknown = "outcome_unknown"
    case discarded
    case replaced

    /// Nothing more can happen to it.
    var isFinal: Bool { [.saved, .discarded, .replaced].contains(self) }
}

enum ImageDraftOutcome: String, Codable, Sendable {
    case saved, failed
    case outcomeUnknown = "outcome_unknown"
}

/// Why a Save didn't write, as the host records it.
enum ImageDraftFailureReason: String, Codable, CaseIterable, Sendable {
    case permissionDenied = "permission_denied"
    case destinationUnavailable = "destination_unavailable"
    case invalidFields = "invalid_fields"
    case writeFailed = "write_failed"

    /// What `{{reason}}` says.
    var message: String {
        switch self {
        case .permissionDenied: "bighelp isn't allowed to add it. You can allow it in Settings."
        case .destinationUnavailable: "That account or calendar isn't available. Choose another one."
        case .invalidFields: "Some details can't be saved as they are. Check them and try again."
        case .writeFailed: "Try again in a moment."
        }
    }
}

struct ImageDraftHostState: Codable, Equatable, Sendable {
    let draftID: String
    let state: ImageDraftState
    var decisionID: String?
    var outcome: ImageDraftOutcome?
    /// The label the person saw (`iCloud`, `Home`).
    var destination: String?
    var reason: ImageDraftFailureReason?
    var verified: Bool?
    var replacedBy: String?
    var updatedAt: Date?
    /// The `content_hash` of the card the plugin made for this draft. A card in the chat with
    /// another hash isn't that card.
    var cardHash: String?

    init(draftID: String, state: ImageDraftState, decisionID: String? = nil, outcome: ImageDraftOutcome? = nil,
         destination: String? = nil, reason: ImageDraftFailureReason? = nil, verified: Bool? = nil,
         replacedBy: String? = nil, updatedAt: Date? = nil, cardHash: String? = nil) {
        self.draftID = draftID
        self.state = state
        self.decisionID = decisionID
        self.outcome = outcome
        self.destination = destination
        self.reason = reason
        self.verified = verified
        self.replacedBy = replacedBy
        self.updatedAt = updatedAt
        self.cardHash = cardHash
    }

    /// Lenient: only the state is needed; a part that doesn't read is left out. A reply that
    /// doesn't name its draft (`{"state": "applying"}`) is the one asked about.
    init?(json: [String: BighelpJSONValue], draftID asked: String? = nil) {
        let object = json["draft"]?.object ?? json
        guard let name = object["state"]?.string, let state = ImageDraftState(rawValue: name) else { return nil }
        let id = object["draftId"]?.string ?? asked
        guard let id, ImageDraftText.isDraftID(id), asked == nil || asked == id else { return nil }
        func line(_ key: String, maximum: Int) -> String? {
            guard let text = object[key]?.string, !text.isEmpty, ImageDraftText.length(text) <= maximum,
                  ImageDraftText.isPlain(text, oneLine: true) else { return nil }
            return text
        }
        self.init(draftID: id, state: state,
                  decisionID: line("decisionId", maximum: 64).flatMap { UUID(uuidString: $0) == nil ? nil : $0.lowercased() },
                  outcome: object["outcome"]?.string.flatMap(ImageDraftOutcome.init(rawValue:)),
                  destination: line("destination", maximum: ImageDraftWire.maximumDestinationLength),
                  reason: object["reason"]?.string.flatMap(ImageDraftFailureReason.init(rawValue:)),
                  verified: object["verified"]?.boolean,
                  replacedBy: line("replacedBy", maximum: 64).flatMap { ImageDraftText.isDraftID($0) ? $0 : nil },
                  updatedAt: object["updatedAt"]?.string.flatMap(ImageDraftEventTime.date),
                  cardHash: object["cardHash"]?.string.flatMap { ImageDraftText.isHex($0, count: 64) ? $0.lowercased() : nil })
    }

    var json: [String: BighelpJSONValue] {
        var object: [String: BighelpJSONValue] = ["draftId": .string(draftID), "state": .string(state.rawValue)]
        if let decisionID { object["decisionId"] = .string(decisionID) }
        if let outcome { object["outcome"] = .string(outcome.rawValue) }
        if let destination { object["destination"] = .string(destination) }
        if let reason { object["reason"] = .string(reason.rawValue) }
        if let verified { object["verified"] = .boolean(verified) }
        if let replacedBy { object["replacedBy"] = .string(replacedBy) }
        if let cardHash { object["cardHash"] = .string(cardHash) }
        if let updatedAt { object["updatedAt"] = .string(ISO8601DateFormatter().string(from: updatedAt)) }
        return object
    }
}

struct ImageActionsSettingsPage: Equatable, Sendable {
    var settings: ImageActionsSettings
    var defaults: ImageActionsDefaults
}

/// Why a draft request didn't go, in the terms the review needs.
enum ImageDraftsError: Error, Equatable, Sendable {
    /// The plugin lacks `native-image-drafts-v1`: "Update the bighelp plugin".
    case needsPluginUpdate
    case noConnection
    /// Not this agent's or this chat's draft, or gone.
    case notFound
    /// Already decided (saved, discarded, replaced, or failed or unclear by another decision).
    case decided(ImageDraftHostState?)
    /// Another Save is being written.
    case busy(ImageDraftHostState?)
    /// The settings changed on the computer since they were read.
    case revisionConflict
    /// A change the computer may or may not have made.
    case outcomeUnknown
    case refused(String?)
    case failed

    init(_ error: any Error) {
        if let error = error as? ImageDraftsError { self = error; return }
        switch error as? WorkspaceClientError {
        case .unavailable(.unsupportedOperation)?, .unavailable(.pluginRequired)?: self = .needsPluginUpdate
        case .rejected(let code, _)?:
            switch code {
            case "draft_decided": self = .decided(nil)
            case "draft_busy": self = .busy(nil)
            case "revision_conflict": self = .revisionConflict
            case "draft_not_found": self = .notFound
            default: self = .refused(code)
            }
        case .outcomeUnknown?: self = .outcomeUnknown
        case .transportUnavailable?, .ownerChanged?, .authenticationRequired?, .unavailable?: self = .noConnection
        default: self = .failed
        }
    }
}

// MARK: - The plugin's routes

enum ImageDraftsOperation: CaseIterable, Sendable {
    case settingsGet, settingsSave, states, source, claim, finish, discard, reopen

    var workspaceOperation: WorkspaceOperation {
        switch self {
        case .settingsGet: .imageActionsGet
        case .settingsSave: .imageActionsSave
        case .states: .imageDraftsStates
        case .source: .imageDraftsSource
        case .claim: .imageDraftsClaim
        case .finish: .imageDraftsFinish
        case .discard: .imageDraftsDiscard
        case .reopen: .imageDraftsReopen
        }
    }
}

/// One computer's `image-actions` and `image-drafts` routes.
@MainActor
protocol ImageDraftsClient: AnyObject {
    func perform(_ operation: ImageDraftsOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]
}

/// The plugin's routes on the computer in use.
@MainActor
final class DirectHermesImageDraftsClient: ImageDraftsClient {
    private let workspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(workspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.workspace = workspace
    }

    func perform(_ operation: ImageDraftsOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard let workspace = workspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.transportUnavailable
        }
        do {
            return try await workspace.perform(operation.workspaceOperation, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            return try await workspace.perform(operation.workspaceOperation, payload: payload, owner: owner)
        }
    }
}

/// Typed calls over a client: the payloads the contract names, lenient reading of the replies,
/// and the host's refusals as `ImageDraftsError`.
@MainActor
struct ImageDraftsAPI {
    static let maximumStatesPerCall = 50
    /// Larger than any photo bighelp sends (8 MB) with room for a newer plugin.
    static let maximumSourceBytes = ChatAttachment.maximumAgentBytes
    static let pieceRetryDelays: [Duration] = [.seconds(1), .seconds(3)]

    let client: any ImageDraftsClient

    init(client: any ImageDraftsClient) {
        self.client = client
    }

    private func call(_ operation: ImageDraftsOperation,
                      _ payload: [String: BighelpJSONValue]) async throws(ImageDraftsError) -> [String: BighelpJSONValue] {
        do { return try await client.perform(operation, payload: payload) } catch {
            // The transport's own error, before it's folded into ImageDraftsError. Codes only.
            ImageDraftsAPI.log.error("image drafts \(String(describing: operation), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw ImageDraftsError(error)
        }
    }

    static let log = Logger(subsystem: "app.loopdy.mobile", category: "ImageDrafts")

    // MARK: Settings

    func settings(agentID: String) async throws(ImageDraftsError) -> ImageActionsSettingsPage {
        let reply = try await call(.settingsGet, ["agentId": .string(agentID)])
        return ImageActionsSettingsPage(settings: .lenient(reply["settings"]), defaults: .lenient(reply["defaults"]))
    }

    /// Saves with the revision that was read; the computer refuses it when the revision moved.
    func save(_ settings: ImageActionsSettings, agentID: String) async throws(ImageDraftsError) -> ImageActionsSettings {
        do { try settings.validate() } catch { throw .refused("invalid_settings") }
        let reply = try await call(.settingsSave, ["agentId": .string(agentID), "expectedRevision": .integer(settings.revision),
                                                   "settings": settings.json])
        guard let saved = reply["settings"] else { throw .failed }
        return .lenient(saved)
    }

    // MARK: Drafts

    /// The states of up to 50 drafts in one chat a call; unknown ones are left out.
    func states(agentID: String, sessionID: String, draftIDs: [String]) async throws(ImageDraftsError) -> [ImageDraftHostState] {
        var seen = Set<String>()
        let ids = draftIDs.filter { ImageDraftText.isDraftID($0) && seen.insert($0).inserted }
        var result: [ImageDraftHostState] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + Self.maximumStatesPerCall, ids.count)])
            start += chunk.count
            let reply = try await call(.states, ["agentId": .string(agentID), "sessionId": .string(sessionID),
                                                 "draftIds": .array(chunk.map(BighelpJSONValue.string))])
            let asked = Set(chunk)
            for row in reply["drafts"]?.array ?? [] {
                guard let object = row.object, let state = ImageDraftHostState(json: object), asked.contains(state.draftID) else {
                    continue
                }
                result.append(state)
            }
        }
        return result
    }

    func state(of key: ImageDraftKey) async throws(ImageDraftsError) -> ImageDraftHostState? {
        try await states(agentID: key.agentID, sessionID: key.sessionID, draftIDs: [key.draftID]).first
    }

    private func base(_ key: ImageDraftKey) -> [String: BighelpJSONValue] {
        ["agentId": .string(key.agentID), "sessionId": .string(key.sessionID), "draftId": .string(key.draftID)]
    }

    /// Claims the draft for one Save. The same decision again answers the same; any other decision
    /// is refused with the draft's current state (read back, since the refusal carries no body here).
    func claim(_ approval: ImageDraftApproval) async throws(ImageDraftsError) -> ImageDraftHostState {
        var payload = base(approval.key)
        payload["decisionId"] = .string(approval.decisionID)
        payload["fieldsHash"] = .string(approval.fieldsHash)
        payload["destination"] = .string(approval.destination.label)
        do throws(ImageDraftsError) {
            let reply = try await call(.claim, payload)
            guard let state = ImageDraftHostState(json: reply, draftID: approval.key.draftID) else { throw ImageDraftsError.failed }
            return state
        } catch .decided {
            throw .decided(try? await state(of: approval.key))
        } catch .busy {
            throw .busy(try? await state(of: approval.key))
        }
    }

    func finish(_ approval: ImageDraftApproval, outcome: ImageDraftOutcome, reason: ImageDraftFailureReason? = nil,
                verified: Bool) async throws(ImageDraftsError) -> ImageDraftHostState {
        try await finish(approval.key, decisionID: approval.decisionID, destination: approval.destination.label,
                         outcome: outcome, reason: reason, verified: verified)
    }

    /// Only the claiming decision may finish; an `outcome_unknown` may later finish as saved or failed.
    func finish(_ key: ImageDraftKey, decisionID: String, destination: String, outcome: ImageDraftOutcome,
                reason: ImageDraftFailureReason?, verified: Bool) async throws(ImageDraftsError) -> ImageDraftHostState {
        var payload = base(key)
        payload["decisionId"] = .string(decisionID)
        payload["outcome"] = .string(outcome.rawValue)
        payload["destination"] = .string(destination)
        payload["verified"] = .boolean(verified)
        if let reason { payload["reason"] = .string(reason.rawValue) }
        let reply = try await call(.finish, payload)
        guard let state = ImageDraftHostState(json: reply, draftID: key.draftID) else { throw .failed }
        return state
    }

    func discard(_ key: ImageDraftKey) async throws(ImageDraftsError) -> ImageDraftHostState {
        do throws(ImageDraftsError) {
            let reply = try await call(.discard, base(key))
            guard let state = ImageDraftHostState(json: reply, draftID: key.draftID) else { throw ImageDraftsError.failed }
            return state
        } catch .busy {
            throw .busy(try? await state(of: key))
        } catch .decided {
            throw .decided(try? await state(of: key))
        }
    }

    func reopen(_ key: ImageDraftKey, decisionID: String) async throws(ImageDraftsError) -> ImageDraftHostState {
        var payload = base(key)
        payload["decisionId"] = .string(decisionID)
        let reply = try await call(.reopen, payload)
        guard let state = ImageDraftHostState(json: reply, draftID: key.draftID) else { throw .failed }
        return state
    }

    /// The person's picture for a draft, in pieces of about 3 MB. A piece that fails is asked for
    /// again from its offset, so a dropped request doesn't start the picture over.
    func sourceImage(_ key: ImageDraftKey) async throws(ImageDraftsError) -> (data: Data, mimeType: String) {
        var data = Data()
        var offset = 0
        var total: Int?
        var mime: String?
        while true {
            var payload = base(key)
            payload["offset"] = .integer(offset)
            let reply = try await piece(payload)
            guard let pieceMIME = reply["mimeType"]?.string, ImageDraftSource.isImageMIMEType(pieceMIME),
                  mime == nil || mime == pieceMIME,
                  let size = reply["totalBytes"]?.integer, (1...Self.maximumSourceBytes).contains(size),
                  total == nil || total == size, reply["offset"]?.integer == offset,
                  let encoded = reply["data"]?.string, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
                  offset + bytes.count <= size else { throw .failed }
            mime = pieceMIME
            total = size
            data.append(bytes)
            let end = offset + bytes.count
            switch reply["nextOffset"] {
            case nil, .null?:
                guard end == size else { throw .failed }
                return (data, pieceMIME)
            case .integer(let next)? where next == end && end < size:
                offset = end
            default:
                throw .failed
            }
        }
    }

    private func piece(_ payload: [String: BighelpJSONValue]) async throws(ImageDraftsError) -> [String: BighelpJSONValue] {
        var retries = Self.pieceRetryDelays[...]
        while true {
            do throws(ImageDraftsError) {
                return try await call(.source, payload)
            } catch {
                guard Self.retriesPiece(after: error), !retries.isEmpty else { throw error }
                do { try await Task.sleep(for: retries.removeFirst()) } catch { throw .noConnection }
            }
        }
    }

    /// A timeout or dropped connection is worth asking again; a refusal or a bad answer isn't.
    private static func retriesPiece(after error: ImageDraftsError) -> Bool {
        switch error {
        case .noConnection, .failed: true
        default: false
        }
    }
}
