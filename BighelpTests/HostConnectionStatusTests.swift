import Foundation
import Testing
@testable import Bighelp

/// Every connection surface maps the app's states through one adapter, so the
/// island, the chat, Hosts, host setup and All agents agree, keep the words
/// they already used, and only ever show details the app really has.
@MainActor
struct HostConnectionStatusTests {
    private typealias Shown = (phase: BighelpConnectionPhase, label: String)

    private func shown(_ status: HostConnectionStatus?) -> Shown? {
        status.map { ($0.phase, $0.label) }
    }

    @Test func theIslandKeepsItsWordsAndNoInternetIsDisconnected() {
        let cases: [(ConnectionIslandPhase, BighelpConnectionPhase, String)] = [
            (.connecting, .connecting, "Connecting…"),
            (.reconnecting, .reconnecting, "Reconnecting…"),
            (.connected, .connected, "Connected!"),
            (.disconnected, .disconnected, "Not connected"),
            (.noInternet, .disconnected, "No internet"),
        ]
        for (island, phase, label) in cases {
            let status = HostConnectionStatus(island: island)
            #expect(status?.phase == phase, "\(island)")
            #expect(status?.label == label, "\(island)")
            #expect(status?.detailText == nil, "\(island)")
        }
        #expect(HostConnectionStatus(island: .hidden) == nil)
    }

