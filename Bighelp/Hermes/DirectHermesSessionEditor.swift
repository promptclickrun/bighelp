import Foundation

/// Hides, archives, titles, pins and deletes saved chats on a Hermes host.
///
/// Current Hermes answers its dashboard's edit routes (`PATCH`/`DELETE /api/sessions/{id}`) with
/// `not_found` for chats the app made over its socket: the dashboard forwards the edit to the
/// gateway, which lets only a chat's own transport control it. The socket itself has native methods
/// that work on those chats, so hiding, archiving and deleting go there first (`session.set_hidden`,
/// `session.archive`, `session.delete`), and a title is set on an open chat (`session.title`).
/// Pinning and marking unread have no socket method and stay on the dashboard route.
///
/// A host whose socket doesn't know a method (JSON-RPC "method not found", reported as
/// `unavailable(.unsupportedOperation)`) falls back to the dashboard route. That route is fenced when
/// the row's detail has an integer `runtime_revision`: a fresh `request_id` and `expected_revision`
/// (and `expected_generation` for a delete). A detail without it is an older Hermes and gets the plain
/// body, never the new fields. Nothing here looks at a version string; the replies decide.
@MainActor
struct DirectHermesSessionEditor {
    typealias Perform = @MainActor (WorkspaceOperation, [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]

    struct Receipt {
        /// Shaped like the dashboard's reply whichever route answered: `ok`, `session_id`, and each
        /// edited key with its resulting value.
        let response: [String: BighelpJSONValue]
    }

    private struct Fence {
        var revision: Int?
        var generation: Int?
        /// Why the row couldn't be read, when it couldn't.
        var readError: (any Error)?
    }

    let perform: Perform

    // MARK: Socket first

    func setHidden(_ sessionID: String, profile: String, hidden: Bool) async throws -> Receipt {
        let payload: [String: BighelpJSONValue] = [
            "session_id": .string(sessionID), "hidden": .boolean(hidden), "profile": .string(profile),
        ]
        if let response = try await nativeFlag(.sessionSetHidden, payload, key: "hidden", value: hidden) {
            return Receipt(response: response)
        }
        return try await update(sessionID, profile: profile, fields: ["hidden": .boolean(hidden)])
    }

    func setArchived(_ sessionID: String, profile: String, archived: Bool) async throws -> Receipt {
        let payload: [String: BighelpJSONValue] = [
            "session_id": .string(sessionID), "archived": .boolean(archived), "profile": .string(profile),
        ]
        if let response = try await nativeFlag(.sessionArchive, payload, key: "archived", value: archived) {
            return Receipt(response: response)
        }
        return try await update(sessionID, profile: profile, fields: ["archived": .boolean(archived)])
    }

    /// Deletes a stored row. Hermes refuses while the chat is open on its gateway ("cannot delete an active
    /// session"); that message reaches the person. A row already gone counts as deleted.
    func delete(_ sessionID: String, profile: String) async throws -> [String: BighelpJSONValue] {
        do {
            let result = try await perform(.nativeSessionDelete, ["session_id": .string(sessionID), "profile": .string(profile)])
            guard let deleted = result["deleted"]?.string, DirectHermesSessionValidation.same(deleted, sessionID) else {
                throw WorkspaceClientError.invalidResponse
            }
            return ["ok": .boolean(true), "session_id": .string(sessionID)]
        } catch WorkspaceClientError.rejected(code: "4007", _) {
            return ["ok": .boolean(true), "session_id": .string(sessionID), "already_absent": .boolean(true)]
        } catch WorkspaceClientError.unavailable(.unsupportedOperation) {
            return try await deleteThroughDashboard(sessionID, profile: profile)
        }
    }

    /// Titles a saved chat that isn't open: opens it the way chats open, titles it, and lets the
    /// connection's close end it. Where the socket has no such methods, the dashboard route does it.
    func setTitle(_ storedID: String, profile: String, title: String) async throws -> Receipt {
        do {
            var resume = DirectHermesReleaseContract.resumeParameters(profile: profile, storedID: storedID)
            resume["close_on_disconnect"] = .boolean(true)
            let opened = try DirectHermesReleaseContract.decodeResumedSession(
                .object(try await perform(.sessionResume, resume)), profile: profile)
            let reply = try await perform(.sessionTitle, ["session_id": .string(opened.runtimeID), "title": .string(title)])
            guard reply["pending"]?.boolean == false, reply["title"]?.string == title else {
                throw WorkspaceClientError.outcomeUnknown
            }
            return Receipt(response: ["ok": .boolean(true), "session_id": .string(opened.storedID), "title": .string(title)])
        } catch WorkspaceClientError.unavailable(.unsupportedOperation) {
            return try await update(storedID, profile: profile, fields: ["title": .string(title)])
        }
    }

    /// nil when the socket doesn't know the method.
    private func nativeFlag(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue],
                            key: String, value: Bool) async throws -> [String: BighelpJSONValue]? {
        let result: [String: BighelpJSONValue]
        do { result = try await perform(operation, payload) } catch WorkspaceClientError.unavailable(.unsupportedOperation) {
            return nil
        }
        guard result[key]?.boolean == value, let sessionKey = result["session_key"]?.string, !sessionKey.isEmpty else {
            throw WorkspaceClientError.invalidResponse
        }
        return ["ok": .boolean(true), "session_id": .string(sessionKey), key: .boolean(value)]
    }

