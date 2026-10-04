import BuzzKit
import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import Bighelp

/// Instant alerts: while bighelp is open the computer sends each alert straight to
/// it, and the push goes out only when the device doesn't answer in time.
@MainActor
struct BighelpLiveAlertTests {
    private struct Vector: Decodable {
        let recipientPrivateKey: String
        let senderPublicKey: String
        let plaintext: BighelpSealedAlert.Content
        let avatarImage: String
        let avatarBlob: String
    }

    private let vector: Vector
    private let envelope: [String: BighelpJSONValue]
    private let grantID: String
    private let eventID: String
    private let chat = String(repeating: "c", count: 43)

    init() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/sealed-alert-v2-vector.json"))
        vector = try JSONDecoder().decode(Vector.self, from: data)
        let document = try JSONDecoder().decode(BighelpJSONValue.self, from: data)
        envelope = try #require(document.object?["envelope"]?.object)
        grantID = try #require(envelope["grantId"]?.string)
        eventID = try #require(envelope["eventId"]?.string)
    }

    // MARK: The alert the computer sends

    private func wire(eventType: String = "session.completed", chat: String? = nil,
                      avatar: String? = nil) -> BighelpJSONValue {
        var avatarObject: [String: BighelpJSONValue] = ["sha256": .string(String(repeating: "a", count: 64))]
        if let avatar { avatarObject["data"] = .string(avatar) }
        return .object([
            "grantId": .string(grantID), "agentId": .string("juno"), "eventId": .string(eventID),
            "eventType": .string(eventType), "sessionReference": .string(chat ?? self.chat),
            "turnId": .string("turn-a"), "occurredAt": .integer(1_790_000_000),
            "sealed": .object(envelope), "avatar": .object(avatarObject),
        ])
    }

    @Test func readsTheSealedAlertAsItsPushWouldCarryIt() throws {
        let alert = try #require(BighelpLiveAlert(wire()))
        #expect(alert.eventID == eventID && alert.grantID == grantID && alert.agentID == "juno")
        #expect(alert.inlineAvatar == nil)
        // The same data as the push: the extension's parser, tap routing and the
        // chat-on-screen check all read it.
        let sealed = try #require(BighelpSealedNotification(userInfo: alert.userInfo))
        #expect(sealed.envelope.eventID == eventID)
        let open = try #require(BighelpProactiveNotificationOpen(userInfo: alert.userInfo))
        #expect(open.eventID == eventID && open.hostGrantID == grantID && open.sessionReference == chat)
        #expect(BighelpNotificationGrouping.chat(of: alert.userInfo) == chat)
        #expect(BighelpNotificationGrouping.agent(of: alert.userInfo) == "juno")

        let blob = "data:application/octet-stream;base64," + Data("picture".utf8).base64EncodedString()
        #expect(BighelpLiveAlert(wire(avatar: blob))?.inlineAvatar == Data("picture".utf8))
    }

    @Test func refusesAlertsThatDontAddUp() throws {
        guard case .object(var value) = wire() else { Issue.record(); return }
        for (field, bad) in [("eventType", "session.unknown"), ("agentId", "../root"),
                             ("sessionReference", "short"), ("grantId", UUID().uuidString.lowercased())] {
            var changed = value
            changed[field] = .string(bad)
            #expect(BighelpLiveAlert(.object(changed)) == nil, "\(field)")
        }
        value["avatar"] = .object(["sha256": .string("x"), "data": .string("data:image/png;base64,AAAA")])
        #expect(BighelpLiveAlert(.object(value)) == nil)
        #expect(BighelpLiveAlert(.string("alert")) == nil)
    }

    // MARK: Showing it

    private final class Posted: @unchecked Sendable {
        var requests: [UNNotificationRequest] = []
        var cleared: [String] = []
    }

    private func presenter(_ posted: Posted, recent: BighelpRecentAlerts, showing: String? = nil,
                           active: Bool = true, kindsOn: Bool = true, opens: Bool = true,
                           promptRaised: Bool = false) -> BighelpLiveAlertPresenter {
        let content = vector.plaintext
        var presenter = BighelpLiveAlertPresenter()
        presenter.recent = recent
        presenter.open = { _ in
            guard opens else { throw BighelpSealedAlert.Failure.untrustedSender }
            return content
        }
        presenter.isShowing = { chat, _ in chat != nil && chat == showing }
        presenter.appIsActive = { active }
        presenter.kindIsOn = { _ in kindsOn }
        presenter.promptAlreadyRaised = { _ in promptRaised }
        presenter.avatarFile = { _, _ in nil }
        presenter.clearOlder = { _, _, eventID in posted.cleared.append(eventID) }
        presenter.post = { posted.requests.append($0) }
        return presenter
    }

    private func recentStore() -> BighelpRecentAlerts {
        BighelpRecentAlerts(defaults: UserDefaults(suiteName: "bighelp.tests.recent." + UUID().uuidString))
    }

    @Test func anAlertForAnotherChatShowsLikeItsPush() async throws {
        let posted = Posted(), recent = recentStore()
        let alert = try #require(BighelpLiveAlert(wire()))
        let outcome = await presenter(posted, recent: recent, showing: String(repeating: "d", count: 43)).present(alert)
        #expect(outcome == .shown)
        let request = try #require(posted.requests.first)
        #expect(posted.requests.count == 1)
        // The event ID names it, so a late push of the same alert takes its place.
        #expect(request.identifier == eventID)
        #expect(request.content.title == "Juno")
        #expect(request.content.body == vector.plaintext.body)
        #expect(request.content.threadIdentifier == BighelpNotificationGrouping.thread(agentName: "Juno"))
        #expect(request.content.interruptionLevel == .active)
        #expect(request.content.sound != nil)
        #expect(BighelpProactiveNotificationOpen(userInfo: request.content.userInfo)?.eventID == eventID)
        // The chat's earlier replies make way, as for a push.
        #expect(posted.cleared == [eventID])
        #expect(recent.contains(eventID))
    }

    @Test func anAlertForTheChatOnScreenShowsNothingButIsAnswered() async throws {
        let posted = Posted(), recent = recentStore()
        let alert = try #require(BighelpLiveAlert(wire()))
        #expect(await presenter(posted, recent: recent, showing: chat).present(alert) == .kept)
        #expect(posted.requests.isEmpty)
        // Its push, if the answer is lost, stays quiet too.
        #expect(recent.contains(eventID))
    }

    @Test func theChatOnScreenCountsOnlyWhileBighelpIsInFront() async throws {
        let posted = Posted()
        let alert = try #require(BighelpLiveAlert(wire()))
        #expect(await presenter(posted, recent: recentStore(), showing: chat, active: false).present(alert) == .shown)
        #expect(posted.requests.count == 1)
    }

    @Test func anAlertShownAlreadyIsNotShownTwice() async throws {
        let posted = Posted(), recent = recentStore()
        let alert = try #require(BighelpLiveAlert(wire()))
        let presenter = presenter(posted, recent: recent)
        #expect(await presenter.present(alert) == .shown)
        #expect(await presenter.present(alert) == .kept)
        #expect(posted.requests.count == 1)
    }

    @Test func anAlertThatDoesntOpenIsLeftToThePush() async throws {
        let posted = Posted(), recent = recentStore()
        let alert = try #require(BighelpLiveAlert(wire()))
        #expect(await presenter(posted, recent: recent, opens: false).present(alert) == .failed)
        #expect(posted.requests.isEmpty)
        #expect(!recent.contains(eventID))
    }

    @Test func kindsTurnedOffInSettingsStayOff() async throws {
        let posted = Posted()
        let alert = try #require(BighelpLiveAlert(wire()))
        #expect(await presenter(posted, recent: recentStore(), kindsOn: false).present(alert) == .kept)
        #expect(posted.requests.isEmpty)
        #expect(BighelpLiveAlertKinds.topic(for: "subagent.failed") == .subagentCompletions)
        #expect(BighelpLiveAlertKinds.topic(for: "approval.required") == .questionsAndApprovals)
        #expect(BighelpLiveAlertKinds.topic(for: "scheduled.completed") == .scheduledTasksAndDeliveries)
        #expect(BighelpLiveAlertKinds.topic(for: "session.failed") == .chatRepliesAndCompletions)
    }

    @Test func helperResultsArriveQuietly() async throws {
        let posted = Posted()
        // The plaintext names its kind; the helper vector reuses the reply's sealed text.
        var presenter = presenter(posted, recent: recentStore())
        let reply = vector.plaintext
        presenter.open = { _ in
            BighelpSealedAlert.Content(v: 2, eventId: reply.eventId, eventType: "subagent.completed",
                                       title: reply.title, body: reply.body, avatar: nil)
        }
        let alert = try #require(BighelpLiveAlert(wire(eventType: "subagent.completed")))
        #expect(await presenter.present(alert) == .shown)
        #expect(posted.requests.first?.content.interruptionLevel == .passive)
    }

    @Test func aQuestionBighelpRaisedItselfGoesToNotificationCenterOnly() async throws {
        let posted = Posted()
        var presenter = presenter(posted, recent: recentStore(), promptRaised: true)
        let reply = vector.plaintext
        presenter.open = { _ in
            BighelpSealedAlert.Content(v: 2, eventId: reply.eventId, eventType: "clarification.required",
                                       title: reply.title, body: reply.body, avatar: nil)
        }
        let alert = try #require(BighelpLiveAlert(wire(eventType: "clarification.required")))
        #expect(await presenter.present(alert) == .shown)
        #expect(posted.requests.first?.content.interruptionLevel == .passive)
        #expect(posted.requests.first?.content.sound == nil)
    }

    @Test func theSharedPresentationMatchesThePushPath() {
        let content = UNMutableNotificationContent()
        content.userInfo = ["loopdy": ["eventId": eventID]]
        BighelpSealedAlertPresentation.apply(vector.plaintext, eventType: "session.completed", to: content,
                                             arrivedThread: chat)
        #expect(content.title == "Juno")
        // Older services carry the chat only as the thread; it's kept where the app reads it.
        #expect(BighelpNotificationGrouping.chat(of: content.userInfo) == chat)
        #expect(content.threadIdentifier == BighelpNotificationGrouping.thread(agentName: "Juno"))
        BighelpSealedAlertPresentation.quietRepeat(content)
        #expect(content.interruptionLevel == .passive && content.sound == nil)
    }

    @Test func theInlinePictureOpensAndIsKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bighelp-avatars-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BighelpNotificationAvatarCache(directory: directory)
        let alert = try #require(BighelpLiveAlert(wire(avatar: "data:application/octet-stream;base64,"
            + (BighelpNotificationBase64URL.decodeCanonical(vector.avatarBlob) ?? Data()).base64EncodedString())))
        var sealed = try #require(BighelpSealedNotification(userInfo: alert.userInfo))
        sealed.inlineAvatar = alert.inlineAvatar
        let file = try #require(await sealed.avatarFile(for: vector.plaintext, cache: cache))
        #expect(try Data(contentsOf: file) == BighelpNotificationBase64URL.decodeCanonical(vector.avatarImage))
        #expect(cache.hashes() == [try #require(vector.plaintext.avatar?.sha256)])
    }

    // MARK: Remembering what showed

    @Test func recentAlertsExpireAndStayBounded() {
        let recent = recentStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        recent.insert("first", now: start)
        #expect(recent.contains("first", now: start.addingTimeInterval(60)))
        #expect(!recent.contains("first", now: start.addingTimeInterval(BighelpRecentAlerts.lifetime + 1)))
        for index in 0..<(BighelpRecentAlerts.limit + 5) {
            recent.insert("event-\(index)", now: start.addingTimeInterval(Double(index)))
        }
        #expect(!recent.contains("event-0", now: start.addingTimeInterval(200)))
        #expect(recent.contains("event-\(BighelpRecentAlerts.limit + 4)", now: start.addingTimeInterval(200)))
    }

    @Test func aRepeatedPushGoesToNotificationCenterOnly() {
        let data: [String: JSONValue] = ["loopdy": .object(["eventId": .string(eventID)])]
        #expect(BighelpBuzzKitPresentation.eventID(data) == eventID)
        #expect(BighelpBuzzKitPresentation.eventID([:]) == nil)
    }

    // MARK: Listening

    @Test func listensForThisDevicesGrantsAndAnswersWhatItHandled() async throws {
        let host = try LiveAlertHost()
        let other = try #require(BighelpLiveAlert(wire()))
        host.listens = [.success(["alerts": .array([wire(), .string("junk")])])]
        let presented = LiveAlertBox<[String]>([])
        let listener = BighelpLiveAlertListener(
            workspace: { host }, grants: { [.init(grantID: grantID, recipientKeyID: String(repeating: "k", count: 43))] },
            present: { presented.value.append($0.eventID); return .kept }, knownAvatars: { ["ab"] })
        #expect(await listener.listenOnce() == .again)
        #expect(presented.value == [other.eventID])
        #expect(host.calls == [.liveAlertsListen, .liveAlertsAck])
        let listen = try #require(host.payloads.first)
        #expect(listen["listenerId"]?.string == listener.listenerID)
        #expect(listen["waitSeconds"]?.integer == 25)
        #expect(listen["knownAvatars"] == .array([.string("ab")]))
        #expect(listen["grants"]?.array?.first?.object?["grantId"]?.string == grantID)
        #expect(host.payloads.last?["eventIds"] == .array([.string(eventID)]))
    }

    @Test func anAlertThatFailedIsNotAnswered() async throws {
        let host = try LiveAlertHost()
        host.listens = [.success(["alerts": .array([wire()])])]
        let listener = BighelpLiveAlertListener(
            workspace: { host }, grants: { [.init(grantID: grantID, recipientKeyID: "k")] },
            present: { _ in .failed }, knownAvatars: { [] })
        #expect(await listener.listenOnce() == .again)
        #expect(host.calls == [.liveAlertsListen])
    }

    @Test func alertsForAnotherDevicesGrantAreIgnored() async throws {
        let host = try LiveAlertHost()
        host.listens = [.success(["alerts": .array([wire()])])]
        let presented = LiveAlertBox(0)
        let listener = BighelpLiveAlertListener(
            workspace: { host }, grants: { [.init(grantID: UUID().uuidString.lowercased(), recipientKeyID: "k")] },
            present: { _ in presented.value += 1; return .shown }, knownAvatars: { [] })
        _ = await listener.listenOnce()
        #expect(presented.value == 0)
        #expect(host.calls == [.liveAlertsListen])
    }

    @Test func noConnectionOrNoGrantsMeansNoRequest() async throws {
        let host = try LiveAlertHost()
        let none = BighelpLiveAlertListener(workspace: { nil }, grants: { [] }, present: { _ in .shown })
        #expect(await none.listenOnce() == .wait(.seconds(10)))
        let empty = BighelpLiveAlertListener(workspace: { host }, grants: { [] }, present: { _ in .shown })
        #expect(await empty.listenOnce() == .wait(.seconds(30)))
        #expect(host.calls.isEmpty)
    }

    @Test func olderPluginsAndRefusalsBackOff() async throws {
        let host = try LiveAlertHost()
        let listener = BighelpLiveAlertListener(
            workspace: { host }, grants: { [.init(grantID: grantID, recipientKeyID: "k")] },
            present: { _ in .shown }, knownAvatars: { [] })
        host.listens = [.failure(WorkspaceClientError.unavailable(.unsupportedOperation))]
        #expect(await listener.listenOnce() == .wait(.seconds(300)))
        host.listens = [.failure(WorkspaceClientError.rejected(code: "live_alerts_busy"))]
        #expect(await listener.listenOnce() == .wait(.seconds(60)))
        // A changed plugin context is reloaded at once, one time.
        host.listens = [.failure(WorkspaceClientError.conflict), .failure(WorkspaceClientError.conflict)]
        #expect(await listener.listenOnce() == .again)
        guard case .wait(let wait) = await listener.listenOnce() else { Issue.record(); return }
        #expect(wait >= .seconds(1) && wait <= .seconds(2))
    }

    @Test func aConnectionThatCutsLongRequestsGetsShortOnes() async throws {
        let host = try LiveAlertHost()
        let clock = LiveAlertBox(ContinuousClock.now)
        host.onListen = { clock.value = clock.value.advanced(by: .seconds(15)) }
        host.listens = [.failure(WorkspaceClientError.transportUnavailable)]
        let listener = BighelpLiveAlertListener(
            workspace: { host }, grants: { [.init(grantID: grantID, recipientKeyID: "k")] },
            present: { _ in .shown }, knownAvatars: { [] }, now: { clock.value })
        _ = await listener.listenOnce()
        #expect(listener.waitSeconds == BighelpLiveAlertListener.shortWait)
        host.listens = [.success(["alerts": .array([])])]
        _ = await listener.listenOnce()
        #expect(host.payloads.last?["waitSeconds"]?.integer == BighelpLiveAlertListener.shortWait)
    }

    @Test func leavingTheFrontTellsTheComputer() async throws {
        let host = try LiveAlertHost()
        host.listens = [.success(["alerts": .array([])])]
        let listener = BighelpLiveAlertListener(
            workspace: { host }, grants: { [.init(grantID: grantID, recipientKeyID: "k")] },
            present: { _ in .shown }, knownAvatars: { [] },
            pause: { _ in throw CancellationError() })
        host.listens.append(.failure(WorkspaceClientError.transportUnavailable))
        await listener.run()
        for _ in 0..<20 where !host.calls.contains(.liveAlertsStop) { await Task.yield() }
        #expect(host.calls.last == .liveAlertsStop)
        #expect(host.payloads.last?["listenerId"]?.string == listener.listenerID)
    }

    @Test func theRoutesNeedTheirPluginFeature() {
        for operation in [WorkspaceOperation.liveAlertsListen, .liveAlertsAck, .liveAlertsStop] {
            #expect(DirectHermesNativePluginClient.supports(operation))
        }
    }
}

@MainActor
private final class LiveAlertHost: WorkspaceOperationPerforming {
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
    var listens: [Result<[String: BighelpJSONValue], any Error>] = []
    var onListen: () -> Void = {}
    private(set) var calls: [WorkspaceOperation] = []
    private(set) var payloads: [[String: BighelpJSONValue]] = []

    init() throws {
        owner = WorkspaceOwner(authority: try .fixture(id: UUID().uuidString), authenticationGeneration: UUID(),
                               connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        calls.append(operation)
        payloads.append(payload)
        guard operation == .liveAlertsListen else { return [:] }
        onListen()
        guard !listens.isEmpty else { throw WorkspaceClientError.transportUnavailable }
        return try listens.removeFirst().get()
    }
}

private final class LiveAlertBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
