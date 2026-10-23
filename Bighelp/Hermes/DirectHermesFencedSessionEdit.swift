import Foundation

/// Edits and deletes of a saved chat on current Hermes. Hermes refuses an edit that doesn't say which
/// version of the row it saw (`client_upgrade_required`), so each one sends a fresh `request_id` and the
/// row's `expected_revision`, both read from the row's own detail (`runtime_revision`).
///
/// A detail without `runtime_revision` is an older Hermes: the edit goes out exactly as it always did,
/// because older hosts may refuse fields they don't know. Nothing here looks at a version string.
@MainActor
struct DirectHermesFencedSessionEdit {
    typealias Perform = @MainActor (WorkspaceOperation, [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]

    struct Receipt {
        let response: [String: BighelpJSONValue]
        /// The row's revision after this edit: Hermes' `revision` in its reply. Nil when the edit wasn't
        /// checked. A caller editing the same row again passes it as `knownRevision` to skip the read.
        let revision: Int?
    }

    private struct Fence {
        var revision: Int?
        var generation: Int?
        /// Why the row couldn't be read, when it couldn't.
        var readError: (any Error)?
    }

    let perform: Perform

    /// A PATCH of `fields` (title, archived, hidden, pinned, unread). `expected_generation` is left out:
    /// Hermes only needs it for a delete, and the revision already catches a row that changed.
    func update(_ sessionID: String, profile: String, fields: [String: BighelpJSONValue],
                knownRevision: Int? = nil) async throws -> Receipt {
        let target: [String: BighelpJSONValue] = ["session_id": .string(sessionID), "profile": .string(profile)]
        func send(_ fence: Fence) async throws -> Receipt {
            var payload = fields.merging(target) { _, new in new }
            if let revision = fence.revision { Self.addFence(to: &payload, revision: revision, generation: nil) }
            let response = try await perform(.sessionUpdate, payload)
            return Receipt(response: response, revision: fence.revision == nil ? nil : Self.revision(response["revision"]))
        }
        return try await withOneRetry(sessionID, profile: profile, known: knownRevision.map { Fence(revision: $0) }, send)
    }

    /// A DELETE. Hermes requires the row's `runtime_generation` here as well.
    func delete(_ sessionID: String, profile: String) async throws -> [String: BighelpJSONValue] {
        let target: [String: BighelpJSONValue] = ["session_id": .string(sessionID), "profile": .string(profile)]
        func send(_ fence: Fence) async throws -> Receipt {
            var payload = target
            if let revision = fence.revision {
                Self.addFence(to: &payload, revision: revision, generation: fence.generation)
            }
            return Receipt(response: try await perform(.sessionDelete, payload), revision: nil)
        }
        return try await withOneRetry(sessionID, profile: profile, known: nil, send).response
    }

    /// Sends with the row's current fence. A row that changed between the read and the edit
    /// (`revision_conflict`, `stale_generation`) is read again and sent once more under a new
    /// `request_id`; a second refusal is the person's to see. Hermes' upgrade refusals are never retried.
    private func withOneRetry(_ sessionID: String, profile: String, known: Fence?,
                              _ send: (Fence) async throws -> Receipt) async throws -> Receipt {
        let first: Fence
        if let known { first = known } else { first = try await fence(sessionID, profile: profile) }
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
            guard let revision = Self.revision(detail["runtime_revision"]) else { return Fence() }
            return Fence(revision: revision, generation: Self.revision(detail["runtime_generation"]))
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
    private static func revision(_ value: BighelpJSONValue?) -> Int? {
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
