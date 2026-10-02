import Foundation

/// What a screen shows for a host connection: the shared loaders' phase, the
/// plain words that screen already used, and a detail line only from facts the
/// app really has. Every connection surface maps through here, so the island,
/// the chat, Hosts, host setup and All agents agree on what's happening.
///
/// "Connecting" is a computer the app hasn't reached yet (host setup, the first
/// connection after launch, another host in All agents); "Reconnecting" is
/// getting one back. Details are only a host's own reason when it's down: the
/// reconnect loop keeps trying with backoff for as long as the app is open, so
/// there's no "2 of 5" to count towards, and nothing measures a round trip.
struct HostConnectionStatus: Equatable, Sendable {
    let phase: BighelpConnectionPhase
    let label: String
    var detail: BighelpConnectionDetail?

    init(_ phase: BighelpConnectionPhase, _ label: String, reason: String? = nil) {
        self.phase = phase
        self.label = label
        detail = reason.map { BighelpConnectionDetail(message: $0) }
    }

    /// The line under the label, or nil when nothing real is known.
    var detailText: String? { detail?.text(for: phase) }
}

extension HostConnectionStatus {
    /// The pill under the Dynamic Island; nil while it's hidden. "Not
    /// connected", as Hosts and the opening screen say beside it.
    init?(island: ConnectionIslandPhase) {
        switch island {
        case .hidden: return nil
        case .connecting: self.init(.connecting, "Connecting…")
        case .reconnecting: self.init(.reconnecting, "Reconnecting…")
        case .connected: self.init(.connected, "Connected!")
        case .disconnected: self.init(.disconnected, "Not connected")
        case .noInternet: self.init(.disconnected, "No internet")
        }
    }

    /// In "Needs attention" while the connection is restored; nil once
    /// it's back. Like the island: "Connecting" until the computer has
    /// answered once, and no network at all says so.
    init?(chat state: WorkspaceConnectionState, hasNetwork: Bool = true, hasConnected: Bool = true) {
        switch state {
        case .connected: return nil
        case .reconnecting:
            self = hasConnected ? Self(.reconnecting, "Reconnecting to your computer…")
                                : Self(.connecting, "Connecting to your computer…")
        case .disconnected:
            self.init(.disconnected, hasNetwork ? "Not connected to your computer" : "No internet connection")
        }
    }

    /// A computer's own connection, for Hosts and the screen shown before its
    /// workspace opens. No reason here: a store keeps its last status line
    /// ("Connected directly…") after the app closes its connection, so it
    /// isn't one. The startup screen shows that line on its own.
    init(isConnected: Bool, isConnecting: Bool, isFirstConnection: Bool = false) {
        if isConnected {
            self.init(.connected, "Connected")
        } else if isConnecting {
            self = isFirstConnection ? Self(.connecting, "Connecting…") : Self(.reconnecting, "Reconnecting…")
        } else {
            self.init(.disconnected, "Not connected")
        }
    }

    /// While the keeper is still quietly retrying the computer in use (a dead
    /// host refuses each try at once), it's reconnecting, as the island says.
    @MainActor
    init(workspace store: DirectHermesWorkspaceStore?, keeper: WorkspaceConnectionKeeper? = nil) {
        let following = keeper?.isFollowing(store) == true
        self.init(isConnected: store?.isConnected == true,
                  isConnecting: store?.isConnecting == true || (following && keeper?.state == .reconnecting),
                  isFirstConnection: following && keeper?.hasConnected == false)
    }

    /// Host setup while it checks an address or signs in, then once it's in.
    init?(setupIsWorking isWorking: Bool, isConnected: Bool) {
        if isConnected { self.init(.connected, "Connected") }
        else if isWorking { self.init(.connecting, "Connecting…") }
        else { return nil }
    }

    /// Another host as All agents reads it; nil when there's nothing to say.
    init?(fleet status: FleetHostStatus?, hostName: String) {
        switch status {
        case .loading: self.init(.connecting, "Loading \(hostName)…")
        case .unreachable(let message): self.init(.disconnected, hostName, reason: message)
        case .ready: self.init(.connected, hostName)
        case .idle, nil: return nil
        }
    }

    /// All agents switching to a tapped agent's host. `hasTried`: a failure
    /// shows only after an attempt started.
    init(fleetSwitchTo hostName: String, isConnecting: Bool, hasTried: Bool) {
        self = isConnecting || !hasTried
            ? Self(.connecting, "Connecting to \(hostName)…")
            : Self(.disconnected, "Couldn't connect to \(hostName).")
    }

    /// The agent standing in the room on Vision Pro; nil once it's ready (its
    /// status line then says what it's doing).
    init?(spatial connection: SpatialAvatarModel.Connection) {
        switch connection {
        case .connecting: self.init(.connecting, "Connecting…")
        case .unavailable: self.init(.disconnected, "Can't reach your computer")
        case .ready: return nil
        }
    }

    /// The home dashboard's status line.
    init(dashboardIsConnected isConnected: Bool) {
        self = isConnected ? Self(.connected, "Connected") : Self(.reconnecting, "Reconnecting")
    }

    /// The retired bighelp Link socket, still read by Settings.
    init(link state: BighelpLinkLiveSocketState) {
        switch state {
        case .stopped: self.init(.disconnected, "Disconnected")
        case .connecting: self.init(.connecting, "Connecting")
        case .retrying: self.init(.reconnecting, "Reconnecting")
        case .superseded: self.init(.disconnected, "Connection moved")
        case .verified: self.init(.connected, "Connected")
        }
    }

    /// The retired bighelp Link account's paired devices, still in Settings.
    init(linkSignedIn isSignedIn: Bool, devices: [BighelpLinkDevice], loadState: BighelpLinkLoadState) {
        guard isSignedIn else { self.init(.disconnected, "Not signed in"); return }
        switch loadState {
        case .idle, .loading: self.init(.connecting, "Connecting")
        case .failed: self.init(.disconnected, "Needs attention")
        case .loaded:
            self.init(devices.contains { $0.connection == .online } ? .connected : .disconnected,
                      BighelpLinkDeviceSummary(devices: devices).title)
        }
    }

    /// A plugin update waiting for Hermes to come back after its restart; nil
    /// for the update's other steps.
    @MainActor
    init?(pluginUpdate store: PluginUpdateStore) {
        guard store.isReconnecting else { return nil }
        self.init(.reconnecting, store.title)
    }
}
