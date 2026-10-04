import Foundation
import Observation

/// Hermes' credential vault (`vault.*` on the host socket): logins, cards and
/// addresses an agent's browser tools fill without ever seeing the secret.
/// The vault lives on the person's computer, one per agent. bighelp only
/// passes a new item through once and never stores or reads back a secret.
@MainActor
protocol CredentialVaultService: AnyObject {
    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue
}

/// One saved item as Hermes lists it: a label and where it's used, never the
/// password, card number or address itself.
struct CredentialVaultItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case login, payment, address

        var symbol: String {
            switch self {
            case .login: "key"
            case .payment: "creditcard"
            case .address: "house"
            }
        }
    }

    let id: String
    let kind: Kind
    let label: String
    let origin: String?
    let identifier: String?
    /// "local" for Hermes' own vault, otherwise the password manager it came from.
    let source: String
    let generatesCodes: Bool

    var isLocal: Bool { source == "local" }

    init?(_ value: BighelpJSONValue) {
        guard let object = value.object,
              let id = CredentialVault.text(object["id"], maximumBytes: 256), !id.isEmpty,
              let kind = object["kind"]?.string.flatMap(Kind.init(rawValue:)),
              let label = CredentialVault.text(object["label"], maximumBytes: 512),
              let source = CredentialVault.text(object["backend"], maximumBytes: 64), !source.isEmpty else { return nil }
        self.id = id
        self.kind = kind
        self.label = label
        origin = CredentialVault.text(object["origin"], maximumBytes: 2_048).flatMap { $0.isEmpty ? nil : $0 }
        identifier = CredentialVault.text(object["identifier"], maximumBytes: 512).flatMap { $0.isEmpty ? nil : $0 }
        self.source = source
        generatesCodes = object["has_otp"]?.boolean == true
    }
}

/// A password manager Hermes can read logins from (1Password, Bitwarden, …).
struct CredentialVaultSource: Identifiable, Equatable, Sendable {
    let name: String
    let displayName: String
    let enabled: Bool
    let unlocked: Bool
    let installed: Bool

    var id: String { name }

    init?(_ value: BighelpJSONValue) {
        guard let object = value.object,
              let name = CredentialVault.text(object["name"], maximumBytes: 64), !name.isEmpty,
              let displayName = CredentialVault.text(object["display_name"], maximumBytes: 120) else { return nil }
        self.name = name
        self.displayName = displayName.isEmpty ? name : displayName
        enabled = object["enabled"]?.boolean == true
        unlocked = object["unlocked"]?.boolean == true
        installed = object["installed"]?.boolean == true
    }
}

/// A new item, typed on this device. Its secrets exist only in this value
/// until it's sent once. `label` is the name people and agents see; `sites` are
/// where an agent may use it (Hermes fills cards and addresses only on a site
/// they're linked to).
enum CredentialVaultEntry {
    case login(label: String = "", sites: [String], identifier: String, password: String, authenticatorKey: String)
    case card(label: String = "", sites: [String] = [], name: String, number: String, month: String, year: String,
              securityCode: String, postalCode: String)
    case address(label: String, sites: [String] = [], line1: String, line2: String, city: String, state: String,
                 postalCode: String, country: String)
}

/// Saved copies of one item. Hermes binds each local item to a single site, so an item used on
/// several sites is saved once per site under the same name; the vault shows them as one.
struct CredentialVaultGroup: Identifiable, Equatable {
    let items: [CredentialVaultItem]

    var id: String { items[0].id }
    var kind: CredentialVaultItem.Kind { items[0].kind }
    var label: String { items[0].label }
    var identifier: String? { items[0].identifier }
    var isLocal: Bool { items[0].isLocal }
    var source: String { items[0].source }
    var generatesCodes: Bool { items.contains(where: \.generatesCodes) }
    /// Sites by host, in the order they were saved.
    var sites: [String] {
        var seen = Set<String>()
        return items.compactMap { $0.origin.flatMap { URLComponents(string: $0)?.host ?? $0 } }
            .filter { seen.insert($0).inserted }
    }
    /// Whether an agent can use it at all: cards and addresses need a site.
    var isUsable: Bool { kind == .login || !sites.isEmpty }

