import Foundation
import OSLog

/// Why a space didn't load or change, as Today and the draft card act on it.
enum SpacesError: Error, Equatable, Sendable {
    /// The computer's plugin context doesn't list `native-spaces-v1`: "Update the plugin on <computer>".
    case needsPluginUpdate
    /// Not this bot's space, or the bot or the space is gone.
    case notFound
    /// The bot changed the draft after the card was drawn; nil when the computer couldn't be asked.
    case draftChanged(revision: Int?)
    /// Add on a space that is live with nothing waiting.
    case notDraft
    /// The bot has as many live spaces as it can.
    case full
    /// Update now again too soon; seconds to wait when the computer said.
    case tooSoon(retryAfter: Int?)
    /// The computer's Hermes can't run scheduled tasks right now. From delete: the space is off
    /// Today already, and the same `operationId` finishes the delete later.
    case schedulesUnavailable
    /// Add found the draft's script gone, or it failed the computer's check (`invalid_request`).
    case scriptMissing
    /// Update now ran and failed; the space as it is now, when it could be read.
    case routineFailed(Space?)
    /// No answer, or no connection. Nothing is known to have changed.
    case unreachable
    /// Refused for another reason (a fixed code, or nil for an answer that didn't read).
    case other(code: String?)

    /// The computer said no for good: undo what the phone showed.
    var isDefinite: Bool {
        switch self {
        case .unreachable: false
        default: true
        }
    }

    init(_ error: any Error) {
        if let error = error as? SpacesError { self = error; return }
        guard let error = error as? WorkspaceClientError else { self = .unreachable; return }
        switch error {
        case .unavailable(.unsupportedOperation), .unavailable(.pluginRequired):
            // Only the client's context check says the feature is missing; this is a route
            // that isn't reachable now.
            self = .unreachable
        case .rejected(let code, _):
            switch code ?? "" {
            case "space_not_found", "profile_not_found": self = .notFound
            case "draft_changed": self = .draftChanged(revision: nil)
            case "space_not_draft": self = .notDraft
            case "spaces_full": self = .full
            case "refresh_too_soon": self = .tooSoon(retryAfter: nil)
            case "schedules_unavailable": self = .schedulesUnavailable
            case "routine_failed": self = .routineFailed(nil)
            // The plugin turned the feature off after the context listed it: a reload says.
            case "spaces_unavailable": self = .unreachable
            default: self = .other(code: code)
            }
        case .capacityExceeded: self = .other(code: "too_large")
        case .invalidRequest: self = .other(code: "invalid_request")
        case .invalidResponse: self = .other(code: nil)
        case .unavailable, .ownerChanged, .authenticationRequired, .transportUnavailable, .conflict, .outcomeUnknown:
            self = .unreachable
        }
    }
}

/// One computer's `spaces` routes.
@MainActor
protocol SpacesClient: AnyObject, Sendable {
    func perform(_ operation: SpacesOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]
}

/// The plugin's routes over one computer's connection, read again on every call (bighelp
/// reconnects every time it comes back).
@MainActor
final class DirectHermesSpacesClient: SpacesClient {
    private let workspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(workspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.workspace = workspace
    }

    func perform(_ operation: SpacesOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard let workspace = workspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.transportUnavailable
        }
        var reloadedContext = false
        var askedAgain = false
        while true {
            do {
                return try await workspace.perform(operation.workspaceOperation, payload: payload, owner: owner)
            } catch WorkspaceClientError.conflict where !reloadedContext {
                // The plugin's context changed (412): the next call loads it again. Once.
                reloadedContext = true
            } catch WorkspaceClientError.outcomeUnknown where operation.isMutation && !askedAgain {
                // The same payload carries the same `operationId`: done once, the computer answers
                // with what it did; not done, it does it now.
                askedAgain = true
            } catch WorkspaceClientError.unavailable(.unsupportedOperation),
                    WorkspaceClientError.unavailable(.pluginRequired) {
                if await Self.lacksFeature(workspace, owner: owner) { throw SpacesError.needsPluginUpdate }
                throw WorkspaceClientError.transportUnavailable
            }
        }
    }

    /// Only the plugin's own context says the feature isn't there. A route refused while the
    /// computer reconnects, or a context that didn't load, never does.
    private static func lacksFeature(_ workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner) async -> Bool {
        do {
            let context = try await workspace.perform(.nativeContext, payload: [:], owner: owner)
            guard let features = context["features"]?.array else { return false }
            return !features.contains(.string(SpacesWire.feature))
        } catch WorkspaceClientError.unavailable(.pluginRequired) {
            // No bighelp plugin answers on this computer at all.
            return true
        } catch {
            return false
        }
    }
}

/// Typed calls over a client: the payloads docs/SPACES.md names and lenient reading of the answers.
@MainActor
struct SpacesAPI: Sendable {
    static let log = Logger(subsystem: "app.loopdy.mobile", category: "Spaces")

    let client: any SpacesClient

    init(client: any SpacesClient) {
        self.client = client
    }

