import Foundation
import Observation

/// What Settings › Apps calls on the host: Hermes' connector methods for the computer's own account
/// (`owner: account`), never a chat's.
@MainActor
protocol ConnectorAppsService: AnyObject {
    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue
}

/// The selected host, over its authenticated socket.
@MainActor
final class DirectHermesConnectorAppsService: ConnectorAppsService {
    private let workspace: DirectHermesWorkspaceStore

    init(workspace: DirectHermesWorkspaceStore) { self.workspace = workspace }

    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        try await workspace.connectorRequest(method, params: params)
    }
}

/// Settings › Apps: the apps Hermes can reach through its hosted connectors, which of them have an
/// account, and connect, name and remove. Any account call makes Hermes create the computer's free
/// connector identity, so nothing is called until the person taps Set up apps once.
@MainActor
@Observable
final class ConnectorAppsModel {
    enum Phase: Equatable {
        /// Not set up on this computer yet (as far as this phone knows).
        case intro
        case loading
        case ready
        /// `tools.connectors.enabled: false` or `nous.guest: false` on the computer.
        case turnedOff
        /// A Hermes older than connectors (before 0.21.4).
        case needsUpdate
        case failed(String)
    }

    struct Account: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let alias: String?
        let status: String
        let isActive: Bool
        let isRetired: Bool