    /// The name as typed, without what bighelp adds ("ending 4242", a login's default host).
    var typedLabel: String {
        switch kind {
        case .payment:
            guard let range = label.range(of: #" ?ending \d{4}$"#, options: .regularExpression) else { return label }
            let name = String(label[..<range.lowerBound])
            return name == "Card" ? "" : name
        case .login: return sites.first == label ? "" : label
        case .address: return label == "Address" ? "" : label
        }
    }

    var kindTitle: String {
        switch kind {
        case .login: "Login"
        case .payment: "Card"
        case .address: "Address"
        }
    }

    /// Local copies with the same kind, name and username are one item; anything from a password
    /// manager stays as it is.
    static func grouped(_ items: [CredentialVaultItem]) -> [CredentialVaultGroup] {
        var order: [String] = []
        var groups: [String: [CredentialVaultItem]] = [:]
        for item in items {
            let key = item.isLocal ? "\(item.kind.rawValue)\u{1F}\(item.label)\u{1F}\(item.identifier ?? "")" : "id:" + item.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.compactMap { groups[$0].map(CredentialVaultGroup.init(items:)) }
    }
}

enum CredentialVault {
    /// `scheme://host[:port]` for what someone typed ("example.com",
    /// "https://example.com/login"), or nil when it isn't a web address.
    static func origin(from typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let parts = URLComponents(string: withScheme),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), host.contains(".") || host == "localhost",
              parts.user == nil, parts.password == nil else { return nil }
        return scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
    }

    static let maximumSites = 10

    /// The sites typed, as origins without repeats; empty boxes are skipped.
    static func origins(from sites: [String]) -> Result<[String], EntryProblem> {
        var origins: [String] = []
        for typed in sites where !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let origin = origin(from: typed) else { return .failure(.site) }
            if !origins.contains(origin) { origins.append(origin) }
        }
        guard origins.count <= maximumSites else { return .failure(.tooManySites) }
        return .success(origins)
    }

