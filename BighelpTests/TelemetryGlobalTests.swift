import Foundation
import SwiftUI
import Testing
@testable import Bighelp

/// Tests that use the app-wide `Telemetry` door. They install a fake client, so they run one at a time.
@Suite(.serialized)
struct TelemetryGlobalTests {
    private static let secrets = ["Alice", "hunter2", "/Users", "secret plan", "password", "salary", "S3cr3t",
                                  "evt-secret", "alice@example.com"]

    @Test func underTestsTheAppNeverMakesAClient() async {
        let installed = await MainActor.run { Telemetry.bootstrap() }
        #expect(installed == nil)
        #expect(Telemetry.client == nil && !Telemetry.isActive)
        // With no client every call is a quiet no-op.
        Telemetry.featureUsed(.chatSent)
        Telemetry.record(.appOpened(coldStart: true))
        Telemetry.featureUsedOnce(.cardRendered, key: "x")
        await Telemetry.flushForBackground()
    }

    @Test func realisticTextFilePathsAndNamesCannotReachABatch() async throws {
        let rig = TelemetryTestRig.make()
        Telemetry.install(rig.client)
        defer { Telemetry.install(nil) }

        // Every public way in, fed text from a chat, a file and a person.
        Telemetry.featureUsedOnce(.cardRendered, key: "Dear Alice, my password is hunter2")
        Telemetry.featureUsed(.chatSent)
        Telemetry.record(.featureUsed(.fileOpened))
        Telemetry.record(.firstToken(ms: 400))
        Telemetry.record(.reconnect(ms: 1_000, attempts: 1, outcome: .failed))
        for name in ["/Users/alice/Documents/secret plan.pdf", "Alice's salary.xlsx", "S3cr3t Project"] {
            #expect(TelemetryFrame(binaryUUID: "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", offset: 4, name: name) == nil)
            let frame = TelemetryFrame(binaryUUID: "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", offset: 4,
                                       name: TelemetryMetricMapping.plainBinaryName(name))
            Telemetry.record(.hang(durationMs: 2_000, frames: frame.map { [$0] } ?? []))
        }
        let report: [String: Any] = [
            "terminationReason": "hunter2", "callStacks": [["threadAttributed": true, "callStackRootFrames": [[
                "binaryUUID": "3F2A9C1E-5B7D-4E8F-9A10-2C4D6E8F0A1B", "offsetIntoBinaryTextSegment": 3,
                "binaryName": "Alice S3cr3t", "exceptionReason": "Alice's chat",
            ]]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: report)
        Telemetry.record(TelemetryMetricMapping.crashEvent(exceptionType: 1, exceptionCode: 1, signal: 6, callStackTree: data))
        // A push carrying a sealed message's text, a chat reference and an event ID.
        let receipt = BighelpDeliveryReceipts.receipt(userInfo: [
            "aps": ["alert": ["title": "Alice", "body": "my password is hunter2"], "thread-id": "alice@example.com"],
            "loopdy": ["eventId": "evt-secret-1", "text": "salary"],
            "bighelp_meta": ["v": 1, "path": "direct", "sentAt": 1_800_000_000_000, "title": "Alice"],
        ], receivedAt: Date(timeIntervalSince1970: 1_800_000_001))
        Telemetry.record(TelemetryLifecycle.record(receipt).event, at: Date())

        // Let the fire-and-forget tasks land, then send.
        for _ in 0..<200 where await rig.client.queuedCount < 8 { try? await Task.sleep(for: .milliseconds(5)) }
        await rig.client.flush()
        #expect(await rig.transport.waitForRequests(2))
        let text = rig.transport.allText
        #expect(!text.isEmpty)
        for secret in Self.secrets { #expect(!text.contains(secret), "\(secret) reached a batch") }
        // Nothing but allowlisted event names went out.
        let names = Set(rig.transport.batches.flatMap { ($0["events"] as? [[String: Any]]) ?? [] }.compactMap { $0["name"] as? String })
        #expect(names.isSubset(of: Set(TelemetryEncodingTests.allowedProps.keys)))
    }

    @Test func aCardCountsOncePerRunNoMatterHowOftenItIsDrawn() async throws {
        let rig = TelemetryTestRig.make()
        Telemetry.install(rig.client)
        defer { Telemetry.install(nil) }
        let key = UUID().uuidString
        for _ in 0..<5 { Telemetry.featureUsedOnce(.cardRendered, key: key) }
        Telemetry.featureUsedOnce(.cardRendered, key: UUID().uuidString)
        for _ in 0..<200 where await rig.client.queuedCount < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        let cards = await rig.client.queuedEvents.filter { $0 == .featureUsed(.cardRendered) }
        #expect(cards.count == 2)
    }

    @MainActor
    @Test func openingAndBackgroundingAreCounted() async throws {
        let rig = TelemetryTestRig.make()
        Telemetry.install(rig.client)
        defer { Telemetry.install(nil) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lifecycle = TelemetryLifecycle(now: start)
        lifecycle.scenePhaseChanged(to: .active, now: start.addingTimeInterval(1), receipts: nil)
        lifecycle.scenePhaseChanged(to: .active, now: start.addingTimeInterval(2), receipts: nil)
        lifecycle.scenePhaseChanged(to: .inactive, now: start.addingTimeInterval(3), receipts: nil)
        lifecycle.scenePhaseChanged(to: .background, now: start.addingTimeInterval(11), receipts: nil)
        lifecycle.scenePhaseChanged(to: .active, now: start.addingTimeInterval(100), receipts: nil)
        // The background sends what's queued, so read what was sent plus what is left.
        func sentEvents() -> [[String: Any]] { rig.transport.batches.flatMap { ($0["events"] as? [[String: Any]]) ?? [] } }
        for _ in 0..<400 {
            if sentEvents().count + (await rig.client.queuedCount) >= 4 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let queued = await rig.client.queuedEvents.map { TelemetryBatchEncoder.object(TelemetryWireEvent($0, timeMilliseconds: 0)) }
        let all = sentEvents() + queued
        let names = all.compactMap { $0["name"] as? String }
        #expect(names.filter { $0 == "app.opened" }.count == 2)
        #expect(names.filter { $0 == "app.backgrounded" }.count == 1)
        #expect(names.filter { $0 == "session.ended" }.count == 1)
        func props(_ name: String) -> [[String: Any]] {
            all.filter { ($0["name"] as? String) == name }.compactMap { $0["p"] as? [String: Any] }
        }
        #expect(props("app.backgrounded").first?["foregroundMs"] as? Int == 10_000)
        #expect(props("session.ended").first?["durationMs"] as? Int == 11_000)
        let cold = props("app.opened").compactMap { $0["coldStart"] as? Bool }
        #expect(cold.sorted(by: { $0 && !$1 }) == [true, false], "the first open is a cold start, the one after the background is not")
    }
}
