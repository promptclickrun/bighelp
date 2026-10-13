import Foundation

struct DirectHermesProviderDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let authType: String?
    let isAuthenticated: Bool?
    let keyEnvironment: String?
    let isCurrent: Bool
    let isCustom: Bool
    let modelCount: Int
}

struct DirectHermesProviderCredential: Identifiable, Equatable, Sendable {
    let id: String
    let providerID: String?
    let providerName: String?
    let description: String
    let category: String
    let isSet: Bool
    let isSecret: Bool
    let isAdvanced: Bool
    let isCustom: Bool
    let isChannelManaged: Bool
}

struct DirectHermesOAuthProvider: Identifiable, Equatable, Sendable {
    enum Flow: String, Equatable, Sendable {
        case deviceCode = "device_code"
        case pkce
        case external
        case unsupported
    }

    struct Status: Equatable, Sendable {
        let isLoggedIn: Bool
        let source: String?
        let sourceLabel: String?
        let expiresAt: Date?
        let hasRefreshToken: Bool
        let isFreeTier: Bool?
        let accountTier: String?
        let errorMessage: String?
    }

    let id: String
    let name: String
    let flow: Flow
    let documentationURL: URL?
    let canDisconnect: Bool
    let disconnectHint: String?
    /// What to run on the host for sign-ins Hermes only does in a terminal.
    var cliCommand: String? = nil
    let status: Status
}

struct DirectHermesCustomEndpoint: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let defaultModel: String
    let models: [String]
    let contextLength: Int?
    let discoversModels: Bool
    let hasCredential: Bool
    let isCurrent: Bool
    let source: String
}

struct DirectHermesCustomEndpointDraft: Equatable, Sendable {
    let id: String?
    let name: String
    let baseURL: String
    let model: String
    let models: [String]
    let contextLength: Int?
    let discoversModels: Bool
    let makeDefault: Bool
    /// nil preserves the saved credential, an empty string removes it, and a
    /// non-empty value replaces it. Callers must keep this value ephemeral.
    let apiKey: String?
}

struct DirectHermesProviderValidation: Equatable, Sendable {
    let isAccepted: Bool
    let isReachable: Bool
    let message: String
    let models: [String]
}

struct DirectHermesOAuthSession: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case pending, approved, denied, expired, error, cancelled, unknown
    }

    let id: String
    let providerID: String
    let flow: DirectHermesOAuthProvider.Flow
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let pollInterval: TimeInterval
    let status: Status
    let errorMessage: String?
    let completionReason: String?
    let accountEmail: String?
    let selectedModel: String?
}

struct DirectHermesCredentialPool: Identifiable, Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let index: Int
        let id: String
        let label: String
        let authType: String
        let source: String
        let priority: Int
        let lastStatus: String?
        let requestCount: Int
        let hasRefreshToken: Bool
    }

    let id: String
    let entries: [Entry]
}

struct DirectHermesSetupStatus: Equatable, Sendable {
    let providerConfigured: Bool?
    let isReady: Bool?
    let isFreeTier: Bool?
    let hasOtherProviders: Bool?
    let inferenceProvider: String?
    let profileID: String?
    let isValidProfile: Bool
    let errorMessage: String?
}

struct DirectHermesRuntimeStatus: Equatable, Sendable {
    let isUsable: Bool
    let providerID: String?
    let modelID: String?
    let source: String?
    let isFreeTier: Bool?
    let profileID: String?
    let errorMessage: String?
}

struct DirectHermesPortalStatus: Equatable, Sendable {
    struct Feature: Identifiable, Equatable, Sendable {
        let label: String
        let state: String
        var id: String { "\(label.utf8.count):\(label)\(state)" }
    }

    let isLoggedIn: Bool
    let portalURL: URL?
    let inferenceURL: URL?
    let providerID: String
    let isFreeTier: Bool
    let accountTier: String?
    let subscriptionURL: URL?
    let features: [Feature]
}

struct DirectHermesProviderSnapshot: Equatable, Sendable {
    let providers: [DirectHermesProviderDescriptor]
    let credentials: [DirectHermesProviderCredential]
    let oauthProviders: [DirectHermesOAuthProvider]
    let customEndpoints: [DirectHermesCustomEndpoint]
    /// Credential pools are process/serving-profile state. This is empty unless
    /// the caller explicitly requested that scope after matching the serving profile.
    let credentialPools: [DirectHermesCredentialPool]
    // Extras load on their own: one the host can't answer is left out, not fatal.
    let setup: DirectHermesSetupStatus?
    let runtime: DirectHermesRuntimeStatus?
    let portal: DirectHermesPortalStatus?
    var skippedParts: [String] = []
}

@MainActor
final class DirectHermesProviderClient {
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

    var ownsScope: Bool { currentOwner() == owner && owner.authority.kind == .direct }