    @Test func theReconnectingNoteShowsOnlyWhileTheConnectionIsntThere() {
        #expect(HostConnectionStatus(chat: .connected) == nil)
        #expect(shown(HostConnectionStatus(chat: .reconnecting))! == (.reconnecting, "Reconnecting to your computer…"))
        #expect(shown(HostConnectionStatus(chat: .disconnected))! == (.disconnected, "Not connected to your computer"))
        // Agrees with the island: no network at all says so.
        #expect(shown(HostConnectionStatus(chat: .disconnected, hasNetwork: false))!
                == (.disconnected, "No internet connection"))
        #expect(HostConnectionStatus(chat: .reconnecting, hasNetwork: false)?.phase == .reconnecting)
        // Agrees with the island before the computer has answered once.
        #expect(shown(HostConnectionStatus(chat: .reconnecting, hasConnected: false))!
                == (.connecting, "Connecting to your computer…"))
        #expect(HostConnectionStatus(chat: .disconnected, hasConnected: false)?.phase == .disconnected)
    }

    @Test func aComputerConnectsTheFirstTimeAndReconnectsAfter() {
        #expect(shown(HostConnectionStatus(isConnected: true, isConnecting: false))! == (.connected, "Connected"))
        #expect(shown(HostConnectionStatus(isConnected: false, isConnecting: true, isFirstConnection: true))!
                == (.connecting, "Connecting…"))
        #expect(shown(HostConnectionStatus(isConnected: false, isConnecting: true))! == (.reconnecting, "Reconnecting…"))
        #expect(shown(HostConnectionStatus(isConnected: false, isConnecting: false))! == (.disconnected, "Not connected"))
        #expect(shown(HostConnectionStatus(workspace: nil))! == (.disconnected, "Not connected"))
    }

    @Test func hostSetupShowsTheCheckAndThenConnected() {
        #expect(HostConnectionStatus(setupIsWorking: false, isConnected: false) == nil)
        #expect(shown(HostConnectionStatus(setupIsWorking: true, isConnected: false))! == (.connecting, "Connecting…"))
        #expect(shown(HostConnectionStatus(setupIsWorking: false, isConnected: true))! == (.connected, "Connected"))
    }

    @Test func allAgentsSaysWhichHostsAreLoadingOrOutOfReach() {
        #expect(HostConnectionStatus(fleet: nil, hostName: "Studio Mac") == nil)
        #expect(HostConnectionStatus(fleet: .idle, hostName: "Studio Mac") == nil)
        #expect(shown(HostConnectionStatus(fleet: .loading, hostName: "Studio Mac"))!
                == (.connecting, "Loading Studio Mac…"))
        #expect(shown(HostConnectionStatus(fleet: .ready, hostName: "Studio Mac"))! == (.connected, "Studio Mac"))
        let away = HostConnectionStatus(fleet: .unreachable("Couldn't reach this host."), hostName: "Office Linux")
        #expect(shown(away)! == (.disconnected, "Office Linux"))
        #expect(away?.detailText == "Couldn't reach this host.", "The host's own reason stays visible")

        let opening = HostConnectionStatus(fleetSwitchTo: "Studio Mac", isConnecting: true, hasTried: true)
        #expect(shown(opening)! == (.connecting, "Connecting to Studio Mac…"))
        let starting = HostConnectionStatus(fleetSwitchTo: "Studio Mac", isConnecting: false, hasTried: false)
        #expect(starting.phase == .connecting, "A switch starts connecting a moment later")
        let failed = HostConnectionStatus(fleetSwitchTo: "Studio Mac", isConnecting: false, hasTried: true)
        #expect(shown(failed)! == (.disconnected, "Couldn't connect to Studio Mac."))
    }

    @Test func otherSurfacesMapEveryState() {
        #expect(HostConnectionStatus(spatial: .connecting)?.phase == .connecting)
        #expect(HostConnectionStatus(spatial: .unavailable("No agent yet"))?.phase == .disconnected)
        #expect(HostConnectionStatus(spatial: .ready) == nil)

        #expect(shown(HostConnectionStatus(dashboardIsConnected: true))! == (.connected, "Connected"))
        #expect(shown(HostConnectionStatus(dashboardIsConnected: false))! == (.reconnecting, "Reconnecting"))
    }

    @Test func aPluginUpdateIsReconnectingOnlyWhileHermesComesBack() async {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let client = RestartingPluginHost()
        let store = PluginUpdateStore(scope: "device:host", client: client, defaults: defaults,
                                      operationID: { "update_0123456789abcdef" })
        #expect(HostConnectionStatus(pluginUpdate: store) == nil)
        await store.start()
        #expect(store.status?.phase == .waitingForActivation)
        #expect(shown(HostConnectionStatus(pluginUpdate: store))! == (.reconnecting, "Reconnecting"))
    }

    /// Only real values: a host's reason when it's down. No attempt count (the
    /// keeper retries for as long as the app is open), no latency (nothing
    /// measures it), and no version or reason where none was given.
    @Test func missingValuesGiveNoDetail() {
        let statuses: [HostConnectionStatus?] = [
            HostConnectionStatus(island: .reconnecting), HostConnectionStatus(island: .connected),
            HostConnectionStatus(chat: .reconnecting), HostConnectionStatus(chat: .disconnected),
            HostConnectionStatus(isConnected: true, isConnecting: false),
            HostConnectionStatus(isConnected: false, isConnecting: true),
            HostConnectionStatus(isConnected: false, isConnecting: false),
            HostConnectionStatus(setupIsWorking: true, isConnected: false),
            HostConnectionStatus(setupIsWorking: false, isConnected: true),
            HostConnectionStatus(fleet: .loading, hostName: "Studio Mac"),
            HostConnectionStatus(fleet: .ready, hostName: "Studio Mac"),
            HostConnectionStatus(fleetSwitchTo: "Studio Mac", isConnecting: false, hasTried: true),
            HostConnectionStatus(dashboardIsConnected: false),
        ]
        for status in statuses {
            #expect(status != nil)
            #expect(status?.detail == nil)
            #expect(status?.detailText == nil)
        }
        let blank = HostConnectionStatus(fleet: .unreachable("   "), hostName: "Office Linux")
        #expect(blank?.detailText == nil, "A blank reason isn't a reason")
        #expect(blank?.detail?.attempt == nil)
        #expect(blank?.detail?.latencyMilliseconds == nil)
        #expect(blank?.detail?.hermesVersion == nil)
    }
}

/// A host that accepts the update, then restarts Hermes to load it.
@MainActor
private final class RestartingPluginHost: PluginUpdateClient {
    func start(operationID: String) async throws -> PluginUpdateStatus {
        .init(operationID: operationID, phase: .waitingForActivation, targetRevision: nil, activeRevision: nil,
              runtimeID: nil, message: "Waiting for Hermes")
    }

    func status(operationID: String?) async throws -> PluginUpdateStatus {
        try await start(operationID: operationID ?? "")
    }
}
