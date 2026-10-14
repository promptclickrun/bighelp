import Foundation
import Testing
@testable import Bighelp

/// A Shortcut on a gateway that isn't in use: the app is already connecting it, so the
/// Shortcut waits for that connection instead of failing (BighelpShortcutConnectionWait).
@MainActor
struct BighelpShortcutConnectionWaitTests {
    /// A host whose connection, readiness and wanted state change as the test says.
    @MainActor final class FakeHost {
        var connectingChecks = 0
        var connected = true
        var ready = true
        var wanted = true
        var synchronized = 0
        var checks = 0

        var host: BighelpShortcutConnectionWait.Host {
            .init(
                isWanted: { self.wanted },
                isConnecting: {
                    self.checks += 1
                    return self.checks <= self.connectingChecks
                },
                isConnected: { self.connected },
                isReady: { self.ready && self.synchronized > 0 },
                synchronize: { self.synchronized += 1 }
            )
        }
    }

    @Test func aConnectionAlreadyUnderWayIsWaitedFor() async throws {
        let fake = FakeHost()
        fake.connectingChecks = 3
        let ready = try await BighelpShortcutConnectionWait.untilReady(fake.host, step: .milliseconds(10))
        #expect(ready)
        #expect(fake.checks == 4, "Checked until the connection finished")
        #expect(fake.synchronized == 1, "The workspace is set up only once it's connected")
    }

    @Test func aFailedConnectionGivesUpAtOnce() async throws {
        let fake = FakeHost()
        fake.connected = false
        let started = ContinuousClock.now
        #expect(try await !BighelpShortcutConnectionWait.untilReady(fake.host, step: .milliseconds(10)))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(fake.synchronized == 0)
    }

    @Test func aGatewayNoLongerWantedGivesUpAtOnce() async throws {
        let fake = FakeHost()
        fake.connectingChecks = 100
        fake.wanted = false
        #expect(try await !BighelpShortcutConnectionWait.untilReady(fake.host, step: .milliseconds(10)))
        #expect(fake.checks == 0)
    }

    @Test func aWorkspaceThatNeverGetsReadyTimesOut() async throws {
        let fake = FakeHost()
        fake.ready = false
        let ready = try await BighelpShortcutConnectionWait.untilReady(fake.host, timeout: .milliseconds(100),
                                                                      step: .milliseconds(10))
        #expect(!ready)
        #expect(fake.synchronized > 1, "It kept setting up while it waited")
    }
}
