import Foundation
import Testing
@testable import Bighelp

/// The client with a fake transport: no network, no Keychain, no disk.
struct TelemetryClientTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fill(_ rig: TelemetryTestRig.Rig, _ count: Int) async {
        for _ in 0..<count { await rig.client.record(.featureUsed(.chatSent), at: rig.clock.now) }
    }

    @Test func fiftyQueuedEventsSendWithoutWaitingForTheTimer() async throws {
        let rig = TelemetryTestRig.make()
        await fill(rig, 49)
        #expect(rig.transport.requests.isEmpty)
        await rig.client.record(.featureUsed(.chatSent), at: rig.clock.now)
        #expect(await rig.transport.waitForRequests(1))
        let batch = try #require(rig.transport.batches.first)
        #expect((batch["events"] as? [Any])?.count == 50)
        #expect(batch["source"] as? String == "app")
        #expect(TelemetryBatchEncoder.isUUIDv4(try #require(batch["id"] as? String)))
        #expect(batch["id"] as? String == rig.identity.current)
    }

    @Test func theTimerSendsWhatIsWaiting() async throws {
        var configuration = TelemetryClient.Configuration()
        configuration.flushInterval = .milliseconds(40)
        let rig = TelemetryTestRig.make(configuration: configuration)
        await rig.client.start()
        await rig.client.record(.appOpened(coldStart: true), at: rig.clock.now)
        #expect(await rig.transport.waitForRequests(1))
        #expect(await rig.client.queuedCount == 0)
    }

    @Test func goingToTheBackgroundSendsAndKeepsACopy() async throws {
        let rig = TelemetryTestRig.make(responses: [.rateLimited(after: 5)])
        await rig.client.record(.appBackgrounded(foregroundMs: 900), at: rig.clock.now)
        await rig.client.flushForBackground()
        // The service said wait: the event stays queued and is saved for a restart.
        #expect(rig.transport.requests.count == 1)
        #expect(rig.disk.saved.map(\.event) == [.appBackgrounded(foregroundMs: 900)])
    }

    @Test func oneSessionIDAndOneInstallIDForEveryBatch() async throws {
        let rig = TelemetryTestRig.make()
        await fill(rig, 120)
        await rig.client.flush()
        #expect(await rig.transport.waitForRequests(3))
        let batches = rig.transport.batches
        #expect(Set(batches.compactMap { $0["session"] as? String }).count == 1)
        #expect(Set(batches.compactMap { $0["id"] as? String }).count == 1)
        #expect(rig.identity.created == 1)
    }

    @Test func aRateLimitKeepsTheEventsAndBacksOff() async throws {
        let rig = TelemetryTestRig.make(responses: [.rateLimited(after: nil), .rateLimited(after: 400), .accepted])
        await fill(rig, 3)
        await rig.client.flush()
        #expect(rig.transport.requests.count == 1)
        #expect(await rig.client.queuedCount == 3, "429 keeps the events")
        #expect(await rig.client.nextAttempt == rig.clock.now.addingTimeInterval(60), "first wait is a minute")

        // Too early: nothing goes out.
        rig.clock.advance(59)
        await rig.client.flush()
        #expect(rig.transport.requests.count == 1)

        // Then another 429, with a longer Retry-After than the backoff.
        rig.clock.advance(2)
        await rig.client.flush()
        #expect(rig.transport.requests.count == 2)
        #expect(await rig.client.nextAttempt == rig.clock.now.addingTimeInterval(400))

        rig.clock.advance(401)
        await rig.client.flush()
        #expect(rig.transport.requests.count == 3)
        #expect(await rig.client.queuedCount == 0)
        #expect(await rig.client.nextAttempt == nil, "a success clears the wait")
    }

    @Test func theBackoffDoublesAndStopsAtAnHour() async throws {
        let rig = TelemetryTestRig.make(responses: Array(repeating: .rateLimited(after: nil), count: 9))
        await fill(rig, 1)
        var waits: [TimeInterval] = []
        for _ in 0..<8 {
            await rig.client.flush()
            if let next = await rig.client.nextAttempt {
                waits.append(next.timeIntervalSince(rig.clock.now))
                rig.clock.advance(next.timeIntervalSince(rig.clock.now) + 1)
            }
        }
        #expect(waits == [60, 120, 240, 480, 960, 1_920, 3_600, 3_600])
    }

    @Test(arguments: [TelemetryResponse.dropped])
    func anyOtherFailureDropsTheBatchSilently(response: TelemetryResponse) async throws {
        let rig = TelemetryTestRig.make(responses: [response])
        await fill(rig, 4)
        await rig.client.flush()
        #expect(rig.transport.requests.count == 1)
        #expect(await rig.client.queuedCount == 0)
        #expect(await rig.client.nextAttempt == nil)
    }

    @Test func theQueueIsBoundedAndDropsTheOldest() async throws {
        var configuration = TelemetryClient.Configuration()
        configuration.memoryCapacity = 500
        configuration.flushThreshold = 100_000
        let rig = TelemetryTestRig.make(configuration: configuration)
        for index in 0..<650 { await rig.client.record(.firstToken(ms: index), at: rig.clock.now) }
        #expect(await rig.client.queuedCount == 500)
        let queued = await rig.client.queuedEvents
        #expect(queued.first == .firstToken(ms: 150), "the oldest 150 were dropped")
        #expect(queued.last == .firstToken(ms: 649))
        #expect(await rig.client.droppedForCapacity == 150)
    }

    @Test func aRateLimitedBatchPutBackStillRespectsTheBound() async throws {
        var configuration = TelemetryClient.Configuration()
        configuration.memoryCapacity = 60
        configuration.flushThreshold = 100_000
        let rig = TelemetryTestRig.make(responses: [.rateLimited(after: nil)], configuration: configuration)
        for index in 0..<60 { await rig.client.record(.firstToken(ms: index), at: rig.clock.now) }
        await rig.client.flush()
        for index in 60..<70 { await rig.client.record(.firstToken(ms: index), at: rig.clock.now) }
        #expect(await rig.client.queuedCount == 60)
        #expect(await rig.client.queuedEvents.last == .firstToken(ms: 69))
    }

    @Test func aDisabledClientQueuesAndSendsNothing() async throws {
        let rig = TelemetryTestRig.make(enabled: false)
        await fill(rig, 80)
        await rig.client.flush()
        await rig.client.flushForBackground()
        #expect(await rig.client.queuedCount == 0)
        #expect(rig.transport.requests.isEmpty)
        #expect(rig.identity.created == 0, "no install ID is made while it's off")
        #expect(rig.disk.saved.isEmpty)
    }

    @Test func turningItOffThrowsEverythingAwayAndOnMakesANewID() async throws {
        let rig = TelemetryTestRig.make()
        await fill(rig, 5)
        await rig.client.flush()
        let first = try #require(rig.identity.current)
        await fill(rig, 3)
        await rig.client.persistNow()
        #expect(rig.disk.saved.count == 3)

        await rig.client.setEnabled(false)
        #expect(await rig.client.queuedCount == 0)
        #expect(rig.identity.current == nil, "the install ID is deleted")
        #expect(rig.disk.saved.isEmpty && rig.disk.deleted >= 1)
        let sentBefore = rig.transport.requests.count
        await fill(rig, 60)
        await rig.client.flush()
        #expect(rig.transport.requests.count == sentBefore, "nothing more is sent")

        await rig.client.setEnabled(true)
        await fill(rig, 2)
        await rig.client.flush()
        let second = try #require(rig.identity.current)
        #expect(second != first, "turning it back on starts a new ID")
        #expect(rig.transport.batches.last?["id"] as? String == second)
    }

    @Test func aBatchInTheAirWhenItIsTurnedOffIsNotKept() async throws {
        let rig = TelemetryTestRig.make(responses: [.rateLimited(after: nil)])
        await fill(rig, 2)
        async let flushing: Void = rig.client.flush()
        await rig.client.setEnabled(false)
        await flushing
        #expect(await rig.client.queuedCount == 0)
    }

    @Test func noInstallIDMeansNothingIsSent() async throws {
        let rig = TelemetryTestRig.make()
        rig.identity.failsToCreate = true
        await fill(rig, 2)
        await rig.client.flush()
        #expect(rig.transport.requests.isEmpty)
        #expect(await rig.client.queuedCount == 2)
    }

    @Test func unsentEventsComeBackAfterAKillButOldOnesDoNot() async throws {
        let clock = TelemetryTestClock()
        let fresh = TelemetryRecord(.appOpened(coldStart: true), at: clock.now.addingTimeInterval(-3_600))
        let stale = TelemetryRecord(.appOpened(coldStart: true), at: clock.now.addingTimeInterval(-7 * 86_400))
        let rig = TelemetryTestRig.make(disk: FakeTelemetryDisk([stale, fresh]), clock: clock)
        await rig.client.start()
        #expect(await rig.client.queuedCount == 1)
        await rig.client.flush()
        #expect(rig.transport.batches.first.flatMap { ($0["events"] as? [[String: Any]])?.count } == 1)
    }

    @Test func theCopyOnDiskIsBounded() async throws {
        var configuration = TelemetryClient.Configuration()
        configuration.diskCapacity = 200
        configuration.flushThreshold = 100_000
        let rig = TelemetryTestRig.make(configuration: configuration)
        for index in 0..<350 { await rig.client.record(.firstToken(ms: index), at: rig.clock.now) }
        await rig.client.persistNow()
        #expect(rig.disk.saved.count == 200)
        #expect(rig.disk.saved.last?.event == .firstToken(ms: 349))
    }

    @Test func dateInTheFutureCountsAsNowAndOldDatesAreDropped() async throws {
        let rig = TelemetryTestRig.make()
        await rig.client.record(.appOpened(coldStart: true), at: rig.clock.now.addingTimeInterval(86_400))
        await rig.client.record(.appOpened(coldStart: true), at: rig.clock.now.addingTimeInterval(-30 * 86_400))
        #expect(await rig.client.queuedCount == 1)
        await rig.client.flush()
        let events = try #require(rig.transport.batches.first?["events"] as? [[String: Any]])
        let time = try #require(events.first?["t"] as? Int64)
        #expect(time == Int64((rig.clock.now.timeIntervalSince1970 * 1_000).rounded()))
    }

    @Test func receiptsAndAppEventsTravelInSeparateBatches() async throws {
        let rig = TelemetryTestRig.make()
        await rig.client.record(.appOpened(coldStart: true), at: rig.clock.now)
        await rig.client.record(.notificationReceived(kind: .alert, path: .direct, delayMs: 900, hostToPhoneMs: 1_100),
                                at: rig.clock.now)
        await rig.client.record(.appBackgrounded(foregroundMs: 5), at: rig.clock.now)
        await rig.client.flush()
        #expect(rig.transport.batches.map { $0["source"] as? String } == ["app", "nse", "app"])
    }
}

