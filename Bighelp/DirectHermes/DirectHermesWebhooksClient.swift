import Foundation

struct HermesWebhookSubscription: Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    let events: [String]
    let skills: [String]
    let delivery: String
    let deliversWithoutAgent: Bool
    let isEnabled: Bool
    let hasSecret: Bool
    let URL: URL
    let createdAt: String?

    var id: String { name }
}

struct HermesWebhookCatalog: Equatable, Sendable {
    let isPlatformEnabled: Bool
    let baseURL: URL
    let subscriptions: [HermesWebhookSubscription]
}

struct HermesWebhookDraft: Equatable, Sendable {
    enum Delivery: String, CaseIterable, Identifiable, Sendable {
        case log
        case origin
        case telegram
        case discord
        case slack
        case githubComment = "github_comment"

        var id: Self { self }
        var title: String {
            switch self {
            case .log: "Computer log"
            case .origin: "Origin conversation"
            case .telegram: "Telegram"
            case .discord: "Discord"
            case .slack: "Slack"
            case .githubComment: "GitHub comment"
            }
        }
    }

    let name: String
    let description: String
    let events: [String]
    let prompt: String
    let skills: [String]
    let delivery: Delivery
    let deliversWithoutAgent: Bool
    let deliveryChatID: String?
}

/// The secret is returned once by Hermes and is retained only by the presenting
/// in-memory store. It must never be persisted, logged, or copied automatically.
struct HermesWebhookCreationReceipt: Equatable, Sendable {
    let subscription: HermesWebhookSubscription
    let secret: String
}

@MainActor
protocol HermesWebhooksManaging: AnyObject {
    func list() async throws -> HermesWebhookCatalog
    func enablePlatform() async throws -> HermesWebhookCatalog
    func create(_ draft: HermesWebhookDraft) async throws -> HermesWebhookCreationReceipt
    func setEnabled(_ enabled: Bool, name: String) async throws -> HermesWebhookSubscription
    func delete(name: String) async throws
}

/// Fixed native webhook lifecycle. This intentionally omits script/custom-route
/// editing and arbitrary HTTP dispatch; Hermes remains the sole webhook runtime.
@MainActor
final class DirectHermesWebhooksClient: HermesWebhooksManaging {
    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.rpc = rpc
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func list() async throws -> HermesWebhookCatalog {
        let value = try await request(.init(path: "/api/webhooks", method: .get))
        guard let object = value.object,
              let enabled = object["enabled"]?.boolean,
              let baseURL = try Self.webURL(object["base_url"]),
              let values = object["subscriptions"]?.array,
              values.count <= 1_000 else { throw WorkspaceClientError.invalidResponse }
        var names = Set<String>()
        let subscriptions = try values.map { value -> HermesWebhookSubscription in
            let item = try Self.subscription(value)
            guard names.insert(item.name).inserted else { throw WorkspaceClientError.invalidResponse }
            return item
        }
        return .init(isPlatformEnabled: enabled, baseURL: baseURL, subscriptions: subscriptions)
    }

    func enablePlatform() async throws -> HermesWebhookCatalog {
        let before = try await list()
        if before.isPlatformEnabled { return before }
        let value = try await request(.init(path: "/api/webhooks/enable", method: .post, body: [:]))
        guard let object = value.object, object["ok"]?.boolean == true,
              object["platform"]?.string == "webhook", object["enabled"]?.boolean == true else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let after = try await list()
        guard after.isPlatformEnabled else { throw WorkspaceClientError.outcomeUnknown }
        return after
    }

    func create(_ draft: HermesWebhookDraft) async throws -> HermesWebhookCreationReceipt {
        let name = try Self.name(draft.name)
        let suppliedDescription = try Self.text(draft.description, maximum: 8_192, empty: true)
        let description = suppliedDescription.isEmpty
            ? "Dashboard-created subscription: \(name)"
            : suppliedDescription
        let prompt = try Self.text(draft.prompt, maximum: 256_000, empty: true)
        let events = try Self.list(draft.events, maximumCount: 100, maximumBytes: 128)
        let skills = try Self.list(draft.skills, maximumCount: 100, maximumBytes: 128)
        let chatID = try draft.deliveryChatID.map { try Self.text($0, maximum: 512) }
        guard !draft.deliversWithoutAgent || draft.delivery != .log else {
            throw WorkspaceClientError.invalidRequest
        }

        let before = try await list()
        guard before.isPlatformEnabled,
              !before.subscriptions.contains(where: { Self.exact($0.name, name) }) else {
            throw WorkspaceClientError.conflict
        }
        var body: [String: BighelpJSONValue] = [
            "name": .string(name), "description": .string(description),
            "events": .array(events.map(BighelpJSONValue.string)),
            "prompt": .string(prompt), "skills": .array(skills.map(BighelpJSONValue.string)),
            "deliver": .string(draft.delivery.rawValue),
            "deliver_only": .boolean(draft.deliversWithoutAgent)
        ]
        if let chatID { body["deliver_chat_id"] = .string(chatID) }
        // Omit both `secret` and `script`: Hermes creates a strong secret and this
        // native surface cannot become an arbitrary executable-script console.
        let value = try await request(.init(path: "/api/webhooks", method: .post, body: body))
        guard let object = value.object,
              let secret = object["secret"]?.string,
              !secret.isEmpty, secret.utf8.count <= 4_096,
              let returnedName = object["name"]?.string,
              Self.exact(returnedName, name) else { throw WorkspaceClientError.outcomeUnknown }

        let after = try await list()
        guard let created = after.subscriptions.first(where: { Self.exact($0.name, name) }),
              created.description == description,
              created.events == events,
              created.skills == skills,
              created.delivery == draft.delivery.rawValue,
              created.deliversWithoutAgent == draft.deliversWithoutAgent,
              created.isEnabled, created.hasSecret else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return .init(subscription: created, secret: secret)
    }

