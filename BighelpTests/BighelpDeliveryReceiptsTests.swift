import Foundation
import Testing
@testable import Bighelp

/// What the notification service extension writes, and what the app makes of it.
struct BighelpDeliveryReceiptsTests {
    private static let sent: Int64 = 1_800_000_000_000
    private let directory = FileManager.default.temporaryDirectory.appending(path: "receipts-\(UUID().uuidString)")

    private func receipts(defaults: UserDefaults? = nil) throws -> BighelpDeliveryReceipts {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return BighelpDeliveryReceipts(fileURL: directory.appending(path: "receipts.json"), defaults: defaults)
    }

    private func push(path: Any = "direct", sentAt: Any? = BighelpDeliveryReceiptsTests.sent,
                      occurredAt: Any? = BighelpDeliveryReceiptsTests.sent - 700, version: Any = 1) -> [AnyHashable: Any] {
        var meta: [String: Any] = ["v": version, "path": path]
        if let sentAt { meta["sentAt"] = sentAt }
        if let occurredAt { meta["occurredAt"] = occurredAt }
        return ["aps": ["alert": ["title": "bighelp", "body": "Sealed"], "mutable-content": 1], "bighelp_meta": meta]
    }

    private func arrival(afterSent milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(Self.sent + milliseconds) / 1_000)
    }

    @Test func aDirectAlertRecordsItsPathAndBothDelays() throws {
        let store = try receipts()
        store.record(userInfo: push(), receivedAt: arrival(afterSent: 1_800))
        let receipt = try #require(store.drain(limit: 10).first)
        #expect(receipt.kind == .alert && receipt.path == .direct)
        #expect(receipt.delayMilliseconds == 1_800)
        #expect(receipt.hostToPhoneMilliseconds == 2_500)
    }

    @Test func aBuzzKitCopyHasItsOwnPathAndOccurredAtIsOptional() throws {
        let store = try receipts()
        store.record(userInfo: push(path: "buzzkit", occurredAt: nil), receivedAt: arrival(afterSent: 12_000))
        let receipt = try #require(store.drain(limit: 1).first)
        #expect(receipt.path == .buzzkit && receipt.delayMilliseconds == 12_000 && receipt.hostToPhoneMilliseconds == nil)
    }

    /// The relay's BuzzKit copy carries `{"v":1,"path":"buzzkit","occurredAt":…}` and never `sentAt`
    /// (CONTRACTS.md §2): only the host-to-phone time is known then.
    @Test func theBuzzKitCopyHasNoSendTimeSoOnlyHostToPhoneIsKnown() throws {
        let store = try receipts()
        let userInfo: [AnyHashable: Any] = ["bighelp_meta": ["v": 1, "path": "buzzkit", "occurredAt": Self.sent - 5_000]]
        store.record(userInfo: userInfo, receivedAt: arrival(afterSent: 9_000))
        let receipt = try #require(store.drain(limit: 1).first)
        #expect(receipt.path == .buzzkit && receipt.sentAt == nil)
        #expect(receipt.delayMilliseconds == nil && receipt.hostToPhoneMilliseconds == 14_000)
    }

    @Test func aWakeIsToldFromAnAlert() {
        let at = Date()
        #expect(BighelpDeliveryReceipts.receipt(userInfo: ["aps": ["content-available": 1],
                                                           "bighelp_wake": ["version": 1, "type": "renew-sign-in"]],
                                                receivedAt: at).kind == .wake)
        #expect(BighelpDeliveryReceipts.receipt(userInfo: ["aps": ["content-available": 1]], receivedAt: at).kind == .wake)
        #expect(BighelpDeliveryReceipts.receipt(userInfo: ["aps": ["content-available": 1, "alert": ["body": "x"]]],
                                                receivedAt: at).kind == .alert)
        #expect(BighelpDeliveryReceipts.receipt(userInfo: push(), receivedAt: at).kind == .alert)
        #expect(BighelpDeliveryReceipts.receipt(userInfo: [:], receivedAt: at).kind == .alert)
    }

    @Test func aPushWithoutMetaStillCountsWithNoTimes() throws {
        let store = try receipts()
        store.record(userInfo: ["aps": ["alert": ["body": "x"]]], receivedAt: arrival(afterSent: 5))
        let receipt = try #require(store.drain(limit: 1).first)
        #expect(receipt.path == .unknown && receipt.delayMilliseconds == nil && receipt.hostToPhoneMilliseconds == nil)
    }

    @Test func garbageMetaGivesPathUnknownAndNoTimes() {
        let at = arrival(afterSent: 1_000)
        let cases: [[AnyHashable: Any]] = [
            ["bighelp_meta": "direct"], ["bighelp_meta": [1, 2, 3]], ["bighelp_meta": NSNull()],
            push(version: 2), push(version: "1"), push(version: true),
            push(path: 7, sentAt: "yesterday", occurredAt: [:]),
            push(sentAt: -5, occurredAt: 1.5), push(sentAt: Double.nan, occurredAt: Double.infinity),
            push(sentAt: 12, occurredAt: 99_999_999_999_999_999),
        ]
        for userInfo in cases {
            let receipt = BighelpDeliveryReceipts.receipt(userInfo: userInfo, receivedAt: at)
            #expect(receipt.delayMilliseconds == nil && receipt.hostToPhoneMilliseconds == nil, "\(userInfo)")
            #expect(receipt.kind == .alert)
        }
        #expect(BighelpDeliveryReceipts.receipt(userInfo: push(path: 7), receivedAt: at).path == .unknown)
        #expect(BighelpDeliveryReceipts.receipt(userInfo: push(path: "carrier-pigeon"), receivedAt: at).path == .unknown)
    }

    @Test func aClockThatDisagreesNeverGivesANegativeDelay() {
        let early = BighelpDeliveryReceipts.receipt(userInfo: push(), receivedAt: arrival(afterSent: -3_000))
        #expect(early.delayMilliseconds == nil && early.hostToPhoneMilliseconds == nil)
        let exactly = BighelpDeliveryReceipts.receipt(userInfo: push(occurredAt: Self.sent), receivedAt: arrival(afterSent: 0))
        #expect(exactly.delayMilliseconds == 0 && exactly.hostToPhoneMilliseconds == 0)
        let stale = BighelpDeliveryReceipts.receipt(userInfo: push(), receivedAt: arrival(afterSent: 90_000_000))
        #expect(stale.delayMilliseconds == nil, "over a day is a bad clock, not a delay")
    }

    @Test func theFileHoldsTwoHundredAndDropsTheOldest() throws {
        let store = try receipts()
        for index in 0..<260 {
            store.append(BighelpDeliveryReceipt(kind: .alert, path: .direct, receivedAt: Self.sent + Int64(index),
                                                sentAt: nil, occurredAt: nil))
        }
        #expect(store.count == 200)
        let all = store.drain(limit: 1_000)
        #expect(all.count == 200)
        #expect(all.first?.receivedAt == Self.sent + 60 && all.last?.receivedAt == Self.sent + 259)
        #expect(store.count == 0)
    }

    @Test func drainTakesTheOldestFirstAndLeavesTheRest() throws {
        let store = try receipts()
        for index in 0..<5 {
            store.append(BighelpDeliveryReceipt(kind: .wake, path: .unknown, receivedAt: Self.sent + Int64(index),
                                                sentAt: nil, occurredAt: nil))
        }
        #expect(store.drain(limit: 2).map(\.receivedAt) == [Self.sent, Self.sent + 1])
        #expect(store.count == 3)
        #expect(store.drain(limit: 0).isEmpty && store.drain(limit: -4).isEmpty)
        #expect(store.drain(limit: 10).count == 3)
        #expect(store.drain(limit: 10).isEmpty)
    }

    @Test func aDamagedFileIsStartedOver() throws {
        let store = try receipts()
        try Data("{ not receipts".utf8).write(to: try #require(store.fileURL))
        #expect(store.drain(limit: 5).isEmpty)
        store.record(userInfo: push(), receivedAt: arrival(afterSent: 10))
        #expect(store.count == 1)
    }

    @Test func noGroupContainerMeansNothingIsRecordedAndNothingCrashes() {
        let store = BighelpDeliveryReceipts(fileURL: nil)
        store.record(userInfo: push(), receivedAt: Date())
        #expect(store.drain(limit: 5).isEmpty && store.count == 0)
    }

    @Test func theExtensionWritesNothingWhileSharingIsOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "receipts-\(UUID().uuidString)"))
        let store = try receipts(defaults: defaults)
        #expect(store.isRecording, "on unless the app says otherwise")
        store.setRecording(false)
        store.record(userInfo: push(), receivedAt: Date())
        #expect(store.count == 0)
        store.setRecording(true)
        store.record(userInfo: push(), receivedAt: Date())
        #expect(store.count == 1)
    }

    @Test func nothingOfTheMessageIsKept() throws {
        let store = try receipts()
        var userInfo = push()
        userInfo["aps"] = ["alert": ["title": "Alice", "body": "My password is hunter2"], "thread-id": "chat-with-alice"]
        userInfo["loopdy"] = ["eventId": "evt-secret-123", "sessionReference": "alice-private-chat", "text": "hunter2"]
        userInfo["bighelp_meta"] = ["v": 1, "path": "direct", "sentAt": Self.sent, "note": "hunter2 and Alice"]
        store.record(userInfo: userInfo, receivedAt: arrival(afterSent: 400))
        let text = try String(contentsOf: try #require(store.fileURL), encoding: .utf8)
        for secret in ["Alice", "hunter2", "evt-secret", "alice-private", "password", "chat-with"] {
            #expect(!text.contains(secret), "\(secret) was written to the receipts file")
        }
        let keys = try #require((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])?.first).keys
        #expect(Set(keys).isSubset(of: ["kind", "path", "receivedAt", "sentAt", "occurredAt"]))
    }

    @Test func twoProcessesWritingAtOnceLoseNothing() async throws {
        let store = try receipts()
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<4 {
                group.addTask {
                    for index in 0..<30 {
                        store.append(BighelpDeliveryReceipt(kind: .alert, path: .direct,
                                                            receivedAt: Self.sent + Int64(worker * 100 + index),
                                                            sentAt: nil, occurredAt: nil))
                    }
                }
            }
        }
        #expect(store.count == 120)
    }

    // MARK: - The app's side

    @Test func theAppTurnsReceiptsIntoNotificationReceivedEvents() throws {
        let receipt = BighelpDeliveryReceipt(kind: .alert, path: .buzzkit, receivedAt: Self.sent + 3_000,
                                             sentAt: Self.sent, occurredAt: Self.sent - 1_000)
        let record = TelemetryLifecycle.record(receipt)
        #expect(record.event == .notificationReceived(kind: .alert, path: .buzzkit, delayMs: 3_000, hostToPhoneMs: 4_000))
        #expect(record.time == Self.sent + 3_000)
        #expect(record.event.source == .nse)
        let wake = TelemetryLifecycle.record(BighelpDeliveryReceipt(kind: .wake, path: .direct, receivedAt: 5,
                                                                   sentAt: nil, occurredAt: nil))
        #expect(wake.event == .notificationReceived(kind: .wake, path: .direct, delayMs: nil, hostToPhoneMs: nil))
    }

    @Test func drainingSendsAnNSEBatchAndEmptiesTheFile() async throws {
        let store = try receipts()
        let rig = TelemetryTestRig.make()
        let now = rig.clock.now
        for index in 0..<3 {
            store.append(BighelpDeliveryReceipt(kind: .alert, path: .direct,
                                                receivedAt: Int64(now.timeIntervalSince1970 * 1_000) - 1_000 + Int64(index),
                                                sentAt: nil, occurredAt: nil))
        }
        await TelemetryLifecycle.drain(store, into: rig.client, now: now)
        #expect(store.count == 0)
        await rig.client.flush()
        let batch = try #require(rig.transport.batches.first)
        #expect(batch["source"] as? String == "nse")
        #expect((batch["events"] as? [Any])?.count == 3)
    }

    @Test func drainingWithSharingOffThrowsReceiptsAwayAndSendsNothing() async throws {
        let store = try receipts()
        let rig = TelemetryTestRig.make(enabled: false)
        store.append(BighelpDeliveryReceipt(kind: .alert, path: .direct, receivedAt: Self.sent, sentAt: nil, occurredAt: nil))
        await TelemetryLifecycle.drain(store, into: rig.client, now: rig.clock.now)
        #expect(store.count == 0)
        #expect(await rig.client.queuedCount == 0)
        store.append(BighelpDeliveryReceipt(kind: .alert, path: .direct, receivedAt: Self.sent, sentAt: nil, occurredAt: nil))
        await TelemetryLifecycle.drain(store, into: nil, now: rig.clock.now)
        #expect(store.count == 0)
    }

    @Test func moreThanOneBatchOfReceiptsAllGetDrained() async throws {
        let store = try receipts()
        let rig = TelemetryTestRig.make()
        let base = Int64(rig.clock.now.timeIntervalSince1970 * 1_000) - 5_000
        for index in 0..<200 {
            store.append(BighelpDeliveryReceipt(kind: .alert, path: .direct, receivedAt: base + Int64(index),
                                                sentAt: nil, occurredAt: nil))
        }
        await TelemetryLifecycle.drain(store, into: rig.client, now: rig.clock.now)
        #expect(store.count == 0)
        #expect(await rig.client.queuedCount + rig.transport.requests.count * 50 >= 200)
    }
}
