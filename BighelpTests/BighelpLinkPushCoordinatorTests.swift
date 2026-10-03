import Foundation
import Testing
import XCTest
@testable import Bighelp

@MainActor
struct BighelpLinkPushCoordinatorTests {
    @Test func earlyAPNSFailureReplaysOnceOnInstall() {
        let center = BighelpAPNSTokenHookCenter()
        var failures = 0
        center.receiveFailure(URLError(.notConnectedToInternet))
        center.installFailure { _ in failures += 1 }
        #expect(failures == 1)
        center.installFailure { _ in failures += 1 }
        #expect(failures == 1)
    }

    @Test func wakeWithoutHandlerReportsFailureButInstalledHandlerDoesNot() async {
        let center = BighelpLinkWakeCenter()
        let payload: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "loopdy_link": ["version": 2, "type": "wake", "frameId": "fixture_frame_0001"]
        ]
        #expect(await center.receive(payload) == .failed)
        center.install { false }
        #expect(await center.receive(payload) == .noData)
    }

    @Test func earlyAPNSTokenReplaysLatestExactBytesOnlyOnce() {
        let center = BighelpAPNSTokenHookCenter()
        var received: [Data] = []
        center.receive(Data([0, 1, 128, 255]))
        let latest = Data([255, 0, 129, 42, 10])
        center.receive(latest)
        center.install { received.append($0) }
        #expect(received == [latest])
        center.install { received.append($0) }
        #expect(received == [latest])
    }

    @Test func installedAPNSHookReceivesEachExactTokenSynchronously() {
        let center = BighelpAPNSTokenHookCenter()
        var received: [Data] = []
        center.install { received.append($0) }
        let token = Data([0, 255, 128, 1, 10])
        center.receive(token)
        #expect(received == [token])
        let rotated = Data([255, 0, 1])
        center.receive(rotated)
        #expect(received == [token, rotated])
    }

    @Test func acceptsOnlyTheContentFreeBighelpLinkBackgroundWakeMarker() {
        let backgroundPayloadIsWake = BighelpBuzzKitWakePayload.isWake([
            "aps": ["content-available": 1],
            "loopdy_link": ["version": 2, "type": "wake", "frameId": "fixture_frame_0001"]
        ])
        let alertPayloadIsWake = BighelpBuzzKitWakePayload.isWake([
            "aps": ["alert": ["body": "private text"]],
            "loopdy_link": ["version": 2, "type": "wake", "frameId": "fixture_frame_0001"]
        ])
        let wrongMarkerIsWake = BighelpBuzzKitWakePayload.isWake([
            "aps": ["content-available": 1],
            "loopdy_link": ["version": 1, "type": "message"]
        ])
        #expect(backgroundPayloadIsWake)
        #expect(alertPayloadIsWake == false)
        #expect(wrongMarkerIsWake == false)
    }

    @Test func notificationParsersPreserveFoundationBridgingPolicy() {
        let grant = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let cases: [(Any?, Bool)] = [
            (2, true), (NSNumber(value: 2.0), true), (NSNumber(value: 2.5), false),
            (NSNumber(value: true), false), ("2", false), (NSNull(), false), (nil, false),
            (NSNumber(value: Double.infinity), false), (NSNumber(value: Double.nan), false)
        ]
        for (version, accepted) in cases {
            var open: [String: Any] = ["eventId": grant + ":" + String(repeating: "a", count: 64),
                                       "eventType": "channel.message", "grantId": grant]
            var wake: [String: Any] = ["type": "wake", "frameId": "fixture_frame_0001"]
            open["version"] = version
            wake["version"] = version
            for foundationDictionary in [false, true] {
                let openPayload: Any = foundationDictionary ? open as NSDictionary : open
                let wakePayload: Any = foundationDictionary ? wake as NSDictionary : wake
                #expect((BighelpProactiveNotificationOpen(userInfo: ["loopdy": openPayload]) != nil) == accepted)
                #expect(BighelpBuzzKitWakePayload.isWake([
                    "aps": ["content-available": NSNumber(value: true)] as NSDictionary,
                    "loopdy_link": wakePayload
                ]) == accepted)
            }
        }
        let mixedKeys: NSDictionary = [1: "not a string key", "version": 2,
                                      "eventId": grant + ":" + String(repeating: "a", count: 64),
                                      "eventType": "channel.message", "grantId": grant,
                                      "type": "wake", "frameId": "fixture_frame_0001"]
        let openAcceptsMixedKeys = BighelpProactiveNotificationOpen(userInfo: ["loopdy": mixedKeys]) != nil
        let wakeAcceptsMixedKeys = BighelpBuzzKitWakePayload.isWake([
            "aps": ["content-available": 1], "loopdy_link": mixedKeys
        ])
        #expect(!openAcceptsMixedKeys)
        #expect(!wakeAcceptsMixedKeys)
    }

    @Test func wakeCenterStartsAndDrainsLinkBeforeCompletingBackgroundFetch() async {
        let center = BighelpLinkWakeCenter()
        var wakeCount = 0
        center.install {
            wakeCount += 1
            return true
        }

        let result = await center.receive([
            "aps": ["content-available": 1],
            "loopdy_link": ["version": 2, "type": "wake", "frameId": "fixture_frame_0001"]
        ])

        #expect(result == .newData)
        #expect(wakeCount == 1)
        #expect(await center.receive(["aps": ["content-available": 1]]) == .noData)
        #expect(wakeCount == 1)
    }

    @Test func decryptedNotificationProjectsToAnIdempotentNativeRequestAndTapRoute() throws {
        let event = try JSONDecoder().decode(
            BighelpLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "channel.message:fixture_0001",
                  "eventType": "channel.message",
                  "agentId": "default",
                  "agentName": "Juno",
                  "sessionId": "session_fixture_0001",
                  "title": "Juno just messaged you!",
                  "body": "The forecast is ready.",
                  "sentAt": 1788000001
                }
                """.utf8
            )
        )

        let request = try #require(BighelpProactiveNotificationRequest(event: event))

        #expect(request.identifier == event.eventID)
        #expect(request.title == event.title)
        #expect(request.body == event.body)
        #expect(request.threadIdentifier == event.sessionID)
        #expect(request.categoryIdentifier == "BIGHELP_AGENT_UPDATE")
        #expect(request.userInfo["loopdy_event_id"] == event.eventID)
        #expect(request.userInfo["loopdy_session_id"] == event.sessionID)
        #expect(request.userInfo["loopdy_agent_id"] == event.agentID)
        #expect(BighelpProactiveNotificationOpen(userInfo: request.userInfo)?.eventID == event.eventID)
        #expect(BighelpProactiveNotificationOpen(userInfo: request.userInfo)?.eventType == event.eventType)
        #expect(BighelpProactiveNotificationOpen(userInfo: [:]) == nil)
    }

    @Test func lifecycleNoiseCannotBecomeLocalBannersButInboxClarifyAndApprovalCan() throws {
        let lifecycle = try JSONDecoder().decode(
            BighelpLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "job.completed:fixture_0001",
                  "eventType": "job.completed",
                  "agentId": "default",
                  "agentName": "Juno",
                  "title": "Scheduled task completed",
                  "body": "From Juno",
                  "sentAt": 1788000001
                }
                """.utf8
            )
        )
        let message = try JSONDecoder().decode(
            BighelpLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "channel.message:fixture_0002",
                  "eventType": "channel.message",
                  "agentId": "default",
                  "agentName": "Juno",
                  "title": "Morning weather",
                  "body": "Rain starts at 3 PM",
                  "sentAt": 1788000002
                }
                """.utf8
            )
        )
        let clarification = try JSONDecoder().decode(
            BighelpLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "attention.required:clarify_0001",
                  "eventType": "attention.required",
                  "agentId": "default",
                  "agentName": "Juno",
                  "sessionId": "session_fixture_0001",
                  "title": "Clarification needed",
                  "body": "Which environment should I deploy to?",
                  "sentAt": 1788000003
                }
                """.utf8
            )
        )
        let approval = try JSONDecoder().decode(
            BighelpLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "approval.required:approval_0001",
                  "eventType": "approval.required",
                  "agentId": "default",
                  "agentName": "Juno",
                  "sessionId": "session_fixture_0001",
                  "title": "Approval requested",
                  "body": "Restart the Hermes gateway",
                  "sentAt": 1788000004
                }
                """.utf8
            )
        )

        let lifecycleRequest: BighelpProactiveNotificationRequest? =
            BighelpProactiveNotificationRequest(event: lifecycle)
        let messageRequest: BighelpProactiveNotificationRequest? =
            BighelpProactiveNotificationRequest(event: message)
        let clarificationRequest = BighelpProactiveNotificationRequest(event: clarification)
        let approvalRequest = BighelpProactiveNotificationRequest(event: approval)

        #expect(lifecycleRequest == nil)
        #expect(messageRequest?.identifier == "channel.message:fixture_0002")
        #expect(clarificationRequest?.identifier == "attention.required:clarify_0001")
        #expect(approvalRequest?.identifier == "approval.required:approval_0001")
    }

    @Test func operationalGatewayChannelMessagesCannotBecomeLocalBanners() throws {
        let event = try JSONDecoder().decode(
            BighelpLinkNotificationEvent.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "notification.event",
                  "eventId": "channel.message:gateway-restart",
                  "eventType": "channel.message",
                  "agentId": "default",
                  "agentName": "Juno",
                  "title": "Gateway status",
                  "body": "♻️ Gateway restarted — current work will resume.",
                  "sentAt": 1788000002
                }
                """.utf8
            )
        )

        #expect(BighelpProactiveNotificationRequest(event: event) == nil)
    }

    @Test func notificationTapCenterOpensOnlyValidatedBighelpInboxEvents() async {
        let center = BighelpProactiveNotificationOpenCenter()
        var opened: [BighelpProactiveNotificationOpen] = []
        center.install { opened.append($0) }
        await center.activate()

        await center.receive([
            "loopdy_notification_version": "1",
            "loopdy_event_id": "channel.message:fixture_0001",
            "loopdy_agent_id": "default",
            "loopdy_session_id": "session_fixture_0001",
        ])
        await center.receive(["loopdy_event_id": "untrusted"])

        #expect(opened.map(\.eventID) == ["channel.message:fixture_0001"])
        #expect(opened.map(\.sessionID) == ["session_fixture_0001"])
    }

    @Test func retiredSchemaV1RelayDeepLinkIsRejected() {
        let open = BighelpProactiveNotificationOpen(userInfo: [
            "aps": ["alert": ["title": "Generic", "body": "Open bighelp"]],
            "loopdy": [
                "schema_version": 1,
                "event_id": "channel.message:fixture_0002",
                "type": "channel.message",
                "deep_link": "loopdy:///dashboard?eventId=channel.message%3Afixture_0002",
            ],
        ])

        #expect(open == nil)
    }

    @Test func managedColdLaunchUsesOnlyManagedHandlerAndPreservesExactCoordinates() async throws {
        let center = BighelpProactiveNotificationOpenCenter()
        let grant = "11111111-1111-4111-8111-111111111111"
        let event = grant + ":" + String(repeating: "a", count: 64)
        var local: [BighelpProactiveNotificationOpen] = []
        var managed: [BighelpProactiveNotificationOpen] = []
        center.install { local.append($0) }
        center.installManaged { managed.append($0) }
        let payload: [AnyHashable: Any] = ["loopdy": [
            "version": 2, "eventId": event, "eventType": "session.completed", "grantId": grant
        ]]
        await center.receive(payload)
        #expect(managed.isEmpty)
        await center.activate()
        await center.activate()
        #expect(local.isEmpty)
        #expect(managed.map(\.eventID) == [event])
        #expect(managed.map(\.hostGrantID) == [grant])
        #expect(managed.map(\.eventType) == ["session.completed"])
        #expect(managed.map(\.sessionID) == [nil])
    }

    @Test func malformedManagedPayloadsCannotFallBackToLocalRouting() async {
        let center = BighelpProactiveNotificationOpenCenter()
        var opened: [BighelpProactiveNotificationOpen] = []
        center.install { opened.append($0) }
        center.installManaged { opened.append($0) }
        await center.activate()
        let grant = "11111111-1111-4111-8111-111111111111"
        let event = grant + ":" + String(repeating: "a", count: 64)
        let valid: [String: Any] = ["version": 2, "eventId": event,
                                  "eventType": "session.completed", "grantId": grant]
        for (field, invalid) in [("version", 1 as Any), ("grantId", "other" as Any),
                                 ("eventId", event + "a" as Any),
                                 ("eventId", grant + ":" + String(repeating: "A", count: 64) as Any),
                                 ("eventType", "unknown.event" as Any)] {
            var payload = valid
            payload[field] = invalid
            await center.receive(["loopdy": payload] as [AnyHashable: Any])
        }
        for field in ["version", "grantId", "eventId", "eventType"] {
            var payload = valid
            payload.removeValue(forKey: field)
            await center.receive(["loopdy": payload] as [AnyHashable: Any])
        }
        #expect(opened.isEmpty)
    }

    @Test func coldLaunchTapWaitsForRootActivationInsteadOfBeingDiscarded() async {
        let center = BighelpProactiveNotificationOpenCenter()
        var opened: [String] = []

        await center.receive([
            "loopdy_notification_version": "1",
            "loopdy_event_id": "channel.message:cold-launch",
            "loopdy_agent_id": "default",
        ])
        center.install { opened.append($0.eventID) }

        #expect(opened.isEmpty)
        await center.activate()
        #expect(opened == ["channel.message:cold-launch"])
    }
}

