import Foundation

/// One Composio app and the person's accounts in it.
struct ComposioConnection: Equatable, Sendable {
    struct Account: Identifiable, Equatable, Sendable {
        let id: String
        /// `active`, `initiated`, `failed`, `expired`… as Composio says it.
        let status: String
        let email: String?

        var isActive: Bool { status.lowercased() == "active" }
    }

    let toolkit: String
    let accounts: [Account]

    var isConnected: Bool { accounts.contains(where: \.isActive) }
}

/// A new account's sign-in: Composio's page, and the account it waits on (removed if the page is
/// closed before the sign-in finishes, so unfinished tries don't pile up in the person's account).
struct ComposioConnectStart: Equatable, Sendable {
    let url: URL
    let pendingAccountID: String?
}

/// What Settings › Apps › Composio asks of Composio Connect.
@MainActor
protocol ComposioConnecting: AnyObject {
    /// The apps Composio lists as connected for this account.
    func connectedToolkits() async throws -> [String]
    /// Accounts per app, for the apps asked about.
    func connections(_ toolkits: [String]) async throws -> [String: ComposioConnection]
    /// Composio's sign-in page for a new account in an app, and the pending account it made.
    func connect(_ toolkit: String) async throws -> ComposioConnectStart
    func remove(_ toolkit: String, accountID: String) async throws
}

/// Composio Connect's MCP server (`connect.composio.dev/mcp`) with the person's own sign-in.
/// Only its connection tool and its tool list are used: never a tool that acts in an app.
@MainActor
final class ComposioConnectClient: ComposioConnecting {
    static let endpoint = ComposioOAuth.resource
    static let maximumResponseBytes = 2_097_152
    /// Toolkits per `list` call; a category page asks about this many at a time.
    static let batchSize = 25

    private let account: ComposioAccount
    private let http: any ComposioHTTP
    private var sessionID: String?
    private var isInitialized = false
    private var nextID = 1

    init(account: ComposioAccount, http: any ComposioHTTP = ComposioURLSessionHTTP()) {
        self.account = account
        self.http = http
    }

    func connectedToolkits() async throws -> [String] {
        let result = try await rpc("tools/list", [:])
        let tools = result["tools"] as? [[String: Any]] ?? []
        let search = tools.first { $0["name"] as? String == "COMPOSIO_SEARCH_TOOLS" }?["description"] as? String
        return search.map(Self.connectedToolkits(inDescription:)) ?? []
    }

    func connections(_ toolkits: [String]) async throws -> [String: ComposioConnection] {
        var found: [String: ComposioConnection] = [:]
        let slugs = Array(Set(toolkits.filter(Self.isSlug))).sorted()
        for start in stride(from: 0, to: slugs.count, by: Self.batchSize) {
            let batch = slugs[start..<min(start + Self.batchSize, slugs.count)]
            let data = try await manage(batch.map { ["name": $0, "action": "list"] })
            for (slug, connection) in try Self.connections(in: data) where batch.contains(slug) { found[slug] = connection }
        }
        return found
    }

    func connect(_ toolkit: String) async throws -> ComposioConnectStart {
        guard Self.isSlug(toolkit) else { throw ComposioError.invalidResponse }
        let data = try await manage([["name": toolkit, "action": "add"]])
        return try Self.connectStart(in: data, toolkit: toolkit)
    }

    func remove(_ toolkit: String, accountID: String) async throws {
        guard Self.isSlug(toolkit), ComposioOAuth.isToken(accountID, maximum: 200) else { throw ComposioError.invalidResponse }
        _ = try await manage([["name": toolkit, "action": "remove", "account_id": accountID]])
    }

    // MARK: Parsing (static, for tests)

    /// Composio's search tool says which apps are connected: "User has manually connected
    /// the apps: gmail, github. Prefer these apps…". Absent, nothing is known connected.
    nonisolated static func connectedToolkits(inDescription description: String) -> [String] {
        guard let range = description.range(of: "connected the apps:") else { return [] }
        let tail = description[range.upperBound...].prefix(8_192)
        let list = tail.split(separator: ".", maxSplits: 1).first ?? tail[...]
        return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isSlug).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    nonisolated static func connections(in data: [String: Any]) throws -> [String: ComposioConnection] {
        guard let results = data["results"] as? [String: Any] else { throw ComposioError.invalidResponse }
        var found: [String: ComposioConnection] = [:]
        for (slug, value) in results.prefix(200) {
            guard isSlug(slug), let entry = value as? [String: Any] else { continue }
            let accounts = (entry["accounts"] as? [[String: Any]] ?? []).prefix(20).compactMap { row -> ComposioConnection.Account? in
                guard let id = row["id"] as? String, ComposioOAuth.isToken(id, maximum: 200),
                      let status = row["status"] as? String, status.utf8.count <= 40 else { return nil }
                let info = row["user_info"] as? [String: Any]
                let email = (info?["email"] as? String).flatMap { $0.contains("@") && $0.utf8.count <= 320 ? $0 : nil }
                return .init(id: id, status: status, email: email)
            }
            found[slug] = ComposioConnection(toolkit: slug, accounts: Array(accounts))
        }
        return found
    }