    private func call(_ operation: SpacesOperation,
                      _ payload: [String: BighelpJSONValue]) async throws(SpacesError) -> [String: BighelpJSONValue] {
        do { return try await client.perform(operation, payload: payload) } catch {
            // The transport's own error, before it's folded into SpacesError. Codes only.
            Self.log.error("spaces \(operation.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw SpacesError(error)
        }
    }

    private func space(in reply: [String: BighelpJSONValue], agentID: String, spaceID: String) throws(SpacesError) -> Space {
        guard let object = reply["space"]?.object, let space = Space(json: object),
              space.agentID == agentID, space.spaceID == spaceID else { throw .other(code: nil) }
        return space
    }

    /// The live spaces of up to 64 bots. `known` (`agentId/spaceId` → `cardsSha256`) lets the
    /// computer leave out cards the phone has.
    func list(agentIDs: [String], known: [String: String]) async throws(SpacesError) -> SpacesList {
        let agents = Array(agentIDs.filter(SpacesWire.isAgentID).prefix(SpacesWire.maximumAgentsPerList))
        guard !agents.isEmpty else { return SpacesList() }
        let names = Set(agents)
        let known = known.filter { key, hash in
            hash.utf8.count == 64 && key.split(separator: "/").first.map { names.contains(String($0)) } == true
        }.sorted { $0.key < $1.key }.prefix(SpacesWire.maximumKnownCards)
        let reply = try await call(.list, [
            "agentIds": .array(agents.map(BighelpJSONValue.string)),
            "known": .object(Dictionary(uniqueKeysWithValues: known.map { ($0.key, BighelpJSONValue.string($0.value)) })),
        ])
        guard reply["spaces"]?.array != nil else { throw .other(code: nil) }
        var list = SpacesList(json: reply)
        // Only the bots asked about, so another bot's answer can't replace their spaces.
        list.spaces.removeAll { !names.contains($0.agentID) }
        return list
    }

    /// One space with its cards; drafts too.
    func space(agentID: String, spaceID: String) async throws(SpacesError) -> Space {
        let reply = try await call(.get, ["agentId": .string(agentID), "spaceId": .string(spaceID)])
        return try space(in: reply, agentID: agentID, spaceID: spaceID)
    }

    /// Turns a draft (or a live space's waiting routine change) into a live space at `draftRevision`.
    func add(agentID: String, spaceID: String, draftRevision: Int, size: SpaceSize? = nil, position: Double? = nil,
             operationID: String = SpacesWire.newOperationID()) async throws(SpacesError) -> Space {
        var payload: [String: BighelpJSONValue] = [
            "agentId": .string(agentID), "spaceId": .string(spaceID),
            "draftRevision": .integer(draftRevision), "operationId": .string(operationID),
        ]
        payload["size"] = size.map { .string($0.rawValue) }
        payload["position"] = position.map(BighelpJSONValue.number)
        do throws(SpacesError) {
            return try space(in: try await call(.add, payload), agentID: agentID, spaceID: spaceID)
        } catch .draftChanged {
            // The refusal's revision doesn't reach the app; the space itself says it.
            throw .draftChanged(revision: try? await space(agentID: agentID, spaceID: spaceID).revision)
        } catch .other(let code) where code == "invalid_request" {
            // This app's payload always fits, and its `operationId` is new: the script is the problem.
            throw .scriptMissing
        }
    }

    func update(agentID: String, spaceID: String, changes: SpaceChanges,
                operationID: String = SpacesWire.newOperationID()) async throws(SpacesError) -> Space {
        let reply = try await call(.update, [
            "agentId": .string(agentID), "spaceId": .string(spaceID),
            "operationId": .string(operationID), "changes": .object(changes.payload),
        ])
        return try space(in: reply, agentID: agentID, spaceID: spaceID)
    }

    /// Runs the routine now: a script answers with its new state, an AI routine is queued, and a
    /// paused AI routine runs nothing (`.paused`).
    func refresh(agentID: String, spaceID: String,
                 operationID: String = SpacesWire.newOperationID()) async throws(SpacesError) -> (space: Space, ran: SpaceRefreshRun) {
        do throws(SpacesError) {
            let reply = try await call(.refresh, [
                "agentId": .string(agentID), "spaceId": .string(spaceID), "operationId": .string(operationID),
            ])
            let ran = reply["ran"]?.string.flatMap(SpaceRefreshRun.init(rawValue:)) ?? .queued
            return (try space(in: reply, agentID: agentID, spaceID: spaceID), ran)
        } catch .routineFailed {
            throw .routineFailed(try? await space(agentID: agentID, spaceID: spaceID))
        }
    }

    /// Stops the routine and removes the space and its page. True when it was there. A
    /// `schedulesUnavailable` refusal means the space is off Today and the delete isn't finished:
    /// call again with the same `operationID`.
    @discardableResult
    func delete(agentID: String, spaceID: String,
                operationID: String = SpacesWire.newOperationID()) async throws(SpacesError) -> Bool {
        let reply = try await call(.delete, [
            "agentId": .string(agentID), "spaceId": .string(spaceID), "operationId": .string(operationID),
        ])
        guard reply["deleted"]?.boolean == true else { throw .other(code: nil) }
        return reply["existed"]?.boolean ?? true
    }
}