struct TelemetryEnvironmentTests {
    private func allows(_ arguments: [String] = [], environment: [String: String] = [:], debug: Bool,
                        xctest: Bool = false) -> Bool {
        TelemetryEnvironment.allowsSending(arguments: arguments, environment: environment, isDebugBuild: debug,
                                           xctestIsLoaded: xctest)
    }

    @Test func testsAndUITestsNeverSend() {
        for environment in [["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
                            ["XCTestBundlePath": "/tmp/x.xctest"], ["BIGHELP_UI_TEST_RUN_ID": UUID().uuidString]] {
            #expect(!allows(environment: environment, debug: false))
            #expect(!allows([TelemetryEnvironment.debugOptIn], environment: environment, debug: true))
        }
        #expect(!allows(debug: false, xctest: true))
    }

    @Test func demoModeNeverSends() {
        for argument in ["-use-demo-fixtures", "-disable-demo-delays", "-force-signed-out-onboarding",
                         "-native-workspace-acceptance"] {
            #expect(!allows(["Bighelp", argument], debug: false))
            #expect(!allows([argument, TelemetryEnvironment.debugOptIn], debug: true))
        }
    }

    @Test func aDebugBuildSendsOnlyWhenAskedAndAReleaseBuildSends() {
        #expect(!allows(["Bighelp"], debug: true))
        #expect(allows(["Bighelp", TelemetryEnvironment.debugOptIn], debug: true))
        #expect(allows(["Bighelp"], debug: false))
    }

    @Test func thisTestRunNeverSends() {
        #expect(!TelemetryEnvironment.allowsSending())
    }
}