    // MARK: Dashboard route

    /// A PATCH of `fields` (title, archived, hidden, pinned, unread). `expected_generation` is left out:
    /// Hermes only needs it for a delete, and the revision already catches a row that changed.
    func update(_ sessionID: String, profile: String, fields: [String: BighelpJSONValue]) async throws -> Receipt {
        let target: [String: BighelpJSONValue] = ["session_id": .string(sessionID), "profile": .string(profile)]
        func send(_ fence: Fence) async throws -> [String: BighelpJSONValue] {
            var payload = fields.merging(target) { _, new in new }
            if let revision = fence.revision { Self.addFence(to: &payload, revision: revision, generation: nil) }
            return try await perform(.sessionUpdate, payload)
        }
        return Receipt(response: try await withOneRetry(sessionID, profile: profile, send))
    }

    private func deleteThroughDashboard(_ sessionID: String, profile: String) async throws -> [String: BighelpJSONValue] {
        let target: [String: BighelpJSONValue] = ["session_id": .string(sessionID), "profile": .string(profile)]
        func send(_ fence: Fence) async throws -> [String: BighelpJSONValue] {
            var payload = target
            if let revision = fence.revision {
                Self.addFence(to: &payload, revision: revision, generation: fence.generation)
            }
            return try await perform(.sessionDelete, payload)
        }
        return try await withOneRetry(sessionID, profile: profile, send)
    }

    /// Sends with the row's current fence. A row that changed between the read and the edit
    /// (`revision_conflict`, `stale_generation`) is read again and sent once more under a new
    /// `request_id`; a second refusal is the person's to see. Hermes' other refusals are never retried.
    private func withOneRetry(_ sessionID: String, profile: String,
                              _ send: (Fence) async throws -> [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        let first = try await fence(sessionID, profile: profile)
        do {
            return try await send(first)
        } catch let error where first.revision != nil && Self.isChangedRow(error) {
            let again = try await fence(sessionID, profile: profile)
            guard again.revision != nil else { throw error }
            return try await send(again)
        } catch let error where first.revision == nil && first.readError != nil && Self.isUpgradeRefusal(error) {
            // The row never read, so the plain edit was bound to be refused: the read is the real cause.
            throw first.readError ?? error
        }
    }

    /// The row's revision and generation, or neither when Hermes doesn't send them or the row can't be
    /// read. A failed read isn't fatal here: the plain edit then runs and Hermes answers it. A cancelled
    /// task or a changed host is, and ends the edit.
    private func fence(_ sessionID: String, profile: String) async throws -> Fence {
        do {
            let detail = try await perform(.sessionDetail, ["session_id": .string(sessionID), "profile": .string(profile)])
            guard let revision = Self.whole(detail["runtime_revision"]) else { return Fence() }
            return Fence(revision: revision, generation: Self.whole(detail["runtime_generation"]))
        } catch {
            if Self.isFatalRead(error) { throw error }
            return Fence(readError: error)
        }
    }

    private static func addFence(to payload: inout [String: BighelpJSONValue], revision: Int, generation: Int?) {
        payload["request_id"] = .string(UUID().uuidString.lowercased())
        payload["expected_revision"] = .integer(revision)
        if let generation { payload["expected_generation"] = .integer(generation) }
    }

    /// A non-negative whole number, else nil: a revision Hermes sent as text or a fraction isn't one.
    private static func whole(_ value: BighelpJSONValue?) -> Int? {
        guard let number = value?.integer, number >= 0 else { return nil }
        return number
    }

    private static func isChangedRow(_ error: any Error) -> Bool {
        guard case WorkspaceClientError.rejected(let code, _) = error else { return false }
        return code == "revision_conflict" || code == "stale_generation"
    }

    private static func isUpgradeRefusal(_ error: any Error) -> Bool {
        guard case WorkspaceClientError.rejected(let code, _) = error else { return false }
        return code == "client_upgrade_required" || code == "mutation_identity_required"
    }

    private static func isFatalRead(_ error: any Error) -> Bool {
        error is CancellationError || error as? WorkspaceClientError == .ownerChanged
    }
}