    /// What Hermes stores for a new item, one request per site, or a plain reason it can't be saved.
    static func requests(for entry: CredentialVaultEntry) -> Result<[[String: BighelpJSONValue]], EntryProblem> {
        func field(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func named(_ label: String, limit: Int = 120) -> String? {
            let name = field(label)
            return name.isEmpty ? nil : String(name.prefix(limit))
        }
        func perSite(_ base: [String: BighelpJSONValue], _ sites: [String]) -> Result<[[String: BighelpJSONValue]], EntryProblem> {
            Self.origins(from: sites).map { targets in
                targets.isEmpty ? [base] : targets.map { base.merging(["origin": .string($0)]) { _, new in new } }
            }
        }
        switch entry {
        case .login(let label, let sites, let identifier, let password, let authenticatorKey):
            let targets: [String]
            switch Self.origins(from: sites) {
            case .success(let value): targets = value
            case .failure(let problem): return .failure(problem)
            }
            guard let first = targets.first else { return .failure(.site) }
            let name = field(identifier)
            guard !name.isEmpty, name.utf8.count <= 512 else { return .failure(.identifier) }
            guard !password.isEmpty, password.utf8.count <= 4_096 else { return .failure(.password) }
            let type = name.contains("@") ? "email"
                : name.drop(while: { $0 == "+" }).allSatisfy(\.isNumber) ? "phone" : "username"
            var secret: [String: BighelpJSONValue] = [
                "identifier_type": .string(type), "identifier": .string(name), "password": .string(password),
            ]
            let key = field(authenticatorKey)
            if !key.isEmpty {
                guard key.utf8.count <= 2_048 else { return .failure(.authenticatorKey) }
                secret["otp_secret"] = .string(key)
            }
            let title = named(label) ?? URLComponents(string: first)?.host ?? first
            return .success(targets.map { ["kind": .string("login"), "label": .string(title), "origin": .string($0),
                                           "secret": .object(secret)] })
        case .card(let label, let sites, let name, let number, let month, let year, let securityCode, let postalCode):
            let digits = number.filter(\.isNumber)
            guard (12...19).contains(digits.count), digits.count == number.filter({ !$0.isWhitespace && $0 != "-" }).count
            else { return .failure(.cardNumber) }
            guard let monthValue = Int(field(month)), (1...12).contains(monthValue) else { return .failure(.expiry) }
            var yearValue = Int(field(year)) ?? 0
            if (0...99).contains(yearValue) { yearValue += 2000 }
            guard (2000...2100).contains(yearValue) else { return .failure(.expiry) }
            let code = field(securityCode)
            guard (3...4).contains(code.count), code.allSatisfy(\.isNumber) else { return .failure(.securityCode) }
            var secret: [String: BighelpJSONValue] = [
                "card_number": .string(digits), "exp_month": .string(String(format: "%02d", monthValue)),
                "exp_year": .string(String(yearValue)), "cvc": .string(code),
            ]
            if !field(name).isEmpty { secret["cardholder_name"] = .string(String(field(name).prefix(200))) }
            if !field(postalCode).isEmpty { secret["billing_postal_code"] = .string(String(field(postalCode).prefix(20))) }
            // The last digits stay in the name so the person and Hermes' "fill this card?" know which card.
            let title = "\(named(label, limit: 100) ?? "Card") ending \(digits.suffix(4))"
            return perSite(["kind": .string("payment"), "label": .string(title), "secret": .object(secret)], sites)
        case .address(let label, let sites, let line1, let line2, let city, let state, let postalCode, let country):
            let required = [field(line1), field(city), field(postalCode), field(country)]
            guard required.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 300 }) else { return .failure(.address) }
            var secret: [String: BighelpJSONValue] = [
                "address_line1": .string(required[0]), "city": .string(required[1]),
                "postal_code": .string(required[2]), "country": .string(required[3]),
            ]
            if !field(line2).isEmpty { secret["address_line2"] = .string(String(field(line2).prefix(300))) }
            if !field(state).isEmpty { secret["state"] = .string(String(field(state).prefix(100))) }
            return perSite(["kind": .string("address"), "label": .string(named(label) ?? "Address"),
                            "secret": .object(secret)], sites)
        }
    }

    enum EntryProblem: Error, Equatable {
        case site, tooManySites, identifier, password, authenticatorKey, cardNumber, expiry, securityCode, address

        var message: String {
            switch self {
            case .site: "Enter each site's address, like example.com."
            case .tooManySites: "Link up to \(CredentialVault.maximumSites) sites."
            case .identifier: "Enter the email or username you sign in with."
            case .password: "Enter the password."
            case .authenticatorKey: "That authenticator key is too long."
            case .cardNumber: "Enter the card number."
            case .expiry: "Enter the expiry month and year."
            case .securityCode: "Enter the 3 or 4 digit security code."
            case .address: "Enter the street, city, postal code and country."
            }
        }
    }

    static func text(_ value: BighelpJSONValue?, maximumBytes: Int) -> String? {
        guard let value, value != .null else { return "" }
        guard let text = value.string, text.utf8.count <= maximumBytes,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return text
    }
}

/// The vault screen's state for one agent on the selected host.
@MainActor
@Observable
final class CredentialVaultModel: Identifiable {
    enum State: Equatable {
        case loading, ready, unsupported, failed
    }

    struct Agent: Identifiable, Equatable {
        let id: String
        let name: String
    }

    let id = UUID()
    let agents: [Agent]
    private(set) var agentID: String
    private(set) var items: [CredentialVaultItem] = []
    private(set) var sources: [CredentialVaultSource] = []
    private(set) var state = State.loading
    private(set) var isWorking = false
    var message: String?
    @ObservationIgnored private let service: any CredentialVaultService

    init(service: any CredentialVaultService, agents: [Agent], agentID: String) {
        self.service = service
        self.agents = agents
        self.agentID = agents.contains { $0.id == agentID } ? agentID : agents.first?.id ?? "default"
    }

    var agentName: String { agents.first { $0.id == agentID }?.name ?? agentID }
    /// Password managers found on the computer; the Hermes vault itself is always on.
    var managers: [CredentialVaultSource] { sources.filter { $0.name != "local" && $0.installed } }

    func select(agentID: String) async {
        guard agentID != self.agentID, agents.contains(where: { $0.id == agentID }) else { return }
        self.agentID = agentID
        items = []
        sources = []
        await load()
    }

    func load() async {
        if items.isEmpty && sources.isEmpty { state = .loading }
        let agent = agentID
        do {
            let listed = try await service.call("vault.list", params: profile)
            let found = try await service.call("vault.sources", params: profile)
            guard agent == agentID else { return }
            items = (listed.object?["items"]?.array ?? []).prefix(500).compactMap(CredentialVaultItem.init)
                .sorted { ($0.isLocal ? 0 : 1, $0.label.lowercased()) < ($1.isLocal ? 0 : 1, $1.label.lowercased()) }
            sources = (found.object?["sources"]?.array ?? []).prefix(32).compactMap(CredentialVaultSource.init)
            state = .ready
        } catch {
            guard agent == agentID else { return }
            state = Self.isUnsupported(error) ? .unsupported : .failed
        }
    }

