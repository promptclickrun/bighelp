import Foundation
import UIKit

/// Demo mode's computer: drafts and Photo actions settings kept in memory, answering the way the
/// plugin does (docs/IMAGE_DRAFTS.md › Routes): its replies, its refusals as
/// `WorkspaceClientError.rejected`, and the same state rules. UI tests and the demo need no host.
@MainActor
final class DemoImageDraftsClient: ImageDraftsClient {
    static let shared = DemoImageDraftsClient()

    struct Row: Equatable, Sendable {
        let agentID: String
        let sessionID: String
        var state: ImageDraftState = .awaitingReview
        var decisionID: String?
        var fieldsHash: String?
        var destination: String?
        var outcome: ImageDraftOutcome?
        var reason: ImageDraftFailureReason?
        var verified: Bool?
        var replacedBy: String?
        var updatedAt: Date
        /// The `content_hash` of the card the plugin made for this draft.
        var cardHash: String?
    }

    private(set) var rows: [String: Row] = [:]
    /// The demo's drafts were "made" by an agent before the app ran, so the first chat that asks
    /// for one owns it. Tests turn this off to check `draft_not_found`.
    var registersUnknownDrafts: Bool
    /// The person's picture for each draft; a plain placeholder when none is set.
    var images: [String: (data: Data, mimeType: String)] = [:]
    var pieceBytes = 3 * 1_024 * 1_024
    private var settings: [String: ImageActionsSettings] = [:]
    private let clock: () -> Date
    /// Every call, for tests.
    private(set) var calls: [(operation: ImageDraftsOperation, payload: [String: BighelpJSONValue])] = []

    init(registersUnknownDrafts: Bool = true, clock: @escaping () -> Date = { Date() }) {
        self.registersUnknownDrafts = registersUnknownDrafts
        self.clock = clock
    }

    func register(draftID: String, agentID: String, sessionID: String, state: ImageDraftState = .awaitingReview) {
        rows[draftID] = Row(agentID: agentID, sessionID: sessionID, state: state, updatedAt: clock())
    }

    func setCardHash(_ hash: String, for draftID: String) {
        rows[draftID]?.cardHash = hash
    }

    func perform(_ operation: ImageDraftsOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        calls.append((operation, payload))
        guard let agentID = payload["agentId"]?.string, !agentID.isEmpty else { throw Self.refusal("invalid_request") }
        switch operation {
        case .settingsGet:
            return ["settings": (settings[agentID] ?? ImageActionsSettings()).json, "defaults": Self.defaultsJSON]
        case .settingsSave:
            let current = settings[agentID] ?? ImageActionsSettings()
            guard let expected = payload["expectedRevision"]?.integer, let value = payload["settings"] else {
                throw Self.refusal("invalid_request")
            }
            guard expected == current.revision else { throw Self.refusal("revision_conflict") }
            guard var next = try? ImageActionsSettings(json: value) else { throw Self.refusal("invalid_settings") }
            next.revision = current.revision + 1
            settings[agentID] = next
            return ["settings": next.json]
        case .states:
            guard let sessionID = payload["sessionId"]?.string, let ids = payload["draftIds"]?.array,
                  (1...ImageDraftsAPI.maximumStatesPerCall).contains(ids.count) else { throw Self.refusal("invalid_request") }
            let drafts = ids.compactMap { value -> BighelpJSONValue? in
                guard let id = value.string, let row = try? lookup(id, agentID: agentID, sessionID: sessionID) else { return nil }
                return .object(json(id, row))
            }
            return ["drafts": .array(drafts)]
        case .source:
            let (id, _) = try lookup(payload, agentID: agentID)
            guard let offset = payload["offset"]?.integer, offset >= 0 else { throw Self.refusal("invalid_request") }
            let image = images[id] ?? Self.placeholder
            guard offset < image.data.count else { throw Self.refusal("invalid_request") }
            let end = min(image.data.count, offset + pieceBytes)
            var reply: [String: BighelpJSONValue] = [
                "mimeType": .string(image.mimeType), "totalBytes": .integer(image.data.count), "offset": .integer(offset),
                "data": .string(image.data.subdata(in: offset..<end).base64EncodedString()),
            ]
            if end < image.data.count { reply["nextOffset"] = .integer(end) }
            return reply
        case .claim:
            var (id, row) = try lookup(payload, agentID: agentID)
            guard let decision = Self.decisionID(payload), let hash = payload["fieldsHash"]?.string,
                  ImageDraftText.isHex(hash, count: 64), let destination = Self.destination(payload) else {
                throw Self.refusal("invalid_request")
            }
            switch row.state {
            case .awaitingReview:
                row.state = .applying
                row.decisionID = decision
                row.fieldsHash = hash
                row.destination = destination
                row.updatedAt = clock()
            case .applying where row.decisionID == decision:
                // As the plugin: the same Save asking again, unless it now brings other details.
                guard row.fieldsHash == hash else { throw Self.refusal("draft_busy") }
            case .saved where row.decisionID == decision, .failed where row.decisionID == decision,
                 .outcomeUnknown where row.decisionID == decision:
                // The same Save asking again after its outcome gets the draft as it is.
                return json(id, row)
            case .applying:
                throw Self.refusal("draft_busy")
            case .saved, .failed, .outcomeUnknown, .discarded, .replaced:
                throw Self.refusal("draft_decided")
            }
            rows[id] = row
            return json(id, row)
        case .finish:
            var (id, row) = try lookup(payload, agentID: agentID)
            guard let decision = Self.decisionID(payload),
                  let outcome = payload["outcome"]?.string.flatMap(ImageDraftOutcome.init(rawValue:)),
                  let destination = Self.destination(payload), let verified = payload["verified"]?.boolean else {
                throw Self.refusal("invalid_request")
            }
            let reason = payload["reason"]?.string.flatMap(ImageDraftFailureReason.init(rawValue:))
            if outcome == .failed, reason == nil { throw Self.refusal("invalid_request") }
            guard row.decisionID == decision else {
                throw Self.refusal(row.state == .applying ? "draft_busy" : "draft_decided")
            }
            switch (row.state, outcome) {
            case (.applying, _), (.outcomeUnknown, .saved), (.outcomeUnknown, .failed): break
            default: throw Self.refusal("draft_decided")
            }
            row.state = switch outcome {
            case .saved: .saved
            case .failed: .failed
            case .outcomeUnknown: .outcomeUnknown
            }
            row.outcome = outcome
            row.reason = outcome == .failed ? reason : nil
            row.verified = verified
            row.destination = destination
            row.updatedAt = clock()
            rows[id] = row
            return json(id, row)
        case .discard:
            var (id, row) = try lookup(payload, agentID: agentID)
            switch row.state {
            case .awaitingReview, .failed, .outcomeUnknown:
                row.state = .discarded
                row.updatedAt = clock()
            case .discarded: break
            case .applying: throw Self.refusal("draft_busy")
            case .saved, .replaced: throw Self.refusal("draft_decided")
            }
            rows[id] = row
            return ["state": .string(ImageDraftState.discarded.rawValue)]
        case .reopen:
            var (id, row) = try lookup(payload, agentID: agentID)
            guard let decision = Self.decisionID(payload) else { throw Self.refusal("invalid_request") }
            switch row.state {
            case .applying:
                // Only the Save that claimed it knows nothing was written.
                guard row.decisionID == decision else { throw Self.refusal("draft_busy") }
            case .failed, .outcomeUnknown, .awaitingReview: break
            case .saved, .discarded, .replaced: throw Self.refusal("draft_decided")
            }
            row = Row(agentID: row.agentID, sessionID: row.sessionID, updatedAt: clock())
            rows[id] = row
            return json(id, row)
        }
    }

