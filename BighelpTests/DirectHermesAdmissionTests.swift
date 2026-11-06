import Foundation
import Testing
@testable import Bighelp

/// Before a message goes, the connection shows it still reaches Hermes: by the host's own recent
/// traffic on this socket, or else by a ping. These run the real WebSocket client against a
/// loopback stand-in (`LoopbackHermesSocket`).
@MainActor
struct DirectHermesAdmissionTests {
    /// The host's traffic a moment ago, an answer or an event alike, shows the socket works: the message
    /// goes without a ping round trip. Older traffic gets the ping.
    @Test func recentHostTrafficLetsAMessageSkipThePing() async throws {
        let host = try LoopbackHermesSocket()
        let client = try await host.connect()
        client.admissionFreshness = .milliseconds(300)
        try await client.prepareForAdmission()
        #expect(host.pings == 0, "gateway.ready just arrived")

        try await Task.sleep(for: .milliseconds(450))
        try await client.prepareForAdmission()
        #expect(host.pings == 1, "Quiet for longer than that: ping first")

        try await Task.sleep(for: .milliseconds(450))
        var events = 0
        // Installing a consumer replays gateway.ready to it; count only the event sent here.
        client.onEvent = { if $0.type == "session.info" { events += 1 } }
        host.send(event: "session.info")
        try await eventually { events == 1 }
        try await client.prepareForAdmission()
        #expect(host.pings == 1, "An event the host just sent shows it reaches Hermes")
        await client.disconnect()
    }

    /// A socket gone quiet may be half open: the message waits for the host to answer a ping first.
    @Test func aQuietSocketWaitsForTheHostToAnswer() async throws {
        let host = try LoopbackHermesSocket()
        let client = try await host.connect()
        client.admissionFreshness = .milliseconds(100)
        try await Task.sleep(for: .milliseconds(250))
        host.holdPings()
        let admission = AdmissionProbe(client)
        try await eventually { host.pings == 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!admission.isDone)

        host.releasePings()
        try await admission.task.value
        #expect(admission.isDone)
        await client.disconnect()
    }

    /// Coming back to the app or a network change can leave a socket that looks open but no longer
    /// reaches the host, and frames from before can still sit in its buffer. Until the host answers a
    /// ping sent since, a message waits for it.
    @Test func afterComingBackAMessageWaitsForTheHostToAnswer() async throws {
        let host = try LoopbackHermesSocket()
        let client = try await host.connect()
        host.holdPings()
        let check = Task { await client.verifyLiveness() }
        try await eventually { host.pings == 1 }
        var events = 0
        // Installing a consumer replays gateway.ready to it; count only the event sent here.
        client.onEvent = { if $0.type == "session.info" { events += 1 } }
        host.send(event: "session.info")
        try await eventually { events == 1 }
        let admission = AdmissionProbe(client)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!admission.isDone, "Traffic from before the app came back doesn't vouch for the socket")

        host.releasePings()
        try await admission.task.value
        await check.value
        #expect(admission.isDone)
        let pings = host.pings
        try await client.prepareForAdmission()
        #expect(host.pings == pings, "Once the host answered, its traffic vouches again")
        await client.disconnect()
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

/// Runs `prepareForAdmission()` and says when it finished.
@MainActor
private final class AdmissionProbe {
    private(set) var isDone = false
    private(set) var task: Task<Void, any Error>!

    init(_ client: DirectHermesClient) {
        task = Task { [weak self] in
            try await client.prepareForAdmission()
            self?.isDone = true
        }
    }
}
