import Foundation
import Testing
@testable import Bighelp

/// A Hermes host's saved-chat edits, as `hermes_cli/web_server_sessions.py` and the gateway's socket answer them.
///
/// `.current` is Hermes today: the dashboard's `PATCH`/`DELETE /api/sessions/{id}` refuses an edit without
/// `request_id` and `expected_revision` (409 `client_upgrade_required`), checks the revision against the
/// row's `runtime_revision`, wants `expected_generation` on a delete, and then answers 404 `not_found` for
/// a chat the app made over the socket (the gateway lets only a chat's own transport control it). The
/// socket takes `session.set_hidden`, `session.archive` and `session.delete` on those chats, and
/// `session.title` only on a chat that is open; it has nothing for pinned or unread.
///
/// `.fencedDashboard` has the edit check and a dashboard that works for every row, but no socket edits.
/// `.older` has neither: plain PATCH and DELETE, no revision in a row's detail, and its socket answers
/// "method not found" to the edit methods. `.fencedHidingRevision` checks every edit but shows no
/// revision, so the app can't fence its edits.
@MainActor
final class FakeHermesSessionHost {
    enum Edition { case current, fencedDashboard, older, fencedHidingRevision }

    struct Row {
        var title = "Session"
        var hidden = false
        var archived = false
        var pinned = false
        var unread = false
        var revision = 0
        var generation = 0
        /// Made over the socket, like every chat the app starts.
        var madeOverSocket = true
    }

    struct Request {
        let operation: WorkspaceOperation
        let payload: [String: BighelpJSONValue]
    }

    static let upgradeRequired = "client_upgrade_required: this app is out of sync (different versions) "
        + "with the Hermes backend; update the app to edit sessions"

    var rows: [String: Row]
    let edition: Edition
    private(set) var requests: [Request] = []
    /// The chat open on the gateway, by runtime ID.
    private(set) var live: [String: String] = [:]
    private var receipts: [String: (signature: String, reply: [String: BighelpJSONValue])] = [:]
    /// Runs just before a dashboard edit is checked: someone else editing the row in between.
    var beforeCheck: (@MainActor (FakeHermesSessionHost) -> Void)?

    init(_ edition: Edition, rows: [String: Row]) {
        self.edition = edition
        self.rows = rows
    }

    func requests(_ operation: WorkspaceOperation) -> [Request] { requests.filter { $0.operation == operation } }
    var hasSocketEdits: Bool { edition == .current }

    /// The app's socket closes; Hermes lets go of the chats it had open.
    func closeChats() { live = [:] }

    /// What the app's workspace client does with an operation: its own route checks, then Hermes' answer,
    /// translated the way the client translates it.
    func perform(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        _ = try DirectHermesWorkspaceClient.route(operation, payload: payload)
        do { return try handle(operation, payload) } catch {
            throw DirectHermesWorkspaceClient.workspaceError(error, for: operation)
        }
    }

    var editor: DirectHermesSessionEditor {
        DirectHermesSessionEditor(perform: { [self] operation, payload in try await perform(operation, payload) })
    }