    /// A draft that belongs to this agent and chat; any other gets `draft_not_found`.
    private func lookup(_ id: String, agentID: String, sessionID: String) throws -> Row {
        guard ImageDraftText.isDraftID(id) else { throw Self.refusal("invalid_request") }
        if rows[id] == nil, registersUnknownDrafts {
            rows[id] = Row(agentID: agentID, sessionID: sessionID, updatedAt: clock())
        }
        guard let row = rows[id], row.agentID == agentID, row.sessionID == sessionID else {
            throw Self.refusal("draft_not_found")
        }
        return row
    }

    private func lookup(_ payload: [String: BighelpJSONValue], agentID: String) throws -> (String, Row) {
        guard let id = payload["draftId"]?.string, let sessionID = payload["sessionId"]?.string else {
            throw Self.refusal("invalid_request")
        }
        return (id, try lookup(id, agentID: agentID, sessionID: sessionID))
    }

    private func json(_ id: String, _ row: Row) -> [String: BighelpJSONValue] {
        ImageDraftHostState(draftID: id, state: row.state, decisionID: row.decisionID, outcome: row.outcome,
                            destination: row.destination, reason: row.reason, verified: row.verified,
                            replacedBy: row.replacedBy, updatedAt: row.updatedAt, cardHash: row.cardHash).json
    }

    private static func refusal(_ code: String) -> WorkspaceClientError { .rejected(code: code) }

    private static func decisionID(_ payload: [String: BighelpJSONValue]) -> String? {
        guard let text = payload["decisionId"]?.string, UUID(uuidString: text)?.uuidString.lowercased() == text else { return nil }
        return text
    }

    private static func destination(_ payload: [String: BighelpJSONValue]) -> String? {
        guard let text = payload["destination"]?.string, ImageDraftText.trimmed(text) != nil,
              ImageDraftText.length(text) <= ImageDraftWire.maximumDestinationLength else { return nil }
        return text
    }

    private static var defaultsJSON: BighelpJSONValue {
        .object(Dictionary(uniqueKeysWithValues: ImageDraftPreset.allCases.map { preset in
            let value = ImageActionsDefaults.standard[preset]
            return (preset.rawValue, BighelpJSONValue.object([
                "offer": .boolean(value.offer), "instructions": .string(value.instructions),
                "question": .string(value.question), "messages": value.messages.json,
            ]))
        }))
    }

    /// A light gray picture, for a draft the demo has no photo for.
    private static var placeholder: (data: Data, mimeType: String) {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 40)).pngData { context in
            UIColor(white: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        }
        return (data, "image/png")
    }
}
