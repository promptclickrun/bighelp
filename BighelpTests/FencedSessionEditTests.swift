import Foundation
import Testing
@testable import Bighelp

/// A Hermes dashboard's saved-chat edits, as `hermes_cli/web_server_sessions.py` answers them. Current
/// Hermes (`.checksEdits`) refuses a PATCH or DELETE that doesn't carry `request_id` and `expected_revision`
/// with 409 `client_upgrade_required`, checks the revision against the row's `runtime_revision`, bumps it on
/// success, answers a repeated `request_id` with the stored receipt and wants `expected_generation` on a
/// delete. An older Hermes (`.older`) takes the plain body and has no revision in a row's detail.
@MainActor
final class FakeHermesSessionDashboard {
    enum Edition {
        case checksEdits
        case older
        /// Checks every edit but doesn't show the revision in a row's detail: the app can't fence its edits.
        case checksEditsHidingRevision
    }

    struct Row {
        var title = "Session"
        var hidden = false
        var archived = false
        var pinned = false
        var unread = false
        var revision = 0
        var generation = 0
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
    private var receipts: [String: (signature: String, reply: [String: BighelpJSONValue])] = [:]
    /// Runs just before an edit is checked, once per call: someone else editing the row in between.
    var beforeCheck: (@MainActor (FakeHermesSessionDashboard) -> Void)?

    init(_ edition: Edition, rows: [String: Row]) {
        self.edition = edition
        self.rows = rows
    }

    var updates: [Request] { requests.filter { $0.operation == .sessionUpdate } }
    var deletes: [Request] { requests.filter { $0.operation == .sessionDelete } }

    /// Edits as the app's workspace client sends them: its own route checks first, then Hermes' answer
    /// translated the way the client does.
    var edits: DirectHermesFencedSessionEdit {
        DirectHermesFencedSessionEdit(perform: { [self] operation, payload in
            _ = try DirectHermesWorkspaceClient.route(operation, payload: payload)
            do { return try handle(operation, payload) } catch {
                throw DirectHermesWorkspaceClient.workspaceError(error, for: operation)
            }
        })
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
            if edition == .checksEdits {
                detail["runtime_revision"] = .integer(row.revision)
                detail["runtime_generation"] = .integer(row.generation)
            }
            return detail
        case .sessionUpdate, .sessionDelete:
            return try mutate(operation, id: id, payload: payload)
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }

    private func refusal(_ detail: String) -> DirectHermesError {
        // What `DirectHermesHTTP.sessionEditRefusal` makes of a 409 with this `detail`.
        .rpcRejected(code: 409, message: HermesRefusalMessage(detail))
    }

    private func mutate(_ operation: WorkspaceOperation, id: String,
                        payload: [String: BighelpJSONValue]) throws -> [String: BighelpJSONValue] {
        let fenceKeys = ["request_id", "expected_revision", "expected_generation"]
        if edition == .older {
            // Unknown fields are a 422 there.
            guard fenceKeys.allSatisfy({ payload[$0] == nil }) else { throw DirectHermesError.invalidResponse }
            return try apply(operation, id: id, payload: payload, fenced: false)
        }
        let requestID = payload["request_id"], revision = payload["expected_revision"]
        let generation = payload["expected_generation"]
        if fenceKeys.allSatisfy({ payload[$0] == nil }) { throw refusal(Self.upgradeRequired) }
        guard requestID != nil, revision != nil else { throw refusal("mutation_identity_required") }
        guard let requestText = requestID?.string, let expected = revision?.integer, expected >= 0,
              generation == nil || (generation?.integer ?? -1) >= 0 else { throw DirectHermesError.invalidResponse }
        let signature = payload.keys.filter { $0 != "request_id" }.sorted().map { "\($0)=\(payload[$0]!)" }
            .joined(separator: "&")
        if let seen = receipts[requestText] {
            guard seen.signature == signature else { throw refusal("request_id_reused") }
            return seen.reply
        }
        beforeCheck?(self)
        guard let row = rows[id] else {
            if operation == .sessionDelete { return ["ok": .boolean(true), "already_absent": .boolean(true)] }
            throw DirectHermesError.unsupportedAuthentication
        }
        if operation == .sessionDelete, generation == nil { throw DirectHermesError.invalidResponse }
        guard row.revision == expected else { throw refusal("revision_conflict") }
        if let generation, generation.integer != row.generation { throw refusal("stale_generation") }
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
            // As Hermes' SessionDB.set_session_title answers for a hidden Bot Chat.
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
struct FencedSessionEditTests {
    typealias Catalog = DirectHermesSessionCatalogClientTests

    // MARK: Request fields

    /// Current Hermes answers a plain edit with 409 and no row changes, which was every edit in the app:
    /// New Bot Chat, rename, pin, archive, mark unread, hide and delete.
    @Test func theFakeRefusesAPlainEditTheWayCurrentHermesDoes() throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: ["a": .init()])
        let plain: [String: BighelpJSONValue] = ["session_id": .string("a"), "profile": .string("alpha"),
                                                  "pinned": .boolean(true)]
        #expect(throws: DirectHermesError.rpcRejected(code: 409)) { try dashboard.handle(.sessionUpdate, plain) }
        #expect(dashboard.rows["a"]?.pinned == false)
    }

