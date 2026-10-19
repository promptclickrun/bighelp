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
    /// Hermes has a sign-in saved, but its connection test doesn't reach Composio's tools with it.
    case cannotReach(server: String)
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
    @ObservationIgnored private let signInFlow: @MainActor (ComposioAccount) async throws -> Void
    @ObservationIgnored private let sleep: (Duration) async throws -> Void

    init(account: ComposioAccount,
         connect: (any ComposioConnecting)? = nil,
         catalog: any ComposioCatalogLoading = ComposioCatalogStore(),
         agentHost: (any ComposioAgentHost)?,
         // Main actor: a plain async closure runs on a background thread, and the sign-in sheet's
         // helper traps when it's made there (2.5.0 (125) crashed on Sign in to Composio).
         signIn: @escaping @MainActor (ComposioAccount) async throws -> Void = { @MainActor account in
             try await ComposioSignInBrowser().signIn(account: account)
         },
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

    /// An app's sign-in page that is open: the active accounts it had before, and the account
    /// Composio made for this sign-in.
    struct OpenSignIn: Equatable {
        let id = UUID()
        let slug: String
        let accountsBefore: Set<String>
        let pendingAccountID: String?
    }

    private(set) var openSignIn: OpenSignIn?

    /// Composio's sign-in page for a new account in the app. The page stays open until
    /// `waitForSignIn()` sees the new account or the person closes it (`signInPageClosed()`).
    func startConnect(_ slug: String) async -> URL? {
        busySlug = slug
        defer { busySlug = nil }
        let before = Set(connections[slug]?.accounts.filter(\.isActive).map(\.id) ?? [])
        do {
            let start = try await connect.connect(slug)
            openSignIn = OpenSignIn(slug: slug, accountsBefore: before, pendingAccountID: start.pendingAccountID)
            return start.url
        } catch {
            handle(error, fallback: "Composio couldn't start that sign-in. Try again.")
            return nil
        }
    }

    /// Checks while the page is open, every 3 seconds for a minute, then every 10 seconds for
    /// up to 10 minutes. True once a new account is active: the caller closes the page then.
    func waitForSignIn() async -> Bool {
        guard let current = openSignIn else { return false }
        for attempt in 0..<74 {
            try? await sleep(.seconds(attempt < 20 ? 3 : 10))
            guard openSignIn == current else { return false }
            if await signedIn(current) {
                openSignIn = nil
                return true
            }
        }
        return false
    }

    /// Coming back to bighelp (on the Mac the page opens in the browser): look now, but leave
    /// the page alone; `waitForSignIn()` closes it once the account is there.
    func checkSignIn() async {
        guard let current = openSignIn else { return }
        _ = await signedIn(current)
    }

    /// The person closed the page. Without a new account, the pending one Composio made for
    /// this try is removed, so unfinished tries don't pile up in their Composio account.
    func signInPageClosed() async {
        guard let current = openSignIn else { return }
        openSignIn = nil
        if await signedIn(current) { return }
        guard let pending = current.pendingAccountID else { return }
        try? await connect.remove(current.slug, accountID: pending)
        if let known = connections[current.slug] {
            connections[current.slug] = ComposioConnection(toolkit: current.slug,
                                                           accounts: known.accounts.filter { $0.id != pending })
        }
    }

    /// Whether the app now has an active account it didn't have when the page opened.
    private func signedIn(_ signIn: OpenSignIn) async -> Bool {
        if let known = connections[signIn.slug], isNew(known, signIn) { return true }
        guard let found = try? await connect.connections([signIn.slug])[signIn.slug] else { return false }
        connections[signIn.slug] = found
        guard isNew(found, signIn) else { return false }
        if !connectedSlugs.contains(signIn.slug) { connectedSlugs.insert(signIn.slug, at: 0) }
        return true
    }

    private func isNew(_ connection: ComposioConnection, _ signIn: OpenSignIn) -> Bool {
        connection.accounts.contains { $0.isActive && !signIn.accountsBefore.contains($0.id) }
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
    /// sign-in for Hermes (again, when Composio no longer takes the saved one). `open` shows the
    /// page; the caller polls `finishAgentSignIn`.
    func turnOnForAgent(open: (URL) -> Void) async -> MCPOAuthFlow? {
        guard let agentHost, !agentWorking else { return nil }
        agentWorking = true
        message = nil
        defer { agentWorking = false }
        do {
            let server: String
            switch agent {
            case .needsSignIn(let name), .cannotReach(let name), .ready(let name): server = name
            default: server = try await agentHost.install()
            }
            agent = try await agentHost.access()
            switch agent {
            case .needsSignIn, .cannotReach: break
            default: return nil
            }
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
