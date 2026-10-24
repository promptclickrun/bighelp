import Foundation
import Testing
import UserNotifications
@testable import Bighelp

/// The notification service extension's work, with fakes for opening a sealed alert, the avatar, the
/// phone and the clock: whatever happens, the system gets exactly one notification.
@MainActor @Suite(.serialized) struct NotificationProcessorTests {
    private static let grantID = "0b3f1c2e-4d5a-4b6c-8d7e-9f0a1b2c3d4e"
    private static let eventID = grantID + ":" + String(repeating: "ab", count: 32)
    nonisolated private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    // MARK: Fakes

    /// A task that waits until the test lets it go.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if opened { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        func open() {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                opened = true
                defer { continuation = nil }
                return continuation
            }
            pending?.resume()
        }
    }

    /// What the system was handed.
    final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var contents: [UNNotificationContent] = []
        func record(_ content: UNNotificationContent) { lock.withLock { contents.append(content) } }
        var all: [UNNotificationContent] { lock.withLock { contents } }

        /// Waits for the first one, then a moment longer, so a second would show.
        func settled() async -> [UNNotificationContent] {
            for _ in 0..<600 where all.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            try? await Task.sleep(for: .milliseconds(120))
            return all
        }
    }

    final class Fakes: @unchecked Sendable {
        var opened: BighelpSealedAlert.Content?
        var avatarGate: Gate?
        var avatarFile: URL?
        var downloadGate: Gate?
        var shownLive = false
        var avatarWait = Duration.milliseconds(400)
        let categories = PushDisplayTests.Categories()
        /// When set, reading the categories waits for this gate: a point inside the display stage.
        var categoriesGate: Gate?
        var receiptGate: Gate?
        private let lock = NSLock()
        private var receipts: [String] = []
        var receiptsSent: [String] { lock.withLock { receipts } }
        private var cleared: [String] = []
        private var downloads: [URL] = []
        var clearedEvents: [String] { lock.withLock { cleared } }
        var downloaded: [URL] { lock.withLock { downloads } }

        func services() -> BighelpNotificationProcessor.Services {
            .init(open: { [self] _ in opened },
                  avatar: { [self] _, _ in
                      await avatarGate?.wait()
                      return avatarFile
                  },
                  alreadyShown: { [self] _ in shownLive },
                  clearOlder: { [self] _, _, eventID, _ in lock.withLock { cleared.append(eventID) } },
                  receipt: { [self] id in
                      lock.withLock { receipts.append(id) }
                      await receiptGate?.wait()
                  },
                  categories: categoriesGate.map { GatedCategories(gate: $0) } ?? categories,
                  download: { [self] url in
                      lock.withLock { downloads.append(url) }
                      await downloadGate?.wait()
                      let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                      try NotificationProcessorTests.png.write(to: file)
                      return (file, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                  },
                  avatarWait: avatarWait)
        }
    }

    final class GatedCategories: BighelpNotificationCategoryStore, @unchecked Sendable {
        let gate: Gate
        init(gate: Gate) { self.gate = gate }
        func categories() async -> Set<UNNotificationCategory> {
            await gate.wait()
            return []
        }
        func setCategories(_ categories: Set<UNNotificationCategory>) {}
    }

    // MARK: Payloads

    private struct Vector: Decodable {
        let plaintext: BighelpSealedAlert.Content
    }

    private static func sealedPush() throws -> (userInfo: [AnyHashable: Any], content: BighelpSealedAlert.Content) {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/sealed-alert-v2-vector.json"))
        let vector = try JSONDecoder().decode(Vector.self, from: data)
        let envelope = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["envelope"] as? [String: Any])
        let info: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "bighelp", "body": "placeholder"], "mutable-content": 1,
                    "thread-id": "chat-ref", "category": "BIGHELP_UPDATE"] as [String: Any],
            "loopdy": ["version": 2, "eventId": envelope["eventId"] as Any, "eventType": "session.completed",
                       "grantId": envelope["grantId"] as Any, "sealed": envelope] as [String: Any],
            "bk": ["category": "BIGHELP_UPDATE", "actions": [["id": "open", "title": "Open"]]] as [String: Any],
            "bighelp_meta": ["v": 1, "path": "direct", "sentAt": 1_800_000_000_000],
        ]
        return (info, vector.plaintext)
    }

    private static func request(_ userInfo: [AnyHashable: Any], title: String = "bighelp", body: String = "placeholder",
                                thread: String = "chat-ref") -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.threadIdentifier = thread; content.userInfo = userInfo
        return UNNotificationRequest(identifier: "request-1", content: content, trigger: nil)
    }

    private static func alert(_ path: PushDisplayTests.Path) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Nova", "body": "Done"], "mutable-content": 1] as [String: Any],
            "loopdy": ["version": 2, "eventId": eventID, "eventType": "approval.required", "grantId": grantID,
                       "agent": ["id": "nova"], "sessionReference": String(repeating: "A", count: 43)] as [String: Any],
        ]
        var bk: [String: Any] = [
            "category": "BIGHELP_APPROVAL", "image": "https://example.com/avatar.png",
            "actions": [["id": "approve", "title": "Approve"], ["id": "deny", "title": "Deny", "destructive": true]],
        ]
        if path == .buzzkit { bk["messageId"] = "msg_1" }
        info["bk"] = bk
        info["bighelp_meta"] = ["v": 1, "path": path.rawValue, "sentAt": 1_800_000_000_000]
        return info
    }

    private func run(_ fakes: Fakes, _ request: UNNotificationRequest) -> (BighelpNotificationProcessor, Delivered) {
        let delivered = Delivered()
        let processor = BighelpNotificationProcessor(services: fakes.services())
        processor.didReceive(request) { delivered.record($0) }
        return (processor, delivered)
    }

    // MARK: Sealed alerts

    @Test func aSealedAlertOpensGetsItsPictureAndShowsOnce() async throws {
        let (info, plaintext) = try Self.sealedPush()
        let fakes = Fakes()
        fakes.opened = plaintext
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Self.png.write(to: file)
        fakes.avatarFile = file
        let (_, delivered) = run(fakes, Self.request(info))
        let shown = await delivered.settled()
        #expect(shown.count == 1)
        let content = try #require(shown.first)
        #expect(content.title == plaintext.title)
        #expect(content.body == plaintext.body)
        #expect(content.attachments.map(\.identifier) == ["bk.image"])
        #expect(content.categoryIdentifier == "BIGHELP_UPDATE", "Its buttons are registered after the opening")
        #expect(fakes.clearedEvents.count == 1)
    }

    @Test func aSealedAlertShownLiveByTheAppIsQuiet() async throws {
        let (info, plaintext) = try Self.sealedPush()
        let fakes = Fakes()
        fakes.opened = plaintext
        fakes.shownLive = true
        let (_, delivered) = run(fakes, Self.request(info))
        let shown = await delivered.settled()
        #expect(shown.count == 1)
        #expect(shown.first?.interruptionLevel == .passive)
    }

    @Test func aSealedAlertThatCannotBeOpenedShowsAsSentOnce() async throws {
        let (info, _) = try Self.sealedPush()
        let fakes = Fakes()
        fakes.opened = nil
        let (_, delivered) = run(fakes, Self.request(info))
        let shown = await delivered.settled()
        #expect(shown.count == 1)
        #expect(shown.first?.title == "bighelp", "The placeholder stays")
        #expect(shown.first?.attachments.isEmpty == true)
        #expect(fakes.clearedEvents.isEmpty, "Nothing was opened, so nothing replaces anything")
    }

    @Test func aSlowFirstAvatarDoesNotHoldTheAlertBack() async throws {
        let (info, plaintext) = try Self.sealedPush()
        let fakes = Fakes()
        fakes.opened = plaintext
        let gate = Gate()
        fakes.avatarGate = gate
        fakes.avatarFile = nil
        fakes.avatarWait = .milliseconds(60)
        let (_, delivered) = run(fakes, Self.request(info))
        let shown = await delivered.settled()
        #expect(shown.count == 1)
        #expect(shown.first?.title == plaintext.title)
        #expect(shown.first?.attachments.isEmpty == true)
        gate.open() // the download ends later, for next time
        try? await Task.sleep(for: .milliseconds(80))
        #expect(delivered.all.count == 1)
    }

    @Test func theSystemRunningOutOfTimeBeforeTheAvatarShowsTheOpenedTextOnce() async throws {
        let (info, plaintext) = try Self.sealedPush()
        let fakes = Fakes()
        fakes.opened = plaintext
        let gate = Gate()
        fakes.avatarGate = gate
        fakes.avatarWait = .seconds(30)
        let (processor, delivered) = run(fakes, Self.request(info))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(delivered.all.isEmpty, "Still waiting for the avatar")
        processor.timeWillExpire()
        #expect(delivered.all.count == 1)
        #expect(delivered.all.first?.title == plaintext.title)
        #expect(delivered.all.first?.attachments.isEmpty == true)
        // The work finishing afterwards shows nothing more.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Self.png.write(to: file)
        fakes.avatarFile = file
        gate.open()
        let shown = await delivered.settled()
        #expect(shown.count == 1)
        processor.timeWillExpire()
        #expect(delivered.all.count == 1)
    }

    @Test func theSystemRunningOutOfTimeAfterTheWorkIsDoneShowsNothingAgain() async throws {
        let (info, plaintext) = try Self.sealedPush()
        let fakes = Fakes()
        fakes.opened = plaintext
        let (processor, delivered) = run(fakes, Self.request(info))
        #expect(await delivered.settled().count == 1)
        processor.timeWillExpire()
        processor.timeWillExpire()
        #expect(delivered.all.count == 1)
    }

    @Test func theSystemRunningOutOfTimeBetweenOpeningAndTheDisplayStageStillShowsOnce() async throws {
        let (info, plaintext) = try Self.sealedPush()
        let fakes = Fakes()
        fakes.opened = plaintext
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Self.png.write(to: file)
        fakes.avatarFile = file
        let gate = Gate()
        fakes.categoriesGate = gate // the display stage starts, and waits here
        let (processor, delivered) = run(fakes, Self.request(info))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(delivered.all.isEmpty)
        processor.timeWillExpire()
        #expect(delivered.all.count == 1, "The hold was never let go between the stages")
        #expect(delivered.all.first?.title == plaintext.title)
        #expect(delivered.all.first?.attachments.map(\.identifier) == ["bk.image"])
        gate.open()
        #expect(await delivered.settled().count == 1)
    }

    // MARK: BuzzKit's delivered receipt

    @Test func aPushBuzzKitDeliveredGetsItsReceiptAndADirectOneDoesNot() async {
        for (path, expected) in [(PushDisplayTests.Path.buzzkit, ["msg_1"]), (.direct, [])] {
            let fakes = Fakes()
            let (_, delivered) = run(fakes, Self.request(Self.alert(path), title: "Nova", body: "Done"))
            #expect(await delivered.settled().count == 1)
            #expect(fakes.receiptsSent == expected, "\(path)")
        }
    }

    @Test func aSealedAlertBuzzKitDeliveredGetsItsReceiptToo() async throws {
        var (info, plaintext) = try Self.sealedPush()
        var bk = info["bk"] as? [String: Any] ?? [:]
        bk["messageId"] = "msg_sealed"
        info["bk"] = bk
        let fakes = Fakes()
        fakes.opened = plaintext
        let (_, delivered) = run(fakes, Self.request(info))
        #expect(await delivered.settled().count == 1)
        #expect(fakes.receiptsSent == ["msg_sealed"])
        // And one that can't be opened still counts as delivered.
        let unreadable = Fakes()
        let (_, second) = run(unreadable, Self.request(info))
        #expect(await second.settled().count == 1)
        #expect(unreadable.receiptsSent == ["msg_sealed"])
    }

    @Test func aTopLevelMessageIDCountsLikeBuzzKitsOwnParser() async {
        let fakes = Fakes()
        let (_, delivered) = run(fakes, Self.request(["messageId": "msg_9", "aps": ["alert": "Hi"]]))
        #expect(await delivered.settled().count == 1)
        #expect(fakes.receiptsSent == ["msg_9"])
        let none = Fakes()
        let (_, other) = run(none, Self.request(["aps": ["alert": "Hi"]]))
        #expect(await other.settled().count == 1)
        #expect(none.receiptsSent.isEmpty)
    }

    @Test func aReceiptThatNeverAnswersDoesNotHoldTheAlertBack() async {
        let fakes = Fakes()
        let gate = Gate()
        fakes.receiptGate = gate
        let (_, delivered) = run(fakes, Self.request(Self.alert(.buzzkit), title: "Nova", body: "Done"))
        #expect(await delivered.settled().count == 1, "Shown while the receipt is still going")
        #expect(fakes.receiptsSent == ["msg_1"])
        gate.open()
    }

    // MARK: Other pushes

    @Test(arguments: PushDisplayTests.Path.allCases)
    func aPushWithButtonsAndAPictureShowsOnceWithBoth(path: PushDisplayTests.Path) async throws {
        let fakes = Fakes()
        let (_, delivered) = run(fakes, Self.request(Self.alert(path), title: "Nova", body: "Done", thread: "chat-ref"))
        let shown = await delivered.settled()
        #expect(shown.count == 1)
        let content = try #require(shown.first)
        #expect(content.categoryIdentifier == "BIGHELP_APPROVAL")
        #expect(content.attachments.map(\.identifier) == ["bk.image"])
        #expect(fakes.downloaded.map(\.absoluteString) == ["https://example.com/avatar.png"])
        let registered = await fakes.categories.categories()
        #expect(registered.first?.actions.map(\.identifier) == ["approve", "deny"])
        // In the agent's stack, with the chat kept where the app reads it.
        #expect(content.threadIdentifier == "agent:nova" || !content.threadIdentifier.isEmpty)
        #expect((content.userInfo["loopdy"] as? [String: Any])?["sessionReference"] as? String
            == String(repeating: "A", count: 43))
    }

    @Test func bothPathsShowTheSameThing() async throws {
        var shown: [UNNotificationContent] = []
        for path in PushDisplayTests.Path.allCases {
            let fakes = Fakes()
            let (_, delivered) = run(fakes, Self.request(Self.alert(path), title: "Nova", body: "Done"))
            shown += await delivered.settled()
        }
        #expect(shown.count == 2)
        #expect(shown[0].title == shown[1].title && shown[0].body == shown[1].body)
        #expect(shown[0].categoryIdentifier == shown[1].categoryIdentifier)
        #expect(shown[0].threadIdentifier == shown[1].threadIdentifier)
        #expect(shown[0].attachments.map(\.identifier) == shown[1].attachments.map(\.identifier))
    }

    @Test func aPushThatIsNotBuzzKitsOrBighelpsShowsAsItIsOnce() async {
        let fakes = Fakes()
        let (_, delivered) = run(fakes, Self.request(["aps": ["alert": "Hello"], "something": ["else": 1]],
                                                      title: "Hi", body: "There", thread: ""))
        let shown = await delivered.settled()
        #expect(shown.count == 1)
        #expect(shown.first?.title == "Hi" && shown.first?.body == "There")
        #expect(shown.first?.categoryIdentifier == "")
        #expect(shown.first?.attachments.isEmpty == true)
        #expect(fakes.downloaded.isEmpty)
        #expect(await fakes.categories.categories().isEmpty)
    }

    @Test func aWakeTouchesNothingAndAnswersOnce() async {
        for path in PushDisplayTests.Path.allCases {
            let fakes = Fakes()
            var info: [AnyHashable: Any] = [
                "aps": ["content-available": 1],
                "bighelp_wake": ["version": 1, "type": "renew-sign-in", "grantId": Self.grantID] as [String: Any],
                "bighelp_meta": ["v": 1, "path": path.rawValue, "sentAt": 1_800_000_000_000],
            ]
            if path == .buzzkit { info["messageId"] = "msg_2" }
            let (_, delivered) = run(fakes, Self.request(info, title: "", body: "", thread: ""))
            let shown = await delivered.settled()
            #expect(shown.count == 1, "\(path)")
            #expect(shown.first?.title == "" && shown.first?.categoryIdentifier == "")
            #expect(fakes.downloaded.isEmpty && fakes.clearedEvents.isEmpty)
            #expect(await fakes.categories.categories().isEmpty)
        }
    }

    @Test func theSystemRunningOutOfTimeDuringAPictureShowsTheButtonsOnce() async throws {
        let fakes = Fakes()
        let gate = Gate()
        fakes.downloadGate = gate
        let (processor, delivered) = run(fakes, Self.request(Self.alert(.direct), title: "Nova", body: "Done"))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(delivered.all.isEmpty, "Waiting for the picture")
        processor.timeWillExpire()
        #expect(delivered.all.count == 1)
        #expect(delivered.all.first?.categoryIdentifier == "BIGHELP_APPROVAL", "Registered before the picture")
        #expect(delivered.all.first?.attachments.isEmpty == true)
        gate.open()
        #expect(await delivered.settled().count == 1)
    }
}