@MainActor
final class NotificationDelegateAPNSTapTests: XCTestCase {
    /// Clearing a notification wakes the app in the background just to report
    /// it. UIKit aborts unless the response's completion runs on the main
    /// thread (a TestFlight crash in 2.3.0 (29)). And a clear isn't an open.
    func testNotificationResponseCompletesOnTheMainThreadAndClearingOpensNothing() async throws {
        let grant = "22222222-2222-4222-8222-222222222222"
        let event = grant + ":" + String(repeating: "b", count: 64)
        var opened: [BighelpProactiveNotificationOpen] = []
        BighelpProactiveNotificationOpenCenter.shared.installManaged { opened.append($0) }
        await BighelpProactiveNotificationOpenCenter.shared.activate()
        let open = try XCTUnwrap(BighelpProactiveNotificationOpen(userInfo: [
            "loopdy": ["version": 2, "eventId": event, "eventType": "session.completed", "grantId": grant],
        ] as [AnyHashable: Any]))

        for dismissed in [true, false] {
            let completedOnMain = await withCheckedContinuation { continuation in
                Task.detached {
                    BighelpLinkApplicationDelegate.respond(to: open, dismissed: dismissed) {
                        continuation.resume(returning: Thread.isMainThread)
                    }
                }
            }
            XCTAssertTrue(completedOnMain, dismissed ? "clear" : "tap")
        }
        for _ in 0..<50 where opened.isEmpty { await Task.yield() }
        XCTAssertEqual(opened.map(\.eventID), [event], "The tap opened its chat; the clear didn't")
    }

