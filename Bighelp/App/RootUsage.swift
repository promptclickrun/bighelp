import SwiftUI

/// ☰ › Usage: one page for plans, limits and what the agents used. With All
/// hosts on it covers every computer; otherwise the one in use.
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
        /// again; otherwise ☰ › Usage pushed onto a stack nothing showed (#99).
        let navigation: ObjectIdentifier
    }

    var usageReaderKey: UsageReaderKey {
        let fixtures = usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true
        return UsageReaderKey(signIn: currentWorkspaceOwner?.signIn ?? workspaceSignIn, fixtures: fixtures,
                              allHosts: fleetModeOn, hostID: usageHostID, hostName: workspaceHostName,
                              navigation: ObjectIdentifier(appState))
    }

    /// The computer in use, as the all-hosts view names it.
    var usageHostID: String {
        fleet?.selectedHostID?.uuidString ?? hostRegistry?.selectedHostID?.uuidString ?? "current"
    }

    func configureUsage(_ key: UsageReaderKey) {
        providerUsage.onOpen = { [self] in openUsage() }
        let fleet = key.allHosts ? self.fleet : nil
        let agents = self.agents
        let agentList: @MainActor () -> [(id: String, name: String)] = {
            agents.profiles.map { ($0.id, $0.name) }
        }
        if key.fixtures {
            usage.configure(reader: DemoUsageReader(hostID: key.hostID, hostName: key.hostName, agents: agentList,
                                                    fleet: fleet),
                            scope: "fixtures-\(key.allHosts)-\(key.hostID)")
            return
        }
        guard let signIn = key.signIn, let connections = workspaceConnections else {
            usage.configure(reader: nil, scope: nil)
            return
        }
        usage.configure(reader: LiveUsageReader(
            hostID: key.hostID, hostName: key.hostName,
            currentWorkspace: { [weak connections] in connections?.workspace },
            agents: agentList, fleet: fleet
        ), scope: [AnyHashable(signIn), AnyHashable(key.allHosts)])
    }

    /// Usage with the home agent's provider first among the plans.
    func showUsage() {
        if providerUsage.isAvailable {
            providerUsage.show(agentID: homeAgent?.id ?? "default")
        } else {
            openUsage()
        }
    }

    /// Pushes Usage over whatever is open, so Back returns there.
    func openUsage() {
        guard appState.path.last != .usage else { return }
        if appState.selectedTab != .sessions {
            appState.select(.sessions)
        }
        appState.path.append(.usage)
    }

    var usageDestination: some View {
        UsageView(store: usage, providerUsage: providerUsage.isAvailable ? providerUsage : nil,
                  selectedHostID: usageHostID, selectedHostName: workspaceHostName)
    }
}
