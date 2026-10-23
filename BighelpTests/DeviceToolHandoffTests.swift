import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

/// `DeviceToolHandoff`: a phone-tool call that leaves bighelp for another app (Shortcuts) and waits
/// for the callback. All ids and texts here are made up.
@MainActor
struct DeviceToolHandoffTests {
    private let tool = "shortcuts"

    // MARK: Ending

    @Test func aCallbackEndsTheHandoffWithItsParameters() async {
        let fixture = HandoffFixture()
        let id = UUID()
        let run = fixture.start(id)
        await fixture.waitUntil { fixture.handoff.isActive }
        #expect(fixture.time.begun == 1 && fixture.time.holds == 1)

        let url = fixture.callback(.success, id, query: "?result=hello%20there%0Anext")
        #expect(fixture.handoff.handleCallback(url))
        let outcome = await run.value
        #expect(outcome == .callback(.init(kind: .success, parameters: ["result": "hello there\nnext"])))
        // Every path lets go of the background time and the host connection.
        #expect(fixture.time.ended == 1 && fixture.time.releases == 1)
    }

    @Test func theAppCountsAsOpenForAShortWhileAfterTheCallbackThenStops() async {
        let fixture = HandoffFixture(grace: .milliseconds(80))
        let id = UUID()
        let run = fixture.start(id)
        await fixture.waitUntil { fixture.handoff.isActive }
        fixture.handoff.handleCallback(fixture.callback(.success, id))
        _ = await run.value
        // The scene is still inactive for a moment; the call checks it may deliver straight after.
        #expect(fixture.handoff.isActive)
        #expect(fixture.handoff.isAppOpen(.inactive))
        await fixture.waitUntil { !fixture.handoff.isActive }
        #expect(!fixture.handoff.isAppOpen(.background))
    }

    @Test func endingTheGraceStopsCountingAsOpenAtOnceAndLeavesARunningHandoffAlone() async {
        let fixture = HandoffFixture(grace: .seconds(30))
        let id = UUID()
        let run = fixture.start(id)
        await fixture.waitUntil { fixture.handoff.isActive }
        fixture.handoff.endReturnGrace()
        #expect(fixture.handoff.isActive, "A run that is still out keeps the app open")
        fixture.handoff.handleCallback(fixture.callback(.success, id))
        _ = await run.value
        #expect(fixture.handoff.isActive)
        fixture.handoff.endReturnGrace()
        #expect(!fixture.handoff.isActive)
    }

    @Test func cancelAndErrorCallbacksEndItToo() async {
        for (kind, query) in [(DeviceToolHandoff.CallbackKind.cancel, ""), (.error, "?errorMessage=It%20broke")] {
            let fixture = HandoffFixture()
            let id = UUID()
            let run = fixture.start(id)
            await fixture.waitUntil { fixture.handoff.isActive }
            fixture.handoff.handleCallback(fixture.callback(kind, id, query: query))
            let outcome = await run.value
            guard case .callback(let callback) = outcome else { Issue.record("Expected a callback, got \(outcome)"); continue }
            #expect(callback.kind == kind)
            #expect(callback.parameters["errorMessage"] == (kind == .error ? "It broke" : nil))
        }
    }

    @Test func noCallbackByTheDeadlineEndsItAtOnce() async {
        let fixture = HandoffFixture()
        let run = fixture.start(UUID(), timeout: .milliseconds(60))
        #expect(await run.value == .timedOut)
        // No grace: nothing is coming back.
        #expect(!fixture.handoff.isActive)
        #expect(fixture.time.ended == 1 && fixture.time.releases == 1)
    }

    @Test func iOSTakingItsBackgroundTimeBackEndsTheWait() async {
        let fixture = HandoffFixture()
        let run = fixture.start(UUID())
        await fixture.waitUntil { fixture.handoff.isActive }
        fixture.time.expire?()
        #expect(await run.value == .timedOut)
        #expect(!fixture.handoff.isActive)
        #expect(fixture.time.ended == 1 && fixture.time.releases == 1)
    }

