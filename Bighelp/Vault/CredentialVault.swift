import Foundation
import Observation

/// Hermes' credential vault (`vault.*` on the host socket): logins, cards and
/// addresses an agent's browser tools fill without ever seeing the secret.
/// The vault lives on the person's computer, one per agent. bighelp only
/// passes a new item through once and never stores or reads back a secret.
@MainActor
protocol CredentialVaultService: AnyObject {
    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue
    /// Whether the computer can copy a saved card or address to more websites (the plugin's
    /// `vault/link`, `native-vault-link-v1`); nil when it couldn't be asked just now.
    func canLink() async -> Bool?
    /// The plugin's `vault/link`: copies saved local cards and addresses to more websites on the
    /// computer, so their numbers never come to the phone.
    func link(_ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]
}

extension CredentialVaultService {
    func canLink() async -> Bool? { false }

    func link(_ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
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
    /// Hermes keeps it for no website. An origin the app couldn't read isn't this.
    let hasNoOrigin: Bool
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
        hasNoOrigin = object["origin"] == nil || object["origin"] == .null || object["origin"]?.string == ""
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

    /// The same for every copy, so it stays put while copies come and go.
    var id: String { Self.key(items[0]) }
    var firstItemID: String { items[0].id }
    var kind: CredentialVaultItem.Kind { items[0].kind }
    var label: String { items[0].label }
    var identifier: String? { items[0].identifier }
    var isLocal: Bool { items[0].isLocal }
    var source: String { items[0].source }
    var generatesCodes: Bool { items.contains(where: \.generatesCodes) }
    /// The copies' websites as Hermes keeps them (`https://example.com`), in the order they were saved.
    var origins: [String] {
        var seen = Set<String>()
        return items.compactMap(\.origin).filter { seen.insert($0).inserted }
    }
    /// Sites by host, in the order they were saved.
    var sites: [String] {
        var seen = Set<String>()
        return origins.map(CredentialVault.siteName).filter { seen.insert($0).inserted }
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

    /// A card's last four digits, which bighelp keeps in its name.
    var lastDigits: String? {
        guard kind == .payment, let range = label.range(of: #"\d{4}$"#, options: .regularExpression) else { return nil }
        return String(label[range])
    }

    var kindTitle: String {
        switch kind {
        case .login: String(localized: "Login")
        case .payment: String(localized: "Card")
        case .address: String(localized: "Address")
        }
    }

    /// Local copies with the same kind, name and username are one item; anything from a password
    /// manager stays as it is.
    static func grouped(_ items: [CredentialVaultItem]) -> [CredentialVaultGroup] {
        var order: [String] = []
        var groups: [String: [CredentialVaultItem]] = [:]
        for item in items {
            let key = key(item)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.compactMap { groups[$0].map(CredentialVaultGroup.init(items:)) }
    }

    private static func key(_ item: CredentialVaultItem) -> String {
        item.isLocal ? "\(item.kind.rawValue)\u{1F}\(item.label)\u{1F}\(item.identifier ?? "")" : "id:" + item.id
    }
}

/// One website and everything an agent may use there: its login, cards and addresses. Hermes keeps
/// a copy of an item for each website, so a website lists the copies saved for it.
struct CredentialVaultSite: Identifiable, Equatable {
    let origin: String
    let items: [CredentialVaultItem]

    var id: String { origin }
    var name: String { CredentialVault.siteName(origin) }
    var logins: [CredentialVaultItem] { items.filter { $0.kind == .login } }
    var cards: [CredentialVaultItem] { items.filter { $0.kind == .payment } }
    var addresses: [CredentialVaultItem] { items.filter { $0.kind == .address } }
    /// The kinds saved here, login first.
    var kinds: [CredentialVaultItem.Kind] {
        [.login, .payment, .address].filter { kind in items.contains { $0.kind == kind } }
    }
    /// Only Hermes' own copies can be removed here; a password manager's stay in the manager.
    var hasLocalItems: Bool { items.contains(where: \.isLocal) }

    /// Every website with something saved for it, by name.
    static func grouped(_ items: [CredentialVaultItem]) -> [CredentialVaultSite] {
        var order: [String] = []
        var bySite: [String: [CredentialVaultItem]] = [:]
        for item in items {
            guard let origin = item.origin else { continue }
            if bySite[origin] == nil { order.append(origin) }
            bySite[origin, default: []].append(item)
        }
        return order.compactMap { origin in
            bySite[origin].map { items in
                CredentialVaultSite(origin: origin, items: [.login, .payment, .address].flatMap { kind in
                    items.filter { $0.kind == kind }
                })
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum CredentialVault {
    /// The plugin route that copies saved cards and addresses to more websites.
    static let linkFeature = "native-vault-link-v1"

    /// `scheme://host[:port]` for what someone typed ("example.com",
    /// "https://example.com/login"), or nil when it isn't a web address. A default port is left
    /// out, as Hermes leaves it out.
    static func origin(from typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let parts = URLComponents(string: withScheme),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), host.contains(".") || host == "localhost",
              parts.user == nil, parts.password == nil else { return nil }
        let port = parts.port.flatMap { (scheme == "https" && $0 == 443) || (scheme == "http" && $0 == 80) ? nil : $0 }
        return scheme + "://" + host + (port.map { ":\($0)" } ?? "")
    }

    /// How a website reads on screen: its host, with a port when it has one.
    static func siteName(_ origin: String) -> String {
        guard let parts = URLComponents(string: origin), let host = parts.host else { return origin }
        return host + (parts.port.map { ":\($0)" } ?? "")
    }

    /// A website as someone would type it back: the site's name, or the whole origin when it isn't https.
    static func typedSite(_ origin: String) -> String {
        origin.hasPrefix("https://") ? siteName(origin) : origin
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
            let title = named(label) ?? siteName(first)
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
            case .site: String(localized: "Enter each site's address, like example.com.")
            case .tooManySites: String(localized: "Link up to \(CredentialVault.maximumSites) sites.")
            case .identifier: String(localized: "Enter the email or username you sign in with.")
            case .password: String(localized: "Enter the password.")
            case .authenticatorKey: String(localized: "That authenticator key is too long.")
            case .cardNumber: String(localized: "Enter the card number.")
            case .expiry: String(localized: "Enter the expiry month and year.")
            case .securityCode: String(localized: "Enter the 3 or 4 digit security code.")
            case .address: String(localized: "Enter the street, city, postal code and country.")
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
    /// The computer copies saved cards and addresses to more websites itself (plugin `vault/link`).
    private(set) var canLink = false
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
            let links = await service.canLink()
            guard agent == agentID else { return }
            items = (listed.object?["items"]?.array ?? []).prefix(500).compactMap(CredentialVaultItem.init)
                .sorted { ($0.isLocal ? 0 : 1, $0.label.lowercased()) < ($1.isLocal ? 0 : 1, $1.label.lowercased()) }
            sources = (found.object?["sources"]?.array ?? []).prefix(32).compactMap(CredentialVaultSource.init)
            // A check that couldn't reach the plugin keeps what the last one found.
            canLink = links ?? canLink
            state = .ready
        } catch {
            guard agent == agentID else { return }
            state = Self.isUnsupported(error) ? .unsupported : .failed
        }
    }

    var groups: [CredentialVaultGroup] { CredentialVaultGroup.grouped(items) }
    /// Every website with something saved for it.
    var sites: [CredentialVaultSite] { CredentialVaultSite.grouped(items) }
    /// Saved cards, then addresses: one each, however many websites use it.
    var wallet: [CredentialVaultGroup] {
        let saved = groups.filter(\.isLocal)
        return saved.filter { $0.kind == .payment } + saved.filter { $0.kind == .address }
    }

    func group(_ id: String) -> CredentialVaultGroup? { groups.first { $0.id == id } }
    func site(_ origin: String) -> CredentialVaultSite? { sites.first { $0.origin == origin } }

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
                try await add(request)
                saved += 1
            } catch {
                message = Self.isUnsupported(error)
                    ? String(localized: "This needs a newer Hermes on your computer.")
                    : saved == 0 ? String(localized: "Hermes couldn't save that. Check the details and try again.")
                    : String(localized: "Saved for \(saved) of \(requests.count) sites. Try the rest again.")
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

    /// Stores one copy (`vault.add`) for this agent. Add a Website checks every part first and
    /// calls this once per part and website.
    func add(_ request: [String: BighelpJSONValue]) async throws {
        _ = try await service.call("vault.add", params: profile.merging(request) { _, new in new })
    }

    /// Copies a saved card or address to more websites on the computer; it's never typed again.
    /// Its copies without a website go once it has one, since an agent can't use them anywhere.
    func link(_ group: CredentialVaultGroup, to origins: [String]) async throws {
        let missing = origins.filter { !group.origins.contains($0) }
        guard !missing.isEmpty else { return }
        guard group.kind != .login, let source = group.items.first(where: \.isLocal) else {
            throw WorkspaceClientError.invalidRequest
        }
        let reply = try await service.link(profile.merging([
            "item_ids": .array([.string(source.id)]), "origins": .array(missing.map(BighelpJSONValue.string)),
        ]) { _, new in new })
        // Hermes writes the website its own way; both sides are compared as the app writes them.
        let copied = Set((reply["copies"]?.array ?? []).compactMap { copy -> String? in
            guard let row = copy.object, row["item_id"]?.string == source.id,
                  ["created", "existing"].contains(row["status"]?.string ?? "") else { return nil }
            return row["origin"]?.string.flatMap(CredentialVault.origin(from:))
        })
        guard missing.allSatisfy(copied.contains) else { throw WorkspaceClientError.invalidResponse }
        for item in group.items where item.isLocal && item.hasNoOrigin {
            _ = try? await service.call("vault.remove", params: profile.merging(["id": .string(item.id)]) { _, new in new })
        }
    }

    /// A saved card's or address's page: Use on another website.
    func use(_ group: CredentialVaultGroup, on typed: String) async -> Bool {
        guard !isWorking else { return false }
        guard let origin = CredentialVault.origin(from: typed) else {
            message = CredentialVault.EntryProblem.site.message
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await link(group, to: [origin])
            message = nil
            await load()
            return true
        } catch {
            message = Self.linkFailure(error)
            await load()
            return false
        }
    }

    /// What to say when copying to a website failed.
    static func linkFailure(_ error: any Error) -> String {
        switch error {
        case WorkspaceClientError.unavailable:
            String(localized: "Update the bighelp plugin on your computer to use this on another website.")
        default:
            String(localized: "Your computer didn't add the website. Try again.")
        }
    }

    /// Stops using a card or address on one website. Its last website stays: removing that copy
    /// removes the card or address, which Remove does with a question first.
    func stop(_ group: CredentialVaultGroup, on origin: String) async {
        guard group.origins.count > 1 else { return }
        for item in group.items where item.isLocal && item.origin == origin { await remove(item) }
    }

    /// Removes Hermes' own copies for a website. A card or address used only there goes with it.
    /// False when one of them couldn't be removed; `message` says so.
    @discardableResult
    func remove(_ site: CredentialVaultSite) async -> Bool {
        var removed = true
        for item in site.items where item.isLocal { removed = await remove(item) && removed }
        return removed
    }

    @discardableResult
    func remove(_ group: CredentialVaultGroup) async -> Bool {
        var removed = true
        for item in group.items where item.isLocal { removed = await remove(item) && removed }
        return removed
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
                saved = (try? await add(request)) != nil
            }
            if saved { imported += 1 } else { failed += 1 }
            importProgress = (imported + failed, logins.count)
        }
        message = nil
        await load()
        return (imported, failed)
    }

    @discardableResult
    func remove(_ item: CredentialVaultItem) async -> Bool {
        guard item.isLocal, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.call("vault.remove", params: profile.merging(["id": .string(item.id)]) { _, new in new })
            items.removeAll { $0.id == item.id }
            return true
        } catch {
            message = String(localized: "Hermes couldn't remove that. Try again.")
            return false
        }
    }

    func setEnabled(_ source: CredentialVaultSource, _ enabled: Bool) async {
        await run("vault.source.set", ["name": .string(source.name), "enabled": .boolean(enabled)],
                  failure: String(localized: "Hermes couldn't change \(source.displayName). Try again."))
    }

    /// The master password goes to the manager on the computer once and is dropped.
    func unlock(_ source: CredentialVaultSource, password: String) async -> Bool {
        guard !password.isEmpty, password.utf8.count <= 4_096 else { return false }
        return await run("vault.unlock", ["name": .string(source.name), "password": .string(password)],
                         failure: String(localized: "That didn't unlock \(source.displayName). Check the master password."))
    }

    func lock(_ source: CredentialVaultSource) async {
        await run("vault.lock", ["name": .string(source.name)],
                  failure: String(localized: "Hermes couldn't lock \(source.displayName)."))
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

    static func isUnsupported(_ error: any Error) -> Bool {
        if case DirectHermesError.rpcRejected(code: -32601, _)? = error as? DirectHermesError { return true }
        return false
    }
}

/// The selected host's own vault, over its authenticated socket, and the plugin's `vault/link`
/// on the same computer.
@MainActor
final class DirectHermesCredentialVaultService: CredentialVaultService {
    private let workspace: DirectHermesWorkspaceStore
    private let plugin: @MainActor () -> DirectHermesWorkspaceClient?

    init(workspace: DirectHermesWorkspaceStore, plugin: @escaping @MainActor () -> DirectHermesWorkspaceClient?) {
        self.workspace = workspace
        self.plugin = plugin
    }

    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        try await workspace.vaultRequest(method, params: params)
    }

    func canLink() async -> Bool? {
        guard let client = plugin(), let owner = client.owner else { return nil }
        if client.nativeContext == nil {
            do {
                _ = try await client.perform(.nativeContext, payload: [:], owner: owner)
            } catch WorkspaceClientError.unavailable {
                return false
            } catch {
                return nil
            }
        }
        return client.nativeContext.map { $0.features.contains(CredentialVault.linkFeature) }
    }

    func link(_ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard let client = plugin(), let owner = client.owner else { throw WorkspaceClientError.transportUnavailable }
        do {
            return try await client.perform(.vaultLink, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            return try await client.perform(.vaultLink, payload: payload, owner: owner)
        } catch WorkspaceClientError.outcomeUnknown {
            // A copy that's already there comes back as "existing", so asking again is safe.
            return try await client.perform(.vaultLink, payload: payload, owner: owner)
        }
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
        .object(["id": .string("demo-address-2"), "kind": .string("address"), "label": .string("Home"),
                 "origin": .string("https://parts.example.net"), "backend": .string("local")]),
        .object(["id": .string("demo-card-1"), "kind": .string("payment"), "label": .string("Everyday Visa ending 4242"),
                 "origin": .string("https://shop.example.org"), "backend": .string("local")]),
        .object(["id": .string("demo-card-2"), "kind": .string("payment"), "label": .string("Everyday Visa ending 4242"),
                 "origin": .string("https://parts.example.net"), "backend": .string("local")]),
        .object(["id": .string("demo-card-3"), "kind": .string("payment"), "label": .string("Card ending 1881"),
                 "backend": .string("local")]),
    ]
    private var managerUnlocked = false
    private var managerEnabled = true
    var linksItems = true

    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        switch method {
        case "vault.list":
            let manager: [BighelpJSONValue] = managerUnlocked && managerEnabled ? [
                .object(["id": .string("demo-manager"), "kind": .string("login"), "label": .string("mail.example.com"),
                         "origin": .string("https://mail.example.com"), "identifier": .string("sam"),
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

    func canLink() async -> Bool? { linksItems }

    /// The plugin's `vault/link`, the way it answers: one row per item and website, `existing`
    /// for a copy that's already there.
    func link(_ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard linksItems else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
        let ids = payload["item_ids"]?.array?.compactMap(\.string) ?? []
        let origins = payload["origins"]?.array?.compactMap(\.string) ?? []
        var copies: [BighelpJSONValue] = []
        for id in ids {
            guard let source = items.first(where: { $0.object?["id"]?.string == id })?.object,
                  source["kind"]?.string != "login" else {
                throw WorkspaceClientError.rejected(code: "not_copyable")
            }
            for origin in origins {
                let same = items.first { row in
                    let row = row.object
                    return row?["kind"] == source["kind"] && row?["label"] == source["label"]
                        && row?["origin"]?.string == origin
                }
                if let same, let existing = same.object?["id"] {
                    copies.append(.object(["item_id": .string(id), "origin": .string(origin), "id": existing,
                                           "status": .string("existing")]))
                    continue
                }
                let copy = "demo-" + UUID().uuidString.prefix(8).lowercased()
                var row = source
                row["id"] = .string(copy)
                row["origin"] = .string(origin)
                items.append(.object(row))
                copies.append(.object(["item_id": .string(id), "origin": .string(origin), "id": .string(copy),
                                       "status": .string("created")]))
            }
        }
        return ["copies": .array(copies)]
    }
}
