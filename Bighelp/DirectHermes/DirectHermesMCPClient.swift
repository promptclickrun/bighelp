import Foundation

enum MCPRuntimeState: String, Equatable, Sendable {
    case connected
    case disabled
    case connecting
    case failed
    case configured
}

struct MCPServerRuntimeStatus: Identifiable, Equatable, Sendable {
    let name: String
    let transport: String
    let toolCount: Int
    let isConnected: Bool
    let isDisabled: Bool
    let state: MCPRuntimeState
    var id: String { name }
}

struct MCPRuntimeSnapshot: Equatable, Sendable {
    let servers: [MCPServerRuntimeStatus]
    let checkedAtMilliseconds: Int

    var checkedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(checkedAtMilliseconds) / 1_000)
    }
}

@MainActor
protocol MCPRuntimeManagementClient: AnyObject {
    func cachedRuntimeStatus(configuredServers: [MCPServer]) async throws -> MCPRuntimeSnapshot
    func setAPIKey(_ value: String, environmentVariable: String?, serverName: String) async throws -> MCPServer
}

/// Closed typed CRUD, probe, catalog, OAuth, credential-update, and cached-status client for Hermes MCP servers.
@MainActor
final class DirectHermesMCPClient: MCPManagementClient, MCPRuntimeManagementClient {
    let owner: WorkspaceOwner
    let profileID: String
    let actionStatusClient: (any HermesHostActionStatusClient)?

    private let http: any DirectHermesAuthenticatedHTTP
    private let rpc: (any DirectHermesRPC)?
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    var isCurrentActionOwner: Bool { currentOwner() == owner }

    init(
        http: any DirectHermesAuthenticatedHTTP,
        rpc: (any DirectHermesRPC)? = nil,
        owner: WorkspaceOwner,
        profileID: String,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        actionStatusClient: (any HermesHostActionStatusClient)? = nil
    ) {
        self.http = http
        self.rpc = rpc
        self.owner = owner
        self.profileID = profileID
        self.currentOwner = currentOwner
        self.actionStatusClient = actionStatusClient
    }

    func load() async throws -> MCPSnapshot {
        let profile = try checkedProfile()
        async let serversValue = request(.servers(profile: profile))
        async let catalogValue = request(.catalog(profile: profile))
        let servers = try await serversValue
        let catalog = try await catalogValue
        let serverRows = try CapabilitiesPayload.array(servers["servers"]).map(decodeServer)
        let catalogRows = try CapabilitiesPayload.array(catalog["entries"]).map(decodeCatalogEntry)
        let diagnostics = try CapabilitiesPayload.array(catalog["diagnostics"]).map { value in
            let row = try CapabilitiesPayload.object(value)
            let name = try CapabilitiesPayload.text(row["name"], maximumBytes: 160)
            let kind = try CapabilitiesPayload.text(row["kind"], maximumBytes: 80)
            return "\(name): \(kind)"
        }
        return MCPSnapshot(servers: serverRows, catalog: catalogRows, diagnostics: diagnostics)
    }

