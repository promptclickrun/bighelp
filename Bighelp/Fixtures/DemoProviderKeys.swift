import Foundation

#if DEBUG
/// Demo runs: Provider Keys with made-up accounts and keys, and no host. Nous is
/// signed in and OpenRouter has a key; a phone sign-in is approved after two
/// checks. The shapes match what Hermes' dashboard answers.
@MainActor
final class DemoProviderKeysTransport: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
    var onEvent: ((DirectHermesEvent) -> Void)?

    private(set) var signedIn: Set<String> = ["nous"]
    /// Seconds each Refresh model catalogs request was allowed, in order.
    private(set) var catalogRefreshTimeouts: [TimeInterval] = []
    private var savedKeys: Set<String> = ["OPENROUTER_API_KEY"]
    private var sessions: [String: (provider: String, checks: Int)] = [:]

    private static let accounts: [(id: String, name: String, flow: String, command: String)] = [
        ("nous", "Nous Portal", "device_code", "hermes auth add nous"),
        ("openai-codex", "ChatGPT or Codex Subscription", "device_code", "hermes auth add openai-codex"),
        ("qwen-oauth", "Qwen (via Qwen CLI)", "external", "hermes auth add qwen-oauth"),
        ("minimax-oauth", "MiniMax (OAuth)", "device_code", "hermes auth add minimax-oauth"),
        ("xai-oauth", "xAI Grok OAuth (SuperGrok / Premium+)", "device_code", "hermes auth add xai-oauth"),
        ("copilot-acp", "GitHub Copilot (ACP)", "external", "copilot login"),
        ("claude-subscription-directsdk-experimental", "Claude Subscription DirectSDK (Experimental)", "external",
         "hermes auth add claude-subscription-directsdk-experimental"),
        ("anthropic", "Anthropic Account", "external", "hermes auth add anthropic"),
    ]

    private static let keys: [(id: String, provider: String, label: String, secret: Bool)] = [
        ("OPENROUTER_API_KEY", "openrouter", "OpenRouter", true),
        ("OPENAI_API_KEY", "openai", "OpenAI", true),
        ("ANTHROPIC_API_KEY", "anthropic", "Anthropic", true),
        ("GEMINI_API_KEY", "gemini", "Google AI Studio", true),
        ("DEEPSEEK_API_KEY", "deepseek", "DeepSeek", true),
        ("GROQ_API_KEY", "groq", "Groq", true),
        ("MISTRAL_API_KEY", "mistral", "Mistral", true),
        ("XAI_API_KEY", "xai", "xAI", true),
        ("DASHSCOPE_API_KEY", "alibaba", "Qwen Cloud", true),
        ("COPILOT_GITHUB_TOKEN", "copilot", "GitHub Copilot", true),
        ("OPENAI_BASE_URL", "openai", "OpenAI", false),
    ]

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        switch method {
        case "setup.status":
            return .object(["profile": .string("default"), "provider_configured": .boolean(true), "ready": .boolean(true),
                            "free_tier": .boolean(true), "inference_provider": .string("nous")])
        case "setup.runtime_check":
            return .object(["profile": .string("default"), "ok": .boolean(true), "provider": .string("nous"),
                            "model": .string("hermes-4-405b"), "source": .string("config")])
        default:
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    func disconnect() async {}

    /// What the host's sign-in leaves behind: Hermes' GitHub login saves a
    /// Copilot token; the others are accounts Hermes sees as signed in.
    func markSignedIn(_ provider: String) {
        if provider == "copilot" { savedKeys.insert("COPILOT_GITHUB_TOKEN") } else { signedIn.insert(provider) }
    }

    var hasCopilotToken: Bool { savedKeys.contains("COPILOT_GITHUB_TOKEN") }

    /// Hermes 0.22's status cards: Nous sends its expiry as ISO 8601 text,
    /// a ChatGPT sign-in from the credential pool sends none.
    private static func status(_ id: String, signedIn: Bool) -> [String: BighelpJSONValue] {
        guard signedIn else { return ["logged_in": .boolean(false), "source": .null, "expires_at": .null] }
        switch id {
        case "nous":
            return ["logged_in": .boolean(true), "source": .string("nous_portal"),
                    "source_label": .string("https://portal.nousresearch.com"), "token_preview": .string("…demo"),
                    "expires_at": .string("2026-10-17T03:20:42+00:00"), "has_refresh_token": .boolean(true),
                    "free_tier": .boolean(true), "account_tier": .null]
        case "openai-codex":
            return ["logged_in": .boolean(true), "source": .string("pool:device_code"),
                    "source_label": .string("device_code"), "token_preview": .string("…demo"), "expires_at": .null,
                    "has_refresh_token": .boolean(true), "last_refresh": .string("2026-10-16T20:01:12+00:00")]
        default:
            return ["logged_in": .boolean(true), "source": .string(id), "expires_at": .null]
        }
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        let path = request.path
        switch (request.method, path) {
        case (.get, "/api/model/options"):
            if request.query.contains(.init(name: "refresh", value: "true")) { catalogRefreshTimeouts.append(request.timeout) }
            return .object(["providers": .array(Self.keys.filter(\.secret).map { key in
                .object(["slug": .string(key.provider), "name": .string(key.label), "auth_type": .string("api_key"),
                         "authenticated": .boolean(savedKeys.contains(key.id)), "key_env": .string(key.id),
                         "total_models": .integer(12)])
            } + [.object(["slug": .string("nous"), "name": .string("Nous Portal"), "auth_type": .string("oauth_device_code"),
                          "authenticated": .boolean(signedIn.contains("nous")), "is_current": .boolean(true),
                          "total_models": .integer(8)])])])
        case (.get, "/api/env"):
            var rows: [String: BighelpJSONValue] = [:]
            for key in Self.keys {
                rows[key.id] = .object(["provider": .string(key.provider), "provider_label": .string(key.label),
                                        "description": .string("\(key.label) credential"), "category": .string("provider"),
                                        "is_set": .boolean(savedKeys.contains(key.id)), "is_password": .boolean(key.secret),
                                        "advanced": .boolean(!key.secret)])
            }
            return .object(rows)
        case (.post, "/api/providers/validate"):
            return .object(["ok": .boolean(true), "reachable": .boolean(true), "message": .string("The key works."),
                            "models": .array([])])
        case (.put, "/api/env"):
            if let key = request.body?["key"]?.string { savedKeys.insert(key) }
            return .object(["ok": .boolean(true)])
        case (.delete, "/api/env"):
            if let key = request.body?["key"]?.string { savedKeys.remove(key) }
            return .object(["ok": .boolean(true)])
        case (.get, "/api/providers/oauth"):
            return .object(["providers": .array(Self.accounts.map { account in
                let isSignedIn = signedIn.contains(account.id)
                return .object([
                    "id": .string(account.id), "name": .string(account.name), "flow": .string(account.flow),
                    "cli_command": .string(account.command), "docs_url": .string("https://example.com/\(account.id)"),
                    "disconnectable": .boolean(account.flow != "external"),
                    "status": .object(Self.status(account.id, signedIn: isSignedIn)),
                ])
            })])
        case (.get, "/api/providers/custom-endpoints"):
            return .object(["endpoints": .array([])])
        case (.get, "/api/credentials/pool"):
            return .object(["providers": .array([])])
        case (.get, "/api/portal"):
            return .object(["logged_in": .boolean(signedIn.contains("nous")), "provider": .string("nous"),
                            "free_tier": .boolean(true), "features": .array([])])
        default:
            break
        }
        // "/api/providers/oauth/<provider>/start", ".../<provider>/poll/<session>",
        // "/api/providers/oauth/sessions/<session>" and "/api/providers/oauth/<provider>".
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "api", parts[1] == "providers", parts[2] == "oauth" else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        if request.method == .post, parts.count == 5, parts[4] == "start" {
            let id = "demo-\(sessions.count + 1)"
            sessions[id] = (parts[3], 0)
            return .object(["session_id": .string(id), "flow": .string("device_code"), "user_code": .string("WDJB-MJHT"),
                            "verification_url": .string("https://example.com/device"), "expires_in": .integer(900),
                            "poll_interval": .integer(2)])
        }
        if request.method == .get, parts.count == 6, parts[4] == "poll", var session = sessions[parts[5]] {
            session.checks += 1
            sessions[parts[5]] = session
            let approved = session.checks >= 2
            if approved { signedIn.insert(session.provider) }
            return .object(["session_id": .string(parts[5]), "status": .string(approved ? "approved" : "pending")])
        }
        if request.method == .delete, parts.count == 5, parts[3] == "sessions" {
            sessions[parts[4]] = nil
            return .object(["ok": .boolean(true)])
        }
        if request.method == .delete, parts.count == 4 {
            signedIn.remove(parts[3])
            return .object(["ok": .boolean(true), "provider": .string(parts[3])])
        }
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
}

/// Demo runs: the plugin's sign-ins with each provider's own tool. GitHub
/// Copilot signs in with a code, Claude accounts take a pasted code, the
/// Copilot CLI isn't installed, and Qwen ended its sign-in.
@MainActor
final class DemoHostSignInClient: HostSignInClient {
    private let transport: DemoProviderKeysTransport
    private var sessions: [String: (provider: String, flow: HostSignInFlow, status: HostSignInSession.Status, checks: Int)] = [:]

    init(transport: DemoProviderKeysTransport) { self.transport = transport }

    func providers(agentID: String) async throws -> [HostSignInProvider] {
        let claudeSignedIn = transport.signedIn.contains("claude-subscription-directsdk-experimental")
        return [
            .init(providerID: "copilot", name: "GitHub Copilot", client: "Hermes", flow: .device,
                  state: .ready(signedIn: transport.hasCopilotToken),
                  documentationURL: URL(string: "https://example.com/copilot")),
            .init(providerID: "copilot-acp", name: "GitHub Copilot (ACP)", client: "GitHub Copilot CLI", flow: .device,
                  state: .notInstalled(installCommand: "npm install -g @github/copilot"),
                  documentationURL: URL(string: "https://example.com/copilot-cli")),
            .init(providerID: "claude-subscription-directsdk-experimental", name: "Claude Subscription DirectSDK",
                  client: "Claude Code", flow: .paste, state: .ready(signedIn: claudeSignedIn),
                  documentationURL: URL(string: "https://example.com/claude-code")),
            .init(providerID: "anthropic", name: "Anthropic Account", client: "Claude Code", flow: .paste,
                  state: .ready(signedIn: nil), documentationURL: URL(string: "https://example.com/claude-code")),
            .init(providerID: "qwen-oauth", name: "Qwen OAuth", client: "Qwen Code", flow: .device,
                  state: .retired(message: "Qwen stopped offering Qwen OAuth sign-in in April 2026. Use a Qwen Cloud API key instead.",
                                  replacementKey: "DASHSCOPE_API_KEY"),
                  documentationURL: nil),
        ]
    }

    func start(agentID: String, providerID: String) async throws -> HostSignInSession {
        guard let provider = try await providers(agentID: agentID).first(where: { $0.providerID == providerID }),
              case .ready = provider.state else { throw WorkspaceClientError.rejected(code: "sign_in_unavailable") }
        let id = UUID().uuidString.lowercased()
        sessions[id] = (providerID, provider.flow, provider.flow == .paste ? .needsCode : .waiting, 0)
        return session(id)
    }

    func status(agentID: String, sessionID: String) async throws -> HostSignInSession {
        guard var entry = sessions[sessionID] else { throw WorkspaceClientError.rejected(code: "sign_in_not_found") }
        entry.checks += 1
        // A device sign-in is approved on the second check; a pasted code lands on the next one.
        if (entry.status == .waiting && entry.checks >= 2) || entry.status == .finishing {
            entry.status = .signedIn
            transport.markSignedIn(entry.provider)
        }
        sessions[sessionID] = entry
        return session(sessionID)
    }

    func submit(agentID: String, sessionID: String, code: String) async throws -> HostSignInSession {
        guard var entry = sessions[sessionID], entry.status == .needsCode else {
            throw WorkspaceClientError.rejected(code: "sign_in_not_waiting")
        }
        entry.status = code.lowercased().hasPrefix("wrong") ? .failed : .finishing
        sessions[sessionID] = entry
        return session(sessionID)
    }

    func cancel(agentID: String, sessionID: String) async throws -> HostSignInSession {
        sessions[sessionID]?.status = .cancelled
        return session(sessionID)
    }

    private func session(_ id: String) -> HostSignInSession {
        let entry = sessions[id]!
        let running = [.waiting, .needsCode].contains(entry.status)
        let link = entry.flow == .paste ? "https://claude.com/cai/oauth/authorize?demo=1" : "https://github.com/login/device"
        return HostSignInSession(id: id, providerID: entry.provider, flow: entry.flow, status: entry.status,
                                 link: running ? URL(string: link) : nil,
                                 code: running && entry.flow == .device ? "HJKL-4821" : nil,
                                 message: entry.status == .failed ? "Claude Code didn't accept that code. Try again." : nil)
    }
}

@MainActor
enum DemoProviderKeys {
    static let shared = store()

    static func store() -> ProviderAccountsStore? {
        guard let authority = try? WorkspaceAuthority.direct(endpointIdentity: "https://demo-mac.example", providerID: "demo",
                                                             userID: "demo") else { return nil }
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let transport = DemoProviderKeysTransport()
        let client = DirectHermesProviderClient(rpc: transport, http: transport, owner: owner, currentOwner: { owner })
        return ProviderAccountsStore(hostName: "Demo Mac", profileID: "default", servingProfileID: "default",
                                     client: client,
                                     hostSignIn: ProviderHostSignInStore(profileID: "default", hostName: "Demo Mac",
                                                                         client: DemoHostSignInClient(transport: transport),
                                                                         pollInterval: .seconds(1)))
    }
}
#endif