    func testNotificationDelegateRoutesManagedV2AndRejectsRetiredRelay() async {
        let grant = "11111111-1111-4111-8111-111111111111"
        let event = grant + ":" + String(repeating: "a", count: 64)
        var opened: [BighelpProactiveNotificationOpen] = []
        var local: [BighelpProactiveNotificationOpen] = []
        BighelpProactiveNotificationOpenCenter.shared.install { local.append($0) }
        BighelpProactiveNotificationOpenCenter.shared.installManaged { opened.append($0) }
        await BighelpProactiveNotificationOpenCenter.shared.activate()

        let delegate = BighelpLinkApplicationDelegate()
        await delegate.receiveNotificationTap(userInfo: [
            "aps": ["alert": ["title": "Generic", "body": "Open bighelp"]],
            "loopdy": ["version": 2, "eventId": event,
                       "eventType": "session.completed", "grantId": grant],
        ])
        await delegate.receiveNotificationTap(userInfo: [
            "aps": ["alert": ["title": "Generic", "body": "Open bighelp"]],
            "loopdy": [
                "schema_version": 1,
                "event_id": "channel.message:delegate-tap",
                "type": "channel.message",
                "deep_link": "loopdy:///dashboard?eventId=channel.message%3Adelegate-tap",
            ],
        ])
        XCTAssertEqual(opened.map(\.eventID), [event])
        XCTAssertEqual(opened.map(\.hostGrantID), [grant])
        XCTAssertEqual(opened.map(\.eventType), ["session.completed"])
        XCTAssertEqual(opened.map(\.sessionID), [nil])
        XCTAssertTrue(local.isEmpty)
    }
}