    func add(_ draft: MCPServerDraft) async throws -> MCPServer {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(draft.name.trimmingCharacters(in: .whitespacesAndNewlines))
        var body: [String: BighelpJSONValue] = [
            "name": .string(name), "profile": .string(profile),
        ]
        switch draft.transport {
        case .http:
            guard draft.arguments.isEmpty, draft.environment.isEmpty,
                  let components = URLComponents(string: draft.url.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  components.host != nil, components.user == nil, components.password == nil else {
                throw CapabilitiesManagementError.invalidRequest
            }
            body["url"] = .string(draft.url.trimmingCharacters(in: .whitespacesAndNewlines))
            switch draft.authentication {
            case .none: body["auth"] = .string("none")
            case .oauth: body["auth"] = .string("oauth")
            case .bearer:
                let token = try secret(draft.bearerToken)
                body["auth"] = .string("header")
                body["bearer_token"] = .string(token)
            }
        case .stdio:
            guard draft.authentication == .none else { throw CapabilitiesManagementError.invalidRequest }
            let command = try input(draft.command, maximumBytes: 2_048, required: true)
            body["command"] = .string(command)
            body["args"] = .array(try draft.arguments.map { .string(try input($0, maximumBytes: 4_096, required: true)) })
            body["env"] = .object(try environment(draft.environment))
        }
        _ = try await request(.add(body: body))
        if !draft.isEnabled {
            _ = try await request(.setEnabled(name: name, profile: profile, enabled: false))
        }
        let readback = try await loadServers(profile: profile)
        guard let server = readback.first(where: { $0.name == name }),
              server.isEnabled == draft.isEnabled else {
            throw CapabilitiesManagementError.readbackFailed
        }
        return server
    }

    func installCatalog(name: String, environment: [String: String], enable: Bool) async throws -> CapabilityWriteResult {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(name)
        let catalog = try await load()
        guard let entry = catalog.catalog.first(where: { $0.name == name }) else {
            throw CapabilitiesManagementError.invalidRequest
        }
        let allowed = Set(entry.requiredEnvironment.map(\.name))
        guard Set(environment.keys).isSubset(of: allowed),
              entry.requiredEnvironment.filter(\.isRequired).allSatisfy({ !(environment[$0.name] ?? "").isEmpty }) else {
            throw CapabilitiesManagementError.invalidRequest
        }
        let payload = try await request(.installCatalog(body: [
            "name": .string(name), "env": .object(try self.environment(environment)),
            "enable": .boolean(enable), "profile": .string(profile),
        ]))
        guard payload["ok"]?.boolean == true, payload["name"]?.string == name,
              let background = payload["background"]?.boolean else {
            throw CapabilitiesManagementError.invalidResponse
        }
        if background {
            let action = try CapabilitiesPayload.text(payload["action"], maximumBytes: 160)
            let processID = try payload["pid"].flatMap { value in
                value == .null ? nil : try CapabilitiesPayload.integer(value, range: 1...Int.max)
            }
            let actionID = try CapabilitiesPayload.optionalText(payload["action_id"], maximumBytes: 128)
            return .pending(
                receipt: .init(actionName: action, processID: processID, actionID: actionID),
                message: "Hermes is installing the selected catalog server."
            )
        }
        guard try await loadServers(profile: profile).contains(where: { $0.name == name }) else {
            throw CapabilitiesManagementError.readbackFailed
        }
        return .confirmed("Hermes installed the selected MCP server.")
    }

    func setEnabled(_ enabled: Bool, serverName: String) async throws -> MCPServer {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(serverName)
        let payload = try await request(.setEnabled(name: name, profile: profile, enabled: enabled))
        guard payload["ok"]?.boolean == true, payload["name"]?.string == name,
              payload["enabled"]?.boolean == enabled else { throw CapabilitiesManagementError.invalidResponse }
        guard let readback = try await loadServers(profile: profile).first(where: { $0.name == name }),
              readback.isEnabled == enabled else { throw CapabilitiesManagementError.readbackFailed }
        return readback
    }

    func remove(serverName: String) async throws {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(serverName)
        let payload = try await request(.remove(name: name, profile: profile))
        guard payload["ok"]?.boolean == true else { throw CapabilitiesManagementError.invalidResponse }
        guard try await loadServers(profile: profile).allSatisfy({ $0.name != name }) else {
            throw CapabilitiesManagementError.readbackFailed
        }
    }

    func test(serverName: String) async throws -> MCPProbeResult {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(serverName)
        let payload = try await request(.test(name: name, profile: profile))
        let succeeded = try CapabilitiesPayload.boolean(payload["ok"])
        let (tools, toolCount) = try MCPProbeResult.displayedTools(payload["tools"])
        let promptCount: Int
        if let value = payload["prompts"] { promptCount = try CapabilitiesPayload.integer(value) }
        else { promptCount = 0 }
        let resourceCount: Int
        if let value = payload["resources"] { resourceCount = try CapabilitiesPayload.integer(value) }
        else { resourceCount = 0 }
        return MCPProbeResult(
            succeeded: succeeded,
            error: succeeded ? nil : "Connection test failed. Review the server’s authentication and host configuration.",
            tools: tools,
            toolCount: toolCount,
            promptCount: promptCount,
            resourceCount: resourceCount
        )
    }

    func cachedRuntimeStatus(configuredServers: [MCPServer]) async throws -> MCPRuntimeSnapshot {
        let profile = try checkedProfile()
        var expectedTransports: [String: String] = [:]
        for server in configuredServers {
            let name = try CapabilitiesPayload.identifier(server.name)
            guard expectedTransports.updateValue(server.transport, forKey: name) == nil else {
                throw CapabilitiesManagementError.invalidRequest
            }
        }
        let payload = try await requestRPC("mcp.servers.status", params: ["profile": .string(profile)])
        let checkedAt = try CapabilitiesPayload.integer(payload["checked_at"], range: 1...Int.max)
        let rows = try CapabilitiesPayload.array(payload["servers"])
        var seen = Set<String>()
        let statuses = try rows.map { value in
            let row = try CapabilitiesPayload.object(value)
            let name = try CapabilitiesPayload.identifier(
                CapabilitiesPayload.text(row["name"], maximumBytes: 160)
            )
            let transport = try CapabilitiesPayload.text(row["transport"], maximumBytes: 32)
            guard seen.insert(name).inserted, expectedTransports[name] == transport,
                  let state = MCPRuntimeState(rawValue: try CapabilitiesPayload.text(row["status"], maximumBytes: 32)) else {
                throw CapabilitiesManagementError.invalidResponse
            }
            return MCPServerRuntimeStatus(
                name: name,
                transport: transport,
                toolCount: try CapabilitiesPayload.integer(row["tools"], range: 0...2_000_000),
                isConnected: try CapabilitiesPayload.boolean(row["connected"]),
                isDisabled: try CapabilitiesPayload.boolean(row["disabled"]),
                state: state
            )
        }
        guard seen == Set(expectedTransports.keys) else { throw CapabilitiesManagementError.readbackFailed }
        return MCPRuntimeSnapshot(servers: statuses, checkedAtMilliseconds: checkedAt)
    }

    func setAPIKey(
        _ value: String, environmentVariable: String?, serverName: String
    ) async throws -> MCPServer {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(serverName)
        let secret = try secret(value)
        let environmentVariable = try environmentVariable.map { raw in
            let key = try CapabilitiesPayload.identifier(raw, maximumBytes: 128)
            guard key.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil else {
                throw CapabilitiesManagementError.invalidRequest
            }
            return key
        }
        guard let before = try await loadServers(profile: profile).first(where: { $0.name == name }),
              !(before.transport == "http" && before.auth == "oauth") else {
            throw CapabilitiesManagementError.invalidRequest
        }
        var params: [String: BighelpJSONValue] = [
            "profile": .string(profile), "name": .string(name), "value": .string(secret),
        ]
        if let environmentVariable { params["env_var"] = .string(environmentVariable) }
        let payload = try await requestRPC("mcp.servers.set_api_key", params: params, mutation: true)
        guard try CapabilitiesPayload.boolean(payload["ok"]),
              try CapabilitiesPayload.text(payload["name"], maximumBytes: 160) == name else {
            throw CapabilitiesManagementError.invalidResponse
        }
        let returnedEnvironment = try CapabilitiesPayload.identifier(
            CapabilitiesPayload.text(payload["env_var"], maximumBytes: 128), maximumBytes: 128
        )
        guard returnedEnvironment.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil else {
            throw CapabilitiesManagementError.invalidResponse
        }
        if let environmentVariable, returnedEnvironment != environmentVariable {
            throw CapabilitiesManagementError.readbackFailed
        }
        let acknowledgedServer = try CapabilitiesPayload.object(payload["server"])
        guard try CapabilitiesPayload.text(acknowledgedServer["name"], maximumBytes: 160) == name,
              try CapabilitiesPayload.text(acknowledgedServer["transport"], maximumBytes: 32) == before.transport else {
            throw CapabilitiesManagementError.invalidResponse
        }
        let acknowledgedEnvironment = try CapabilitiesPayload.strings(acknowledgedServer["env"])
        let acknowledgedAuth = try CapabilitiesPayload.optionalText(acknowledgedServer["auth"], maximumBytes: 32)
        guard (before.transport == "http" && acknowledgedAuth == "header")
                || (before.transport == "stdio" && acknowledgedEnvironment.contains(returnedEnvironment)) else {
            throw CapabilitiesManagementError.readbackFailed
        }
        guard let readback = try await loadServers(profile: profile).first(where: { $0.name == name }),
              readback.transport == before.transport else {
            throw CapabilitiesManagementError.readbackFailed
        }
        if readback.transport == "http" {
            guard readback.headerNames.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) else {
                throw CapabilitiesManagementError.readbackFailed
            }
        } else {
            guard readback.environmentKeys.contains(returnedEnvironment) else {
                throw CapabilitiesManagementError.readbackFailed
            }
        }
        return readback
    }

