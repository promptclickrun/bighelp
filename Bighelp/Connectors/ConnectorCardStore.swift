import Foundation
import Observation

/// The connect cards of the chats on screen, drawn inline in each chat. Hermes opens one with
/// `connection.request` when an agent calls `manage_connections` and then waits (5 minutes) for the
/// person: without an answer the tool just times out. Answers go back on the same socket
/// (`connection.respond`, `connectors.connect`, `connectors.operation.wake`), owned by the chat's
/// runtime session. Several cards can wait at once, each answered on its own.
@MainActor
@Observable
final class ConnectorCardStore {
    typealias Requester = @MainActor (_ method: String, _ params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue

    struct Card: Identifiable, Equatable, Sendable {
        let runtimeID: String
        let profile: String
        let visibleSessionID: String
        var operation: ConnectorOperation
        var id: String { operation.id }
    }

    struct AppInfo: Equatable, Sendable {
        let name: String
        let logoURL: URL?
    }

    private struct Binding: Equatable {
        let profile: String
        let visibleSessionID: String
    }

    /// The only methods a card sends.
    static let methods: Set<String> = [
        "connection.respond", "connectors.connect", "connectors.operation.wake", "connectors.operation.status",
        "connectors.catalog",
    ]

    private(set) var revision: UInt64 = 0
    /// Rows waiting on Hermes, so their buttons don't send twice.
    private(set) var working: Set<String> = []
    private(set) var message: String?
    private(set) var apps: [String: AppInfo] = [:]

    @ObservationIgnored private var connection: DirectHermesPromptConnection?
    @ObservationIgnored private var request: Requester?
    @ObservationIgnored private var bindings: [String: Binding] = [:]
    @ObservationIgnored private var cards: [String: Card] = [:]
    /// The open card of each chat, kept across reconnects so it can be read again under the
    /// chat's new runtime session.
    @ObservationIgnored private var remembered: [String: String] = [:]
    @ObservationIgnored private var catalogRequested = false

    /// One chat's open cards, oldest first.
    func cards(runtimeID: String, visibleSessionID: String) -> [Card] {
        _ = revision
        return cards.values
            .filter { $0.runtimeID == runtimeID && $0.visibleSessionID == visibleSessionID
                && bindings[$0.runtimeID] != nil && !$0.operation.isSettled && !$0.operation.isDisplay }
            .sorted { ($0.operation.deadline ?? .distantFuture, $0.id) < ($1.operation.deadline ?? .distantFuture, $1.id) }
    }

    /// The newest frame of a card, or nil once Hermes has settled it.
    func current(_ card: Card) -> Card? {
        _ = revision
        return cards[card.id]
    }

    func beginConnection(_ value: DirectHermesPromptConnection, request: @escaping Requester) {
        connection = value
        self.request = request
        bindings.removeAll()
        cards.removeAll()
        working.removeAll()
        message = nil
        catalogRequested = false
        changed()
    }

    func retireConnection(_ value: DirectHermesPromptConnection) {
        guard connection == value else { return }
        connection = nil
        request = nil
        bindings.removeAll()
        cards.removeAll()
        working.removeAll()
        message = nil
        changed()
    }

    func bind(profile: String, runtimeID: String, visibleSessionID: String, connection expected: DirectHermesPromptConnection) {
        guard connection == expected else { return }
        bindings[runtimeID] = Binding(profile: profile, visibleSessionID: visibleSessionID)
        // A card open before the reconnect: read it again under this runtime session.
        guard let opID = remembered[visibleSessionID],
              !cards.values.contains(where: { $0.visibleSessionID == visibleSessionID }) else { return }
        Task { await refresh(opID: opID, runtimeID: runtimeID, connection: expected) }
    }

    func unbind(runtimeID: String, connection expected: DirectHermesPromptConnection) {
        guard connection == expected, bindings.removeValue(forKey: runtimeID) != nil else { return }
        cards = cards.filter { $0.value.runtimeID != runtimeID }
        changed()
    }

    /// `connection.request` and `connection.update` from the socket. Account-owned updates belong
    /// to Settings › Apps, which reads its own operation.
    func accept(_ event: DirectHermesEvent, connection expected: DirectHermesPromptConnection) {
        guard connection == expected, event.type == "connection.request" || event.type == "connection.update",
              let runtimeID = event.sessionID, bindings[runtimeID] != nil else { return }
        if let owner = event.payload["owner"]?.object, owner["type"]?.string != "session" { return }
        guard let operation = try? ConnectorOperation(payload: event.payload) else { return }
        adopt(operation, runtimeID: runtimeID)
    }

    /// A resumed chat's `pending_connection`: the card it missed while away.
    func acceptPending(_ value: BighelpJSONValue?, runtimeID: String, connection expected: DirectHermesPromptConnection) {
        guard connection == expected, bindings[runtimeID] != nil, let payload = value?.object,
              let operation = try? ConnectorOperation(payload: payload) else { return }
        adopt(operation, runtimeID: runtimeID)
    }

    // MARK: Answers

    /// The person closed the sign-in page: Hermes checks the account now, not at its next tick.
    func signInClosed(_ card: Card) async {
        _ = try? await send("connectors.operation.wake", card: card, ["op_id": .string(card.id)])
    }

    func skip(_ names: [String], in card: Card) async {
        let targets = names.map { BighelpJSONValue.object(["name": .string($0), "status": .string("skipped")]) }
        await respond(card, names: names, result: ["targets": .array(targets)])
    }

    func skipAll(_ card: Card) async {
        let open = (cards[card.id]?.operation ?? card.operation).openTargets.map(\.name)
        guard !open.isEmpty else { return }
        await skip(open, in: card)
    }

    /// An MCP install, enable or authorize the person approved, with the values it asked for.
    func approve(_ target: ConnectorOperation.Target, in card: Card, environment: [String: String]) async {
        var answer: [String: BighelpJSONValue] = ["name": .string(target.name), "status": .string("approved")]
        let values = environment.filter { field in target.requiredEnvironment.contains { $0.name == field.key } && !field.value.isEmpty }
        if !values.isEmpty { answer["env"] = .object(values.mapValues(BighelpJSONValue.string)) }
        await respond(card, names: [target.name], result: ["targets": .array([.object(answer)])])
    }

    /// A failed or expired sign-in gets a fresh link.
    func retry(_ target: ConnectorOperation.Target, in card: Card) async {
        var params: [String: BighelpJSONValue] = ["connectors": .array([.string(target.name)])]
        if target.action == .reconnect { params["reconnect"] = .boolean(true) }
        if let alias = target.alias { params["alias"] = .string(alias) }
        await perform(card, names: [target.name]) {
            let result = try await self.send("connectors.connect", card: card, params)
            if let object = result?.object, let operation = try? ConnectorOperation(payload: object) {
                self.adopt(operation, runtimeID: card.runtimeID)
            }
        }
    }

    func isWorking(_ target: ConnectorOperation.Target, in card: Card) -> Bool {
        working.contains(Self.key(card.id, target.name))
    }

    func app(_ slug: String) -> AppInfo {
        apps[slug] ?? AppInfo(name: ConnectorNames.readable(slug), logoURL: nil)
    }

    // MARK: Private

    private func respond(_ card: Card, names: [String], result: [String: BighelpJSONValue]) async {
        await perform(card, names: names) {
            let answer = try await self.send("connection.respond", card: card,
                                             ["op_id": .string(card.id), "result": .object(result)])
            if answer?.object?["settled"]?.boolean == true { self.settle(card.id) }
        }
    }

    private func perform(_ card: Card, names: [String], _ body: @escaping @MainActor () async throws -> Void) async {
        let keys = names.map { Self.key(card.id, $0) }
        guard keys.allSatisfy({ !working.contains($0) }) else { return }
        working.formUnion(keys)
        message = nil
        defer { working.subtract(keys) }
        do {
            try await body()
        } catch DirectHermesError.rpcRejected(code: 4004, _) {
            // The operation ended on the host (answered elsewhere, or past its deadline).
            settle(card.id)
        } catch DirectHermesError.rpcRejected(code: 4002, _) {
            message = "That sign-in link still works. Open it again to finish."
        } catch {
            message = "Hermes couldn't do that. Try again."
        }
    }

    private func send(_ method: String, card: Card, _ params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue? {
        guard let request, let binding = bindings[card.runtimeID] else { throw WorkspaceClientError.ownerChanged }
        var body = params
        body["owner"] = .object(["type": .string("session"), "session_id": .string(card.runtimeID)])
        body["profile"] = .string(binding.profile)
        let expected = connection
        let result = try await request(method, body)
        guard connection == expected else { throw WorkspaceClientError.ownerChanged }
        return result
    }

    private func refresh(opID: String, runtimeID: String, connection expected: DirectHermesPromptConnection) async {
        guard connection == expected, let request, let binding = bindings[runtimeID] else { return }
        let params: [String: BighelpJSONValue] = [
            "owner": .object(["type": .string("session"), "session_id": .string(runtimeID)]),
            "profile": .string(binding.profile), "op_id": .string(opID),
        ]
        do {
            let value = try await request("connectors.operation.status", params)
            guard connection == expected, let payload = value.object,
                  let operation = try? ConnectorOperation(payload: payload) else { return }
            adopt(operation, runtimeID: runtimeID)
        } catch DirectHermesError.rpcRejected(code: 4004, _) {
            guard connection == expected else { return }
            remembered.removeValue(forKey: binding.visibleSessionID)
        } catch {}
    }

    private func adopt(_ operation: ConnectorOperation, runtimeID: String) {
        guard let binding = bindings[runtimeID] else { return }
        if let current = cards[operation.id], current.operation.sequence >= operation.sequence { return }
        if operation.isSettled || operation.isDisplay {
            settle(operation.id)
            return
        }
        cards[operation.id] = Card(runtimeID: runtimeID, profile: binding.profile,
                                   visibleSessionID: binding.visibleSessionID, operation: operation)
        remembered[binding.visibleSessionID] = operation.id
        if operation.targets.contains(where: { $0.kind == .connector }) { loadCatalog(profile: binding.profile) }
        changed()
    }

    private func settle(_ opID: String) {
        if let card = cards.removeValue(forKey: opID) {
            remembered.removeValue(forKey: card.visibleSessionID)
        }
        remembered = remembered.filter { $0.value != opID }
        changed()
    }

    /// App names and logos for the card. Only once an app connector is on screen: by then the
    /// host has its connector identity, so the catalog read can't be what creates one.
    private func loadCatalog(profile: String) {
        guard !catalogRequested, let request, let expected = connection else { return }
        catalogRequested = true
        Task {
            guard let value = try? await request("connectors.catalog", ["profile": .string(profile)]),
                  connection == expected else { return }
            apps = Self.apps(in: value)
        }
    }

    static func apps(in value: BighelpJSONValue) -> [String: AppInfo] {
        var apps: [String: AppInfo] = [:]
        for row in (value.object?["connectors"]?.array ?? []).prefix(2_000) {
            guard let object = row.object, let slug = object["slug"]?.string, !slug.isEmpty, slug.utf8.count <= 128,
                  let name = object["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 80 else { continue }
            apps[slug] = AppInfo(name: name, logoURL: object["logo_url"]?.string.flatMap(ConnectorOperation.signInURL))
        }
        return apps
    }

    private static func key(_ opID: String, _ name: String) -> String { opID + "\u{0}" + name }

    private func changed() { revision &+= 1 }
}
