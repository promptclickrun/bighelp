import Foundation
import Testing
@testable import Bighelp

private enum LocalCacheRefreshFixtureError: Error {
    case clearFailed
}

struct BighelpAppStartupTests {
    @Test @MainActor func localCacheRefreshInvalidatesClearsThenPerformsAFreshPull() async {
        var events: [String] = []
        let coordinator = BighelpLocalCacheRefreshCoordinator(
            invalidateStaleWork: { events.append("invalidate") },
            clearCurrentHostCache: { events.append("clear") },
            refreshAuthoritativeState: {
                events.append("refresh")
                return true
            }
        )

        #expect(await coordinator.clearAndRefresh())
        #expect(events == ["invalidate", "clear", "refresh"])
    }

    @Test @MainActor func localCacheRefreshReportsFailureWithoutClaimingSuccess() async {
        let coordinator = BighelpLocalCacheRefreshCoordinator(
            invalidateStaleWork: {},
            clearCurrentHostCache: { throw LocalCacheRefreshFixtureError.clearFailed },
            refreshAuthoritativeState: { true }
        )

        #expect(!(await coordinator.clearAndRefresh()))
    }

    @Test @MainActor func hostSelectionChangesSerializeAndCoalesceToLatestAuthority() async {
        let relay = BighelpHostSelectionChangeRelay()
        let gate = AccountRefreshGate()
        var events: [String] = []
        relay.handler = { hostID in
            let host = hostID ?? "none"
            events.append("start:\(host)")
            if hostID == "host-a" { await gate.wait() }
            events.append("end:\(host)")
        }

        relay.send("host-a")
        await gate.waitUntilBlocked()
        relay.send("host-b")
        relay.send("host-c")
        for _ in 0..<20 { await Task.yield() }
        #expect(events == ["start:host-a"])

        gate.open()
        for _ in 0..<200 where events.count < 4 { await Task.yield() }
        #expect(events == [
            "start:host-a",
            "end:host-a",
            "start:host-c",
            "end:host-c",
        ])
    }

    @Test func productionKeepsTheStableDataDirectory() {
        let applicationSupport = URL(filePath: "/fixture/Application Support")

        #expect(
            BighelpApplicationDataDirectories.active(
                fixtures: false,
                applicationSupport: applicationSupport,
                processIdentifier: 77
            ).lastPathComponent == "Loopdy"
        )
        #expect(
            BighelpApplicationDataDirectories.active(
                fixtures: true,
                applicationSupport: applicationSupport,
                processIdentifier: 77
            ).lastPathComponent == "LoopdyDemo-77"
        )
    }

    @Test func homeConnectionStatusUsesCompactAccessibleConnectedAndRecoveryStates() {
        let connected = HostConnectionStatus(dashboardIsConnected: true)
        let reconnecting = HostConnectionStatus(dashboardIsConnected: false)

        #expect(connected.label == "Connected")
        #expect(connected.phase == .connected)
        #expect(reconnecting.label == "Reconnecting")
        #expect(reconnecting.phase == .reconnecting)
    }
}

@MainActor
private final class AccountRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blocked = false
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        blocked = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        while !blocked { await Task.yield() }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