    @Test func aCallThatIsNoLongerWantedIsRetiredEvenWhileTheAppIsAway() async {
        let fixture = HandoffFixture()
        let run = fixture.start(UUID(), stillWanted: { fixture.wanted })
        await fixture.waitUntil { fixture.handoff.isActive }
        fixture.wanted = false   // the switch turned off, or the chat changed
        #expect(await run.value == .retired)
        #expect(!fixture.handoff.isActive)
        #expect(fixture.time.ended == 1)
    }

    @Test func cancellingTheCallRetiresIt() async {
        let fixture = HandoffFixture()
        let run = fixture.start(UUID())
        await fixture.waitUntil { fixture.handoff.isActive }
        run.cancel()
        #expect(await run.value == .retired)
        #expect(!fixture.handoff.isActive)
        #expect(fixture.time.ended == 1 && fixture.time.releases == 1)
    }

    @Test func anAppThatCannotBeOpenedEndsAtOnce() async {
        let fixture = HandoffFixture()
        let run = fixture.start(UUID(), opens: false)
        #expect(await run.value == .notOpened)
        #expect(!fixture.handoff.isActive)
        #expect(fixture.time.ended == 1)
    }

    @Test func onlyOneHandoffIsOutAtATime() async {
        let fixture = HandoffFixture()
        let first = UUID()
        let run = fixture.start(first)
        await fixture.waitUntil { fixture.handoff.isActive }
        let second = fixture.start(UUID())
        #expect(await second.value == .busy)
        // The refused one took and gave back nothing.
        #expect(fixture.time.begun == 1 && fixture.handoff.isActive)
        fixture.handoff.handleCallback(fixture.callback(.cancel, first))
        _ = await run.value
    }

    @Test func aNewHandoffInTheGraceStartsCleanly() async {
        let fixture = HandoffFixture(grace: .milliseconds(60))
        let first = UUID()
        let run = fixture.start(first)
        await fixture.waitUntil { fixture.handoff.isActive }
        fixture.handoff.handleCallback(fixture.callback(.success, first))
        _ = await run.value
        let again = UUID()
        let next = fixture.start(again)
        // The first run's grace timer must not end the second run's hold.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(fixture.handoff.isActive)
        fixture.handoff.handleCallback(fixture.callback(.cancel, again))
        _ = await next.value
    }

    // MARK: Stray callbacks

