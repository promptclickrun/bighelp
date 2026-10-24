import BuzzKit
import Foundation
import Testing
import UserNotifications
@testable import Bighelp

/// A push shows the same whether the notification service sent it through BuzzKit or straight to
/// Apple (CONTRACTS §2): the same action buttons, picture, tap and quiet-chat rules. The only
/// difference is that a direct push has no `bk.messageId`, so bighelp sends no receipt for it.
@MainActor @Suite(.serialized) struct PushDisplayTests {
    private static let grantID = "0b3f1c2e-4d5a-4b6c-8d7e-9f0a1b2c3d4e"
    private static let eventID = grantID + ":" + String(repeating: "ab", count: 32)
    /// A 1 by 1 PNG.
    nonisolated private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    enum Path: String, CaseIterable { case buzzkit, direct }

    /// A sealed or rich alert as the Worker builds it for each path.
    private static func alert(_ path: Path, image: String? = "https://example.com/avatar.png") -> [AnyHashable: Any] {
        var bk: [String: Any] = [
            "deepLink": "loopdy:///dashboard?eventId=\(eventID)",
            "action": ["name": "open_loopdy_managed_event", "data": ["eventId": eventID]],
            "category": "BIGHELP_APPROVAL",
            "actions": [
                ["id": "approve", "title": "Approve", "foreground": true],
                ["id": "deny", "title": "Deny", "destructive": true],
                ["id": "reply", "title": "Reply", "input": true, "placeholder": "Say more"],
                ["id": "broken"],
            ] as [[String: Any]],
        ]
        if let image { bk["image"] = image }
        var info: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "bighelp", "body": "Something needs you"], "mutable-content": 1,
                    "thread-id": "chat-ref", "category": "BIGHELP_APPROVAL"] as [String: Any],
            "loopdy": ["version": 2, "eventId": eventID, "eventType": "approval.required", "grantId": grantID,
                       "agent": ["id": "nova"], "sessionReference": String(repeating: "A", count: 43)] as [String: Any],
            "bk": bk,
        ]
        switch path {
        case .buzzkit:
            var withID = bk
            withID["messageId"] = "msg_0123"
            info["bk"] = withID
            info["bighelp_meta"] = ["v": 1, "path": "buzzkit", "sentAt": 1_800_000_000_000]
        case .direct:
            info["bighelp_meta"] = ["v": 1, "path": "direct", "sentAt": 1_800_000_000_000, "occurredAt": 1_799_999_999_000]
        }
        return info
    }

    private static func wake(_ path: Path) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "bighelp_wake": ["version": 1, "type": "renew-sign-in", "grantId": grantID] as [String: Any],
            "bighelp_meta": ["v": 1, "path": path.rawValue, "sentAt": 1_800_000_000_000],
        ]
        if path == .buzzkit { info["messageId"] = "msg_0456" }
        return info
    }

    // MARK: Fakes

    final class Categories: BighelpNotificationCategoryStore, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Set<UNNotificationCategory>
        private(set) var writes = 0
        init(_ stored: Set<UNNotificationCategory> = []) { self.stored = stored }
        func categories() async -> Set<UNNotificationCategory> { lock.withLock { stored } }
        func setCategories(_ categories: Set<UNNotificationCategory>) {
            lock.withLock { stored = categories; writes += 1 }
        }
    }

    private static func download(status: Int = 200, bytes: Data = png, size: Int? = nil,
                                 requested: Requested = Requested()) -> BighelpPushDisplay.Download {
        { url in
            requested.record(url)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: file)
            if let size { try FileHandle(forWritingTo: file).truncate(atOffset: UInt64(size)) }
            return (file, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    final class Requested: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func record(_ url: URL) { lock.withLock { urls.append(url) } }
        var all: [URL] { lock.withLock { urls } }
    }

    final class Shown: @unchecked Sendable {
        private let lock = NSLock()
        private var titles: [String] = []
        func record(_ content: UNNotificationContent) { lock.withLock { titles.append(content.title) } }
        var all: [String] { lock.withLock { titles } }
    }

    // MARK: Both paths read the same

    @Test func buzzKitAndDirectPushesAskForTheSameDisplay() throws {
        let buzzkit = try #require(BighelpPushDisplay(userInfo: Self.alert(.buzzkit)))
        let direct = try #require(BighelpPushDisplay(userInfo: Self.alert(.direct)))
        #expect(buzzkit == direct)
        #expect(direct.categoryID == "BIGHELP_APPROVAL")
        #expect(direct.imageURL?.absoluteString == "https://example.com/avatar.png")
        // The action without a title is dropped, the rest keep their flags and order.
        #expect(direct.actions.map(\.id) == ["approve", "deny", "reply"])
        #expect(direct.actions.map(\.foreground) == [true, false, false])
        #expect(direct.actions.map(\.destructive) == [false, true, false])
        #expect(direct.actions.map(\.input) == [false, false, true])
        #expect(direct.actions.last?.placeholder == "Say more")
    }

    @Test func aPushWithNothingFromBuzzKitHasNothingToAdd() {
        #expect(BighelpPushDisplay(userInfo: ["aps": ["alert": "Hi"], "loopdy": ["version": 2]]) == nil)
        #expect(BighelpPushDisplay(userInfo: Self.wake(.direct)) == nil)
        // An old-style top-level message ID still counts, like BuzzKit's own parser.
        let legacy = BighelpPushDisplay(userInfo: ["messageId": "msg_1", "imageUrl": "https://example.com/a.png"])
        #expect(legacy?.imageURL?.absoluteString == "https://example.com/a.png")
        #expect(legacy?.actions.isEmpty == true)
    }

    @Test(arguments: Path.allCases)
    func theActionButtonsAreRegisteredAsOneCategory(path: Path) async throws {
        let display = try #require(BighelpPushDisplay(userInfo: Self.alert(path)))
        let store = Categories()
        let content = UNMutableNotificationContent()
        await display.apply(to: content, categories: store, download: Self.download(status: 404))
        #expect(content.categoryIdentifier == "BIGHELP_APPROVAL")
        let registered = await store.categories()
        let category = try #require(registered.first)
        #expect(store.writes == 1)
        #expect(category.identifier == "BIGHELP_APPROVAL")
        #expect(category.options == [.customDismissAction])
        #expect(category.intentIdentifiers.isEmpty)
        #expect(category.actions.map(\.identifier) == ["approve", "deny", "reply"])
        #expect(category.actions.map(\.title) == ["Approve", "Deny", "Reply"])
        #expect(category.actions[0].options == [.foreground])
        #expect(category.actions[1].options == [.destructive])
        let input = try #require(category.actions[2] as? UNTextInputNotificationAction)
        #expect(input.textInputButtonTitle == "Reply" && input.textInputPlaceholder == "Say more")
    }

    @Test func aCategoryThatIsAlreadyRegisteredIsKeptAndOthersAreNotLost() async throws {
        let display = try #require(BighelpPushDisplay(userInfo: Self.alert(.direct)))
        let known = UNNotificationCategory(identifier: "BIGHELP_AGENT_UPDATE", actions: [], intentIdentifiers: [], options: [])
        let store = Categories([known])
        await display.apply(to: UNMutableNotificationContent(), categories: store, download: Self.download(status: 404))
        let registered = await store.categories()
        #expect(Set(registered.map(\.identifier)) == ["BIGHELP_AGENT_UPDATE", "BIGHELP_APPROVAL"])
        let again = UNMutableNotificationContent()
        await display.apply(to: again, categories: store, download: Self.download(status: 404))
        #expect(store.writes == 1, "Registered once")
        #expect(again.categoryIdentifier == "BIGHELP_APPROVAL", "Still set on the later push")
    }

    @Test func aPushWithoutActionsLeavesTheCategoryAlone() async throws {
        let display = try #require(BighelpPushDisplay(userInfo: ["bk": ["category": "ONLY_A_NAME"], "aps": [:]]))
        let store = Categories()
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "BIGHELP_AGENT_UPDATE"
        await display.apply(to: content, categories: store, download: Self.download())
        #expect(content.categoryIdentifier == "BIGHELP_AGENT_UPDATE")
        #expect(store.writes == 0)
    }

    // MARK: The picture

    @Test(arguments: Path.allCases)
    func thePictureIsDownloadedAndAttached(path: Path) async throws {
        let display = try #require(BighelpPushDisplay(userInfo: Self.alert(path)))
        let requested = Requested()
        let content = UNMutableNotificationContent()
        await display.apply(to: content, categories: Categories(), download: Self.download(requested: requested))
        #expect(requested.all.map(\.absoluteString) == ["https://example.com/avatar.png"])
        let attachment = try #require(content.attachments.first)
        #expect(content.attachments.count == 1)
        #expect(attachment.identifier == "bk.image")
    }

    @Test func aPictureThatFailsLeavesTheNotificationAsItIs() async throws {
        let display = try #require(BighelpPushDisplay(userInfo: Self.alert(.direct)))
        for download in [
            Self.download(status: 404),
            Self.download(status: 302),
            Self.download(size: BighelpPushDisplay.maximumImageBytes + 1),
            { @Sendable (_: URL) async throws -> (URL, URLResponse) in throw URLError(.timedOut) },
        ] as [BighelpPushDisplay.Download] {
            let content = UNMutableNotificationContent()
            await display.apply(to: content, categories: Categories(), download: download)
            #expect(content.attachments.isEmpty)
            #expect(content.categoryIdentifier == "BIGHELP_APPROVAL", "The buttons still arrive")
        }
    }

    @Test func aPictureOnAnInsecureAddressIsNeverFetched() async throws {
        let display = try #require(BighelpPushDisplay(userInfo: Self.alert(.direct, image: "http://example.com/a.png")))
        let requested = Requested()
        let content = UNMutableNotificationContent()
        await display.apply(to: content, categories: Categories(), download: Self.download(requested: requested))
        #expect(requested.all.isEmpty && content.attachments.isEmpty)
    }

    @Test func aSealedAlertsOwnPictureStaysWhenThePushHasNone() async throws {
        let display = try #require(BighelpPushDisplay(userInfo: Self.alert(.direct, image: nil)))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Self.png.write(to: file)
        let content = UNMutableNotificationContent()
        content.attachments = [try UNNotificationAttachment(identifier: "bk.image", url: file)]
        await display.apply(to: content, categories: Categories(), download: Self.download(status: 404))
        #expect(content.attachments.count == 1)
    }

    // MARK: Taps, quiet chats and wakes read direct pushes the same

    @Test(arguments: Path.allCases)
    func buzzKitsOwnParserTakesBothAndTheTapStillRoutes(path: Path) throws {
        let payload = try #require(PushPayload(userInfo: Self.alert(path)))
        #expect(payload.messageId == (path == .buzzkit ? "msg_0123" : nil))
        #expect(payload.action?.name == "open_loopdy_managed_event")
        #expect(payload.deepLink?.absoluteString == "loopdy:///dashboard?eventId=\(Self.eventID)")
        #expect(payload.categoryId == "BIGHELP_APPROVAL")
        // bighelp's own meta key rides along as plain data and breaks nothing.
        #expect(payload.data["bighelp_meta"] != nil)
        #expect(BighelpBuzzKitPresentation.isManagedEventLink(try #require(payload.deepLink)))
        #expect(BighelpBuzzKitPresentation.eventID(payload.data) == Self.eventID)
        #expect(BighelpBuzzKitPresentation.eventType(payload.data) == "approval.required")
        #expect(BighelpBuzzKitPresentation.agent(payload.data) == "nova")
        #expect(BighelpBuzzKitPresentation.thread(payload.data) == String(repeating: "A", count: 43))
    }

    @Test(arguments: Path.allCases)
    func theTapOpensTheAlertsChat(path: Path) throws {
        let open = try #require(BighelpProactiveNotificationOpen(userInfo: Self.alert(path)))
        #expect(open.eventID == Self.eventID)
        #expect(open.eventType == "approval.required")
        #expect(open.hostGrantID == Self.grantID)
        #expect(open.agentID == "nova")
        #expect(open.sessionReference == String(repeating: "A", count: 43))
    }

    @Test(arguments: Path.allCases)
    func groupingReadsTheSameFields(path: Path) {
        let info = Self.alert(path)
        #expect(BighelpNotificationGrouping.eventType(of: info) == "approval.required")
        #expect(BighelpNotificationGrouping.agent(of: info) == "nova")
        #expect(BighelpNotificationGrouping.chat(of: info) == String(repeating: "A", count: 43))
    }

    @Test(arguments: Path.allCases)
    func theSignInWakeIsRecognizedWithItsMetaKey(path: Path) throws {
        let info = Self.wake(path)
        #expect(BighelpSignInWake.isRenewal(info))
        #expect(!BighelpBuzzKitWakePayload.isWake(info), "It is not the retired account wake")
        #expect(BighelpPushDisplay(userInfo: info) == nil || path == .buzzkit)
        switch path {
        case .direct:
            // No `bk` and no message ID: BuzzKit's parser sees nothing of its own.
            #expect(PushPayload(userInfo: info) == nil)
        case .buzzkit:
            // Through BuzzKit it carries a message ID and nothing else of BuzzKit's.
            let payload = try #require(PushPayload(userInfo: info))
            #expect(payload.messageId == "msg_0456")
            #expect(payload.deepLink == nil && payload.action == nil && payload.actions.isEmpty)
            #expect(payload.data["bighelp_wake"] != nil && payload.data["bighelp_meta"] != nil)
        }
    }

    // MARK: The picture's size

    /// Answers every request with the stub's head and body, so the downloader's early checks can be seen.
    final class StubPicture: URLProtocol {
        nonisolated(unsafe) static var headers: [String: String] = [:]
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var bodyWasRead = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: Self.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.bodyWasRead = true
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubPicture.self]
        return URLSession(configuration: configuration)
    }

    @Test func aPictureThatSaysItIsTooBigIsRefusedBeforeItsBody() async throws {
        StubPicture.status = 200
        StubPicture.headers = ["Content-Length": String(BighelpPushDisplay.maximumImageBytes + 1)]
        StubPicture.body = Data(count: 16)
        let download = BighelpPushDisplay.download(using: Self.stubbedSession())
        await #expect(throws: URLError.self) { _ = try await download(URL(string: "https://example.com/big.png")!) }
        // And attaching it leaves the notification alone.
        let display = try #require(BighelpPushDisplay(userInfo: Self.alert(.direct)))
        let content = UNMutableNotificationContent()
        await display.attachImage(to: content, download: download)
        #expect(content.attachments.isEmpty)
    }

    @Test func aPictureThatTurnsOutBiggerThanItSaidStopsAtTheCap() async {
        StubPicture.status = 200
        StubPicture.headers = [:]
        StubPicture.body = Data(count: 5_000)
        let download = BighelpPushDisplay.download(using: Self.stubbedSession(), maximumBytes: 1_000)
        await #expect(throws: URLError.self) { _ = try await download(URL(string: "https://example.com/long.png")!) }
    }

    @Test func aPictureWithinTheCapIsSavedWhole() async throws {
        StubPicture.status = 200
        StubPicture.headers = ["Content-Length": String(Self.png.count)]
        StubPicture.body = Self.png
        let download = BighelpPushDisplay.download(using: Self.stubbedSession())
        let (file, response) = try await download(URL(string: "https://example.com/ok.png")!)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try Data(contentsOf: file) == Self.png)
    }

    @Test func aFailedAnswerIsNotDownloaded() async {
        StubPicture.status = 404
        StubPicture.headers = [:]
        StubPicture.body = Self.png
        let download = BighelpPushDisplay.download(using: Self.stubbedSession())
        await #expect(throws: URLError.self) { _ = try await download(URL(string: "https://example.com/gone.png")!) }
    }

    @Test func aSeamAnswerThatClaimsTooMuchIsRefusedEvenIfItWroteAFile() async throws {
        let display = try #require(BighelpPushDisplay(userInfo: Self.alert(.direct)))
        let download: BighelpPushDisplay.Download = { url in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Self.png.write(to: file)
            let head = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Length": String(BighelpPushDisplay.maximumImageBytes + 1)])!
            return (file, head)
        }
        let content = UNMutableNotificationContent()
        await display.attachImage(to: content, download: download)
        #expect(content.attachments.isEmpty)
    }

    // MARK: Finishing in time

    @Test func theNotificationShowsOnceWhicheverEndsFirst() {
        let delivery = BighelpNotificationDelivery()
        let shown = Shown()
        let first = UNMutableNotificationContent(); first.title = "ready"
        delivery.hold({ shown.record($0) }, first)
        // The time limit comes first: what is ready shows, once.
        delivery.finish()
        delivery.finish()
        #expect(shown.all == ["ready"])
        // The work finishing late finds nothing left to show.
        #expect(delivery.take() == nil)
    }

    @Test func aLaterHoldReplacesAnEarlierOneAndTheSystemGetsTheNewest() {
        let delivery = BighelpNotificationDelivery()
        let shown = Shown()
        let handler: BighelpNotificationDelivery.Handler = { shown.record($0) }
        let opened = UNMutableNotificationContent(); opened.title = "opened"
        let withPicture = UNMutableNotificationContent(); withPicture.title = "with picture"
        delivery.hold(handler, opened)
        delivery.hold(handler, withPicture)
        delivery.finish()
        #expect(shown.all == ["with picture"])
    }

    @Test func unknownTopLevelKeysAreIgnoredEverywhere() throws {
        var info = Self.alert(.direct)
        info["bighelp_future"] = ["anything": [1, 2, 3]]
        info["another_new_key"] = "value"
        #expect(BighelpPushDisplay(userInfo: info) == BighelpPushDisplay(userInfo: Self.alert(.direct)))
        #expect(BighelpProactiveNotificationOpen(userInfo: info)?.eventID == Self.eventID)
        #expect(PushPayload(userInfo: info) != nil)
        #expect(BighelpNotificationGrouping.eventType(of: info) == "approval.required")
    }
}
