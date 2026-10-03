import SwiftUI

@MainActor
protocol ProviderUsageClient: AnyObject {
    /// The computer and sign-in a read would go to right now.
    var currentScope: AnyHashable? { get }
    func usage(agentID: String, refresh: Bool) async throws -> ProviderUsageReport
}

/// The bighelp plugin's `native-provider-usage-v1` route. The host does every
/// provider call; the app only reads the result.
///
/// bighelp reconnects each time it comes back, and the home screen that hands
/// out clients can't while a chat covers it (a launch straight into a chat, or
/// another host's agent). So this always reads through the current connection,
/// and the store starts over when that connection is another sign-in.
@MainActor
final class DirectHermesProviderUsageClient: ProviderUsageClient {
    private let currentWorkspace: @MainActor () -> (any WorkspaceOperationPerforming)?
    private let reconnectWait: Duration
    private let reconnectAttempts: Int

    init(currentWorkspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?,
         reconnectWait: Duration = .milliseconds(500), reconnectAttempts: Int = 20) {
        self.currentWorkspace = currentWorkspace
        self.reconnectWait = reconnectWait
        self.reconnectAttempts = reconnectAttempts
    }

    var currentScope: AnyHashable? { currentWorkspace()?.owner?.signIn }

    func usage(agentID: String, refresh: Bool) async throws -> ProviderUsageReport {
        do {
            return try await read(agentID: agentID, refresh: refresh)
        } catch let error where ProviderUsageStore.isConnectionHiccup(error) {
            // A dropped connection or a slow answer: once more, once it's back.
            return try await read(agentID: agentID, refresh: refresh)
        }
    }

    private func read(agentID: String, refresh: Bool) async throws -> ProviderUsageReport {
        let (workspace, owner) = try await connection()
        func ask(_ agent: String) async throws -> ProviderUsageReport {
            let payload: [String: BighelpJSONValue] = ["agentId": .string(agent), "refresh": .boolean(refresh)]
            do {
                return try ProviderUsageReport(json: try await workspace.perform(.usageList, payload: payload, owner: owner))
            } catch WorkspaceClientError.conflict {
                // The plugin's context changed (412): the next call loads it again. Once.
                return try ProviderUsageReport(json: try await workspace.perform(.usageList, payload: payload, owner: owner))
            }
        }
        do {
            return try await ask(agentID)
        } catch WorkspaceClientError.rejected(let code)
                    where agentID != "default" && (code == "profile_not_found" || code == "invalid_request") {
            // Usage is the host's, the same for every agent; Hermes just doesn't know this one.
            return try await ask("default")
        }
    }

    /// Waits a few seconds for a connection that's on its way back.
    private func connection() async throws -> (any WorkspaceOperationPerforming, WorkspaceOwner) {
        for attempt in 0...reconnectAttempts {
            if let workspace = currentWorkspace(), let owner = workspace.owner { return (workspace, owner) }
            if attempt < reconnectAttempts { try await Task.sleep(for: reconnectWait) }
        }
        throw WorkspaceClientError.transportUnavailable
    }
}

/// Made-up numbers for the demo and UI tests, covering every status.
@MainActor
final class DemoProviderUsageClient: ProviderUsageClient {
    var currentScope: AnyHashable? { "fixtures" }
    func usage(agentID: String, refresh: Bool) async throws -> ProviderUsageReport {
        let now = Date.now
        func window(_ label: String, _ used: Double, hours: Double?, _ detail: String?) -> ProviderUsage.Window {
            .init(label: label, usedPercent: used, resetsAt: hours.map { now.addingTimeInterval($0 * 3_600) }, detail: detail)
        }
        func provider(_ id: String, _ name: String, status: ProviderUsage.Status = .ok, message: String? = nil,
                      plan: String? = nil, via: [String] = ["cli"], active: Bool = false,
                      windows: [ProviderUsage.Window] = [], facts: [ProviderUsage.Fact] = [],
                      manage: String? = nil, approximate: Bool = false) -> ProviderUsage {
            ProviderUsage(id: id, name: name, status: status, message: message, plan: plan, detectedVia: via,
                          activeInHermes: active, windows: windows, facts: facts,
                          manageURL: manage.flatMap(URL.init(string:)), approximate: approximate)
        }
        return ProviderUsageReport(agentID: agentID, fetchedAt: now.addingTimeInterval(-120), cached: !refresh, providers: [
            provider("codex", "Codex", plan: "Plus", via: ["cli", "hermes"],
                     windows: [window("Session (5 hours)", 62, hours: 3.2, "870k / 1.40M tokens"),
                               window("Week", 18, hours: 90, nil)],
                     manage: "https://chatgpt.com/codex/settings/usage"),
            provider("claude", "Claude", plan: "Max 5x", active: true,
                     windows: [window("Session (5 hours)", 63, hours: 1.5, "1.26M / 2.00M tokens"),
                               window("Week", 41, hours: 70, nil), window("Week (Opus)", 92, hours: 70, nil)],
                     manage: "https://claude.ai/settings/usage"),
            provider("copilot", "GitHub Copilot", plan: "Pro", via: ["cli"],
                     windows: [window("Premium requests (month)", 56, hours: 300, "420 / 750 credits used")],
                     manage: "https://github.com/settings/copilot", approximate: true),
            provider("openrouter", "OpenRouter", via: ["hermes"],
                     facts: [.init(label: "Balance", value: "$25.00"), .init(label: "Spent this month", value: "$3.40")],
                     manage: "https://openrouter.ai/settings/credits"),
            provider("gemini", "Google AI Studio", status: .notShared,
                     message: "Your API key works. Google shows AI Studio usage only on its website.", via: ["hermes"],
                     manage: "https://aistudio.google.com/usage"),
            provider("deepseek", "DeepSeek", status: .signInNeeded,
                     message: "DeepSeek didn't accept the saved key. Update it in Provider Keys.", via: ["hermes"],
                     manage: "https://platform.deepseek.com/usage"),
        ])
    }
}

