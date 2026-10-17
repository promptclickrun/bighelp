#if DEBUG
import Foundation

/// Demo runs: Composio Apps with a made-up catalog and account, and no network. Gmail and
/// GitHub start connected; a new app's sign-in "finishes" at once, except Calendly's. The demo
/// computer has no Composio until Turn on for my agent, and its sign-in approves at once.
@MainActor
enum DemoComposio {
    static func model(signedIn: Bool = true, connect: DemoComposioConnect = DemoComposioConnect()) -> ComposioAppsModel {
        let vault = DemoComposioVault()
        if signedIn { try? vault.save(credential) }
        let account = ComposioAccount(vault: vault)
        return ComposioAppsModel(
            account: account, connect: connect, catalog: DemoComposioCatalog(),
            agentHost: DemoComposioAgentHost(),
            signIn: { account in try await account.finishSignInForDemo() },
            sleep: { _ in }
        )
    }

    static let credential = ComposioCredential(clientID: "demo-client", accessToken: "demo-access",
                                               refreshToken: "demo-refresh",
                                               accessExpiresAt: Date(timeIntervalSinceNow: 86_400),
                                               email: "alex@example.com")

    static let catalog = ComposioCatalog(
        revision: "demo",
        categories: [
            .init(id: "collaboration-communication", name: "Collaboration & Communication"),
            .init(id: "developer-tools", name: "Developer Tools"),
            .init(id: "productivity", name: "Productivity"),
            .init(id: "scheduling-booking", name: "Scheduling & Booking"),
        ],
        toolkits: [
            app("gmail", "Gmail", "Read, send and organize email.", ["collaboration-communication", "productivity"]),
            app("github", "GitHub", "Issues, pull requests and code.", ["developer-tools"]),
            app("slack", "Slack", "Messages and channels.", ["collaboration-communication"]),
            app("googlecalendar", "Google Calendar", "Events and invitations.", ["productivity", "scheduling-booking"]),
            app("notion", "Notion", "Pages and databases.", ["productivity"]),
            app("linear", "Linear", "Issues and projects.", ["developer-tools", "productivity"]),
            app("calendly", "Calendly", "Booking links and meetings.", ["scheduling-booking"]),
            app("hackernews", "Hacker News", "Stories and comments.", ["collaboration-communication"], noAuth: true),
        ]
    )

    private static func app(_ slug: String, _ name: String, _ summary: String, _ categories: [String],
                            noAuth: Bool = false) -> ComposioCatalog.Toolkit {
        .init(slug: slug, name: name, summary: summary, logoURL: nil, categories: categories, noAuth: noAuth)
    }
}

extension ComposioAccount {
    /// The demo's sign-in: no page, just the made-up account.
    func finishSignInForDemo() async throws {
        try await finishSignIn(demo: DemoComposio.credential)
    }
}

@MainActor
final class DemoComposioVault: ComposioCredentialVault {
    private var saved: ComposioCredential?
    func load() -> ComposioCredential? { saved }
    func save(_ credential: ComposioCredential) throws { saved = credential }
    func remove() { saved = nil }
}

@MainActor
final class DemoComposioCatalog: ComposioCatalogLoading {
    func cached() -> ComposioCatalog? { DemoComposio.catalog }
    func refresh() async throws -> ComposioCatalog { DemoComposio.catalog }
}

@MainActor
final class DemoComposioConnect: ComposioConnecting {
    /// Calendly's sign-in never finishes, so its page stays open until it's closed.
    static let neverFinishes: Set<String> = ["calendly"]

    private var accounts: [String: [ComposioConnection.Account]] = [
        "gmail": [.init(id: "gmail_demo-1", status: "active", email: "alex@example.com")],
        "github": [.init(id: "github_demo-1", status: "active", email: nil)],
    ]
    private var made = 0
    private(set) var removed: [String] = []

    func connectedToolkits() async throws -> [String] {
        accounts.filter { $0.value.contains(where: \.isActive) }.keys.sorted()
    }

    /// A pending account turns active the first time it's checked (the demo's page "finishes" at once).
    func connections(_ toolkits: [String]) async throws -> [String: ComposioConnection] {
        for slug in toolkits where !Self.neverFinishes.contains(slug) {
            accounts[slug] = accounts[slug]?.map { $0.isActive ? $0 : .init(id: $0.id, status: "active", email: nil) }
        }
        return Dictionary(uniqueKeysWithValues: toolkits.map { ($0, ComposioConnection(toolkit: $0, accounts: accounts[$0] ?? [])) })
    }

    func connect(_ toolkit: String) async throws -> ComposioConnectStart {
        made += 1
        let id = "\(toolkit)_demo-\(made)"
        accounts[toolkit, default: []].append(.init(id: id, status: "initiated", email: nil))
        return ComposioConnectStart(url: URL(string: "https://example.com/composio/connect/\(toolkit)")!, pendingAccountID: id)
    }

    func remove(_ toolkit: String, accountID: String) async throws {
        removed.append(accountID)
        accounts[toolkit]?.removeAll { $0.id == accountID }
        if accounts[toolkit]?.isEmpty == true { accounts[toolkit] = nil }
    }
}

@MainActor
final class DemoComposioAgentHost: ComposioAgentHost {
    let hostName = "Demo Mac"
    let agentName = "Atlas"
    private var state: ComposioAgentAccess = .notInstalled

    func access() async throws -> ComposioAgentAccess { state }

    func install() async throws -> String {
        if case .notInstalled = state { state = .needsSignIn(server: "composio") }
        return "composio"
    }

    func startSignIn(server: String) async throws -> MCPOAuthFlow {
        .init(id: "demo-flow", serverName: server, status: .authorizationRequired,
              authorizationURL: nil, error: nil, tools: [])
    }

    func signInStatus(flowID: String) async throws -> MCPOAuthFlow {
        state = .ready(server: "composio")
        return .init(id: flowID, serverName: "composio", status: .approved, authorizationURL: nil, error: nil, tools: [])
    }
}
#endif