    @Test func callbacksForUnknownOrFinishedRunsAreIgnored() async {
        let fixture = HandoffFixture(grace: .milliseconds(10))
        // Nothing is out: swallowed, never a screen to open.
        #expect(fixture.handoff.handleCallback(fixture.callback(.success, UUID(), query: "?result=x")))

        let id = UUID()
        let run = fixture.start(id)
        await fixture.waitUntil { fixture.handoff.isActive }
        let strays: [URL] = [
            fixture.callback(.success, UUID(), query: "?result=guess"),                       // not this run
            URL(string: "loopdy://device-tool/other/success/\(id.uuidString.lowercased())?result=x")!, // another tool
            URL(string: "loopdy://device-tool/shortcuts/maybe/\(id.uuidString.lowercased())")!, // not a kind
            URL(string: "loopdy://device-tool/shortcuts/success/not-a-uuid")!,
            URL(string: "loopdy://device-tool/shortcuts/success")!,
            URL(string: "loopdy://device-tool/shortcuts/success/\(id.uuidString.lowercased())/extra")!,
            URL(string: "loopdy://device-tool")!,
        ]
        for url in strays { #expect(fixture.handoff.handleCallback(url), "\(url) is ours, so it is swallowed") }
        #expect(fixture.handoff.isActive, "A stray callback must not end the real run")
        #expect(fixture.time.ended == 0)

        fixture.handoff.handleCallback(fixture.callback(.success, id, query: "?result=real"))
        #expect(await run.value == .callback(.init(kind: .success, parameters: ["result": "real"])))

        // A replay of the finished run's callback does nothing.
        let nextID = UUID()
        let next = fixture.start(nextID)
        await fixture.waitUntil { fixture.handoff.isActive && fixture.time.begun == 2 }
        fixture.handoff.handleCallback(fixture.callback(.success, id, query: "?result=replay"))
        #expect(fixture.time.ended == 1, "Only the first run has ended")
        fixture.handoff.handleCallback(fixture.callback(.cancel, nextID))
        _ = await next.value
    }

    @Test func otherLinksAreNotCallbacks() {
        let handoff = DeviceToolHandoff(backgroundTime: { _ in {} }, holdConnection: { {} })
        #expect(!handoff.handleCallback(URL(string: "loopdy://chat/abc")!))
        #expect(!handoff.handleCallback(URL(string: "https://device-tool/shortcuts/success/\(UUID().uuidString)")!))
        #expect(!handoff.handleCallback(URL(string: "shortcuts://device-tool")!))
    }

    @Test func anOversizeCallbackIsIgnoredWhole() async {
        let fixture = HandoffFixture()
        let id = UUID()
        let run = fixture.start(id, timeout: .milliseconds(200))
        await fixture.waitUntil { fixture.handoff.isActive }
        let huge = String(repeating: "a", count: DeviceToolHandoff.maximumCallbackLength + 1)
        #expect(fixture.handoff.handleCallback(fixture.callback(.success, id, query: "?result=" + huge)))
        #expect(await run.value == .timedOut)
    }

    // MARK: Staying open

    /// A notification pulled down, Control Center or a system question makes bighelp inactive, not gone:
    /// the phone tools keep going. The background closes them, except through a handoff's hop.
    @Test func inactiveCountsAsOpenAndTheBackgroundOnlyThroughAHop() async {
        let fixture = HandoffFixture()
        #expect([ScenePhase.active, .inactive, .background].map { fixture.handoff.isOpen($0) } == [true, true, false])
        #expect(fixture.handoff.isAppOpen(.active) && fixture.handoff.isAppOpen(.inactive) && !fixture.handoff.isAppOpen(.background))

        let id = UUID()
        let run = fixture.start(id)
        await fixture.waitUntil { fixture.handoff.isActive }
        // bighelp goes away to Shortcuts and comes back: the channel counts it as open throughout.
        for phase in [ScenePhase.inactive, .background, .inactive, .active] {
            #expect(fixture.handoff.isOpen(phase))
        }
        #expect(fixture.handoff.isAppOpen(.background))
        fixture.handoff.handleCallback(fixture.callback(.cancel, id))
        _ = await run.value
    }

    /// A quick trip away (the app switcher, a widget, a notification opened) keeps the phone tools for
    /// the background grace, like the host connection; they stop when it ends or bighelp comes back.
    @Test func theBackgroundGraceKeepsThePhoneToolsUntilItEnds() {
        let handoff = DeviceToolHandoff()
        handoff.holdBackgroundGrace()
        #expect(handoff.isOpen(.background) && handoff.isAppOpen(.background))
        handoff.releaseBackgroundGrace()
        #expect(!handoff.isOpen(.background) && !handoff.isAppOpen(.background))
        #expect(handoff.isOpen(.inactive))
    }

    // MARK: Callback URLs

    @Test func callbackURLsCarryTheRunIDInThePathBeforeAnyQuery() {
        let id = UUID()
        let url = DeviceToolHandoff.callbackURL(tool: "shortcuts", kind: .error, runID: id)
        #expect(url?.absoluteString == "loopdy://device-tool/shortcuts/error/\(id.uuidString.lowercased())")
        #expect(url.map(DeviceToolHandoff.isCallback) == true)
        #expect(url?.query == nil)
    }

    @Test func parametersAreDecodedSafelyAndBounded() async {
        func parameters(_ query: String, id: UUID = UUID()) async -> [String: String]? {
            let fixture = HandoffFixture()
            let run = fixture.start(id, timeout: .seconds(2))
            await fixture.waitUntil { fixture.handoff.isActive }
            fixture.handoff.handleCallback(fixture.callback(.success, id, query: query))
            guard case .callback(let callback) = await run.value else { return nil }
            return callback.parameters
        }
        // Multi-byte text and a plus sign (Shortcuts encodes spaces as %20, so + is a plus).
        #expect(await parameters("?result=caf%C3%A9%20%E2%9C%93%2B1+2")?["result"] == "café ✓+1+2")
        // Bytes that are not UTF-8 become replacement characters.
        #expect(await parameters("?result=a%FFb")?["result"] == "a\u{FFFD}b")
        // The first value of a repeated name wins; a name with no value is empty.
        let repeated = await parameters("?result=first&result=second&flag")
        #expect(repeated?["result"] == "first" && repeated?["flag"] == "")
        // An app that appends `&result=…` to a URL with no `?`.
        let id = UUID()
        let fixture = HandoffFixture()
        let run = fixture.start(id, timeout: .seconds(2))
        await fixture.waitUntil { fixture.handoff.isActive }
        let stray = URL(string: fixture.callback(.success, id).absoluteString + "&result=late%26text")!
        fixture.handoff.handleCallback(stray)
        guard case .callback(let callback) = await run.value else { Issue.record("Expected a callback"); return }
        #expect(callback.parameters["result"] == "late&text")
        // A long value is cut.
        let long = await parameters("?result=" + String(repeating: "z", count: DeviceToolHandoff.maximumValueLength + 500))
        #expect(long?["result"]?.count == DeviceToolHandoff.maximumValueLength)
    }

    @Test func decodeNeverFails() {
        #expect(DeviceToolHandoff.decode("") == "")
        #expect(DeviceToolHandoff.decode("%") == "%")
        #expect(DeviceToolHandoff.decode("%4") == "%4")
        #expect(DeviceToolHandoff.decode("%zz") == "%zz")
        #expect(DeviceToolHandoff.decode("%41%42") == "AB")
    }
}

// MARK: Fixtures

@MainActor
final class FakeHandoffBackgroundTime {
    private(set) var begun = 0
    private(set) var ended = 0
    private(set) var holds = 0
    private(set) var releases = 0
    var expire: (@MainActor () -> Void)?