    @Test func eachEditSendsAFreshRequestIDAndTheRowsRevision() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: ["a": .init(revision: 4, generation: 2)])
        let first = try await dashboard.edits.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
        let second = try await dashboard.edits.update("a", profile: "alpha", fields: ["unread": .boolean(true)])

        let sent = dashboard.updates.map(\.payload)
        #expect(sent.count == 2)
        #expect(sent[0]["expected_revision"] == .integer(4))
        #expect(sent[1]["expected_revision"] == .integer(5), "The second edit read the row again")
        let ids = sent.compactMap { $0["request_id"]?.string }
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil && $0 == $0.lowercased() })
        #expect(sent.allSatisfy { $0["expected_generation"] == nil }, "A PATCH needs no generation")
        #expect(first.revision == 5 && second.revision == 6)
        #expect(dashboard.rows["a"]?.pinned == true && dashboard.rows["a"]?.unread == true)
    }

    @Test func aKnownRevisionSkipsTheRead() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: ["a": .init(revision: 9)])
        let receipt = try await dashboard.edits.update("a", profile: "alpha", fields: ["pinned": .boolean(true)],
                                                       knownRevision: 9)
        #expect(receipt.revision == 10)
        #expect(!dashboard.requests.contains { $0.operation == .sessionDetail })
    }

    @Test func aDeleteSendsTheRowsGenerationToo() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: ["a": .init(revision: 3, generation: 7)])
        let reply = try await dashboard.edits.delete("a", profile: "alpha")
        let sent = try #require(dashboard.deletes.first?.payload)
        #expect(sent["expected_revision"] == .integer(3))
        #expect(sent["expected_generation"] == .integer(7))
        #expect(sent["request_id"]?.string.flatMap(UUID.init(uuidString:)) != nil)
        #expect(reply["ok"] == .boolean(true))
        #expect(dashboard.rows["a"] == nil)
    }

    // MARK: Changed rows

    @Test func aRowThatChangedBeforeTheEditIsReadAgainAndSentOnceMore() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: ["a": .init(revision: 1)])
        var interruptions = 0
        dashboard.beforeCheck = { host in
            guard interruptions == 0 else { return }
            interruptions += 1
            host.rows["a"]?.revision += 1
        }
        let receipt = try await dashboard.edits.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])

        let sent = dashboard.updates.map(\.payload)
        #expect(sent.map { $0["expected_revision"] } == [.integer(1), .integer(2)])
        #expect(Set(sent.compactMap { $0["request_id"]?.string }).count == 2, "A new request ID for the new try")
        #expect(receipt.revision == 3)
        #expect(dashboard.rows["a"]?.pinned == true)
    }

    @Test func aRowThatChangedBeforeADeleteIsReadAgainAndDeleted() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: ["a": .init(revision: 1, generation: 1)])
        var interruptions = 0
        dashboard.beforeCheck = { host in
            guard interruptions == 0 else { return }
            interruptions += 1
            host.rows["a"]?.generation += 1
            host.rows["a"]?.revision += 1
        }
        _ = try await dashboard.edits.delete("a", profile: "alpha")
        #expect(dashboard.deletes.count == 2)
        #expect(dashboard.deletes.last?.payload["expected_generation"] == .integer(2))
        #expect(dashboard.rows["a"] == nil)
    }

    @Test func aRowThatKeepsChangingIsTriedTwiceNotForever() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: ["a": .init()])
        dashboard.beforeCheck = { $0.rows["a"]?.revision += 1 }
        await #expect(throws: WorkspaceClientError.rejected(code: "revision_conflict")) {
            try await dashboard.edits.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
        }
        #expect(dashboard.updates.count == 2)
        #expect(dashboard.rows["a"]?.pinned == false)
    }

    @Test func aStaleKnownRevisionIsReadAgainOnce() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: ["a": .init(revision: 6)])
        let receipt = try await dashboard.edits.update("a", profile: "alpha", fields: ["pinned": .boolean(true)],
                                                       knownRevision: 5)
        #expect(dashboard.updates.map { $0.payload["expected_revision"] } == [.integer(5), .integer(6)])
        #expect(receipt.revision == 7)
    }

    // MARK: Older Hermes and refusals

    @Test func olderHermesGetsExactlyTheOldBody() async throws {
        let dashboard = FakeHermesSessionDashboard(.older, rows: ["a": .init()])
        let receipt = try await dashboard.edits.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
        _ = try await dashboard.edits.delete("a", profile: "alpha")

        #expect(dashboard.updates.map(\.payload) == [["session_id": .string("a"), "profile": .string("alpha"),
                                                      "pinned": .boolean(true)]])
        #expect(dashboard.deletes.map(\.payload) == [["session_id": .string("a"), "profile": .string("alpha")]])
        #expect(receipt.revision == nil)
        #expect(dashboard.rows["a"] == nil)
    }

    @Test func aRowThatCannotBeReadStillGetsThePlainEdit() async throws {
        let dashboard = FakeHermesSessionDashboard(.older, rows: [:])
        let reply = try await dashboard.edits.delete("gone", profile: "alpha")
        #expect(reply["already_absent"] == .boolean(true))
    }

    @Test func anUpgradeRefusalIsShownAsHermesSaidItAndNeverRetried() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEditsHidingRevision, rows: ["a": .init()])
        do {
            _ = try await dashboard.edits.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
            Issue.record("Expected Hermes' refusal")
        } catch {
            #expect(error as? WorkspaceClientError == .rejected(code: "client_upgrade_required"))
            let words = HermesRefusalMessage.sentence(in: error)
            #expect(words?.contains("update the app to edit sessions") == true)
        }
        #expect(dashboard.updates.count == 1)
    }

    @Test func aMissingIdentityIsAlsoNeverRetried() async throws {
        var attempts = 0
        let edits = DirectHermesFencedSessionEdit(perform: { _, _ in
            attempts += 1
            throw WorkspaceClientError.rejected(code: "mutation_identity_required")
        })
        await #expect(throws: WorkspaceClientError.rejected(code: "mutation_identity_required")) {
            try await edits.update("a", profile: "alpha", fields: ["pinned": .boolean(true)], knownRevision: 0)
        }
        #expect(attempts == 1)
    }

    @Test func aHostThatCannotBeReachedForTheReadSaysSoNotUpgrade() async throws {
        var attempts = 0
        let edits = DirectHermesFencedSessionEdit(perform: { operation, _ in
            attempts += 1
            if operation == .sessionDetail { throw WorkspaceClientError.transportUnavailable }
            throw WorkspaceClientError.rejected(code: "client_upgrade_required")
        })
        await #expect(throws: WorkspaceClientError.transportUnavailable) {
            try await edits.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
        }
        #expect(attempts == 2)
    }

    @Test func aChangedHostEndsTheEditAtTheRead() async throws {
        let edits = DirectHermesFencedSessionEdit(perform: { _, _ in throw WorkspaceClientError.ownerChanged })
        await #expect(throws: WorkspaceClientError.ownerChanged) {
            try await edits.update("a", profile: "alpha", fields: ["pinned": .boolean(true)])
        }
    }

    // MARK: Request builders and Hermes' 409

    @Test func theRequestBuildersTakeTheEditCheckAndRefuseBadValues() throws {
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

    @Test func hermes409OnASessionEditKeepsItsReasonAndWords() throws {
        func response(_ status: Int, _ body: String) -> DirectHermesHTTP.Response {
            let url = URL(string: "https://host.example/api/sessions/a")!
            return .init(http: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!,
                         body: Data(body.utf8))
        }
        let patch = DirectHermesHTTPRequest(path: "/api/sessions/a", method: .patch)
        let upgrade = try #require(DirectHermesHTTP.sessionEditRefusal(
            patch, response(409, #"{"detail":"\#(FakeHermesSessionDashboard.upgradeRequired)"}"#)))
        let translated = DirectHermesWorkspaceClient.workspaceError(upgrade, for: .sessionUpdate)
        #expect(translated as? WorkspaceClientError == .rejected(code: "client_upgrade_required"))
        #expect(HermesRefusalMessage.sentence(in: translated)?.contains("update the app to edit sessions") == true)

        let conflict = try #require(DirectHermesHTTP.sessionEditRefusal(
            DirectHermesHTTPRequest(path: "/api/sessions/a", method: .delete),
            response(409, #"{"detail":"revision_conflict"}"#)))
        #expect(DirectHermesWorkspaceClient.workspaceError(conflict, for: .sessionDelete) as? WorkspaceClientError
                == .rejected(code: "revision_conflict"))

        // Only a session edit's 409 with a text `detail`; everything else is as before.
        #expect(DirectHermesHTTP.sessionEditRefusal(patch, response(400, #"{"detail":"invalid_params"}"#)) == nil)
        #expect(DirectHermesHTTP.sessionEditRefusal(patch, response(409, #"{"detail":{"errors":[]}}"#)) == nil)
        #expect(DirectHermesHTTP.sessionEditRefusal(
            DirectHermesHTTPRequest(path: "/api/sessions/a", method: .get), response(409, #"{"detail":"x"}"#)) == nil)
        #expect(DirectHermesHTTP.sessionEditRefusal(
            DirectHermesHTTPRequest(path: "/api/cron/jobs/a", method: .patch), response(409, #"{"detail":"x"}"#)) == nil)
    }

    // MARK: The chat list's actions

    private func hostRows(_ dashboard: FakeHermesSessionDashboard) -> [String: BighelpJSONValue] {
        Catalog.ownershipPage(dashboard.rows.keys.sorted().map { id in
            var row = Catalog.session(id: id).object ?? [:]
            let state = dashboard.rows[id] ?? .init()
            row["title"] = .string(state.title)
            row["hidden"] = .boolean(state.hidden)
            row["pinned"] = .boolean(state.pinned)
            return .object(row)
        })
    }

    private func workspace(_ dashboard: FakeHermesSessionDashboard,
                           canonical: String? = nil, resolved: String? = nil) throws -> SessionWorkspaceStub {
        let workspace = try SessionWorkspaceStub()
        workspace.handler = { operation, payload in
            switch operation {
            case .profilesList: return Catalog.profiles(canonical: canonical, resolved: resolved)
            case .sessionsList: return self.hostRows(dashboard)
            case .sessionResume, .sessionActivate: return Catalog.attached(stored: resolved ?? canonical ?? "a")
            case .sessionTitle:
                // The live title: a hidden Bot Chat's is refused, as Hermes' set_session_title does.
                let id = resolved ?? canonical ?? "a"
                guard dashboard.rows[id]?.hidden != true else {
                    throw WorkspaceClientError.rejected(code: "4022", message: HermesRefusalMessage("canonical Bot Chat"))
                }
                dashboard.rows[id]?.title = payload["title"]?.string ?? ""
                return ["pending": .boolean(false), "title": payload["title"] ?? .null]
            case .sessionUpdate, .sessionDetail, .sessionDelete:
                return try dashboard.handle(operation, payload)
            default:
                Issue.record("Unexpected \(operation)")
                throw WorkspaceClientError.invalidRequest
            }
        }
        return workspace
    }

    @Test(arguments: [FakeHermesSessionDashboard.Edition.checksEdits, .older])
    func renamePinUnreadArchiveAndDeleteWork(edition: FakeHermesSessionDashboard.Edition) async throws {
        let dashboard = FakeHermesSessionDashboard(edition, rows: ["a": .init(revision: 4, generation: 1)])
        let client = Catalog.client(try workspace(dashboard))
        let record = try #require(try await client.list().first)

        try await client.rename(record, title: "Trip plans")
        #expect(dashboard.rows["a"]?.title == "Trip plans")
        try await client.setPinned(record, pinned: true)
        #expect(dashboard.rows["a"]?.pinned == true)
        try await client.setFlags(record, flags: .init(unread: true))
        #expect(dashboard.rows["a"]?.unread == true)
        try await client.archive(record)
        #expect(dashboard.rows["a"]?.archived == true)

        let fenced = edition == .checksEdits
        #expect(dashboard.updates.count == 4)
        #expect(dashboard.updates.allSatisfy { ($0.payload["request_id"] != nil) == fenced })
        if fenced {
            #expect(dashboard.updates.map { $0.payload["expected_revision"] }
                    == [.integer(4), .integer(5), .integer(6), .integer(7)])
        }
        let fresh = Catalog.client(try workspace(dashboard))
        let again = try #require(try await fresh.list().first)
        _ = try await fresh.deleteNativeRow(again)
        #expect(dashboard.rows["a"] == nil)
        let generation: BighelpJSONValue? = fenced ? .integer(1) : nil
        #expect(dashboard.deletes.first?.payload["expected_generation"] == generation)
    }

    @Test(arguments: [FakeHermesSessionDashboard.Edition.checksEdits, .older])
    func newBotChatUnhidesAndRetitlesTheBotChatTheAppNoLongerKnows(edition: FakeHermesSessionDashboard.Edition) async throws {
        let dashboard = FakeHermesSessionDashboard(
            edition, rows: ["bot-live": .init(title: "Bot Chat", hidden: true, revision: 5)])
        let stub = try workspace(dashboard, canonical: "bot-live")
        let sessions = Catalog.client(stub)
        let botChat = SessionRecord(
            id: try DirectHermesSessionIdentity.appID(owner: try #require(stub.owner), profileID: "alpha",
                                                      anchorID: "bot-live"),
            kind: .direct, agentIDs: ["alpha"], title: "Bot Chat")
        let retired = try SessionTitleRules.validated(SessionRecord.retiredBotChatTitle(at: .now))

        try await sessions.rename(botChat, title: retired)

        #expect(dashboard.rows["bot-live"]?.title == retired)
        #expect(dashboard.rows["bot-live"]?.hidden == false)
        let updates = dashboard.updates
        #expect(updates.count == 2, "Unhide, then title")
        if edition == .checksEdits {
            #expect(updates.map { $0.payload["expected_revision"] } == [.integer(5), .integer(6)])
            #expect(Set(updates.compactMap { $0.payload["request_id"]?.string }).count == 2)
            let firstUpdate = try #require(dashboard.requests.firstIndex { $0.operation == .sessionUpdate })
            let secondUpdate = try #require(dashboard.requests.lastIndex { $0.operation == .sessionUpdate })
            #expect(!dashboard.requests[firstUpdate + 1..<secondUpdate].contains { $0.operation == .sessionDetail },
                    "The reply's revision stands in for another read")
        } else {
            #expect(updates.allSatisfy { $0.payload["request_id"] == nil && $0.payload["expected_revision"] == nil })
        }
    }

    @Test func renamingTheBotChatUnhidesEachOfItsRowsAgainstItsOwnRevision() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: [
            "canonical-root": .init(title: "Bot Chat", hidden: true, revision: 3),
            "tip": .init(title: "Bot Chat", hidden: true, revision: 7),
        ])
        let sessions = Catalog.client(try workspace(dashboard, canonical: "canonical-root", resolved: "tip"))
        guard case .resolved(let botChat) = try await sessions.resolveCanonicalChat(profileID: "alpha") else {
            Issue.record("Expected the Bot Chat")
            return
        }
        try await sessions.rename(botChat.record, title: "Trip")

        #expect(dashboard.rows["canonical-root"]?.hidden == false && dashboard.rows["tip"]?.hidden == false)
        let byRow = Dictionary(grouping: dashboard.updates) { $0.payload["session_id"]?.string ?? "" }
        #expect(byRow["canonical-root"]?.first?.payload["expected_revision"] == .integer(3))
        #expect(byRow["tip"]?.first?.payload["expected_revision"] == .integer(7))
        #expect(dashboard.rows["tip"]?.title == "Trip")
    }

    @Test func archivingTheBotChatRetiresItAgainstCurrentHermes() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: [
            "canonical-root": .init(title: "Bot Chat", hidden: true, revision: 2),
        ])
        let sessions = Catalog.client(try workspace(dashboard, canonical: "canonical-root"))
        guard case .resolved(let botChat) = try await sessions.resolveCanonicalChat(profileID: "alpha") else {
            Issue.record("Expected the Bot Chat")
            return
        }
        try await sessions.archive(botChat.record)
        #expect(dashboard.rows["canonical-root"]?.archived == true)
        #expect(dashboard.rows["canonical-root"]?.hidden == true)
        #expect(dashboard.updates.count == 1)
    }

    @Test func aRowThatChangedMeanwhileDoesNotFailTheChatListAction() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: ["a": .init(revision: 1)])
        var interruptions = 0
        dashboard.beforeCheck = { host in
            guard interruptions == 0 else { return }
            interruptions += 1
            host.rows["a"]?.revision += 1
        }
        let client = Catalog.client(try workspace(dashboard))
        let record = try #require(try await client.list().first)
        try await client.setPinned(record, pinned: true)
        #expect(dashboard.rows["a"]?.pinned == true)
        #expect(dashboard.updates.count == 2)
    }

    @Test func restoringAnArchivedChatSendsTheEditCheck() async throws {
        let dashboard = FakeHermesSessionDashboard(.checksEdits, rows: ["a": .init(archived: true, revision: 8)])
        let client = Catalog.client(try workspace(dashboard))
        try await client.restoreArchivedChat(SessionArchivedChat(
            profileID: "alpha", storedID: "a", title: "Old", source: nil, preview: nil, lastActive: nil))
        #expect(dashboard.rows["a"]?.archived == false)
        #expect(dashboard.updates.first?.payload["expected_revision"] == .integer(8))
    }

    // MARK: All sessions on another computer

    @Test(arguments: [FakeHermesSessionDashboard.Edition.checksEdits, .older])
    func chatsOnAnotherComputerRenameAndArchive(edition: FakeHermesSessionDashboard.Edition) async throws {
        let dashboard = FakeHermesSessionDashboard(edition, rows: [
            "plans": .init(title: "Plans", revision: 1),
            "bot": .init(title: "Bot Chat", hidden: true, revision: 6),
        ])
        func chat(_ id: String, _ title: String) -> FleetChat {
            FleetChat(hostID: UUID(), profileID: "rio", storedSessionID: id, title: title, preview: "",
                      updatedAt: Date(), isActive: false)
        }
        try await RegistryFleetReader.apply(.rename("Trip"), to: chat("plans", "Plans"), edits: dashboard.edits)
        #expect(dashboard.rows["plans"]?.title == "Trip")
        try await RegistryFleetReader.apply(.archive, to: chat("plans", "Trip"), edits: dashboard.edits)
        #expect(dashboard.rows["plans"]?.archived == true)

        // A Bot Chat is shown first, then renamed on the revision the first edit left.
        try await RegistryFleetReader.apply(.rename("Notes"), to: chat("bot", "Bot Chat"), edits: dashboard.edits)
        #expect(dashboard.rows["bot"]?.hidden == false && dashboard.rows["bot"]?.title == "Notes")
        let botEdits = dashboard.updates.filter { $0.payload["session_id"] == .string("bot") }
        #expect(botEdits.count == 2)
        if edition == .checksEdits {
            #expect(botEdits.map { $0.payload["expected_revision"] } == [.integer(6), .integer(7)])
        } else {
            #expect(botEdits.allSatisfy { $0.payload["request_id"] == nil })
        }
        // Archiving a Bot Chat hides it, which retires it.
        dashboard.rows["bot"] = .init(title: "Bot Chat", revision: 0)
        try await RegistryFleetReader.apply(.archive, to: chat("bot", "Bot Chat"), edits: dashboard.edits)
        #expect(dashboard.rows["bot"]?.archived == true && dashboard.rows["bot"]?.hidden == true)
    }
}
