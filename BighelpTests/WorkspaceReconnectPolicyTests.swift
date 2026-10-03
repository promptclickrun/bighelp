import Testing
@testable import Bighelp

struct WorkspaceReconnectPolicyTests {
    @Test func backoffGrowsThenHoldsAtThirtySeconds() {
        let delays = (0..<8).map(WorkspaceReconnectPolicy.delay(afterAttempt:))
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15),
                           .seconds(30), .seconds(30), .seconds(30)])
        #expect(WorkspaceReconnectPolicy.delay(afterAttempt: -1) == .seconds(1))
    }

    @Test func retryIsOfferedOnlyAfterQuietAttempts() {
        #expect(WorkspaceReconnectPolicy.quietAttempts == 3)
        // The first three tries (about 7 seconds) show "Reconnecting…" only.
        let quietWindow = (0..<WorkspaceReconnectPolicy.quietAttempts)
            .map(WorkspaceReconnectPolicy.delay(afterAttempt:))
            .reduce(Duration.zero, +)
        #expect(quietWindow == .seconds(7))
    }
}

/// A connection that died quietly is found in seconds, not when a request finally times out:
/// Cloudflare drops a connection after 100 quiet seconds, phone networks and Tailscale relays
/// drop idle ones, and a switch from Wi-Fi to cellular leaves the old one dead.
struct ConnectionLivenessTests {
    @Test func everyConnectionIsKeptAwakeWellUnderCloudflaresIdleLimit() {
        #expect(DirectHermesKeepalive.interval(heartbeatAdvertised: true) == .seconds(15))
        #expect(DirectHermesKeepalive.interval(heartbeatAdvertised: false) == .seconds(20),
                "Hermes not asking for a heartbeat still gets one")
        #expect(DirectHermesKeepalive.interval(heartbeatAdvertised: false) < .seconds(100))
        #expect(DirectHermesKeepalive.livenessTimeout <= .seconds(5))
    }

    @Test func onlyASilentConnectionCountsAsDead() {
        #expect(DirectHermesKeepalive.outcome(of: nil) == .alive)
        #expect(DirectHermesKeepalive.outcome(of: DirectHermesError.rpcRejected(code: -32601)) == .unsupported,
                "A Hermes without ping answered, so the connection is fine")
        #expect(DirectHermesKeepalive.outcome(of: DirectHermesError.timedOut(outcomeUnknown: false)) == .dead)
        #expect(DirectHermesKeepalive.outcome(of: DirectHermesError.disconnected(outcomeUnknown: false)) == .dead)
    }

    @Test func aNetworkSwitchChecksTheConnectionRightAway() {
        typealias Path = NetworkPathSignature
        let wifi = Path(satisfied: true, interfaces: ["wifi"])
        let cellular = Path(satisfied: true, interfaces: ["cellular"])
        let tailscale = Path(satisfied: true, interfaces: ["wifi", "other"])
        #expect(Path.needsLivenessCheck(from: wifi, to: cellular), "Wi-Fi to cellular")
        #expect(Path.needsLivenessCheck(from: wifi, to: tailscale), "A VPN like Tailscale coming up")
        #expect(Path.needsLivenessCheck(from: Path(satisfied: false, interfaces: []), to: wifi), "Back online")
        #expect(!Path.needsLivenessCheck(from: wifi, to: wifi), "Nothing changed")
        #expect(!Path.needsLivenessCheck(from: wifi, to: Path(satisfied: false, interfaces: [])),
                "Offline: nothing to check until it's back")
        #expect(!Path.needsLivenessCheck(from: nil, to: wifi), "The first reading isn't a change")
    }
}

/// A computer reached over Tailscale can't be reached while Tailscale is off on the phone.
/// Say that, instead of a general "couldn't connect".
struct TailscaleHintTests {
    @Test func aTailscaleComputerWithTailscaleOffSaysSo() {
        let hint = DirectHermesConnectionHint.message(for: .connectionFailed, host: "studio.tail1234.ts.net",
                                                      vpnActive: false)
        #expect(hint?.contains("Turn on Tailscale") == true)
        #expect(DirectHermesConnectionHint.message(for: .timedOut(outcomeUnknown: false), host: "100.101.2.3",
                                                   vpnActive: false) != nil, "Tailscale's own addresses too")
    }

    @Test func otherwiseTheUsualMessageStays() {
        #expect(DirectHermesConnectionHint.message(for: .connectionFailed, host: "studio.tail1234.ts.net",
                                                   vpnActive: true) == nil, "Tailscale is on: something else is wrong")
        #expect(DirectHermesConnectionHint.message(for: .connectionFailed, host: "hermes.example.com",
                                                   vpnActive: false) == nil)
        #expect(DirectHermesConnectionHint.message(for: .connectionFailed, host: "100.200.1.1",
                                                   vpnActive: false) == nil, "Outside Tailscale's range")
        #expect(DirectHermesConnectionHint.message(for: .authenticationRequired, host: "studio.tail1234.ts.net",
                                                   vpnActive: false) == nil, "Not a reachability problem")
    }
}
