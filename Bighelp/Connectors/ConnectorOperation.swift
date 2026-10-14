import Foundation

/// One `manage_connections` operation as Hermes sends it: the `connection.request` event that opens
/// the card, each `connection.update`, `connectors.operation.status` and a resumed chat's
/// `pending_connection`. Every frame carries the whole snapshot, so the card shows what the newest
/// frame says and never works state out for itself. Hermes 0.21.4 and later; older hosts used
/// `mcp.setup` (`DirectHermesSecurePrompt`).
struct ConnectorOperation: Equatable, Sendable {
    enum TargetKind: String, Sendable {
        /// An app account through Hermes' hosted connectors.
        case connector
        /// A local MCP server from Hermes' catalog.
        case mcp
        /// Catalog rows only Hermes Desktop draws (`manage_catalog`).
        case plugin, skill
        case other
    }

    enum Action: String, Sendable {
        case connect, reconnect, install, enable, authorize, other
    }

    enum State: String, Sendable {
        case pending, initiated, connected, skipped, failed, expired
        case notConnected = "not_connected"
        case other
    }

    /// A value an MCP install still needs; sent back only with the approval.
    struct EnvironmentField: Equatable, Sendable, Identifiable {
        let name: String
        let isRequired: Bool
        let isSecret: Bool
        let defaultValue: String
        let prompt: String?
        var id: String { name }
    }

    struct Target: Equatable, Sendable, Identifiable {
        let name: String
        let kind: TargetKind
        let action: Action
        let state: State
        /// Hermes' own word that the row needs nothing more from the person.
        let isResolved: Bool
        let detail: String?
        let instructions: String?
        /// The sign-in page. Only https; it's a vendor page the person opens.
        let connectURL: URL?
        let alias: String?
        let requiredEnvironment: [EnvironmentField]
        let tools: [String]

        var id: String { name }

        /// Still waiting on the person: connect, approve, retry or skip.
        var isOpen: Bool {
            !isResolved && [.pending, .initiated, .failed, .expired].contains(state)
        }

        /// The link expired or the sign-in failed; Hermes mints a new one on Try again.
        var canRetry: Bool { [.failed, .expired].contains(state) && !isResolved }
    }

    let id: String
    let sequence: Int
    let deadline: Date?
    let timeout: TimeInterval?
    let toolCallID: String?
    let isSettled: Bool
    let targets: [Target]
    /// Hermes Desktop's app directory card; it has no targets and isn't drawn here.
    let isDisplay: Bool

    var openTargets: [Target] { targets.filter(\.isOpen) }

    static let maximumTargets = 32

    init(payload: [String: BighelpJSONValue]) throws {
        guard let id = payload["op_id"]?.string, Self.valid(id, maximumBytes: 128),
              let sequence = payload["seq"].flatMap(Self.integer),
              let rawTargets = payload["targets"]?.array, rawTargets.count <= Self.maximumTargets else {
            throw DirectHermesError.invalidResponse
        }
        self.id = id
        self.sequence = sequence
        deadline = payload["deadline_at"].flatMap(Self.number).map(Date.init(timeIntervalSince1970:))
        timeout = payload["timeout_seconds"].flatMap(Self.number)
        toolCallID = payload["tool_call_id"]?.string.flatMap { Self.valid($0, maximumBytes: 256) ? $0 : nil }
        if let settled = payload["settled"]?.boolean {
            isSettled = settled
        } else {
            isSettled = payload["settled_at"].flatMap(Self.number) != nil
        }
        isDisplay = payload["display"]?.object != nil
        var seen = Set<String>()
        targets = try rawTargets.map { value in
            guard let object = value.object else { throw DirectHermesError.invalidResponse }
            let target = try Self.target(object)
            guard seen.insert(target.name).inserted else { throw DirectHermesError.invalidResponse }
            return target
        }
    }

    private static func target(_ object: [String: BighelpJSONValue]) throws -> Target {
        guard let name = object["name"]?.string, valid(name, maximumBytes: 128) else {
            throw DirectHermesError.invalidResponse
        }
        let state = object["state"]?.string.flatMap(State.init(rawValue:)) ?? .other
        let resolved = object["resolved"]?.boolean
            ?? [.connected, .skipped, .notConnected].contains(state)
        let environment = (object["required_env"]?.array ?? []).prefix(32).compactMap { value -> EnvironmentField? in
            guard let field = value.object, let name = field["name"]?.string, valid(name, maximumBytes: 128) else {
                return nil
            }
            return EnvironmentField(
                name: name,
                isRequired: field["required"]?.boolean ?? true,
                isSecret: field["secret"]?.boolean ?? true,
                defaultValue: text(field["default"], limit: 512) ?? "",
                prompt: text(field["prompt"], limit: 512)
            )
        }
        return Target(
            name: name,
            kind: object["kind"]?.string.flatMap(TargetKind.init(rawValue:)) ?? .other,
            action: object["action"]?.string.flatMap(Action.init(rawValue:)) ?? .other,
            state: state,
            isResolved: resolved,
            detail: text(object["detail"], limit: 1_000),
            instructions: text(object["instructions"], limit: 1_000),
            connectURL: object["connect_url"]?.string.flatMap(signInURL),
            alias: object["alias"]?.string.flatMap { valid($0, maximumBytes: 64) ? $0 : nil },
            requiredEnvironment: Array(environment),
            tools: (object["tools"]?.array ?? []).prefix(64).compactMap { text($0, limit: 128) }
        )
    }

    /// Opened in a browser the person sees, so only an https page with no credentials in it.
    static func signInURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= 4_096, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.host()?.isEmpty == false,
              url.user() == nil, url.password() == nil else { return nil }
        return url
    }

    private static func text(_ value: BighelpJSONValue?, limit: Int) -> String? {
        guard let raw = value?.string else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    private static func valid(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func integer(_ value: BighelpJSONValue) -> Int? {
        switch value {
        case .integer(let number): number
        case .number(let number) where number.rounded() == number && abs(number) < 1e15: Int(number)
        default: nil
        }
    }

    private static func number(_ value: BighelpJSONValue) -> Double? {
        switch value {
        case .integer(let number): Double(number)
        case .number(let number) where number.isFinite: number
        default: nil
        }
    }
}

/// How an app reads on screen: Hermes' catalog name when the host gave one, else its slug
/// made readable ("google_calendar" → "Google Calendar").
enum ConnectorNames {
    static func readable(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