    func handle(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue]) throws -> [String: BighelpJSONValue] {
        requests.append(.init(operation: operation, payload: payload))
        guard let id = payload["session_id"]?.string else { throw WorkspaceClientError.invalidRequest }
        switch operation {
        case .sessionDetail:
            // A missing row is a 404, which the app's HTTP layer reports as a failed request.
            guard let row = rows[id] else { throw DirectHermesError.unsupportedAuthentication }
            var detail: [String: BighelpJSONValue] = [
                "id": .string(id), "profile": payload["profile"] ?? .null, "title": .string(row.title),
                "hidden": .boolean(row.hidden), "archived": .boolean(row.archived), "pinned": .boolean(row.pinned),
            ]
            if edition == .current || edition == .fencedDashboard {
                detail["runtime_revision"] = .integer(row.revision)
                detail["runtime_generation"] = .integer(row.generation)
            }
            return detail
        case .sessionUpdate, .sessionDelete:
            return try mutateThroughDashboard(operation, id: id, payload: payload)
        case .sessionSetHidden, .sessionArchive:
            guard hasSocketEdits else { throw DirectHermesError.rpcRejected(code: -32601) }
            guard let key = stored(id) else {
                throw DirectHermesError.rpcRejected(code: 4001, message: HermesRefusalMessage("session not found"))
            }
            if operation == .sessionSetHidden, let hidden = payload["hidden"]?.boolean {
                rows[key]?.hidden = hidden
                return ["hidden": .boolean(hidden), "session_key": .string(key)]
            }
            let archived = payload["archived"]?.boolean ?? true
            rows[key]?.archived = archived
            return ["archived": .boolean(archived), "session_key": .string(key)]
        case .nativeSessionDelete:
            guard hasSocketEdits else { throw DirectHermesError.rpcRejected(code: -32601) }
            guard rows[id] != nil else {
                throw DirectHermesError.rpcRejected(code: 4007, message: HermesRefusalMessage("session not found"))
            }
            guard !live.values.contains(id) else {
                throw DirectHermesError.rpcRejected(code: 4023, message: HermesRefusalMessage("cannot delete an active session"))
            }
            rows[id] = nil
            return ["deleted": .string(id)]
        case .sessionResume:
            guard rows[id] != nil else {
                throw DirectHermesError.rpcRejected(code: 4007, message: HermesRefusalMessage("session not found"))
            }
            live["runtime"] = id
            return DirectHermesSessionCatalogClientTests.attached(stored: id, profile: payload["profile"]?.string ?? "alpha")
        case .sessionTitle:
            guard let key = live[id] else {
                throw DirectHermesError.rpcRejected(code: 4001, message: HermesRefusalMessage("session not found"))
            }
            // As Hermes' set_session_title answers for a hidden Bot Chat.
            if rows[key]?.hidden == true, rows[key]?.title == "Bot Chat" {
                throw DirectHermesError.rpcRejected(code: 4022, message: HermesRefusalMessage(
                    "This is the bot's canonical Bot Chat"))
            }
            let title = payload["title"]?.string ?? ""
            rows[key]?.title = title
            return ["pending": .boolean(false), "title": .string(title)]
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }

    /// The stored ID a live runtime ID or a stored ID names.
    private func stored(_ id: String) -> String? {
        if let key = live[id] { return key }
        return rows[id] == nil ? nil : id
    }

    private func refusal(_ status: Int, _ detail: String) -> DirectHermesError {
        // What `DirectHermesHTTP.sessionEditRefusal` makes of a 403, 404 or 409 with this `detail`.
        .rpcRejected(code: status, message: HermesRefusalMessage(detail))
    }

    private func mutateThroughDashboard(_ operation: WorkspaceOperation, id: String,
                                        payload: [String: BighelpJSONValue]) throws -> [String: BighelpJSONValue] {
        let fenceKeys = ["request_id", "expected_revision", "expected_generation"]
        if edition == .older {
            // Unknown fields are a 422 there.
            guard fenceKeys.allSatisfy({ payload[$0] == nil }) else { throw DirectHermesError.invalidResponse }
            return try apply(operation, id: id, payload: payload, fenced: false)
        }
        let requestID = payload["request_id"], revision = payload["expected_revision"]
        let generation = payload["expected_generation"]
        if fenceKeys.allSatisfy({ payload[$0] == nil }) { throw refusal(409, Self.upgradeRequired) }
        guard requestID != nil, revision != nil else { throw refusal(409, "mutation_identity_required") }
        guard let requestText = requestID?.string, let expected = revision?.integer, expected >= 0,
              generation == nil || (generation?.integer ?? -1) >= 0 else { throw DirectHermesError.invalidResponse }
        let signature = payload.keys.filter { $0 != "request_id" }.sorted().map { "\($0)=\(payload[$0]!)" }
            .joined(separator: "&")
        if let seen = receipts[requestText] {
            guard seen.signature == signature else { throw refusal(409, "request_id_reused") }
            return seen.reply
        }
        beforeCheck?(self)
        guard let row = rows[id] else {
            if operation == .sessionDelete { return ["ok": .boolean(true), "already_absent": .boolean(true)] }
            throw refusal(404, "not_found")
        }
        // The dashboard forwards the edit to the gateway, which won't let it touch a chat made over the socket.
        if edition == .current, row.madeOverSocket { throw refusal(404, "not_found") }
        if operation == .sessionDelete, generation == nil { throw DirectHermesError.invalidResponse }
        guard row.revision == expected else { throw refusal(409, "revision_conflict") }
        if let generation, generation.integer != row.generation { throw refusal(409, "stale_generation") }
        let reply = try apply(operation, id: id, payload: payload, fenced: true)
        receipts[requestText] = (signature, reply)
        return reply
    }

    private func apply(_ operation: WorkspaceOperation, id: String, payload: [String: BighelpJSONValue],
                       fenced: Bool) throws -> [String: BighelpJSONValue] {
        guard var row = rows[id] else {
            if operation == .sessionDelete { return ["ok": .boolean(true), "already_absent": .boolean(true)] }
            throw DirectHermesError.unsupportedAuthentication
        }
        var reply: [String: BighelpJSONValue] = ["ok": .boolean(true), "session_id": .string(id)]
        if operation == .sessionDelete {
            rows[id] = nil
            return reply
        }
        if let title = payload["title"]?.string {
            if row.hidden, row.title == "Bot Chat", payload["hidden"] != .boolean(false) {
                throw DirectHermesError.rpcRejected(code: 4022, message: HermesRefusalMessage(
                    "This is the bot's canonical Bot Chat"))
            }
            row.title = title
            reply["title"] = .string(title)
        }
        for (key, keyPath) in [("hidden", \Row.hidden), ("archived", \Row.archived),
                               ("pinned", \Row.pinned), ("unread", \Row.unread)] {
            if let value = payload[key]?.boolean {
                row[keyPath: keyPath] = value
                reply[key] = .boolean(value)
            }
        }
        row.revision += 1
        rows[id] = row
        if fenced {
            reply["revision"] = .integer(row.revision)
            reply["execution_generation"] = .integer(row.generation)
            reply["operation"] = .string("sidebar")
        }
        return reply
    }
}