    func startOAuth(serverName: String) async throws -> MCPOAuthFlow {
        let name = try CapabilitiesPayload.identifier(serverName)
        return try decodeFlow(await request(.startOAuth(name: name, profile: checkedProfile())))
    }

    func pollOAuth(flowID: String) async throws -> MCPOAuthFlow {
        let flowID = try CapabilitiesPayload.identifier(flowID, maximumBytes: 256)
        return try decodeFlow(await request(.pollOAuth(flowID: flowID)))
    }

    func cancelOAuth(flowID: String) async throws -> MCPOAuthFlow.Status {
        let flowID = try CapabilitiesPayload.identifier(flowID, maximumBytes: 256)
        let payload = try await request(.cancelOAuth(flowID: flowID))
        guard payload["ok"]?.boolean == true,
              let status = MCPOAuthFlow.Status(rawValue: try CapabilitiesPayload.text(payload["status"], maximumBytes: 64)) else {
            throw CapabilitiesManagementError.invalidResponse
        }
        return status
    }

    private enum Route {
        case servers(profile: String)
        case catalog(profile: String)
        case add(body: [String: BighelpJSONValue])
        case installCatalog(body: [String: BighelpJSONValue])
        case setEnabled(name: String, profile: String, enabled: Bool)
        case remove(name: String, profile: String)
        case test(name: String, profile: String)
        case startOAuth(name: String, profile: String)
        case pollOAuth(flowID: String)
        case cancelOAuth(flowID: String)