    var groups: [CredentialVaultGroup] { CredentialVaultGroup.grouped(items) }

    /// Sends a new item once per site. Editing replaces the old copies, which go only after every new
    /// one is saved, so a failed edit never loses what was there. Returns whether all were saved.
    func save(_ entry: CredentialVaultEntry, replacing old: CredentialVaultGroup? = nil) async -> Bool {
        guard !isWorking else { return false }
        let requests: [[String: BighelpJSONValue]]
        switch CredentialVault.requests(for: entry) {
        case .success(let value): requests = value
        case .failure(let problem):
            message = problem.message
            return false
        }
        isWorking = true
        defer { isWorking = false }
        var saved = 0
        for request in requests {
            do {
                _ = try await service.call("vault.add", params: profile.merging(request) { _, new in new })
                saved += 1
            } catch {
                message = Self.isUnsupported(error)
                    ? "This needs a newer Hermes on your computer."
                    : saved == 0 ? "Hermes couldn't save that. Check the details and try again."
                    : "Saved for \(saved) of \(requests.count) sites. Try the rest again."
                await load()
                return false
            }
        }
        if let old {
            for item in old.items where item.isLocal {
                _ = try? await service.call("vault.remove", params: profile.merging(["id": .string(item.id)]) { _, new in new })
            }
        }
        message = nil
        await load()
        return true
    }

    func remove(_ group: CredentialVaultGroup) async {
        for item in group.items { await remove(item) }
    }

    private(set) var importProgress: (done: Int, total: Int)?

    /// Saves imported logins one by one. A login whose authenticator key Hermes
    /// refuses is saved without it rather than dropped.
    func importLogins(_ logins: [CredentialVaultImport.Login]) async -> (imported: Int, failed: Int) {
        guard !isWorking, !logins.isEmpty else { return (0, 0) }
        isWorking = true
        defer { isWorking = false; importProgress = nil }
        var imported = 0
        var failed = 0
        importProgress = (0, logins.count)
        for login in logins {
            var keys = [login.authenticatorKey]
            if !login.authenticatorKey.isEmpty { keys.append("") }
            var saved = false
            for key in keys where !saved {
                guard case .success(let requests) = CredentialVault.requests(for: .login(sites: [login.origin],
                    identifier: login.identifier, password: login.password, authenticatorKey: key)),
                      let request = requests.first else { continue }
                saved = (try? await service.call("vault.add", params: profile.merging(request) { _, new in new })) != nil
            }
            if saved { imported += 1 } else { failed += 1 }
            importProgress = (imported + failed, logins.count)
        }
        message = nil
        await load()
        return (imported, failed)
    }

    func remove(_ item: CredentialVaultItem) async {
        guard item.isLocal, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.call("vault.remove", params: profile.merging(["id": .string(item.id)]) { _, new in new })
            items.removeAll { $0.id == item.id }
        } catch {
            message = "Hermes couldn't remove that. Try again."
        }
    }

    func setEnabled(_ source: CredentialVaultSource, _ enabled: Bool) async {
        await run("vault.source.set", ["name": .string(source.name), "enabled": .boolean(enabled)],
                  failure: "Hermes couldn't change \(source.displayName). Try again.")
    }

    /// The master password goes to the manager on the computer once and is dropped.
    func unlock(_ source: CredentialVaultSource, password: String) async -> Bool {
        guard !password.isEmpty, password.utf8.count <= 4_096 else { return false }
        return await run("vault.unlock", ["name": .string(source.name), "password": .string(password)],
                         failure: "That didn't unlock \(source.displayName). Check the master password.")
    }

    func lock(_ source: CredentialVaultSource) async {
        await run("vault.lock", ["name": .string(source.name)], failure: "Hermes couldn't lock \(source.displayName).")
    }

    @discardableResult
    private func run(_ method: String, _ params: [String: BighelpJSONValue], failure: String) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.call(method, params: profile.merging(params) { _, new in new })
            message = nil
            await load()
            return true
        } catch {
            message = failure
            return false
        }
    }

    private var profile: [String: BighelpJSONValue] { ["profile": .string(agentID)] }

    private static func isUnsupported(_ error: any Error) -> Bool {
        if case DirectHermesError.rpcRejected(code: -32601)? = error as? DirectHermesError { return true }
        return false
    }
}