    var backgroundTime: DeviceToolHandoff.BackgroundTime {
        { [self] onExpire in
            begun += 1
            expire = onExpire
            return { [self] in ended += 1 }
        }
    }

    var holdConnection: DeviceToolHandoff.ConnectionHold {
        { [self] in
            holds += 1
            return { [self] in releases += 1 }
        }
    }
}

@MainActor
private final class HandoffFixture {
    let time = FakeHandoffBackgroundTime()
    let handoff: DeviceToolHandoff
    var wanted = true

    init(grace: Duration = .milliseconds(30)) {
        handoff = DeviceToolHandoff(backgroundTime: time.backgroundTime, holdConnection: time.holdConnection,
                                    returnGrace: grace)
    }

    func start(
        _ id: UUID, timeout: Duration = .seconds(5), opens: Bool = true,
        stillWanted: (@MainActor () -> Bool)? = nil
    ) -> Task<DeviceToolHandoff.Outcome, Never> {
        let handoff = handoff
        let wanted = stillWanted ?? { true }
        return Task { @MainActor in
            await handoff.perform(tool: "shortcuts", runID: id, timeout: timeout, pollEvery: .milliseconds(10),
                                  isStillWanted: wanted, open: { opens })
        }
    }

    func callback(_ kind: DeviceToolHandoff.CallbackKind, _ id: UUID, query: String = "") -> URL {
        URL(string: DeviceToolHandoff.callbackURL(tool: "shortcuts", kind: kind, runID: id)!.absoluteString + query)!
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