        var isCapabilityProbe: Bool {
            switch self {
            case .servers, .catalog: true
            default: false
            }
        }

        var request: DirectHermesHTTPRequest {
            switch self {
            case .servers(let profile):
                return DirectHermesHTTPRequest(path: "/api/mcp/servers", method: .get, query: [.init(name: "profile", value: profile)])
            case .catalog(let profile):
                return DirectHermesHTTPRequest(path: "/api/mcp/catalog", method: .get, query: [.init(name: "profile", value: profile)])
            case .add(let body):
                return DirectHermesHTTPRequest(path: "/api/mcp/servers", method: .post, body: body)
            case .installCatalog(let body):
                return DirectHermesHTTPRequest(path: "/api/mcp/catalog/install", method: .post, body: body)
            case .setEnabled(let name, let profile, let enabled):
                return DirectHermesHTTPRequest(path: "/api/mcp/servers/\(name)/enabled", method: .put, body: [
                    "enabled": .boolean(enabled), "profile": .string(profile),
                ])
            case .remove(let name, let profile):
                return DirectHermesHTTPRequest(path: "/api/mcp/servers/\(name)", method: .delete, query: [.init(name: "profile", value: profile)])
            case .test(let name, let profile):
                return DirectHermesHTTPRequest(path: "/api/mcp/servers/\(name)/test", method: .post,
                                               query: [.init(name: "profile", value: profile)],
                                               maximumResponseBytes: DirectHermesHTTP.maximumMCPToolListResponseBytes)
            case .startOAuth(let name, let profile):
                return DirectHermesHTTPRequest(path: "/api/mcp/servers/\(name)/auth", method: .post, query: [.init(name: "profile", value: profile)])
            case .pollOAuth(let flowID):
                return DirectHermesHTTPRequest(path: "/api/mcp/oauth/flows/\(flowID)", method: .get,
                                               maximumResponseBytes: DirectHermesHTTP.maximumMCPToolListResponseBytes)
            case .cancelOAuth(let flowID):
                return DirectHermesHTTPRequest(path: "/api/mcp/oauth/flows/\(flowID)", method: .delete)
            }
        }
    }