/// The selected host's own vault, over its authenticated socket.
@MainActor
final class DirectHermesCredentialVaultService: CredentialVaultService {
    private let workspace: DirectHermesWorkspaceStore

    init(workspace: DirectHermesWorkspaceStore) { self.workspace = workspace }

    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        try await workspace.vaultRequest(method, params: params)
    }
}

/// Demo mode: made-up items in memory, never a real secret.
@MainActor
final class DemoCredentialVaultService: CredentialVaultService {
    private var items: [BighelpJSONValue] = [
        .object(["id": .string("demo-login"), "kind": .string("login"), "label": .string("example.com"),
                 "origin": .string("https://example.com"), "identifier": .string("sam@example.com"),
                 "backend": .string("local"), "has_otp": .boolean(true)]),
        .object(["id": .string("demo-address"), "kind": .string("address"), "label": .string("Home"),
                 "origin": .string("https://shop.example.org"), "backend": .string("local")]),
        .object(["id": .string("demo-card-1"), "kind": .string("payment"), "label": .string("Everyday Visa ending 4242"),
                 "origin": .string("https://shop.example.org"), "backend": .string("local")]),
        .object(["id": .string("demo-card-2"), "kind": .string("payment"), "label": .string("Everyday Visa ending 4242"),
                 "origin": .string("https://parts.example.net"), "backend": .string("local")]),
        .object(["id": .string("demo-card-3"), "kind": .string("payment"), "label": .string("Card ending 1881"),
                 "backend": .string("local")]),
    ]
    private var managerUnlocked = false
    private var managerEnabled = true

    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        switch method {
        case "vault.list":
            let manager: [BighelpJSONValue] = managerUnlocked && managerEnabled ? [
                .object(["id": .string("demo-manager"), "kind": .string("login"), "label": .string("shop.example.org"),
                         "origin": .string("https://shop.example.org"), "identifier": .string("sam"),
                         "backend": .string("onepassword")]),
            ] : []
            return .object(["items": .array(items + manager)])
        case "vault.sources":
            return .object(["sources": .array([
                .object(["name": .string("local"), "display_name": .string("Hermes vault"), "enabled": .boolean(true),
                         "needs_unlock": .boolean(false), "unlocked": .boolean(true), "installed": .boolean(true)]),
                .object(["name": .string("onepassword"), "display_name": .string("1Password"),
                         "enabled": .boolean(managerEnabled), "needs_unlock": .boolean(true),
                         "unlocked": .boolean(managerUnlocked), "installed": .boolean(true)]),
                .object(["name": .string("bitwarden"), "display_name": .string("Bitwarden"), "enabled": .boolean(false),
                         "needs_unlock": .boolean(true), "unlocked": .boolean(false), "installed": .boolean(false)]),
            ])])
        case "vault.add":
            let id = "demo-" + UUID().uuidString.prefix(8).lowercased()
            var item: [String: BighelpJSONValue] = ["id": .string(id), "kind": params["kind"] ?? .string("login"),
                "label": params["label"] ?? .string("Item"), "backend": .string("local")]
            if let origin = params["origin"] { item["origin"] = origin }
            if let secret = params["secret"]?.object {
                item["identifier"] = secret["identifier"]
                item["has_otp"] = .boolean(secret["otp_secret"] != nil)
            }
            items.append(.object(item))
            return .object(["id": .string(id)])
        case "vault.remove":
            let id = params["id"]?.string
            items.removeAll { $0.object?["id"]?.string == id }
            return .object(["removed": .boolean(true)])
        case "vault.source.set":
            managerEnabled = params["enabled"]?.boolean == true
            if !managerEnabled { managerUnlocked = false }
            return .object(["name": params["name"] ?? .null, "enabled": .boolean(managerEnabled)])
        case "vault.unlock":
            managerUnlocked = true
            return .object(["name": params["name"] ?? .null, "unlocked": .boolean(true)])
        case "vault.lock":
            managerUnlocked = false
            return .object(["locked": .boolean(true)])
        default:
            throw DirectHermesError.rpcRejected(code: -32601)
        }
    }
}
