import SwiftUI

/// Usage (Settings, a chat's ⋯, the sidebar): one page for plans, limits and what the bots used.
/// With every computer showing it covers them all; otherwise the one in use.
extension RootShellView {
    /// What the Usage page reads: the sign-in (a reconnect keeps it), demo data
    /// or not, whether All hosts is on, and the shell it opens in.
    struct UsageReaderKey: Equatable {
        let signIn: WorkspaceSignIn?
        let fixtures: Bool
        let allHosts: Bool
        let hostID: String
        let hostName: String
        /// The selected host's navigation and agents come with its runtime, which
        /// can arrive after its sign-in (opening the app with All hosts on). Opening
        /// Usage goes through the shell configured last, so a new one configures it
        /// again; otherwise Usage pushed onto a stack nothing showed (#99).
        let navigation: ObjectIdentifier
    }

    var usageReaderKey: UsageReaderKey {
        let fixtures = usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true
        return UsageReaderKey(signIn: currentWorkspaceOwner?.signIn ?? workspaceSignIn, fixtures: fixtures,
                              allHosts: showsEveryHost, hostID: usageHostID, hostName: workspaceHostName,
                              navigation: ObjectIdentifier(appState))
    }

    /// The computer in use, as the all-hosts view names it.
    var usageHostID: String {
        fleet?.selectedHostID?.uuidString ?? hostRegistry?.selectedHostID?.uuidString ?? "current"
    }

    func configureUsage(_ key: UsageReaderKey) {
        providerUsage.onOpen = { [self] in openUsage() }
        let made = usageReader(key)
        usage.configure(reader: made?.reader, scope: made?.scope)
    }

    /// What Usage (and its widget) reads for this key, and the scope that names it.
    func usageReader(_ key: UsageReaderKey) -> (reader: any UsageReading, scope: AnyHashable)? {
        let fleet = key.allHosts ? self.fleet : nil
        let agents = self.agents
        let agentList: @MainActor () -> [(id: String, name: String)] = {
            agents.profiles.map { ($0.id, $0.name) }
        }
        if key.fixtures {
            return (DemoUsageReader(hostID: key.hostID, hostName: key.hostName, agents: agentList, fleet: fleet),
                    AnyHashable("fixtures-\(key.allHosts)-\(key.hostID)"))
        }
        guard let signIn = key.signIn, let connections = workspaceConnections else { return nil }
        return (LiveUsageReader(
            hostID: key.hostID, hostName: key.hostName,
            currentWorkspace: { [weak connections] in connections?.workspace },
            agents: agentList, fleet: fleet
        ), AnyHashable([AnyHashable(signIn), AnyHashable(key.allHosts)]))
    }

    /// Usage with the home agent's provider first among the plans.
    func showUsage() {
        if providerUsage.isAvailable {
            providerUsage.show(agentID: homeAgent?.id ?? "default")
        } else {
            openUsage()
        }
    }

    /// Usage over whatever is open, so Back returns right there.
    func openUsage() {
        guard appState.path.last != .usage else { return }
        appState.path.append(.usage)
    }

    var usageDestination: some View {
        UsageView(store: usage, providerUsage: providerUsage.isAvailable ? providerUsage : nil,
                  selectedHostID: usageHostID, selectedHostName: workspaceHostName)
            // The page sets up its own two stores, as the board pages do (#987, #1042). The root's
            // tasks wait while a page covers the root, and Usage opens from its link before the
            // sign-in is known (a Usage widget tapped with Bighelp closed). The root had then set the
            // stores up with no sign-in, and Usage said "Connect to a computer" until you left it.
            .task(id: usageReaderKey) { await setUpUsagePage(usageReaderKey) }
            .task(id: providerUsageKey) { await setUpUsagePlans(providerUsageKey) }
    }

    /// The same setup the root does. A store that had nothing to read from until now is read at
    /// once: the page's own first read came before it and found no computer.
    private func setUpUsagePage(_ key: UsageReaderKey) async {
        let couldRead = usage.isAvailable
        configureUsage(key)
        if !couldRead, usage.isAvailable { await usage.load(refresh: false) }
    }

    private func setUpUsagePlans(_ key: ProviderUsageKey) async {
        let couldRead = providerUsage.isAvailable
        configureProviderUsage(key)
        if !couldRead, providerUsage.isAvailable, providerUsage.report == nil { await providerUsage.load(refresh: false) }
    }
}