    private func request(_ route: Route) async throws -> [String: BighelpJSONValue] {
        try requireOwner()
        do {
            let value = try await http.request(route.request)
            try requireOwner()
            return try CapabilitiesPayload.object(value)
        } catch DirectHermesError.unsupportedAuthentication where route.isCapabilityProbe {
            throw CapabilitiesManagementError.unsupportedHost("This Hermes host does not expose MCP management routes.")
        } catch DirectHermesError.unsupportedAuthentication {
            throw CapabilitiesManagementError.invalidResponse
        }
    }

    private func requestRPC(
        _ method: String, params: [String: BighelpJSONValue], mutation: Bool = false
    ) async throws -> [String: BighelpJSONValue] {
        try requireOwner()
        guard let rpc else {
            throw CapabilitiesManagementError.unsupportedHost("This Hermes connection does not expose typed MCP RPC management.")
        }
        do {
            let value = try await rpc.request(method, params: params)
            try requireOwner()
            return try CapabilitiesPayload.object(value)
        } catch let error as DirectHermesError {
            try requireOwner()
            if case .rpcRejected(let code) = error {
                if code == -32601 {
                    throw CapabilitiesManagementError.unsupportedHost("This Hermes host does not expose typed MCP RPC management.")
                }
                throw CapabilitiesManagementError.rejected("Hermes rejected the MCP operation.")
            }
            if mutation && error.outcomeIsUnknown {
                throw CapabilitiesManagementError.readbackFailed
            }
            throw error
        }
    }

    private func loadServers(profile: String) async throws -> [MCPServer] {
        try CapabilitiesPayload.array(try await request(.servers(profile: profile))["servers"]).map(decodeServer)
    }

    private func checkedProfile() throws -> String {
        try requireOwner()
        return try CapabilitiesPayload.profile(profileID)
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard currentOwner() == owner else { throw CapabilitiesManagementError.staleOwner }
    }

