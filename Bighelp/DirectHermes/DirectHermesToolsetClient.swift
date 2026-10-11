import Foundation

/// Typed configuration client for Hermes toolsets. Platform terminal backends and
/// computer-use permission grants are deliberately outside this profile toolset UI.
@MainActor
final class DirectHermesToolsetClient: ToolsetManagementClient {
    let owner: WorkspaceOwner
    let profileID: String
    let actionStatusClient: (any HermesHostActionStatusClient)?

    private let http: any DirectHermesAuthenticatedHTTP
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    var isCurrentActionOwner: Bool { currentOwner() == owner }

    init(
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        profileID: String,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        actionStatusClient: (any HermesHostActionStatusClient)? = nil
    ) {
        self.http = http
        self.owner = owner
        self.profileID = profileID
        self.currentOwner = currentOwner
        self.actionStatusClient = actionStatusClient
    }

    func load() async throws -> ToolsetSnapshot {
        let profile = try checkedProfile()
        let value = try await requestValue(.list(profile: profile))
        return ToolsetSnapshot(toolsets: try CapabilitiesPayload.array(value).map(decodeSummary))
    }

    func detail(name: String, modelProvider: String? = nil) async throws -> ToolsetDetail {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(name)
        async let listValue = requestValue(.list(profile: profile))
        async let configValue = requestObject(.config(name: name, profile: profile))
        async let modelsValue = requestObject(.models(name: name, provider: modelProvider, profile: profile))
        let summaries = try CapabilitiesPayload.array(try await listValue).map(decodeSummary)
        guard let summary = summaries.first(where: { $0.name == name }) else {
            throw CapabilitiesManagementError.readbackFailed
        }
        return ToolsetDetail(
            summary: summary,
            configuration: try decodeConfiguration(await configValue),
            models: try decodeModels(await modelsValue)
        )
    }

    func setEnabled(_ enabled: Bool, name: String) async throws -> ToolsetSummary {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(name)
        let payload = try await requestObject(.toggle(name: name, enabled: enabled, profile: profile))
        guard payload["ok"]?.boolean == true, payload["name"]?.string == name,
              payload["enabled"]?.boolean == enabled else { throw CapabilitiesManagementError.invalidResponse }
        guard let readback = try await load().toolsets.first(where: { $0.name == name }),
              readback.isEnabled == enabled else { throw CapabilitiesManagementError.readbackFailed }
        return readback
    }

    func selectProvider(_ provider: String, name: String, capability: ToolsetWebCapability?) async throws -> ToolsetDetail {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(name)
        let provider = try input(provider, maximumBytes: 160)
        var body: [String: BighelpJSONValue] = ["provider": .string(provider), "profile": .string(profile)]
        if let capability { body["capability"] = .string(capability.rawValue) }
        let payload = try await requestObject(.selectProvider(name: name, body: body))
        guard payload["ok"]?.boolean == true, payload["name"]?.string == name,
              payload["provider"]?.string == provider else { throw CapabilitiesManagementError.invalidResponse }
        if payload["needs_nous_auth"]?.boolean == true {
            throw CapabilitiesManagementError.rejected("This provider was selected but requires Nous Portal sign-in before it can become ready.")
        }
        let readback = try await detail(name: name, modelProvider: provider)
        if let capability {
            let selectedBackend = readback.configuration.providers.first(where: { $0.name == provider })?.webBackend
            let active = capability == .search
                ? readback.configuration.activeSearchBackend : readback.configuration.activeExtractBackend
            guard selectedBackend != nil, active == selectedBackend else { throw CapabilitiesManagementError.readbackFailed }
        } else {
            guard readback.configuration.activeProvider == provider else { throw CapabilitiesManagementError.readbackFailed }
        }
        return readback
    }

