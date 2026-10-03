#if DEBUG
import Foundation

/// Demo runs: Settings › Default model against made-up providers, with each
/// agent's own default, so the agent rail and the model picker work without a
/// host. Answers the way Hermes' dashboard does and remembers what you save.
@MainActor
final class DemoModelsTransport: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
    var onEvent: ((DirectHermesEvent) -> Void)?

    private var mains: [String: (provider: String, model: String)]
    private let fallback: (provider: String, model: String)
    private let answersReadiness: Bool
    private var tasks: [(task: String, provider: String, model: String)] = [
        ("vision", "auto", ""), ("compression", "anthropic", "claude-haiku-4-5"), ("title_generation", "auto", "")
    ]

    /// `defaults` maps an agent to its default; others start on `fallback`.
    init(defaults: [String: (provider: String, model: String)] = [:],
         fallback: (provider: String, model: String) = ("openai", "gpt-5.6"),
         answersReadiness: Bool = true) {
        mains = defaults
        self.fallback = fallback
        self.answersReadiness = answersReadiness
    }

    func main(for profile: String) -> (provider: String, model: String) { mains[profile] ?? fallback }

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        guard method == "setup.runtime_check", answersReadiness else {
            throw WorkspaceClientError.unavailable(.policyRestricted)
        }
        let profile = params["profile"]?.string ?? "default"
        let main = main(for: profile)
        return .object(["profile": .string(profile), "ok": .boolean(true), "provider": .string(main.provider),
                        "model": .string(main.model), "source": .string("config")])
    }

    func disconnect() async {}

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        let profile = request.query.first(where: { $0.name == "profile" })?.value
            ?? request.body?["profile"]?.string ?? "default"
        let main = main(for: profile)
        switch request.path {
        case "/api/model/options":
            return .object(["providers": .array([
                provider("openai", "OpenAI", ["gpt-5.6", "gpt-5.6-mini"], current: main.provider == "openai"),
                provider("anthropic", "Anthropic", ["claude-sonnet-5", "claude-haiku-4-5"], current: main.provider == "anthropic"),
                provider("nous", "Nous Research", ["Hermes-4-405B", "Hermes-4-70B"], current: main.provider == "nous"),
            ])])
        case "/api/model/info":
            return .object([
                "provider": .string(main.provider), "model": .string(main.model),
                "auto_context_length": .integer(400_000), "config_context_length": .integer(0),
                "effective_context_length": .integer(400_000), "capabilities": .null,
            ])
        case "/api/model/auxiliary":
            return .object([
                "main": .object(["provider": .string(main.provider), "model": .string(main.model)]),
                "tasks": .array(tasks.map {
                    .object(["task": .string($0.task), "provider": .string($0.provider), "model": .string($0.model),
                             "base_url": .string(""), "local_endpoint": .boolean(false)])
                }),
            ])
        case "/api/model/moa":
            return .object([
                "default_preset": .string("balanced"), "active_preset": .string(""),
                "presets": .object(["balanced": .object([
                    "reference_models": .array([
                        .object(["provider": .string("openai"), "model": .string("gpt-5.6")]),
                        .object(["provider": .string("anthropic"), "model": .string("claude-sonnet-5")]),
                    ]),
                    "aggregator": .object(["provider": .string("nous"), "model": .string("Hermes-4-405B")]),
                    "degraded_reference_policy": .string("loud"), "enabled": .boolean(true),
                ])]),
            ])
        case "/api/model/set":
            let body = request.body ?? [:]
            let provider = body["provider"]?.string ?? "", model = body["model"]?.string ?? ""
            if body["scope"]?.string == "main" {
                mains[profile] = (provider, model)
            } else if let task = body["task"]?.string, let index = tasks.firstIndex(where: { $0.task == task }) {
                tasks[index] = (task, provider, model)
            }
            return .object(["ok": .boolean(true)])
        default:
            throw WorkspaceClientError.unavailable(.policyRestricted)
        }
    }

    private func provider(_ slug: String, _ name: String, _ models: [String], current: Bool) -> BighelpJSONValue {
        .object(["slug": .string(slug), "name": .string(name), "models": .array(models.map { .string($0) }),
                 "is_current": .boolean(current)])
    }
}

/// The demo's Default model page runs the same host screens as a real
/// computer. Those need a direct sign-in, so the demo's stands in for its
/// fixture one, keeping its generations: a demo reconnect is still a reconnect.
@MainActor
enum DemoModels {
    /// Each demo agent starts on a different model, so picking one shows it.
    static let transport = DemoModelsTransport(defaults: [
        "finance": ("openai", "gpt-5.6"),
        "travel": ("anthropic", "claude-sonnet-5"),
        "home": ("nous", "Hermes-4-70B"),
    ])

    static func owner(standingInFor fixture: WorkspaceOwner) -> WorkspaceOwner? {
        guard let authority = authority else { return nil }
        return WorkspaceOwner(authority: authority, authenticationGeneration: fixture.authenticationGeneration,
                              connectionGeneration: fixture.connectionGeneration)
    }

    static func signIn(standingInFor fixture: WorkspaceSignIn) -> WorkspaceSignIn? {
        authority.map { WorkspaceSignIn(authority: $0, authenticationGeneration: fixture.authenticationGeneration) }
    }

    private static let authority = try? WorkspaceAuthority.direct(
        endpointIdentity: "https://demo-mac.example", providerID: "demo", userID: "demo"
    )
}
#endif
