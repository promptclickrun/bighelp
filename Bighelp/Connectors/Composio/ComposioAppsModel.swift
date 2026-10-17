import Foundation
import Observation

/// Whether the agent on the computer in use can use the person's Composio apps: Hermes
/// needs Composio Connect's MCP server, turned on and signed in to the same account.
enum ComposioAgentAccess: Equatable, Sendable {
    case unknown
    /// The computer's bighelp plugin is older than `native-composio-v1`.
    case needsPluginUpdate
    case notInstalled
    case turnedOff(server: String)
    case needsSignIn(server: String)
    case ready(server: String)
}

/// The computer's side: our plugin reports and installs Composio Connect in Hermes, and
/// Hermes' own MCP sign-in signs it in.
@MainActor
protocol ComposioAgentHost: AnyObject {
    var hostName: String { get }
    var agentName: String { get }
    func access() async throws -> ComposioAgentAccess
    /// Installs and turns on Composio Connect; returns the server's name.
    func install() async throws -> String
    func startSignIn(server: String) async throws -> MCPOAuthFlow
    func signInStatus(flowID: String) async throws -> MCPOAuthFlow
}

/// Settings › Apps › Composio Apps: sign in to Composio once, browse its apps by category,
/// connect and remove them, and let the agent on this computer use them.
@MainActor
@Observable
final class ComposioAppsModel {
    let account: ComposioAccount
    private(set) var catalog: ComposioCatalog?
    private(set) var catalogFailed = false
    /// Apps with at least one account, by slug, as Composio last said.
    private(set) var connections: [String: ComposioConnection] = [:]
    private(set) var connectedSlugs: [String] = []
    private(set) var agent: ComposioAgentAccess = .unknown
    private(set) var isSigningIn = false
    private(set) var isLoadingConnections = false
    private(set) var busySlug: String?
    private(set) var agentWorking = false
    private(set) var message: String?
    var search = ""

    @ObservationIgnored private let connect: any ComposioConnecting
    @ObservationIgnored private let catalogStore: any ComposioCatalogLoading
    @ObservationIgnored private let agentHost: (any ComposioAgentHost)?
    @ObservationIgnored private let signInFlow: (ComposioAccount) async throws -> Void
    @ObservationIgnored private let sleep: (Duration) async throws -> Void

    init(account: ComposioAccount,
         connect: (any ComposioConnecting)? = nil,
         catalog: any ComposioCatalogLoading = ComposioCatalogStore(),
         agentHost: (any ComposioAgentHost)?,
         signIn: @escaping (ComposioAccount) async throws -> Void = { try await ComposioSignInBrowser().signIn(account: $0) },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.account = account
        self.connect = connect ?? ComposioConnectClient(account: account)
        catalogStore = catalog
        self.agentHost = agentHost
        signInFlow = signIn
        self.sleep = sleep
    }

    var hostName: String? { agentHost?.hostName }
    var agentName: String? { agentHost?.agentName }

    /// The connected apps, in the catalog's order, then any the catalog doesn't know.
    var connectedApps: [ComposioCatalog.Toolkit] {
        let slugs = connectedSlugs.filter { connections[$0]?.isConnected ?? true }
        let known = slugs.compactMap { catalog?.toolkit($0) }
        let unknown = slugs.filter { catalog?.toolkit($0) == nil }.map {
            ComposioCatalog.Toolkit(slug: $0, name: Self.displayName($0), summary: "", logoURL: nil, categories: [], noAuth: false)
        }
        return known + unknown
    }

    func isConnected(_ slug: String) -> Bool {
        connections[slug]?.isConnected ?? connectedSlugs.contains(slug)
    }

    func appear() async {
        account.reload()
        if catalog == nil { catalog = catalogStore.cached() }
        async let catalogLoad: Void = refreshCatalog()
        async let agentLoad: Void = refreshAgent()
        if account.isSignedIn { await refreshConnected() }
        _ = await (catalogLoad, agentLoad)
    }