        var title: String { alias ?? label }
        var isWorking: Bool { status == "active" && isActive && !isRetired }
    }

    struct App: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let summary: String
        let category: String
        let logoURL: URL?
        var accounts: [Account]

        var liveAccounts: [Account] { accounts.filter { !$0.isRetired } }
        var isConnected: Bool { liveAccounts.contains(where: \.isWorking) }
    }

    private(set) var phase: Phase = .intro
    private(set) var apps: [App] = []
    private(set) var working: Set<String> = []
    var message: String?
    var search = ""

    private let service: any ConnectorAppsService
    private let scope: String
    private let defaults: UserDefaults

    init(service: any ConnectorAppsService, scope: String, defaults: UserDefaults = .standard) {
        self.service = service
        self.scope = scope
        self.defaults = defaults
    }

    var connected: [App] { filtered.filter(\.isConnected) }
    var others: [App] { filtered.filter { !$0.isConnected } }

    private var filtered: [App] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    private var setUpKey: String { "bighelp.connectors.set-up.\(scope)" }

    func appear() async {
        if defaults.bool(forKey: setUpKey) { await load() } else { phase = .intro }
    }

    /// The person asked for apps: Hermes creates the computer's connector identity if it has none.
    func setUp() async {
        phase = .loading
        do {
            _ = try await service.call("connectors.list", params: ["owner": .object(["type": .string("account")])])
            defaults.set(true, forKey: setUpKey)
            await load()
        } catch {
            fail(error)
        }
    }

    func load() async {
        if apps.isEmpty { phase = .loading }
        do {
            let catalog = try await service.call("connectors.catalog", params: [:])
            let accounts = try await service.call("connectors.accounts", params: [:])
            apps = Self.merge(catalog: catalog, accounts: accounts)
            defaults.set(true, forKey: setUpKey)
            phase = .ready
        } catch {
            fail(error)
        }
    }

    /// A sign-in in progress: the page is open (or was just closed) and Hermes is checking.
    struct SignIn: Equatable {
        let opID: String
        let appID: String
        var pageClosedAt: Date?
    }

    private(set) var signIn: SignIn?

    /// Starts a sign-in and returns the page to open. A connector that needs no sign-in comes back
    /// connected at once (nil, and the list reloads).
    func connect(_ app: App, alias: String? = nil, repairing account: Account? = nil) async -> URL? {
        guard signIn == nil, begin(app.id) else { return nil }
        defer { end(app.id) }
        var params: [String: BighelpJSONValue] = [
            "owner": .object(["type": .string("account")]), "connectors": .array([.string(app.id)]),
        ]
        if let alias { params["alias"] = .string(alias) }
        if let account {
            params["reconnect"] = .boolean(true)
            params["connection_id"] = .string(account.id)
        }
        do {
            let value = try await service.call("connectors.connect", params: params)
            guard let payload = value.object, let operation = try? ConnectorOperation(payload: payload) else {
                throw DirectHermesError.invalidResponse
            }
            if let target = operation.targets.first(where: { $0.name == app.id }), target.isOpen,
               let url = target.connectURL {
                signIn = SignIn(opID: operation.id, appID: app.id)
                return url
            }
            await load()
            return nil
        } catch {
            message = Self.sentence(for: error, fallback: "Hermes couldn't start the sign-in. Try again.")
            return nil
        }
    }

    /// The person closed the sign-in page: Hermes checks the account now instead of at its next tick.
    func pageClosed() async {
        guard let current = signIn, current.pageClosedAt == nil else { return }
        signIn?.pageClosedAt = .now
        _ = try? await service.call("connectors.operation.wake",
                                    params: ["owner": Self.accountOwner, "op_id": .string(current.opID)])
    }

    func stopWaiting() { signIn = nil }

    /// Watches the sign-in until the account shows up (true), the page was closed a few seconds ago
    /// without it, Hermes' 5 minutes pass, or the person stops waiting. Then reloads the list.
    func watchSignIn(pollInterval: Duration = .seconds(2), graceAfterClose: TimeInterval = 8) async -> Bool {
        guard let started = signIn else { return false }
        let deadline = Date.now.addingTimeInterval(300)
        var connected = false
        while let current = signIn, current.opID == started.opID, Date.now < deadline, !Task.isCancelled {
            if let value = try? await service.call("connectors.operation.status",
                                                   params: ["owner": Self.accountOwner, "op_id": .string(current.opID)]),
               let payload = value.object, let operation = try? ConnectorOperation(payload: payload) {
                let target = operation.targets.first { $0.name == current.appID }
                if target?.state == .connected { connected = true; break }
                if operation.isSettled || target?.isOpen == false { break }
            }
            if let closed = signIn?.pageClosedAt, Date.now.timeIntervalSince(closed) > graceAfterClose { break }
            try? await Task.sleep(for: pollInterval)
        }
        if signIn?.opID == started.opID { signIn = nil }
        await load()
        return connected
    }

    private static let accountOwner: BighelpJSONValue = .object(["type": .string("account")])

    func rename(_ account: Account, in app: App, to name: String) async -> Bool {
        guard let alias = Self.alias(name) else {
            message = "Use 1 to 32 lowercase letters, numbers or dashes, like work or home."
            return false
        }
        guard begin(account.id) else { return false }
        defer { end(account.id) }
        do {
            _ = try await service.call("connectors.accounts.rename",
                                       params: ["connection_id": .string(account.id), "alias": .string(alias)])
            await load()
            return true
        } catch DirectHermesError.rpcRejected(code: 4090, _) {
            message = "Another \(app.name) account already has that name."
        } catch {
            message = Self.sentence(for: error, fallback: "Hermes couldn't rename it. Try again.")
        }
        return false
    }

    func remove(_ account: Account) async {
        guard begin(account.id) else { return }
        defer { end(account.id) }
        do {
            _ = try await service.call("connectors.accounts.remove", params: ["connection_id": .string(account.id)])
            await load()
        } catch {
            message = Self.sentence(for: error, fallback: "Hermes couldn't remove it. Try again.")
        }
    }

    func isWorking(_ id: String) -> Bool { working.contains(id) }

    /// An account name the way Hermes takes it: 1–32 lowercase letters, digits or dashes.
    static func alias(_ typed: String) -> String? {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-")
        guard (1...32).contains(value.count), let first = value.unicodeScalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains) else {
            return nil
        }
        return value
    }

    static func merge(catalog: BighelpJSONValue, accounts: BighelpJSONValue) -> [App] {
        var byConnector: [String: [Account]] = [:]
        for row in (accounts.object?["accounts"]?.array ?? []).prefix(1_000) {
            guard let object = row.object, let id = object["connection_id"]?.string, !id.isEmpty,
                  let connector = object["connector"]?.string else { continue }
            let label = (object["label"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            byConnector[connector, default: []].append(Account(
                id: id, label: label.isEmpty ? "Account" : String(label.prefix(80)),
                alias: object["alias"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                status: object["status"]?.string ?? "", isActive: object["active"]?.boolean ?? false,
                isRetired: object["disabled"]?.boolean ?? false))
        }
        let info = ConnectorCardStore.apps(in: catalog)
        var apps: [App] = []
        for row in (catalog.object?["connectors"]?.array ?? []).prefix(2_000) {
            guard let object = row.object, let slug = object["slug"]?.string, let known = info[slug] else { continue }
            apps.append(App(id: slug, name: known.name,
                            summary: object["description"]?.string.map { String($0.prefix(300)) } ?? "",
                            category: object["category"]?.string.map { String($0.prefix(60)) } ?? "",
                            logoURL: known.logoURL, accounts: byConnector[slug] ?? []))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func fail(_ error: any Error) {
        switch error {
        case DirectHermesError.rpcRejected(code: -32601, _): phase = .needsUpdate
        case DirectHermesError.rpcRejected(code: 4031, _): phase = .turnedOff
        case DirectHermesError.rpcRejected(code: 4032, _):
            defaults.removeObject(forKey: setUpKey)
            phase = .intro
        default:
            phase = apps.isEmpty ? .failed(Self.sentence(for: error, fallback: "Hermes couldn't load your apps.")) : .ready
            if !apps.isEmpty { message = "Hermes couldn't refresh your apps." }
        }
    }

    private static func sentence(for error: any Error, fallback: String) -> String {
        if case DirectHermesError.rpcRejected(code: 4030, _) = error {
            return "This account can't manage apps for its organization."
        }
        return fallback
    }

    private func begin(_ id: String) -> Bool {
        guard !working.contains(id) else { return false }
        working.insert(id)
        message = nil
        return true
    }

    private func end(_ id: String) { working.remove(id) }
}

/// Demo mode: made-up apps in memory; connecting succeeds at once.
@MainActor
final class DemoConnectorAppsService: ConnectorAppsService {
    private var accounts: [[String: BighelpJSONValue]] = [
        ["connection_id": .string("demo-1"), "connector": .string("example_mail"), "status": .string("active"),
         "label": .string("sam@example.com"), "alias": .null, "active": .boolean(true), "disabled": .boolean(false),
         "created_at": .string("2026-10-01T10:00:00Z"), "updated_at": .string("2026-10-01T10:00:00Z")],
    ]

    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        switch method {
        case "connectors.list":
            return .object(["available": .boolean(true), "connectors": .array([])])
        case "connectors.catalog":
            let rows: [(String, String, String, String)] = [
                ("example_mail", "Example Mail", "Read, sort and send email.", "Communication"),
                ("example_notes", "Example Notes", "Find and write notes and pages.", "Productivity"),
                ("example_tracker", "Example Tracker", "Create and update issues.", "Developer tools"),
                ("example_calendar", "Example Calendar", "See and plan events.", "Productivity"),
            ]
            return .object(["connectors": .array(rows.map {
                .object(["slug": .string($0.0), "name": .string($0.1), "description": .string($0.2), "category": .string($0.3)])
            })])
        case "connectors.accounts":
            return .object(["accounts": .array(accounts.map(BighelpJSONValue.object))])
        case "connectors.connect":
            let slug = params["connectors"]?.array?.first?.string ?? ""
            let alias = params["alias"]?.string
            accounts.append(["connection_id": .string("demo-\(accounts.count + 1)"), "connector": .string(slug),
                             "status": .string("active"), "label": .string("sam@example.com"),
                             "alias": alias.map(BighelpJSONValue.string) ?? .null,
                             "active": .boolean(true), "disabled": .boolean(false),
                             "created_at": .string("2026-10-14T10:00:00Z"), "updated_at": .string("2026-10-14T10:00:00Z")])
            return .object(["op_id": .string("demo-op"), "seq": .integer(2), "settled": .boolean(true),
                            "deadline_at": .number(0),
                            "targets": .array([.object(["name": .string(slug), "kind": .string("connector"),
                                                        "action": .string("connect"), "state": .string("connected"),
                                                        "resolved": .boolean(true)])])])
        case "connectors.accounts.rename":
            let id = params["connection_id"]?.string
            if let index = accounts.firstIndex(where: { $0["connection_id"]?.string == id }) {
                accounts[index]["alias"] = params["alias"] ?? .null
            }
            return .object([:])
        case "connectors.accounts.remove":
            let id = params["connection_id"]?.string
            accounts.removeAll { $0["connection_id"]?.string == id }
            return .object(["status": .string("removed")])
        default:
            return .object([:])
        }
    }
}