    private func input(_ value: String, maximumBytes: Int, required: Bool = false) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!required || !value.isEmpty), value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw CapabilitiesManagementError.invalidRequest
        }
        return value
    }

    private func secret(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 16_384,
              !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw CapabilitiesManagementError.invalidRequest
        }
        return value
    }

    private func environment(_ values: [String: String]) throws -> [String: BighelpJSONValue] {
        guard values.count <= 32 else { throw CapabilitiesManagementError.capacityExceeded }
        var result: [String: BighelpJSONValue] = [:]
        for (rawKey, rawValue) in values {
            let key = try CapabilitiesPayload.identifier(rawKey, maximumBytes: 128)
            guard key.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil else {
                throw CapabilitiesManagementError.invalidRequest
            }
            result[key] = .string(try secret(rawValue))
        }
        return result
    }

    private func decodeServer(_ value: BighelpJSONValue) throws -> MCPServer {
        let row = try CapabilitiesPayload.object(value)
        let environmentObject = try CapabilitiesPayload.object(row["env"] ?? .object([:]))
        let headersObject: [String: BighelpJSONValue]
        if let headers = row["headers"] { headersObject = try CapabilitiesPayload.object(headers) }
        else { headersObject = [:] }
        return MCPServer(
            name: try CapabilitiesPayload.text(row["name"], maximumBytes: 160),
            transport: try CapabilitiesPayload.text(row["transport"], maximumBytes: 32),
            url: try CapabilitiesPayload.optionalText(row["url"], maximumBytes: 4_096),
            command: try CapabilitiesPayload.optionalText(row["command"], maximumBytes: 2_048),
            arguments: try CapabilitiesPayload.strings(row["args"]),
            auth: try CapabilitiesPayload.optionalText(row["auth"], maximumBytes: 32),
            isEnabled: try CapabilitiesPayload.boolean(row["enabled"]),
            environmentKeys: environmentObject.keys.sorted(),
            headerNames: headersObject.keys.sorted()
        )
    }

    private func decodeCatalogEntry(_ value: BighelpJSONValue) throws -> MCPCatalogEntry {
        let row = try CapabilitiesPayload.object(value)
        let requirements = try CapabilitiesPayload.array(row["required_env"]).map { value in
            let field = try CapabilitiesPayload.object(value)
            return MCPEnvironmentRequirement(
                name: try CapabilitiesPayload.text(field["name"], maximumBytes: 128),
                prompt: try CapabilitiesPayload.text(field["prompt"], maximumBytes: 512),
                isRequired: try CapabilitiesPayload.boolean(field["required"])
            )
        }
        return MCPCatalogEntry(
            name: try CapabilitiesPayload.text(row["name"], maximumBytes: 160),
            summary: try CapabilitiesPayload.text(row["description"], maximumBytes: 8_192, required: false),
            source: try CapabilitiesPayload.text(row["source"], maximumBytes: 2_048, required: false),
            transport: try CapabilitiesPayload.text(row["transport"], maximumBytes: 32),
            authType: try CapabilitiesPayload.text(row["auth_type"], maximumBytes: 32),
            requiredEnvironment: requirements,
            command: try CapabilitiesPayload.optionalText(row["command"], maximumBytes: 2_048),
            arguments: try CapabilitiesPayload.strings(row["args"]),
            url: try CapabilitiesPayload.optionalText(row["url"], maximumBytes: 4_096),
            installURL: try CapabilitiesPayload.optionalText(row["install_url"], maximumBytes: 4_096),
            installReference: try CapabilitiesPayload.optionalText(row["install_ref"], maximumBytes: 256),
            bootstrap: try CapabilitiesPayload.strings(row["bootstrap"]),
            postInstall: try CapabilitiesPayload.text(row["post_install"], maximumBytes: 8_192, required: false),
            needsInstall: try CapabilitiesPayload.boolean(row["needs_install"]),
            isInstalled: try CapabilitiesPayload.boolean(row["installed"]),
            isEnabled: try CapabilitiesPayload.boolean(row["enabled"])
        )
    }

    private func decodeFlow(_ payload: [String: BighelpJSONValue]) throws -> MCPOAuthFlow {
        let rawStatus = try CapabilitiesPayload.text(payload["status"], maximumBytes: 64)
        let status = MCPOAuthFlow.Status(rawValue: rawStatus) ?? .unknown
        let url: URL?
        if let raw = try CapabilitiesPayload.optionalText(payload["authorization_url"], maximumBytes: 8_192) {
            guard let parsed = URL(string: raw), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host != nil else { throw CapabilitiesManagementError.invalidResponse }
            url = parsed
        } else { url = nil }
        let tools = payload["tools"] == nil ? [] : try MCPProbeResult.displayedTools(payload["tools"]).tools
        let remoteError = try CapabilitiesPayload.optionalText(payload["error"], maximumBytes: 8_192)
        return MCPOAuthFlow(
            id: try CapabilitiesPayload.text(payload["flow_id"], maximumBytes: 256),
            serverName: try CapabilitiesPayload.text(payload["server_name"], maximumBytes: 160),
            status: status,
            authorizationURL: url,
            error: remoteError == nil ? nil : "Authorization did not complete.",
            tools: tools
        )
    }
}