    func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        message = nil
        defer { isSigningIn = false }
        do {
            try await signInFlow(account)
            await refreshConnected()
        } catch ComposioError.signInCancelled {
        } catch {
            message = "Composio didn't finish the sign-in. Try again."
        }
    }

    func signOut() {
        account.signOut()
        connections = [:]
        connectedSlugs = []
    }

    /// Which apps Composio lists as connected, with their accounts.
    func refreshConnected() async {
        guard account.isSignedIn else { return }
        isLoadingConnections = true
        defer { isLoadingConnections = false }
        do {
            let slugs = try await connect.connectedToolkits()
            let found = try await connect.connections(slugs)
            connections.merge(found) { _, new in new }
            connectedSlugs = slugs.filter { found[$0]?.isConnected ?? true }
            message = nil
        } catch {
            handle(error, fallback: "Composio didn't answer. Pull down to try again.")
        }
    }

    /// Account status for the apps on screen (a category or a search).
    func loadStatus(for toolkits: [ComposioCatalog.Toolkit]) async {
        guard account.isSignedIn else { return }
        let missing = toolkits.prefix(ComposioConnectClient.batchSize * 2).map(\.slug).filter { connections[$0] == nil }
        guard !missing.isEmpty else { return }
        do {
            let found = try await connect.connections(missing)
            connections.merge(found) { _, new in new }
        } catch {
            handle(error, fallback: nil)
        }
    }

    /// Composio's sign-in page for the app; after it, `confirm(_:)` checks the result.
    func connectLink(_ slug: String) async -> URL? {
        busySlug = slug
        defer { busySlug = nil }
        do {
            return try await connect.connect(slug)
        } catch {
            handle(error, fallback: "Composio couldn't start that sign-in. Try again.")
            return nil
        }
    }

    /// After the app's sign-in page closes: Composio may take a moment to mark the account active.
    func confirm(_ slug: String) async {
        for attempt in 0..<4 {
            guard let found = try? await connect.connections([slug])[slug] else { break }
            connections[slug] = found
            if found.isConnected {
                if !connectedSlugs.contains(slug) { connectedSlugs.insert(slug, at: 0) }
                return
            }
            if attempt < 3 { try? await sleep(.seconds(2)) }
        }
        // A sign-in left open or cancelled leaves a pending account; Composio drops it on its own.
    }

    func remove(_ slug: String, account accountID: String) async {
        busySlug = slug
        defer { busySlug = nil }
        do {
            try await connect.remove(slug, accountID: accountID)
            let left = (connections[slug]?.accounts ?? []).filter { $0.id != accountID }
            connections[slug] = ComposioConnection(toolkit: slug, accounts: left)
            if !left.contains(where: \.isActive) { connectedSlugs.removeAll { $0 == slug } }
        } catch {
            handle(error, fallback: "Composio couldn't remove that account. Try again.")
        }
    }

    // MARK: The agent

    func refreshAgent() async {
        guard let agentHost else { agent = .unknown; return }
        do {
            agent = try await agentHost.access()
        } catch WorkspaceClientError.unavailable(.unsupportedOperation) {
            agent = .needsPluginUpdate
        } catch {
            agent = .unknown
        }
    }

    /// Installs and turns on Composio Connect on the computer if needed, then opens Composio's
    /// sign-in for Hermes. `open` shows the page; the caller polls `finishAgentSignIn`.
    func turnOnForAgent(open: (URL) -> Void) async -> MCPOAuthFlow? {
        guard let agentHost, !agentWorking else { return nil }
        agentWorking = true
        message = nil
        defer { agentWorking = false }
        do {
            let server: String
            switch agent {
            case .needsSignIn(let name): server = name
            case .ready(let name): server = name
            default: server = try await agentHost.install()
            }
            agent = try await agentHost.access()
            guard case .needsSignIn = agent else { return nil }
            let flow = try await agentHost.startSignIn(server: server)
            if let url = flow.authorizationURL { open(url) }
            return flow
        } catch WorkspaceClientError.unavailable(.unsupportedOperation) {
            agent = .needsPluginUpdate
        } catch {
            message = "\(agentHost.hostName) couldn't turn on Composio. Try again."
        }
        return nil
    }

    /// Waits for Hermes' sign-in to finish (up to five minutes), then checks again.
    func finishAgentSignIn(_ flow: MCPOAuthFlow) async {
        guard let agentHost else { return }
        agentWorking = true
        defer { agentWorking = false }
        for _ in 0..<150 {
            guard let latest = try? await agentHost.signInStatus(flowID: flow.id) else { break }
            switch latest.status {
            case .approved:
                await refreshAgent()
                return
            case .error, .expired:
                message = latest.error.map { String($0.prefix(200)) } ?? "The sign-in didn't finish. Try again."
                await refreshAgent()
                return
            default:
                try? await sleep(.seconds(2))
            }
        }
        await refreshAgent()
    }

    // MARK: -

    private func refreshCatalog() async {
        do {
            catalog = try await catalogStore.refresh()
            catalogFailed = false
        } catch {
            catalogFailed = catalog == nil
        }
    }

    private func handle(_ error: any Error, fallback: String?) {
        switch error {
        case ComposioError.signedOut:
            signOut()
            message = "Your Composio sign-in ended. Sign in again."
        case ComposioError.refused(let reason):
            message = reason
        default:
            if let fallback { message = fallback }
        }
    }

    /// "google_calendar" → "Google Calendar", for apps the catalog doesn't list.
    nonisolated static func displayName(_ slug: String) -> String {
        slug.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