/// Plans and limits for the connected host, for the Usage page. One per
/// host connection; keeps the last result while a refresh runs.
@MainActor @Observable
final class ProviderUsageStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        /// The host's bighelp plugin predates usage.
        case needsPluginUpdate
        case unavailable(String)
    }

    private(set) var state: State = .idle
    private(set) var report: ProviderUsageReport?
    private(set) var isRefreshing = false

    /// Which agent's view of Hermes to read (its provider comes first).
    private(set) var agentID = "default"
    @ObservationIgnored private var client: (any ProviderUsageClient)?
    /// The computer and sign-in the client reads. A reconnect keeps it.
    @ObservationIgnored private var scope: AnyHashable?
    @ObservationIgnored private var generation = 0

    /// Observed, so menus show or hide the entry points as hosts connect.
    private(set) var isAvailable = false

    /// The same scope keeps the client and whatever is on screen.
    func configure(client: (any ProviderUsageClient)?, scope: AnyHashable? = nil) {
        if client != nil, scope != nil, scope == self.scope { return }
        self.client = client
        self.scope = client == nil ? nil : scope
        isAvailable = client != nil
        generation += 1
        report = nil
        isRefreshing = false
        state = .idle
    }

    /// Opens the Usage page; the app sets it. Screens that offer Usage (chat ⋯,
    /// the context window, ☰) call `show(agentID:)` and stay out of navigation.
    @ObservationIgnored var onOpen: (@MainActor () -> Void)?

    /// Opens Usage with an agent's view of the plans (its provider first) and
    /// loads them (the host caches for five minutes).
    func show(agentID: String) {
        if agentID != self.agentID {
            self.agentID = agentID
            report = nil
            state = .idle
        }
        onOpen?()
        Task { await load(refresh: false) }
    }

    func load(refresh: Bool) async {
        guard let client else {
            state = .unavailable("Connect to a host to see provider usage.")
            return
        }
        generation += 1
        let current = generation
        // Another computer or sign-in than the one on screen: start over.
        let readScope = client.currentScope
        if let readScope, readScope != scope {
            scope = readScope
            report = nil
        }
        if report == nil { state = .loading }
        isRefreshing = refresh
        defer { if current == generation { isRefreshing = false } }
        do {
            let value = try await client.usage(agentID: agentID, refresh: refresh)
            guard current == generation else { return }
            if client.currentScope != readScope {
                // The sign-in changed while this was read: read for the new one.
                await load(refresh: refresh)
                return
            }
            report = value
            state = .loaded
        } catch {
            guard current == generation else { return }
            switch error {
            case WorkspaceClientError.unavailable(.unsupportedOperation), WorkspaceClientError.unavailable(.pluginRequired):
                state = .needsPluginUpdate
            default:
                // Keep the last result on screen; say why it didn't refresh.
                state = .unavailable(report == nil ? Self.reason(error) : "Couldn't refresh. Showing the last result.")
            }
        }
    }
}

extension ProviderUsageStore {
    static func isConnectionHiccup(_ error: any Error) -> Bool {
        switch error {
        case WorkspaceClientError.transportUnavailable, WorkspaceClientError.ownerChanged,
             DirectHermesError.timedOut, DirectHermesError.connectionFailed, DirectHermesError.notConnected,
             DirectHermesError.disconnected, DirectHermesError.serverUnavailable:
            true
        default:
            false
        }
    }

    static func reason(_ error: any Error) -> String {
        switch error {
        case WorkspaceClientError.authenticationRequired, DirectHermesError.authenticationRequired:
            "Your computer turned down bighelp's sign-in. Sign in to it again in Hosts."
        case DirectHermesError.timedOut:
            "Your computer took too long to answer. Try again in a moment."
        case _ where isConnectionHiccup(error):
            "bighelp isn't connected to your computer right now. Try again in a moment."
        default:
            "Usage couldn't be loaded from your computer. Try again in a moment."
        }
    }
}

/// Which providers the overlay shows. Stores the hidden ones, so a provider
/// set up later shows until it's turned off. Saved on this device; the key never
/// changes, so choices survive app updates.
enum ProviderUsagePreferences {
    static let hiddenKey = "bighelp.provider-usage.hidden"

    /// A choice is saved per provider, not per report id. The host names one provider
    /// differently depending on where it found the sign-in and which agent asks
    /// (`codex` or `codex-hermes`, `openrouter` or `hermes-openrouter`), so an exact
    /// id brought hidden providers back after a restart or an update.
    static func key(for id: String) -> String { ProviderUsagePresentation.logoProviderID(id) }

    static func isHidden(_ id: String, in hidden: Set<String>) -> Bool {
        hidden.contains(key(for: id)) || hidden.contains(id)
    }

    static func hidden(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map { key(for: String($0)) })
    }

    static func raw(_ hidden: Set<String>) -> String {
        hidden.sorted().joined(separator: "\n")
    }
}

extension EnvironmentValues {
    @Entry var providerUsage: ProviderUsageStore? = nil
}