@MainActor
struct SessionEditorTests {
    typealias Catalog = DirectHermesSessionCatalogClientTests
    typealias Edition = FakeHermesSessionHost.Edition

    private func chat(_ id: String, _ title: String) -> FleetChat {
        FleetChat(hostID: UUID(), profileID: "rio", storedSessionID: id, title: title, preview: "",
                  updatedAt: Date(), isActive: false)
    }

    // MARK: The fake itself

    @Test func theFakeAnswersLikeCurrentHermes() throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init()])
        let plain: [String: BighelpJSONValue] = ["session_id": .string("a"), "profile": .string("alpha"),
                                                  "pinned": .boolean(true)]
        // An edit without the check: 409 and nothing changes.
        #expect(throws: DirectHermesError.rpcRejected(code: 409)) { try host.handle(.sessionUpdate, plain) }
        // With the check, a chat made over the socket is still not the dashboard's to edit.
        let fenced = plain.merging(["request_id": .string(UUID().uuidString.lowercased()),
                                    "expected_revision": .integer(0)]) { $1 }
        #expect(throws: DirectHermesError.rpcRejected(code: 404)) { try host.handle(.sessionUpdate, fenced) }
        #expect(host.rows["a"]?.pinned == false)
    }

    // MARK: Hide, archive and delete go over the socket

    @Test func hidingAndShowingUseTheSocketAlone() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init()])
        let hidden = try await host.editor.setHidden("a", profile: "alpha", hidden: true)
        #expect(hidden.response["ok"] == .boolean(true) && hidden.response["hidden"] == .boolean(true))
        #expect(host.rows["a"]?.hidden == true)
        _ = try await host.editor.setHidden("a", profile: "alpha", hidden: false)
        #expect(host.rows["a"]?.hidden == false)

        #expect(host.requests.map(\.operation) == [.sessionSetHidden, .sessionSetHidden])
        #expect(host.requests[0].payload == ["session_id": .string("a"), "hidden": .boolean(true),
                                             "profile": .string("alpha")])
    }

    @Test func archivingAndRestoringUseTheSocketAlone() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init()])
        _ = try await host.editor.setArchived("a", profile: "alpha", archived: true)
        #expect(host.rows["a"]?.archived == true)
        _ = try await host.editor.setArchived("a", profile: "alpha", archived: false)
        #expect(host.rows["a"]?.archived == false)
        #expect(host.requests.map(\.operation) == [.sessionArchive, .sessionArchive])
        #expect(host.requests[0].payload == ["session_id": .string("a"), "archived": .boolean(true),
                                             "profile": .string("alpha")])
    }

    @Test func deletingUsesTheSocket() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init()])
        let reply = try await host.editor.delete("a", profile: "alpha")
        #expect(reply["ok"] == .boolean(true))
        #expect(host.rows["a"] == nil)
        #expect(host.requests.map(\.operation) == [.nativeSessionDelete])
        #expect(host.requests[0].payload == ["session_id": .string("a"), "profile": .string("alpha")])
    }

    @Test func aChatThatIsOpenOnTheGatewayCannotBeDeletedAndHermesSaysWhy() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init()])
        _ = try await host.perform(.sessionResume, ["session_id": .string("a"), "profile": .string("alpha")])
        do {
            _ = try await host.editor.delete("a", profile: "alpha")
            Issue.record("Expected Hermes' refusal")
        } catch {
            #expect(HermesRefusalMessage.sentence(in: error) == "Hermes said: cannot delete an active session")
        }
        #expect(host.rows["a"] != nil)
    }

    @Test func aChatThatIsAlreadyGoneCountsAsDeleted() async throws {
        let host = FakeHermesSessionHost(.current, rows: [:])
        let reply = try await host.editor.delete("gone", profile: "alpha")
        #expect(reply["already_absent"] == .boolean(true))
    }

    // MARK: Titles

    @Test func aSavedChatIsOpenedThenTitledOnTheSocket() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init(title: "Plans")])
        let receipt = try await host.editor.setTitle("a", profile: "alpha", title: "Trip")
        #expect(receipt.response["title"] == .string("Trip"))
        #expect(host.rows["a"]?.title == "Trip")
        #expect(host.requests.map(\.operation) == [.sessionResume, .sessionTitle])
        let resume = host.requests[0].payload
        #expect(resume["source"] == .string("bighelp") && resume["close_on_disconnect"] == .boolean(true))
        #expect(host.requests[1].payload["session_id"] == .string("runtime"), "The title goes to the live ID")
    }

    @Test func aHostWithoutASocketTitleEditsTheSavedRow() async throws {
        let host = FakeHermesSessionHost(.fencedDashboard, rows: ["a": .init(title: "Plans", revision: 2)])
        let editor = DirectHermesSessionEditor(perform: { operation, payload in
            if operation == .sessionResume || operation == .sessionTitle {
                throw WorkspaceClientError.unavailable(.unsupportedOperation)
            }
            return try await host.perform(operation, payload)
        })
        _ = try await editor.setTitle("a", profile: "alpha", title: "Trip")
        #expect(host.rows["a"]?.title == "Trip")
        #expect(host.requests(.sessionUpdate).first?.payload["expected_revision"] == .integer(2))
    }

    // MARK: Pin and unread stay on the dashboard

    @Test func pinningAChatTheDashboardWontTouchSaysWhatHermesSaid() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init(revision: 3)])
        do {
            _ = try await host.editor.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
            Issue.record("Expected Hermes' refusal")
        } catch {
            #expect(error as? WorkspaceClientError == .rejected(code: "not_found"))
            #expect(HermesRefusalMessage.sentence(in: error) == "Hermes said: not_found")
        }
        #expect(host.rows["a"]?.pinned == false)
        let sent = try #require(host.requests(.sessionUpdate).first?.payload)
        #expect(sent["expected_revision"] == .integer(3) && sent["request_id"] != nil)
        #expect(host.requests(.sessionUpdate).count == 1, "A refusal isn't retried")
    }

    @Test func eachDashboardEditSendsAFreshRequestIDAndTheRowsRevision() async throws {
        let host = FakeHermesSessionHost(.fencedDashboard, rows: ["a": .init(revision: 4, generation: 2)])
        _ = try await host.editor.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
        _ = try await host.editor.update("a", profile: "alpha", fields: ["unread": .boolean(true)])

        let sent = host.requests(.sessionUpdate).map(\.payload)
        #expect(sent.map { $0["expected_revision"] } == [.integer(4), .integer(5)])
        let ids = sent.compactMap { $0["request_id"]?.string }
        #expect(Set(ids).count == 2 && ids.allSatisfy { UUID(uuidString: $0) != nil && $0 == $0.lowercased() })
        #expect(sent.allSatisfy { $0["expected_generation"] == nil }, "A PATCH needs no generation")
        #expect(host.rows["a"]?.pinned == true && host.rows["a"]?.unread == true)
    }

    @Test func aRowThatChangedBeforeTheEditIsReadAgainAndSentOnceMore() async throws {
        let host = FakeHermesSessionHost(.fencedDashboard, rows: ["a": .init(revision: 1)])
        var interruptions = 0
        host.beforeCheck = { host in
            guard interruptions == 0 else { return }
            interruptions += 1
            host.rows["a"]?.revision += 1
        }
        _ = try await host.editor.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
        let sent = host.requests(.sessionUpdate).map(\.payload)
        #expect(sent.map { $0["expected_revision"] } == [.integer(1), .integer(2)])
        #expect(Set(sent.compactMap { $0["request_id"]?.string }).count == 2, "A new request ID for the new try")
        #expect(host.rows["a"]?.pinned == true)
    }

    @Test func aRowThatKeepsChangingIsTriedTwiceNotForever() async throws {
        let host = FakeHermesSessionHost(.fencedDashboard, rows: ["a": .init()])
        host.beforeCheck = { $0.rows["a"]?.revision += 1 }
        await #expect(throws: WorkspaceClientError.rejected(code: "revision_conflict")) {
            try await host.editor.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
        }
        #expect(host.requests(.sessionUpdate).count == 2)
    }

    @Test func aDashboardDeleteSendsTheRowsGenerationAndRetriesOnce() async throws {
        let host = FakeHermesSessionHost(.fencedDashboard, rows: ["a": .init(revision: 1, generation: 1)])
        var interruptions = 0
        host.beforeCheck = { host in
            guard interruptions == 0 else { return }
            interruptions += 1
            host.rows["a"]?.generation += 1
            host.rows["a"]?.revision += 1
        }
        // The socket has no delete here, so the dashboard route runs.
        _ = try await host.editor.delete("a", profile: "alpha")
        let sent = host.requests(.sessionDelete).map(\.payload)
        #expect(sent.count == 2)
        #expect(sent.last?["expected_generation"] == .integer(2) && sent.last?["expected_revision"] == .integer(2))
        #expect(host.rows["a"] == nil)
    }

    // MARK: Older Hermes

    @Test func olderHermesFallsBackToTheOldBodyAfterOneSocketTry() async throws {
        let host = FakeHermesSessionHost(.older, rows: ["a": .init(), "b": .init(), "c": .init()])
        _ = try await host.editor.setHidden("a", profile: "alpha", hidden: true)
        _ = try await host.editor.setArchived("b", profile: "alpha", archived: true)
        _ = try await host.editor.update("c", profile: "alpha", fields: ["pinned": .boolean(true)])
        _ = try await host.editor.delete("c", profile: "alpha")

        #expect(host.requests(.sessionUpdate).map(\.payload) == [
            ["session_id": .string("a"), "profile": .string("alpha"), "hidden": .boolean(true)],
            ["session_id": .string("b"), "profile": .string("alpha"), "archived": .boolean(true)],
            ["session_id": .string("c"), "profile": .string("alpha"), "pinned": .boolean(true)],
        ])
        #expect(host.requests(.sessionDelete).map(\.payload) == [["session_id": .string("c"), "profile": .string("alpha")]])
        #expect(host.rows["a"]?.hidden == true && host.rows["b"]?.archived == true && host.rows["c"] == nil)
    }

    @Test func olderHermesTitlesOnTheSocketToo() async throws {
        let host = FakeHermesSessionHost(.older, rows: ["a": .init(title: "Plans")])
        _ = try await host.editor.setTitle("a", profile: "alpha", title: "Trip")
        #expect(host.rows["a"]?.title == "Trip")
        #expect(host.requests(.sessionUpdate).isEmpty)
    }

    @Test func aRowThatCannotBeReadStillGetsThePlainEdit() async throws {
        let host = FakeHermesSessionHost(.older, rows: [:])
        let reply = try await host.editor.delete("gone", profile: "alpha")
        #expect(reply["already_absent"] == .boolean(true))
    }

    // MARK: Refusals

    @Test func anUpgradeRefusalIsShownAsHermesSaidItAndNeverRetried() async throws {
        let host = FakeHermesSessionHost(.fencedHidingRevision, rows: ["a": .init()])
        do {
            _ = try await host.editor.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
            Issue.record("Expected Hermes' refusal")
        } catch {
            #expect(error as? WorkspaceClientError == .rejected(code: "client_upgrade_required"))
            #expect(HermesRefusalMessage.sentence(in: error)?.contains("update the app to edit sessions") == true)
        }
        #expect(host.requests(.sessionUpdate).count == 1)
    }

    @Test func aHostThatCannotBeReachedForTheReadSaysSoNotUpgrade() async throws {
        var attempts = 0
        let editor = DirectHermesSessionEditor(perform: { operation, _ in
            attempts += 1
            if operation == .sessionDetail { throw WorkspaceClientError.transportUnavailable }
            throw WorkspaceClientError.rejected(code: "client_upgrade_required")
        })
        await #expect(throws: WorkspaceClientError.transportUnavailable) {
            try await editor.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
        }
        #expect(attempts == 2)
    }

    @Test func aChangedHostEndsTheEditAtTheRead() async throws {
        let editor = DirectHermesSessionEditor(perform: { _, _ in throw WorkspaceClientError.ownerChanged })
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await editor.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
        }
    }

    @Test func aMalformedSocketAnswerIsNotTakenForSuccess() async throws {
        let editor = DirectHermesSessionEditor(perform: { _, _ in ["hidden": .boolean(false), "session_key": .string("a")] })
        await #expect(throws: WorkspaceClientError.invalidResponse) {
            try await editor.setHidden("a", profile: "alpha", hidden: true)
        }
    }

    // MARK: Request builders and Hermes' refusals

    @Test func theSocketEditsListExactlyTheFieldsTheAppSends() throws {
        let hide = try DirectHermesWorkspaceClient.route(.sessionSetHidden, payload: [
            "session_id": .string("a"), "hidden": .boolean(true), "profile": .string("alpha")])
        #expect(hide == .rpc("session.set_hidden", ["session_id": .string("a"), "hidden": .boolean(true),
                                                    "profile": .string("alpha")]))
        let archive = try DirectHermesWorkspaceClient.route(.sessionArchive, payload: [
            "session_id": .string("a"), "archived": .boolean(false), "profile": .string("alpha")])
        #expect(archive == .rpc("session.archive", ["session_id": .string("a"), "archived": .boolean(false),
                                                    "profile": .string("alpha")]))
        let delete = try DirectHermesWorkspaceClient.route(.nativeSessionDelete, payload: [
            "session_id": .string("a"), "profile": .string("alpha")])
        #expect(delete == .rpc("session.delete", ["session_id": .string("a"), "profile": .string("alpha")]))

        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.sessionSetHidden, payload: [
                "session_id": .string("a"), "hidden": .string("yes")])
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.sessionSetHidden, payload: ["session_id": .string("a")])
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.sessionArchive, payload: [
                "session_id": .string("a"), "archived": .boolean(true), "title": .string("x")])
        }
        #expect(throws: WorkspaceClientError.invalidRequest) {
            try DirectHermesWorkspaceClient.route(.nativeSessionDelete, payload: [
                "session_id": .string("a"), "request_id": .string("x")])
        }
    }

    @Test func theDashboardBuildersTakeTheEditCheckAndRefuseBadValues() throws {
        let id = UUID().uuidString.lowercased()
        let patch = try DirectHermesWorkspaceClient.route(.sessionUpdate, payload: [
            "session_id": .string("a"), "profile": .string("alpha"), "pinned": .boolean(true),
            "request_id": .string(id), "expected_revision": .integer(3), "expected_generation": .integer(0),
        ])
        guard case .http(let request) = patch else { Issue.record("Expected HTTP"); return }
        #expect(request.method == .patch && request.path == "/api/sessions/a")
        #expect(request.body?["request_id"] == .string(id))
        #expect(request.body?["expected_revision"] == .integer(3))
        #expect(request.body?["expected_generation"] == .integer(0))

        let delete = try DirectHermesWorkspaceClient.route(.sessionDelete, payload: [
            "session_id": .string("a"), "profile": .string("alpha"),
            "request_id": .string(id), "expected_revision": .integer(3), "expected_generation": .integer(0),
        ])
        guard case .http(let deletion) = delete else { Issue.record("Expected HTTP"); return }
        #expect(deletion.method == .delete)
        #expect(Dictionary(uniqueKeysWithValues: deletion.query.map { ($0.name, $0.value) })
                == ["profile": "alpha", "request_id": id, "expected_revision": "3", "expected_generation": "0"])

        let base: [String: BighelpJSONValue] = ["session_id": .string("a"), "profile": .string("alpha"),
                                                "pinned": .boolean(true)]
        let bad: [[String: BighelpJSONValue]] = [
            ["request_id": .string(id.uppercased()), "expected_revision": .integer(1)],
            ["request_id": .string("not-a-uuid"), "expected_revision": .integer(1)],
            ["request_id": .string(id), "expected_revision": .integer(-1)],
            ["request_id": .string(id), "expected_revision": .string("1")],
            ["request_id": .string(id), "expected_revision": .number(1.5)],
            ["request_id": .string(id)],
            ["expected_revision": .integer(1)],
            ["request_id": .string(id), "expected_revision": .integer(1), "expected_generation": .integer(-2)],
            ["expected_generation": .integer(1)],
        ]
        for extra in bad {
            #expect(throws: WorkspaceClientError.invalidRequest, "\(extra)") {
                try DirectHermesWorkspaceClient.route(.sessionUpdate, payload: base.merging(extra) { $1 })
            }
        }
    }

    @Test func hermesRefusalsOfADashboardEditKeepTheirReasonAndWords() throws {
        func response(_ status: Int, _ body: String) -> DirectHermesHTTP.Response {
            let url = URL(string: "https://host.example/api/sessions/a")!
            return .init(http: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!,
                         body: Data(body.utf8))
        }
        let patch = DirectHermesHTTPRequest(path: "/api/sessions/a", method: .patch)
        let upgrade = try #require(DirectHermesHTTP.sessionEditRefusal(
            patch, response(409, #"{"detail":"\#(FakeHermesSessionHost.upgradeRequired)"}"#)))
        let translated = DirectHermesWorkspaceClient.workspaceError(upgrade, for: .sessionUpdate)
        #expect(translated as? WorkspaceClientError == .rejected(code: "client_upgrade_required"))
        #expect(HermesRefusalMessage.sentence(in: translated)?.contains("update the app to edit sessions") == true)

        for (status, reason) in [(404, "not_found"), (403, "permission_denied"), (409, "revision_conflict")] {
            let refusal = try #require(DirectHermesHTTP.sessionEditRefusal(
                DirectHermesHTTPRequest(path: "/api/sessions/a", method: .delete),
                response(status, #"{"detail":"\#(reason)"}"#)))
            #expect(DirectHermesWorkspaceClient.workspaceError(refusal, for: .sessionDelete) as? WorkspaceClientError
                    == .rejected(code: reason))
        }

        // Only a session edit's refusal that names a reason; a gate's or a proxy's answer is as before.
        #expect(DirectHermesHTTP.sessionEditRefusal(patch, response(400, #"{"detail":"invalid_params"}"#)) == nil)
        #expect(DirectHermesHTTP.sessionEditRefusal(patch, response(409, #"{"detail":{"errors":[]}}"#)) == nil)
        #expect(DirectHermesHTTP.sessionEditRefusal(patch, response(403, #"{"detail":"Access denied for this tunnel."}"#)) == nil)
        #expect(DirectHermesHTTP.sessionEditRefusal(patch, response(404, "<html>Not found</html>")) == nil)
        #expect(DirectHermesHTTP.sessionEditRefusal(
            DirectHermesHTTPRequest(path: "/api/sessions/a", method: .get), response(404, #"{"detail":"not_found"}"#)) == nil)
        #expect(DirectHermesHTTP.sessionEditRefusal(
            DirectHermesHTTPRequest(path: "/api/cron/jobs/a", method: .patch), response(409, #"{"detail":"x"}"#)) == nil)
    }

    // MARK: The chat list's actions

    private func hostRows(_ host: FakeHermesSessionHost) -> [String: BighelpJSONValue] {
        Catalog.ownershipPage(host.rows.keys.sorted().map { id in
            var row = Catalog.session(id: id).object ?? [:]
            let state = host.rows[id] ?? .init()
            row["title"] = .string(state.title)
            row["hidden"] = .boolean(state.hidden)
            row["pinned"] = .boolean(state.pinned)
            return .object(row)
        })
    }

    private func workspace(_ host: FakeHermesSessionHost, canonical: String? = nil,
                           resolved: String? = nil) throws -> SessionWorkspaceStub {
        let workspace = try SessionWorkspaceStub()
        // The fake answers "method not found" itself where the host has no such methods.
        workspace.hasSocketEdits = true
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Catalog.profiles(canonical: canonical, resolved: resolved)
            case .sessionsList: return self.hostRows(host)
            case .sessionActivate:
                // The chat opened last, the way the gateway answers an ID-only activate.
                return Catalog.attached(stored: host.live["runtime"] ?? resolved ?? canonical ?? "a")
            case .sessionResume, .sessionTitle, .sessionUpdate, .sessionDetail, .sessionDelete,
                 .sessionSetHidden, .sessionArchive, .nativeSessionDelete:
                return try host.handle(operation, payload)
            default:
                Issue.record("Unexpected \(operation)")
                throw WorkspaceClientError.invalidRequest
            }
        }
        return workspace
    }

    @Test(arguments: [Edition.current, .older])
    func renameHideArchiveAndDeleteWork(edition: Edition) async throws {
        let host = FakeHermesSessionHost(edition, rows: ["a": .init(revision: 4, generation: 1)])
        let client = Catalog.client(try workspace(host))
        let record = try #require(try await client.list().first)

        try await client.rename(record, title: "Trip plans")
        #expect(host.rows["a"]?.title == "Trip plans")
        try await client.setFlags(record, flags: .init(hidden: true))
        #expect(host.rows["a"]?.hidden == true)
        try await client.archive(record)
        #expect(host.rows["a"]?.archived == true)
        #expect(host.requests(.sessionUpdate).isEmpty == (edition == .current), "Older Hermes uses the dashboard")

        host.closeChats()
        let fresh = Catalog.client(try workspace(host))
        let again = try #require(try await fresh.list().first)
        _ = try await fresh.deleteNativeRow(again)
        #expect(host.rows["a"] == nil)
        #expect(host.requests(.nativeSessionDelete).count == 1, "The socket is tried once")
        #expect(host.requests(.sessionDelete).isEmpty == (edition == .current))
    }

    @Test func renamingAChatNotOpenOpensItThenTitlesItOverTheSocket() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init(title: "Plans")])
        let client = Catalog.client(try workspace(host))
        let record = try #require(try await client.list().first)
        try await client.rename(record, title: "Trip")

        #expect(host.rows["a"]?.title == "Trip")
        let operations = host.requests.map(\.operation)
        let resumed = try #require(operations.firstIndex(of: .sessionResume))
        let titled = try #require(operations.firstIndex(of: .sessionTitle))
        #expect(resumed < titled, "Opened first")
        #expect(host.requests(.sessionTitle).first?.payload["session_id"] == .string("runtime"))
        #expect(!operations.contains(.sessionUpdate), "The dashboard route isn't used")
    }

    @Test func pinAndUnreadRefusedByHermesAreShownNotPretended() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init()])
        let client = Catalog.client(try workspace(host))
        let record = try #require(try await client.list().first)
        let attempts: [() async throws -> Void] = [
            { try await client.setPinned(record, pinned: true) },
            { try await client.setFlags(record, flags: .init(unread: true)) },
        ]
        for attempt in attempts {
            do {
                try await attempt()
                Issue.record("Expected Hermes' refusal")
            } catch {
                #expect(HermesRefusalMessage.sentence(in: error) == "Hermes said: not_found")
            }
        }
        #expect(host.rows["a"]?.pinned == false && host.rows["a"]?.unread == false)
    }

    @Test func pinAndUnreadWorkWhereTheDashboardTakesThem() async throws {
        let host = FakeHermesSessionHost(.fencedDashboard, rows: ["a": .init(revision: 2)])
        let client = Catalog.client(try workspace(host))
        let record = try #require(try await client.list().first)
        try await client.setPinned(record, pinned: true)
        try await client.setFlags(record, flags: .init(unread: true))
        #expect(host.rows["a"]?.pinned == true && host.rows["a"]?.unread == true)
        #expect(host.requests(.sessionUpdate).map { $0.payload["expected_revision"] } == [.integer(2), .integer(3)])
    }

    @Test func restoringAnArchivedChatUsesTheSocket() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init(archived: true)])
        let client = Catalog.client(try workspace(host))
        try await client.restoreArchivedChat(SessionArchivedChat(
            profileID: "alpha", storedID: "a", title: "Old", source: nil, preview: nil, lastActive: nil))
        #expect(host.rows["a"]?.archived == false)
        #expect(host.requests.map(\.operation) == [.sessionArchive])
    }

    @Test func deletingAChatThatIsOpenShowsHermesWords() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["a": .init()])
        let client = Catalog.client(try workspace(host))
        let record = try #require(try await client.list().first)
        _ = try await client.resolveSession(record)
        do {
            _ = try await client.deleteNativeRow(record)
            Issue.record("Expected Hermes' refusal")
        } catch {
            #expect(HermesRefusalMessage.sentence(in: error) == "Hermes said: cannot delete an active session")
        }
        #expect(host.rows["a"] != nil)
    }

    // MARK: New Bot Chat

    @Test(arguments: [Edition.current, .older])
    func newBotChatRetiresALiveBotChat(edition: Edition) async throws {
        let host = FakeHermesSessionHost(edition, rows: [
            "canonical-root": .init(title: "Bot Chat", hidden: true, revision: 3),
            "tip": .init(title: "Bot Chat", hidden: true, revision: 7),
        ])
        let sessions = Catalog.client(try workspace(host, canonical: "canonical-root", resolved: "tip"))
        guard case .resolved(let botChat) = try await sessions.resolveCanonicalChat(profileID: "alpha") else {
            Issue.record("Expected the Bot Chat")
            return
        }
        let retired = try SessionTitleRules.validated(SessionRecord.retiredBotChatTitle(at: .now))
        try await sessions.rename(botChat.record, title: retired)

        #expect(host.rows["canonical-root"]?.hidden == false && host.rows["tip"]?.hidden == false)
        #expect(host.rows["tip"]?.title == retired)
        if edition == .current {
            // Unhidden and titled over the socket; the dashboard route is never needed.
            #expect(host.requests(.sessionSetHidden).compactMap { $0.payload["session_id"]?.string }
                    .sorted() == ["canonical-root", "tip"])
            #expect(host.requests(.sessionUpdate).isEmpty)
        } else {
            #expect(host.requests(.sessionUpdate).allSatisfy { $0.payload["request_id"] == nil })
        }
    }

    @Test(arguments: [Edition.current, .older])
    func newBotChatOpensABotChatTheAppNoLongerKnowsBeforeTitlingIt(edition: Edition) async throws {
        let host = FakeHermesSessionHost(edition, rows: ["bot-live": .init(title: "Bot Chat", hidden: true, revision: 5)])
        let stub = try workspace(host, canonical: "bot-live")
        let sessions = Catalog.client(stub)
        let botChat = SessionRecord(
            id: try DirectHermesSessionIdentity.appID(owner: try #require(stub.owner), profileID: "alpha",
                                                      anchorID: "bot-live"),
            kind: .direct, agentIDs: ["alpha"], title: "Bot Chat")
        let retired = try SessionTitleRules.validated(SessionRecord.retiredBotChatTitle(at: .now))

        try await sessions.rename(botChat, title: retired)

        #expect(host.rows["bot-live"]?.title == retired && host.rows["bot-live"]?.hidden == false)
        let operations = host.requests.map(\.operation)
        let unhid = try #require(operations.firstIndex { $0 == .sessionSetHidden || $0 == .sessionUpdate })
        let titled = try #require(operations.firstIndex(of: .sessionTitle))
        #expect(unhid < titled, "Shown first: a hidden Bot Chat can't be renamed")
        #expect(operations.contains(.sessionResume), "Opened to be titled")
        if edition == .current { #expect(host.requests(.sessionUpdate).isEmpty) }
    }

    @Test func archivingTheBotChatArchivesThenHidesItOverTheSocket() async throws {
        let host = FakeHermesSessionHost(.current, rows: ["canonical-root": .init(title: "Bot Chat", hidden: true)])
        let sessions = Catalog.client(try workspace(host, canonical: "canonical-root"))
        guard case .resolved(let botChat) = try await sessions.resolveCanonicalChat(profileID: "alpha") else {
            Issue.record("Expected the Bot Chat")
            return
        }
        try await sessions.archive(botChat.record)
        #expect(host.rows["canonical-root"]?.archived == true && host.rows["canonical-root"]?.hidden == true)
        let edits = host.requests.map(\.operation).filter { $0 == .sessionArchive || $0 == .sessionSetHidden }
        #expect(edits == [.sessionArchive, .sessionSetHidden])
        #expect(host.requests(.sessionUpdate).isEmpty)
    }

    // MARK: All sessions on another computer

    @Test(arguments: [Edition.current, .older])
    func chatsOnAnotherComputerRenameAndArchive(edition: Edition) async throws {
        let host = FakeHermesSessionHost(edition, rows: [
            "plans": .init(title: "Plans", revision: 1),
            "bot": .init(title: "Bot Chat", hidden: true, revision: 6),
        ])
        func apply(_ change: FleetChatChange, _ chat: FleetChat) async throws {
            try await RegistryFleetReader.apply(change, to: chat, editor: host.editor)
        }
        try await apply(.rename("Trip"), chat("plans", "Plans"))
        #expect(host.rows["plans"]?.title == "Trip")
        try await apply(.archive, chat("plans", "Trip"))
        #expect(host.rows["plans"]?.archived == true)

        // A Bot Chat is shown first, then renamed.
        try await apply(.rename("Notes"), chat("bot", "Bot Chat"))
        #expect(host.rows["bot"]?.hidden == false && host.rows["bot"]?.title == "Notes")
        // Archiving a Bot Chat hides it too, which retires it.
        host.rows["bot"] = .init(title: "Bot Chat", hidden: false)
        try await apply(.archive, chat("bot", "Bot Chat"))
        #expect(host.rows["bot"]?.archived == true && host.rows["bot"]?.hidden == true)
        if edition == .current {
            #expect(host.requests(.sessionUpdate).isEmpty, "Never the dashboard route on a current host")
        }
    }
}