    func setEnabled(_ enabled: Bool, name: String) async throws -> HermesWebhookSubscription {
        let name = try Self.name(name)
        let before = try await list()
        guard before.isPlatformEnabled || !enabled,
              before.subscriptions.contains(where: { Self.exact($0.name, name) }) else {
            throw WorkspaceClientError.conflict
        }
        let value = try await request(.init(
            path: "/api/webhooks/\(name)/enabled", method: .put,
            body: ["enabled": .boolean(enabled)]
        ))
        guard let object = value.object, object["ok"]?.boolean == true,
              Self.exact(object["name"]?.string ?? "", name),
              object["enabled"]?.boolean == enabled else { throw WorkspaceClientError.outcomeUnknown }
        let after = try await list()
        guard let item = after.subscriptions.first(where: { Self.exact($0.name, name) }),
              item.isEnabled == enabled else { throw WorkspaceClientError.outcomeUnknown }
        return item
    }

    func delete(name: String) async throws {
        let name = try Self.name(name)
        let before = try await list()
        guard before.subscriptions.contains(where: { Self.exact($0.name, name) }) else {
            throw WorkspaceClientError.conflict
        }
        let value = try await request(.init(path: "/api/webhooks/\(name)", method: .delete))
        guard value.object?["ok"]?.boolean == true else { throw WorkspaceClientError.outcomeUnknown }
        let after = try await list()
        guard !after.subscriptions.contains(where: { Self.exact($0.name, name) }) else {
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    private func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        try checkOwner()
        do {
            let value = try await http.request(request)
            try checkOwner()
            return value
        } catch {
            try checkOwner()
            throw error
        }
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        _ = rpc
        guard owner.authority.kind == .direct, currentOwner() == owner else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    private static func subscription(_ value: BighelpJSONValue) throws -> HermesWebhookSubscription {
        guard let object = value.object,
              let nameValue = object["name"]?.string,
              let description = object["description"]?.string,
              description.utf8.count <= 8_192,
              let eventValues = object["events"]?.array,
              let skillValues = object["skills"]?.array,
              let delivery = object["deliver"]?.string, !delivery.isEmpty, delivery.utf8.count <= 128,
              let deliverOnly = object["deliver_only"]?.boolean,
              let enabled = object["enabled"]?.boolean,
              let hasSecret = object["secret_set"]?.boolean,
              let URL = try webURL(object["url"]) else {
            throw WorkspaceClientError.invalidResponse
        }
        let name = try Self.name(nameValue)
        let events = try decodedList(eventValues, maximumCount: 100, maximumBytes: 128)
        let skills = try decodedList(skillValues, maximumCount: 100, maximumBytes: 128)
        let createdAt: String?
        if object["created_at"] == nil || object["created_at"] == .null {
            createdAt = nil
        } else if let value = object["created_at"]?.string, value.utf8.count <= 128 {
            createdAt = value
        } else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            name: name, description: description, events: events, skills: skills,
            delivery: delivery, deliversWithoutAgent: deliverOnly,
            isEnabled: enabled, hasSecret: hasSecret, URL: URL, createdAt: createdAt
        )
    }

    private static func name(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 128,
              value == value.lowercased(),
              value.utf8.first.map({ (48...57).contains($0) || (97...122).contains($0) }) == true,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0)
                  || $0 == 45 || $0 == 95 }) else { throw WorkspaceClientError.invalidRequest }
        return value
    }

    private static func list(
        _ values: [String],
        maximumCount: Int,
        maximumBytes: Int
    ) throws -> [String] {
        guard values.count <= maximumCount else { throw WorkspaceClientError.capacityExceeded }
        var seen = Set<String>()
        return try values.map {
            let value = try text($0, maximum: maximumBytes)
            guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  seen.insert(value).inserted else { throw WorkspaceClientError.invalidRequest }
            return value
        }
    }

    private static func decodedList(
        _ values: [BighelpJSONValue],
        maximumCount: Int,
        maximumBytes: Int
    ) throws -> [String] {
        guard values.count <= maximumCount else { throw WorkspaceClientError.capacityExceeded }
        var seen = Set<String>()
        return try values.map {
            guard let string = $0.string else { throw WorkspaceClientError.invalidResponse }
            let value = try text(string, maximum: maximumBytes)
            guard seen.insert(value).inserted else { throw WorkspaceClientError.invalidResponse }
            return value
        }
    }

    private static func text(_ value: String, maximum: Int, empty: Bool = false) throws -> String {
        guard value.utf8.count <= maximum, (empty || !value.isEmpty),
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private static func webURL(_ value: BighelpJSONValue?) throws -> URL? {
        guard let text = value?.string, !text.isEmpty, text.utf8.count <= 4_096,
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              components.user == nil, components.password == nil,
              components.host?.isEmpty == false,
              let URL = components.url else { throw WorkspaceClientError.invalidResponse }
        return URL
    }

    private static func exact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}