    func saveEnvironment(_ environment: [String: String], name: String) async throws -> ToolsetDetail {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(name)
        let before = try await detail(name: name, modelProvider: nil)
        let allowed = Set(before.configuration.providers.flatMap(\.environment).map(\.key))
        guard !environment.isEmpty, environment.count <= 32, Set(environment.keys).isSubset(of: allowed) else {
            throw CapabilitiesManagementError.invalidRequest
        }
        var values: [String: BighelpJSONValue] = [:]
        for (key, value) in environment {
            guard !value.isEmpty, value.utf8.count <= 16_384,
                  !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
                throw CapabilitiesManagementError.invalidRequest
            }
            values[key] = .string(value)
        }
        let payload = try await requestObject(.saveEnvironment(name: name, body: [
            "env": .object(values), "profile": .string(profile),
        ]))
        guard payload["ok"]?.boolean == true, payload["name"]?.string == name else {
            throw CapabilitiesManagementError.invalidResponse
        }
        let readback = try await detail(name: name, modelProvider: before.configuration.activeProvider)
        var statuses: [String: Bool] = [:]
        for field in readback.configuration.providers.flatMap(\.environment) {
            statuses[field.key] = (statuses[field.key] ?? false) || field.isSet
        }
        guard environment.keys.allSatisfy({ statuses[$0] == true }) else {
            throw CapabilitiesManagementError.readbackFailed
        }
        return readback
    }

    func selectModel(_ model: String, provider: String?, name: String) async throws -> ToolsetDetail {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(name)
        let model = try input(model, maximumBytes: 256)
        var body: [String: BighelpJSONValue] = ["model": .string(model), "profile": .string(profile)]
        if let provider { body["provider"] = .string(try input(provider, maximumBytes: 160)) }
        let payload = try await requestObject(.selectModel(name: name, body: body))
        guard payload["ok"]?.boolean == true, payload["name"]?.string == name,
              payload["model"]?.string == model else { throw CapabilitiesManagementError.invalidResponse }
        let readback = try await detail(name: name, modelProvider: provider)
        guard readback.models.current == model else { throw CapabilitiesManagementError.readbackFailed }
        return readback
    }

    func runPostSetup(key: String, name: String) async throws -> CapabilityWriteResult {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(name)
        let detail = try await detail(name: name, modelProvider: nil)
        let allowed = Set(detail.configuration.providers.compactMap(\.postSetupKey))
        guard allowed.contains(key) else { throw CapabilitiesManagementError.invalidRequest }
        let payload = try await requestObject(.postSetup(name: name, body: [
            "key": .string(key), "profile": .string(profile),
        ]))
        guard payload["ok"]?.boolean == true, payload["key"]?.string == key else {
            throw CapabilitiesManagementError.invalidResponse
        }
        let action = try CapabilitiesPayload.optionalText(payload["action"], maximumBytes: 160)
            ?? CapabilitiesPayload.optionalText(payload["name"], maximumBytes: 160)
            ?? "tools-post-setup"
        let processID = try payload["pid"].flatMap { value in
            value == .null ? nil : try CapabilitiesPayload.integer(value, range: 1...Int.max)
        }
        let actionID = try CapabilitiesPayload.optionalText(payload["action_id"], maximumBytes: 128)
        return .pending(
            receipt: .init(actionName: action, processID: processID, actionID: actionID),
            message: "Hermes started the selected provider setup."
        )
    }

    private enum Route {
        case list(profile: String)
        case config(name: String, profile: String)
        case models(name: String, provider: String?, profile: String)
        case toggle(name: String, enabled: Bool, profile: String)
        case selectProvider(name: String, body: [String: BighelpJSONValue])
        case saveEnvironment(name: String, body: [String: BighelpJSONValue])
        case selectModel(name: String, body: [String: BighelpJSONValue])
        case postSetup(name: String, body: [String: BighelpJSONValue])

        var isCapabilityProbe: Bool {
            if case .list = self { return true }
            return false
        }

        var request: DirectHermesHTTPRequest {
            switch self {
            case .list(let profile):
                return DirectHermesHTTPRequest(path: "/api/tools/toolsets", method: .get, query: [.init(name: "profile", value: profile)])
            case .config(let name, let profile):
                return DirectHermesHTTPRequest(path: "/api/tools/toolsets/\(name)/config", method: .get, query: [.init(name: "profile", value: profile)])
            case .models(let name, let provider, let profile):
                var query = [URLQueryItem(name: "profile", value: profile)]
                if let provider { query.append(.init(name: "provider", value: provider)) }
                return DirectHermesHTTPRequest(path: "/api/tools/toolsets/\(name)/models", method: .get, query: query)
            case .toggle(let name, let enabled, let profile):
                return DirectHermesHTTPRequest(path: "/api/tools/toolsets/\(name)", method: .put, body: [
                    "enabled": .boolean(enabled), "profile": .string(profile),
                ])
            case .selectProvider(let name, let body):
                return DirectHermesHTTPRequest(path: "/api/tools/toolsets/\(name)/provider", method: .put, body: body)
            case .saveEnvironment(let name, let body):
                return DirectHermesHTTPRequest(path: "/api/tools/toolsets/\(name)/env", method: .put, body: body)
            case .selectModel(let name, let body):
                return DirectHermesHTTPRequest(path: "/api/tools/toolsets/\(name)/model", method: .put, body: body)
            case .postSetup(let name, let body):
                return DirectHermesHTTPRequest(path: "/api/tools/toolsets/\(name)/post-setup", method: .post, body: body)
            }
        }
    }

    private func requestValue(_ route: Route) async throws -> BighelpJSONValue {
        try requireOwner()
        do {
            let value = try await http.request(route.request)
            try requireOwner()
            return value
        } catch DirectHermesError.unsupportedAuthentication where route.isCapabilityProbe {
            throw CapabilitiesManagementError.unsupportedHost("This Hermes host does not expose typed toolset management.")
        } catch DirectHermesError.unsupportedAuthentication {
            throw CapabilitiesManagementError.invalidResponse
        }
    }

    private func requestObject(_ route: Route) async throws -> [String: BighelpJSONValue] {
        try CapabilitiesPayload.object(try await requestValue(route))
    }

    private func checkedProfile() throws -> String {
        try requireOwner()
        return try CapabilitiesPayload.profile(profileID)
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard currentOwner() == owner else { throw CapabilitiesManagementError.staleOwner }
    }

    private func input(_ value: String, maximumBytes: Int) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw CapabilitiesManagementError.invalidRequest
        }
        return value
    }

    private func decodeSummary(_ value: BighelpJSONValue) throws -> ToolsetSummary {
        let row = try CapabilitiesPayload.object(value)
        return ToolsetSummary(
            name: try CapabilitiesPayload.text(row["name"], maximumBytes: 160),
            label: try CapabilitiesPayload.text(row["label"], maximumBytes: 256),
            summary: try CapabilitiesPayload.text(row["description"], maximumBytes: 8_192, required: false),
            platform: try CapabilitiesPayload.text(row["platform"], maximumBytes: 80),
            platformLabel: try CapabilitiesPayload.text(row["platform_label"], maximumBytes: 160),
            isEnabled: try CapabilitiesPayload.boolean(row["enabled"]),
            isConfigured: try CapabilitiesPayload.boolean(row["configured"]),
            tools: try CapabilitiesPayload.strings(row["tools"])
        )
    }

    private func decodeConfiguration(_ payload: [String: BighelpJSONValue]) throws -> ToolsetConfiguration {
        let providers = try CapabilitiesPayload.array(payload["providers"]).map { value in
            let row = try CapabilitiesPayload.object(value)
            let environment = try CapabilitiesPayload.array(row["env_vars"]).map { value in
                let field = try CapabilitiesPayload.object(value)
                let rawURL = try CapabilitiesPayload.optionalText(field["url"], maximumBytes: 4_096)
                let helpURL: URL?
                if let rawURL {
                    guard let parsed = URL(string: rawURL), parsed.scheme?.lowercased() == "https", parsed.host != nil else {
                        throw CapabilitiesManagementError.invalidResponse
                    }
                    helpURL = parsed
                } else { helpURL = nil }
                return ToolsetEnvironmentField(
                    key: try CapabilitiesPayload.text(field["key"], maximumBytes: 128),
                    prompt: try CapabilitiesPayload.text(field["prompt"], maximumBytes: 512),
                    helpURL: helpURL,
                    defaultValue: try CapabilitiesPayload.optionalText(field["default"], maximumBytes: 4_096),
                    isSet: try CapabilitiesPayload.boolean(field["is_set"])
                )
            }
            let capabilities: [String]
            if row["capabilities"] == nil { capabilities = [] }
            else { capabilities = try CapabilitiesPayload.strings(row["capabilities"]) }
            return ToolsetProvider(
                name: try CapabilitiesPayload.text(row["name"], maximumBytes: 160),
                badge: try CapabilitiesPayload.text(row["badge"], maximumBytes: 128, required: false),
                tag: try CapabilitiesPayload.text(row["tag"], maximumBytes: 128, required: false),
                environment: environment,
                postSetupKey: try CapabilitiesPayload.optionalText(row["post_setup"], maximumBytes: 160),
                requiresNousAuthentication: try CapabilitiesPayload.boolean(row["requires_nous_auth"]),
                isActive: try CapabilitiesPayload.boolean(row["is_active"]),
                status: try CapabilitiesPayload.text(row["status"], maximumBytes: 128),
                webBackend: try CapabilitiesPayload.optionalText(row["web_backend"], maximumBytes: 160),
                capabilities: capabilities
            )
        }
        return ToolsetConfiguration(
            name: try CapabilitiesPayload.text(payload["name"], maximumBytes: 160),
            hasCategory: try CapabilitiesPayload.boolean(payload["has_category"]),
            providers: providers,
            activeProvider: try CapabilitiesPayload.optionalText(payload["active_provider"], maximumBytes: 160),
            activeSearchBackend: try CapabilitiesPayload.optionalText(payload["active_search_backend"], maximumBytes: 160),
            activeExtractBackend: try CapabilitiesPayload.optionalText(payload["active_extract_backend"], maximumBytes: 160)
        )
    }

    private func decodeModels(_ payload: [String: BighelpJSONValue]) throws -> ToolsetModelCatalog {
        let rows = try CapabilitiesPayload.array(payload["models"])
        return ToolsetModelCatalog(
            name: try CapabilitiesPayload.text(payload["name"], maximumBytes: 160),
            hasModels: try CapabilitiesPayload.boolean(payload["has_models"]),
            provider: try CapabilitiesPayload.optionalText(payload["provider"], maximumBytes: 160),
            models: try rows.map { value in
                let row = try CapabilitiesPayload.object(value)
                return ToolsetModel(
                    id: try CapabilitiesPayload.text(row["id"], maximumBytes: 256),
                    displayName: try CapabilitiesPayload.text(row["display"], maximumBytes: 256),
                    speed: try CapabilitiesPayload.text(row["speed"], maximumBytes: 128, required: false),
                    strengths: try CapabilitiesPayload.text(row["strengths"], maximumBytes: 512, required: false),
                    price: try CapabilitiesPayload.text(row["price"], maximumBytes: 128, required: false)
                )
            },
            current: try CapabilitiesPayload.optionalText(payload["current"], maximumBytes: 256),
            defaultModel: try CapabilitiesPayload.optionalText(payload["default"], maximumBytes: 256)
        )
    }
}