    func loadSnapshot(
        profileID: String,
        servingProfileID: String? = nil,
        includeServingCredentialPools: Bool = false
    ) async throws -> DirectHermesProviderSnapshot {
        let profile = try Self.profile(profileID)
        let providers = try await listProviders(profileID: profile)
        var skipped: [String] = []
        func optional<T>(_ name: String, _ load: () async throws -> T) async throws -> T? {
            do { return try await load() } catch is CancellationError { throw CancellationError() } catch {
                skipped.append(name)
                return nil
            }
        }
        let credentials = try await optional("saved keys") { try await listCredentials(profileID: profile) } ?? []
        let oauth = try await optional("sign-in providers") { try await listOAuthProviders(profileID: profile) } ?? []
        let endpoints = try await optional("custom endpoints") { try await listCustomEndpoints(profileID: profile) } ?? []
        let pools: [DirectHermesCredentialPool]
        if includeServingCredentialPools {
            pools = try await optional("credential pools") {
                try await listServingCredentialPools(profileID: profile, servingProfileID: servingProfileID)
            } ?? []
        } else {
            pools = []
        }
        let setup = try await optional("setup status") { try await setupStatus(profileID: profile) }
        let runtime = try await optional("readiness check") { try await runtimeStatus(profileID: profile) }
        let portal = try await optional("Nous Portal") { try await portalStatus() }
        return .init(
            providers: providers,
            credentials: credentials,
            oauthProviders: oauth,
            customEndpoints: endpoints,
            credentialPools: pools,
            setup: setup,
            runtime: runtime,
            portal: portal,
            skippedParts: skipped
        )
    }