    /// Composio's answer to `add`: the page, and the account that waits on it (`initiated`).
    nonisolated static func connectStart(in data: [String: Any], toolkit: String) throws -> ComposioConnectStart {
        guard let results = data["results"] as? [String: Any], let entry = results[toolkit] as? [String: Any] else {
            throw ComposioError.invalidResponse
        }
        guard let link = entry["redirect_url"] as? String, let url = URL(string: link), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil, link.utf8.count <= 4_096 else {
            // No page: Composio says why in the entry (`error`, `message` or `instruction`).
            let reason = ["error", "message", "instruction"].lazy.compactMap { entry[$0] as? String }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            throw ComposioError.refused(reason.map { String($0.prefix(300)) } ?? "Composio didn't give a sign-in page.")
        }
        let pending = (entry["accounts"] as? [[String: Any]] ?? []).last { row in
            ["initiated", "initializing"].contains((row["status"] as? String)?.lowercased() ?? "")
        }?["id"] as? String
        return ComposioConnectStart(url: url, pendingAccountID: pending.flatMap { ComposioOAuth.isToken($0, maximum: 200) ? $0 : nil })
    }

    /// A Composio toolkit slug: lowercase letters, digits and underscores.
    nonisolated static func isSlug(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && value.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5f }
    }

    /// A tool error's text: the `error` of a JSON answer, or the text itself, kept short.
    nonisolated static func errorText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
           let error = object["error"] as? String, !error.isEmpty {
            return String(error.prefix(300))
        }
        return String(trimmed.prefix(300))
    }

    /// The tool's JSON answer from an MCP `tools/call` result: `{successful, data, error}`.
    nonisolated static func toolData(_ result: [String: Any]) throws -> [String: Any] {
        guard let content = result["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ComposioError.invalidResponse
        }
        guard object["successful"] as? Bool == true, let data = object["data"] as? [String: Any] else {
            let message = (object["error"] as? String).map { String($0.prefix(300)) } ?? "Composio couldn't do that."
            throw ComposioError.refused(message)
        }
        return data
    }

    /// A JSON-RPC answer, sent as JSON or as one server-sent event.
    nonisolated static func rpcMessage(_ data: Data, id: Int) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else { throw ComposioError.invalidResponse }
        var candidates: [String] = []
        if text.drop(while: \.isWhitespace).first == "{" {
            candidates = [text]
        } else {
            candidates = text.split(whereSeparator: \.isNewline).compactMap { line in
                line.hasPrefix("data:") ? String(line.dropFirst(5)) : nil
            }
        }
        for candidate in candidates {
            guard let message = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any],
                  (message["id"] as? NSNumber)?.intValue == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw ComposioError.refused(((error["message"] as? String) ?? "Composio refused.").prefix(300).description)
            }
            guard let result = message["result"] as? [String: Any] else { throw ComposioError.invalidResponse }
            return result
        }
        throw ComposioError.invalidResponse
    }

    // MARK: MCP

    private func manage(_ toolkits: [[String: String]]) async throws -> [String: Any] {
        let result = try await rpc("tools/call", ["name": "COMPOSIO_MANAGE_CONNECTIONS", "arguments": ["toolkits": toolkits]])
        if result["isError"] as? Bool == true {
            // Composio's own words, so a refusal says why (not a bare "couldn't").
            let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ")
            let reason = text.flatMap { Self.errorText($0) } ?? "Composio couldn't do that."
            throw ComposioError.refused(reason)
        }
        return try Self.toolData(result)
    }

    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if !isInitialized { try await initialize() }
        do {
            return try await send(method, params)
        } catch ComposioError.signedOut {
            throw ComposioError.signedOut
        } catch let error as HTTPStatus where error.code == 401 || error.code == 404 {
            // An expired token, or a session the server forgot: sign the request again and start over once.
            if error.code == 401 { _ = try await account.tokenRejected() }
            isInitialized = false
            sessionID = nil
            try await initialize()
            return try await send(method, params)
        }
    }

    private func initialize() async throws {
        _ = try await send("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "bighelp", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"],
        ])
        try await notify("notifications/initialized")
        isInitialized = true
    }

    private struct HTTPStatus: Error { let code: Int }

    private func request(_ body: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + (try await account.accessToken()), forHTTPHeaderField: "Authorization")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let (data, response) = try await http.send(
            try await request(["jsonrpc": "2.0", "id": id, "method": method, "params": params]),
            maximumBytes: Self.maximumResponseBytes)
        guard response.statusCode == 200 else { throw HTTPStatus(code: response.statusCode) }
        if let session = response.value(forHTTPHeaderField: "Mcp-Session-Id"), ComposioOAuth.isToken(session, maximum: 256) {
            sessionID = session
        }
        return try Self.rpcMessage(data, id: id)
    }

    private func notify(_ method: String) async throws {
        let (_, response) = try await http.send(try await request(["jsonrpc": "2.0", "method": method]),
                                                maximumBytes: 65_536)
        guard (200...299).contains(response.statusCode) else { throw HTTPStatus(code: response.statusCode) }
    }
}