    func listProviders(profileID: String, refresh: Bool = false) async throws -> [DirectHermesProviderDescriptor] {
        let profile = try Self.profile(profileID)
        let response: BighelpJSONValue
        do { response = try await requestHTTP(.init(
            path: "/api/model/options",
            method: .get,
            query: [
                .init(name: "profile", value: profile),
                .init(name: "refresh", value: refresh ? "true" : "false"),
                .init(name: "include_unconfigured", value: "true"),
                .init(name: "explicit_only", value: "false"),
            ],
            maximumResponseBytes: 2_097_152,
            // A refresh asks every provider for its models again; slow ones take a while.
            timeout: refresh ? 120 : 20
        )) } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Same payload as the chat's model picker, which some hosts serve when the route fails.
            response = try await requestRPC("model.options", [
                "profile": .string(profile), "refresh": .boolean(refresh),
                "include_unconfigured": .boolean(true), "explicit_only": .boolean(false),
            ])
        }
        let object = try DirectHermesAdministrationCodec.object(response)
        let rows = try DirectHermesAdministrationCodec.array(object["providers"], maximum: 256)
        var seen = Set<String>()
        return try rows.map { value in
            let row = try DirectHermesAdministrationCodec.object(value)
            let id = try Self.identifier(DirectHermesAdministrationCodec.string(row["slug"], maximum: 128))
            guard seen.insert(id).inserted else { throw WorkspaceClientError.invalidResponse }
            let models = try DirectHermesAdministrationCodec.stringArray(row["models"], maximumCount: 20_000, maximumBytes: 256, required: false)
            return .init(
                id: id,
                name: try DirectHermesAdministrationCodec.string(row["name"], maximum: 800),
                authType: try DirectHermesAdministrationCodec.optionalString(row["auth_type"], maximum: 128),
                isAuthenticated: try DirectHermesAdministrationCodec.optionalBool(row["authenticated"]),
                keyEnvironment: try DirectHermesAdministrationCodec.optionalString(row["key_env"], maximum: 128),
                isCurrent: try DirectHermesAdministrationCodec.optionalBool(row["is_current"]) ?? false,
                isCustom: try DirectHermesAdministrationCodec.optionalBool(row["is_user_defined"]) ?? false,
                modelCount: try DirectHermesAdministrationCodec.optionalInt(row["total_models"], minimum: 0)
                    ?? models.count
            )
        }
    }

    func listCredentials(profileID: String) async throws -> [DirectHermesProviderCredential] {
        let profile = try Self.profile(profileID)
        let response = try await requestHTTP(.init(
            path: "/api/env", method: .get,
            query: [.init(name: "profile", value: profile)],
            maximumResponseBytes: 1_048_576
        ))
        let source = try DirectHermesAdministrationCodec.object(response)
        guard source.count <= 1_024 else { throw WorkspaceClientError.capacityExceeded }
        return try source.keys.sorted().map { key in
            guard Self.isEnvironmentKey(key) else { throw WorkspaceClientError.invalidResponse }
            let row = try DirectHermesAdministrationCodec.object(source[key])
            return .init(
                id: key,
                providerID: try DirectHermesAdministrationCodec.optionalString(row["provider"], maximum: 128),
                providerName: try DirectHermesAdministrationCodec.optionalString(row["provider_label"], maximum: 800),
                description: try DirectHermesAdministrationCodec.optionalString(row["description"], maximum: 4_096) ?? "",
                category: try DirectHermesAdministrationCodec.optionalString(row["category"], maximum: 128) ?? "",
                isSet: try DirectHermesAdministrationCodec.bool(row["is_set"]),
                isSecret: try DirectHermesAdministrationCodec.bool(row["is_password"]),
                isAdvanced: try DirectHermesAdministrationCodec.bool(row["advanced"]),
                isCustom: try DirectHermesAdministrationCodec.optionalBool(row["custom"]) ?? false,
                isChannelManaged: try DirectHermesAdministrationCodec.optionalBool(row["channel_managed"]) ?? false
            )
        }
    }

    func validateCredential(profileID: String, key: String, value: String, companionAPIKey: String = "") async throws -> DirectHermesProviderValidation {
        let profile = try Self.profile(profileID)
        guard Self.isEnvironmentKey(key), !value.isEmpty, value.utf8.count <= 16_384,
              companionAPIKey.utf8.count <= 16_384 else { throw WorkspaceClientError.invalidRequest }
        let response = try await requestHTTP(.init(
            path: "/api/providers/validate", method: .post,
            body: [
                "key": .string(key), "value": .string(value), "profile": .string(profile),
                "api_key": .string(companionAPIKey),
            ],
            maximumResponseBytes: 16_384
        ), mutation: false)
        return try Self.validation(response)
    }

    /// Validates and then writes the same ephemeral value. A reachable rejection
    /// and an unreachable failed probe both stop before persistence.
    @discardableResult
    func replaceCredential(profileID: String, key: String, value: String, companionAPIKey: String = "") async throws -> DirectHermesProviderCredential {
        let profile = try Self.profile(profileID)
        let validation = try await validateCredential(profileID: profile, key: key, value: value, companionAPIKey: companionAPIKey)
        guard validation.isAccepted else { throw WorkspaceClientError.rejected(code: nil) }
        _ = try await requestHTTP(.init(
            path: "/api/env", method: .put,
            body: ["key": .string(key), "value": .string(value), "profile": .string(profile)],
            maximumResponseBytes: 16_384
        ), mutation: true)
        let verified = try await listCredentials(profileID: profile)
        guard let row = verified.first(where: { $0.id == key }), row.isSet else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return row
    }

    func deleteCredential(profileID: String, key: String) async throws {
        let profile = try Self.profile(profileID)
        guard Self.isEnvironmentKey(key) else { throw WorkspaceClientError.invalidRequest }
        _ = try await requestHTTP(.init(
            path: "/api/env", method: .delete,
            body: ["key": .string(key), "profile": .string(profile)],
            maximumResponseBytes: 16_384
        ), mutation: true)
        let verified = try await listCredentials(profileID: profile)
        guard verified.first(where: { $0.id == key })?.isSet != true else {
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    func listCustomEndpoints(profileID: String) async throws -> [DirectHermesCustomEndpoint] {
        let profile = try Self.profile(profileID)
        let response = try await requestHTTP(.init(
            path: "/api/providers/custom-endpoints", method: .get,
            query: [.init(name: "profile", value: profile)],
            maximumResponseBytes: 1_048_576
        ))
        let object = try DirectHermesAdministrationCodec.object(response)
        let rows = try DirectHermesAdministrationCodec.array(object["endpoints"], maximum: 256)
        var seen = Set<String>()
        return try rows.map { value in
            let row = try DirectHermesAdministrationCodec.object(value)
            let id = try Self.pathIdentifier(DirectHermesAdministrationCodec.string(row["id"], maximum: 128))
            guard seen.insert(id).inserted else { throw WorkspaceClientError.invalidResponse }
            let baseURL = try DirectHermesAdministrationCodec.string(row["base_url"], maximum: 2_048)
            try Self.validateEndpointURL(baseURL)
            return .init(
                id: id,
                name: try DirectHermesAdministrationCodec.string(row["name"], maximum: 800),
                baseURL: baseURL,
                defaultModel: try DirectHermesAdministrationCodec.string(row["model"], maximum: 256),
                models: try DirectHermesAdministrationCodec.stringArray(row["models"], maximumCount: 20_000, maximumBytes: 256),
                contextLength: try DirectHermesAdministrationCodec.optionalInt(row["context_length"], minimum: 1),
                discoversModels: try DirectHermesAdministrationCodec.bool(row["discover_models"]),
                hasCredential: try DirectHermesAdministrationCodec.bool(row["has_api_key"]),
                isCurrent: try DirectHermesAdministrationCodec.bool(row["is_current"]),
                source: try DirectHermesAdministrationCodec.string(row["source"], maximum: 128)
            )
        }
    }

    func validateCustomEndpoint(_ draft: DirectHermesCustomEndpointDraft) async throws -> DirectHermesProviderValidation {
        let body = try Self.customEndpointBody(draft)
        let response = try await requestHTTP(.init(
            path: "/api/providers/custom-endpoints/validate", method: .post,
            body: body, maximumResponseBytes: 256_000
        ), mutation: false)
        return try Self.validation(response)
    }

    @discardableResult
    func saveCustomEndpoint(profileID: String, draft: DirectHermesCustomEndpointDraft) async throws -> DirectHermesCustomEndpoint {
        let profile = try Self.profile(profileID)
        let body = try Self.customEndpointBody(draft)
        let response = try await requestHTTP(.init(
            path: "/api/providers/custom-endpoints", method: .post,
            query: [.init(name: "profile", value: profile)],
            body: body, maximumResponseBytes: 1_048_576
        ), mutation: true)
        let object = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(object["ok"]) else { throw WorkspaceClientError.rejected(code: nil) }
        let savedID = try Self.pathIdentifier(DirectHermesAdministrationCodec.string(object["id"], maximum: 128))
        let verified = try await listCustomEndpoints(profileID: profile)
        guard let endpoint = verified.first(where: { $0.id == savedID }) else { throw WorkspaceClientError.outcomeUnknown }
        return endpoint
    }

    func activateCustomEndpoint(profileID: String, endpointID: String) async throws {
        let profile = try Self.profile(profileID)
        let endpoint = try Self.pathIdentifier(endpointID)
        let response = try await requestHTTP(.init(
            path: "/api/providers/custom-endpoints/\(endpoint)/activate", method: .post,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 16_384
        ), mutation: true)
        let object = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(object["ok"]), object["provider"]?.string == endpoint else {
            throw WorkspaceClientError.outcomeUnknown
        }
        guard try await listCustomEndpoints(profileID: profile).first(where: { $0.id == endpoint })?.isCurrent == true else {
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    func deleteCustomEndpoint(profileID: String, endpointID: String) async throws {
        let profile = try Self.profile(profileID)
        let endpoint = try Self.pathIdentifier(endpointID)
        _ = try await requestHTTP(.init(
            path: "/api/providers/custom-endpoints/\(endpoint)", method: .delete,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 1_048_576
        ), mutation: true)
        guard try await listCustomEndpoints(profileID: profile).contains(where: { $0.id == endpoint }) == false else {
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    func listOAuthProviders(profileID: String) async throws -> [DirectHermesOAuthProvider] {
        let profile = try Self.profile(profileID)
        let response = try await requestHTTP(.init(
            path: "/api/providers/oauth", method: .get,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 256_000
        ))
        let object = try DirectHermesAdministrationCodec.object(response)
        let rows = try DirectHermesAdministrationCodec.array(object["providers"], maximum: 128)
        var seen = Set<String>()
        return try rows.map { value in
            let row = try DirectHermesAdministrationCodec.object(value)
            let id = try Self.pathIdentifier(DirectHermesAdministrationCodec.string(row["id"], maximum: 128))
            guard seen.insert(id).inserted else { throw WorkspaceClientError.invalidResponse }
            let status = try DirectHermesAdministrationCodec.object(row["status"])
            let rawFlow = try DirectHermesAdministrationCodec.string(row["flow"], maximum: 64)
            return .init(
                id: id,
                name: try DirectHermesAdministrationCodec.string(row["name"], maximum: 800),
                flow: DirectHermesOAuthProvider.Flow(rawValue: rawFlow) ?? .unsupported,
                documentationURL: try DirectHermesAdministrationCodec.optionalHTTPSURL(row["docs_url"]),
                canDisconnect: try DirectHermesAdministrationCodec.bool(row["disconnectable"]),
                disconnectHint: try DirectHermesAdministrationCodec.optionalString(row["disconnect_hint"], maximum: 2_000),
                cliCommand: (try? DirectHermesAdministrationCodec.optionalString(row["cli_command"], maximum: 512))
                    .flatMap(Self.terminalCommand),
                status: .init(
                    isLoggedIn: try DirectHermesAdministrationCodec.bool(status["logged_in"]),
                    source: try DirectHermesAdministrationCodec.optionalString(status["source"], maximum: 256),
                    sourceLabel: try DirectHermesAdministrationCodec.optionalString(status["source_label"], maximum: 1_024),
                    expiresAt: try DirectHermesAdministrationCodec.optionalDate(status["expires_at"]),
                    hasRefreshToken: try DirectHermesAdministrationCodec.optionalBool(status["has_refresh_token"]) ?? false,
                    isFreeTier: try DirectHermesAdministrationCodec.optionalBool(status["free_tier"]),
                    accountTier: try DirectHermesAdministrationCodec.optionalString(status["account_tier"], maximum: 256),
                    errorMessage: try DirectHermesAdministrationCodec.optionalString(status["error"], maximum: 2_000)
                )
            )
        }
    }

    /// A one-line command to show and copy: printable, no line breaks.
    nonisolated static func terminalCommand(_ raw: String) -> String? {
        let command = raw.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty,
              command.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
        return command
    }

    func startOAuth(profileID: String, providerID: String) async throws -> DirectHermesOAuthSession {
        let profile = try Self.profile(profileID)
        let provider = try Self.pathIdentifier(providerID)
        let response = try await requestHTTP(.init(
            path: "/api/providers/oauth/\(provider)/start", method: .post,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 32_768
        ), mutation: true)
        let row = try DirectHermesAdministrationCodec.object(response)
        let id = try Self.pathIdentifier(DirectHermesAdministrationCodec.string(row["session_id"], maximum: 256))
        guard let expires = try DirectHermesAdministrationCodec.optionalInt(row["expires_in"], minimum: 1) else {
            throw WorkspaceClientError.invalidResponse
        }
        let rawFlow = try DirectHermesAdministrationCodec.string(row["flow"], maximum: 64)
        let flow: DirectHermesOAuthProvider.Flow
        let verificationURL: URL
        let userCode: String
        let pollInterval: TimeInterval
        switch rawFlow {
        case DirectHermesOAuthProvider.Flow.deviceCode.rawValue:
            guard let url = try DirectHermesAdministrationCodec.optionalHTTPSURL(row["verification_url"]),
                  let interval = try DirectHermesAdministrationCodec.optionalInt(row["poll_interval"], minimum: 1) else {
                throw WorkspaceClientError.invalidResponse
            }
            flow = .deviceCode
            verificationURL = url
            userCode = try DirectHermesAdministrationCodec.string(row["user_code"], maximum: 512)
            pollInterval = TimeInterval(min(max(interval, 2), 30))
        case DirectHermesOAuthProvider.Flow.pkce.rawValue:
            guard let url = try DirectHermesAdministrationCodec.optionalHTTPSURL(row["auth_url"]) else {
                throw WorkspaceClientError.invalidResponse
            }
            flow = .pkce
            verificationURL = url
            userCode = ""
            pollInterval = 2
        default:
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        return .init(
            id: id, providerID: provider, flow: flow,
            userCode: userCode,
            verificationURL: verificationURL,
            expiresAt: Date.now.addingTimeInterval(TimeInterval(min(expires, 86_400))),
            pollInterval: pollInterval, status: .pending,
            errorMessage: nil, completionReason: nil, accountEmail: nil, selectedModel: nil
        )
    }

    /// Submits a one-time PKCE completion code without retaining it. A positive
    /// response is not enough: the selected profile must report the same
    /// provider as authenticated before this returns an approved session.
    func submitOAuthCode(
        profileID: String, session: DirectHermesOAuthSession, code: String
    ) async throws -> DirectHermesOAuthSession {
        let profile = try Self.profile(profileID)
        let provider = try Self.pathIdentifier(session.providerID)
        let sessionID = try Self.pathIdentifier(session.id)
        guard session.flow == .pkce, session.status == .pending else {
            throw WorkspaceClientError.invalidRequest
        }
        let submittedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedCode.isEmpty, submittedCode.utf8.count <= 16_384,
              submittedCode.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw WorkspaceClientError.invalidRequest
        }
        let response = try await requestHTTP(.init(
            path: "/api/providers/oauth/\(provider)/submit", method: .post,
            query: [.init(name: "profile", value: profile)],
            body: ["session_id": .string(sessionID), "code": .string(submittedCode)],
            maximumResponseBytes: 16_384
        ), mutation: true)
        let row = try DirectHermesAdministrationCodec.object(response)
        let acknowledged = try DirectHermesAdministrationCodec.bool(row["ok"])
        let rawStatus = try DirectHermesAdministrationCodec.string(row["status"], maximum: 64)
        _ = try DirectHermesAdministrationCodec.optionalString(row["message"], maximum: 2_000)
        let status = DirectHermesOAuthSession.Status(rawValue: rawStatus) ?? .unknown
        guard (acknowledged && status == .approved) || (!acknowledged && status == .error) else {
            throw WorkspaceClientError.invalidResponse
        }
        if status == .approved {
            guard try await listOAuthProviders(profileID: profile)
                .first(where: { $0.id == provider })?.status.isLoggedIn == true else {
                throw WorkspaceClientError.outcomeUnknown
            }
        }
        return .init(
            id: session.id, providerID: session.providerID, flow: session.flow,
            userCode: session.userCode, verificationURL: session.verificationURL,
            expiresAt: session.expiresAt, pollInterval: session.pollInterval,
            status: status, errorMessage: status == .error ? "Provider sign-in was not accepted." : nil,
            completionReason: nil,
            accountEmail: nil, selectedModel: nil
        )
    }

    func pollOAuth(profileID: String, session: DirectHermesOAuthSession) async throws -> DirectHermesOAuthSession {
        let profile = try Self.profile(profileID)
        let provider = try Self.pathIdentifier(session.providerID)
        let sessionID = try Self.pathIdentifier(session.id)
        let response = try await requestHTTP(.init(
            path: "/api/providers/oauth/\(provider)/poll/\(sessionID)", method: .get,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 16_384
        ))
        let row = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.string(row["session_id"], maximum: 256) == sessionID else {
            throw WorkspaceClientError.invalidResponse
        }
        let rawStatus = try DirectHermesAdministrationCodec.string(row["status"], maximum: 64)
        return .init(
            id: session.id, providerID: session.providerID, flow: session.flow,
            userCode: session.userCode, verificationURL: session.verificationURL,
            expiresAt: try DirectHermesAdministrationCodec.optionalDate(row["expires_at"]) ?? session.expiresAt,
            pollInterval: session.pollInterval,
            status: DirectHermesOAuthSession.Status(rawValue: rawStatus) ?? .unknown,
            errorMessage: try DirectHermesAdministrationCodec.optionalString(row["error_message"], maximum: 2_000),
            completionReason: try DirectHermesAdministrationCodec.optionalString(row["reason"], maximum: 1_000),
            accountEmail: try DirectHermesAdministrationCodec.optionalString(row["account_email"], maximum: 512),
            selectedModel: try DirectHermesAdministrationCodec.optionalString(row["model"], maximum: 256)
        )
    }

    func cancelOAuth(profileID: String, sessionID: String) async throws {
        let profile = try Self.profile(profileID)
        let session = try Self.pathIdentifier(sessionID)
        let response = try await requestHTTP(.init(
            path: "/api/providers/oauth/sessions/\(session)", method: .delete,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 16_384
        ), mutation: true)
        let object = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(object["ok"]) else { throw WorkspaceClientError.outcomeUnknown }
    }

    func disconnectOAuth(profileID: String, providerID: String) async throws {
        let profile = try Self.profile(profileID)
        let provider = try Self.pathIdentifier(providerID)
        let response = try await requestHTTP(.init(
            path: "/api/providers/oauth/\(provider)", method: .delete,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 16_384
        ), mutation: true)
        let object = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(object["ok"]), object["provider"]?.string == provider else {
            throw WorkspaceClientError.outcomeUnknown
        }
        guard try await listOAuthProviders(profileID: profile)
            .first(where: { $0.id == provider })?.status.isLoggedIn != true else {
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    /// Process/serving-profile API. The explicit equality guard prevents a
    /// selected-profile screen from mutating the launch profile by accident.
    func listServingCredentialPools(
        profileID: String, servingProfileID: String?
    ) async throws -> [DirectHermesCredentialPool] {
        _ = try Self.requireServingProfile(profileID, servingProfileID: servingProfileID)
        let response = try await requestHTTP(.init(
            path: "/api/credentials/pool", method: .get, maximumResponseBytes: 256_000
        ))
        let object = try DirectHermesAdministrationCodec.object(response)
        let rows = try DirectHermesAdministrationCodec.array(object["providers"], maximum: 128)
        return try rows.map(Self.pool)
    }

    func addServingCredentialPoolEntry(
        profileID: String, servingProfileID: String?, providerID: String,
        apiKey: String, label: String?
    ) async throws {
        _ = try Self.requireServingProfile(profileID, servingProfileID: servingProfileID)
        let provider = try Self.pathIdentifier(providerID)
        guard !apiKey.isEmpty, apiKey.utf8.count <= 16_384,
              (label?.utf8.count ?? 0) <= 512 else { throw WorkspaceClientError.invalidRequest }
        let before = try await listServingCredentialPools(
            profileID: profileID, servingProfileID: servingProfileID
        )
        let beforeCount = before.first(where: { $0.id == provider })?.entries.count ?? 0
        var body: [String: BighelpJSONValue] = ["provider": .string(provider), "api_key": .string(apiKey)]
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["label"] = .string(label) }
        let response = try await requestHTTP(.init(
            path: "/api/credentials/pool", method: .post, body: body, maximumResponseBytes: 16_384
        ), mutation: true)
        let object = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(object["ok"]), object["provider"]?.string == provider,
              try DirectHermesAdministrationCodec.int(object["count"], minimum: 1) == beforeCount + 1 else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let after = try await listServingCredentialPools(
            profileID: profileID, servingProfileID: servingProfileID
        )
        guard after.first(where: { $0.id == provider })?.entries.count == beforeCount + 1 else {
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    func deleteServingCredentialPoolEntry(
        profileID: String, servingProfileID: String?, providerID: String,
        entry: DirectHermesCredentialPool.Entry
    ) async throws {
        _ = try Self.requireServingProfile(profileID, servingProfileID: servingProfileID)
        let provider = try Self.pathIdentifier(providerID)
        guard entry.index > 0 else { throw WorkspaceClientError.invalidRequest }
        _ = try await requestHTTP(.init(
            path: "/api/credentials/pool/\(provider)/\(entry.index)", method: .delete,
            maximumResponseBytes: 32_768
        ), mutation: true)
        let after = try await listServingCredentialPools(
            profileID: profileID, servingProfileID: servingProfileID
        )
        guard after.first(where: { $0.id == provider })?.entries.contains(where: { $0.id == entry.id }) != true else {
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    func setupStatus(profileID: String) async throws -> DirectHermesSetupStatus {
        let profile = try Self.profile(profileID)
        let row = try DirectHermesAdministrationCodec.object(try await requestRPC("setup.status", ["profile": .string(profile)]))
        let returnedProfile = try DirectHermesAdministrationCodec.optionalString(row["profile"], maximum: 128)
        guard returnedProfile == nil || returnedProfile == profile else { throw WorkspaceClientError.invalidResponse }
        return .init(
            providerConfigured: try DirectHermesAdministrationCodec.optionalBool(row["provider_configured"]),
            isReady: try DirectHermesAdministrationCodec.optionalBool(row["ready"]),
            isFreeTier: try DirectHermesAdministrationCodec.optionalBool(row["free_tier"]),
            hasOtherProviders: try DirectHermesAdministrationCodec.optionalBool(row["other_providers"]),
            inferenceProvider: try DirectHermesAdministrationCodec.optionalString(row["inference_provider"], maximum: 128),
            profileID: returnedProfile,
            isValidProfile: try DirectHermesAdministrationCodec.optionalBool(row["ok"]) ?? true,
            errorMessage: try DirectHermesAdministrationCodec.optionalString(row["error"], maximum: 2_000)
        )
    }

    func runtimeStatus(profileID: String, providerID: String? = nil) async throws -> DirectHermesRuntimeStatus {
        let profile = try Self.profile(profileID)
        var params: [String: BighelpJSONValue] = ["profile": .string(profile)]
        if let providerID { params["provider"] = .string(try Self.identifier(providerID)) }
        let row = try DirectHermesAdministrationCodec.object(try await requestRPC("setup.runtime_check", params))
        let returnedProfile = try DirectHermesAdministrationCodec.optionalString(row["profile"], maximum: 128)
        guard returnedProfile == nil || returnedProfile == profile else { throw WorkspaceClientError.invalidResponse }
        return .init(
            isUsable: try DirectHermesAdministrationCodec.bool(row["ok"]),
            providerID: try DirectHermesAdministrationCodec.optionalString(row["provider"], maximum: 128),
            modelID: try DirectHermesAdministrationCodec.optionalString(row["model"], maximum: 256),
            source: try DirectHermesAdministrationCodec.optionalString(row["source"], maximum: 256),
            isFreeTier: try DirectHermesAdministrationCodec.optionalBool(row["free_tier"]),
            profileID: returnedProfile,
            errorMessage: try DirectHermesAdministrationCodec.optionalString(row["error"], maximum: 2_000)
        )
    }

    func portalStatus() async throws -> DirectHermesPortalStatus {
        let row = try DirectHermesAdministrationCodec.object(try await requestHTTP(.init(
            path: "/api/portal", method: .get, maximumResponseBytes: 64_000
        )))
        let rawFeatures = try DirectHermesAdministrationCodec.array(row["features"], maximum: 128)
        return .init(
            isLoggedIn: try DirectHermesAdministrationCodec.bool(row["logged_in"]),
            portalURL: try DirectHermesAdministrationCodec.optionalHTTPSURL(row["portal_url"]),
            inferenceURL: try DirectHermesAdministrationCodec.optionalHTTPSURL(row["inference_url"]),
            providerID: try DirectHermesAdministrationCodec.string(row["provider"], maximum: 128),
            isFreeTier: try DirectHermesAdministrationCodec.bool(row["free_tier"]),
            accountTier: try DirectHermesAdministrationCodec.optionalString(row["account_tier"], maximum: 256),
            subscriptionURL: try DirectHermesAdministrationCodec.optionalHTTPSURL(row["subscription_url"]),
            features: try rawFeatures.map { value in
                let item = try DirectHermesAdministrationCodec.object(value)
                return .init(
                    label: try DirectHermesAdministrationCodec.string(item["label"], maximum: 800),
                    state: try DirectHermesAdministrationCodec.string(item["state"], maximum: 800)
                )
            }
        )
    }

    /// RPCs without a profile parameter intentionally name the serving scope.
    /// The caller must provide the same profile identity on both sides.
    func saveServingProviderKey(
        profileID: String, servingProfileID: String?, providerID: String, apiKey: String
    ) async throws -> DirectHermesProviderDescriptor {
        let profile = try Self.requireServingProfile(profileID, servingProfileID: servingProfileID)
        let provider = try Self.pathIdentifier(providerID)
        guard !apiKey.isEmpty, apiKey.utf8.count <= 16_384 else { throw WorkspaceClientError.invalidRequest }
        let response = try await requestRPC("model.save_key", ["slug": .string(provider), "api_key": .string(apiKey)], mutation: true)
        let object = try DirectHermesAdministrationCodec.object(response)
        let row = try DirectHermesAdministrationCodec.object(object["provider"])
        guard try DirectHermesAdministrationCodec.bool(row["authenticated"]), row["slug"]?.string == provider else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let models = try DirectHermesAdministrationCodec.stringArray(row["models"], maximumCount: 20_000, maximumBytes: 256, required: false)
        let decoded = DirectHermesProviderDescriptor(
            id: provider,
            name: try DirectHermesAdministrationCodec.string(row["name"], maximum: 800),
            authType: try DirectHermesAdministrationCodec.optionalString(row["auth_type"], maximum: 128),
            isAuthenticated: true,
            keyEnvironment: try DirectHermesAdministrationCodec.optionalString(row["key_env"], maximum: 128),
            isCurrent: try DirectHermesAdministrationCodec.optionalBool(row["is_current"]) ?? false,
            isCustom: try DirectHermesAdministrationCodec.optionalBool(row["is_user_defined"]) ?? false,
            modelCount: try DirectHermesAdministrationCodec.optionalInt(row["total_models"], minimum: 0) ?? models.count
        )
        guard try await listProviders(profileID: profile, refresh: true)
            .first(where: { $0.id == provider })?.isAuthenticated == true else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return decoded
    }

    func disconnectServingProvider(
        profileID: String, servingProfileID: String?, providerID: String
    ) async throws {
        let profile = try Self.requireServingProfile(profileID, servingProfileID: servingProfileID)
        let provider = try Self.pathIdentifier(providerID)
        let row = try DirectHermesAdministrationCodec.object(try await requestRPC(
            "model.disconnect", ["slug": .string(provider)], mutation: true
        ))
        guard row["slug"]?.string == provider, try DirectHermesAdministrationCodec.bool(row["disconnected"]) else {
            throw WorkspaceClientError.outcomeUnknown
        }
        guard try await listProviders(profileID: profile, refresh: true)
            .first(where: { $0.id == provider })?.isAuthenticated != true else {
            throw WorkspaceClientError.outcomeUnknown
        }
    }

    @discardableResult
    func reloadServingEnvironment(profileID: String, servingProfileID: String?) async throws -> Int {
        _ = try Self.requireServingProfile(profileID, servingProfileID: servingProfileID)
        let row = try DirectHermesAdministrationCodec.object(try await requestRPC("reload.env", [:], mutation: true))
        return try DirectHermesAdministrationCodec.int(row["updated"], minimum: 0)
    }

    private func requestHTTP(_ request: DirectHermesHTTPRequest, mutation: Bool = false) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: checkOwner,
            mapError: { DirectHermesAdministrationCodec.safeError($0, mutation: mutation) }) {
            try await http.request(request)
        }
    }

    private func requestRPC(_ method: String, _ params: [String: BighelpJSONValue], mutation: Bool = false) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: checkOwner,
            mapError: { DirectHermesAdministrationCodec.safeError($0, mutation: mutation) }) {
            try await rpc.request(method, params: params)
        }
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard ownsScope else { throw WorkspaceClientError.ownerChanged }
    }

    private static func validation(_ response: BighelpJSONValue) throws -> DirectHermesProviderValidation {
        let row = try DirectHermesAdministrationCodec.object(response)
        return .init(
            isAccepted: try DirectHermesAdministrationCodec.bool(row["ok"]),
            isReachable: try DirectHermesAdministrationCodec.bool(row["reachable"]),
            message: try DirectHermesAdministrationCodec.string(row["message"], maximum: 2_000),
            models: try DirectHermesAdministrationCodec.stringArray(row["models"], maximumCount: 20_000, maximumBytes: 256, required: false)
        )
    }

    private static func customEndpointBody(_ draft: DirectHermesCustomEndpointDraft) throws -> [String: BighelpJSONValue] {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 800, !model.isEmpty, model.utf8.count <= 256,
              draft.models.count <= 20_000, (draft.contextLength.map({ $0 > 0 }) ?? true),
              (draft.apiKey?.utf8.count ?? 0) <= 16_384 else { throw WorkspaceClientError.invalidRequest }
        try validateEndpointURL(baseURL)
        var body: [String: BighelpJSONValue] = [
            "id": .string(try draft.id.map(pathIdentifier) ?? ""),
            "name": .string(name), "base_url": .string(baseURL), "model": .string(model),
            "models": .array(try draft.models.map {
                guard !$0.isEmpty, $0.utf8.count <= 256 else { throw WorkspaceClientError.invalidRequest }
                return .string($0)
            }),
            "discover_models": .boolean(draft.discoversModels), "make_default": .boolean(draft.makeDefault),
        ]
        if let context = draft.contextLength { body["context_length"] = .integer(context) }
        if let key = draft.apiKey { body["api_key"] = .string(key) }
        return body
    }

    private static func pool(_ value: BighelpJSONValue) throws -> DirectHermesCredentialPool {
        let row = try DirectHermesAdministrationCodec.object(value)
        let provider = try pathIdentifier(DirectHermesAdministrationCodec.string(row["provider"], maximum: 128))
        let entries = try DirectHermesAdministrationCodec.array(row["entries"], maximum: 1_024).map { value in
            let item = try DirectHermesAdministrationCodec.object(value)
            return DirectHermesCredentialPool.Entry(
                index: try DirectHermesAdministrationCodec.int(item["index"], minimum: 1),
                id: try DirectHermesAdministrationCodec.string(item["id"], maximum: 256),
                label: try DirectHermesAdministrationCodec.string(item["label"], maximum: 800),
                authType: try DirectHermesAdministrationCodec.string(item["auth_type"], maximum: 128),
                source: try DirectHermesAdministrationCodec.string(item["source"], maximum: 256),
                priority: try DirectHermesAdministrationCodec.int(item["priority"]),
                lastStatus: try DirectHermesAdministrationCodec.optionalString(item["last_status"], maximum: 512),
                requestCount: try DirectHermesAdministrationCodec.int(item["request_count"], minimum: 0),
                hasRefreshToken: try DirectHermesAdministrationCodec.bool(item["has_refresh"])
            )
        }
        guard Set(entries.map(\.id)).count == entries.count else { throw WorkspaceClientError.invalidResponse }
        return .init(id: provider, entries: entries)
    }

    nonisolated static func profile(_ value: String) throws -> String {
        try DirectHermesCoreRequestScope.profile(value)
    }

    nonisolated private static func requireServingProfile(
        _ profileID: String, servingProfileID: String?
    ) throws -> String {
        let requested = try Self.profile(profileID)
        guard let servingProfileID,
              requested == (try Self.profile(servingProfileID)) else {
            throw WorkspaceClientError.unavailable(.policyRestricted)
        }
        return requested
    }

    nonisolated static func identifier(_ value: String) throws -> String {
        try WorkspaceAuthority.validateIdentifier(value, maximumBytes: 128)
        guard !value.contains("/"), !value.contains("\\"), value != ".", value != ".." else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    nonisolated static func pathIdentifier(_ value: String) throws -> String {
        let value = try identifier(value)
        guard value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 46].contains($0)
        }) else { throw WorkspaceClientError.invalidRequest }
        return value
    }

    nonisolated static func isEnvironmentKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }

    nonisolated static func validateEndpointURL(_ value: String) throws {
        guard value.utf8.count <= 2_048,
              let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw WorkspaceClientError.invalidRequest }
    }
}
