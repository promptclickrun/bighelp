import Foundation
import Testing
import UserNotifications
@testable import Bighelp

/// The agent's `iphone_focus` tool, bighelp's Focus filter state, and the quiet alerts it asks the
/// notification extension for. Every name and note here is made up.
@MainActor
struct DeviceFocusToolTests {
    private static let context = DeviceToolCallContext(requestID: "a1b2c3d4-0000-4000-8000-000000000002", hostID: "host-1",
                                                       agentID: "agent-1", sessionID: "session-1", turnID: "turn-1")
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// A store that is its own: nothing here touches the real app group. Its clock reads a minute after
    /// `start` unless a test moves it.
    private static func store(clock: FocusClock = FocusClock()) -> BighelpFocusFilterStore {
        BighelpFocusFilterStore(defaults: UserDefaults(suiteName: "bighelp.tests.focus." + UUID().uuidString),
                                clock: { clock.now })
    }

    private func run(
        _ tool: DeviceFocusTool, _ operation: String = "focus.current", _ arguments: [String: BighelpJSONValue] = [:],
        authorize: @escaping @MainActor () throws -> Void = {}
    ) async throws -> [String: BighelpJSONValue] {
        try await tool.execute(operation: operation, arguments: arguments, context: Self.context, authorize: authorize)
    }

    // MARK: Capability

    @Test func focusNeedsTheNewerPluginAndIsNeverJournaled() {
        #expect(DeviceToolCapability.focus.pluginFeature == "native-device-focus-v1")
        #expect(DeviceToolCatalog.operations["focus.current"]?.capability == .focus)
        #expect(DeviceToolCatalog.operations["focus.current"]?.journaled == false)
        #expect(DeviceFocusTool(store: Self.store()).capability == .focus)
    }

    @Test func thereIsNoIOSPermissionToAskFor() async {
        let tool = DeviceFocusTool(store: Self.store())
        #expect(await tool.status() == .available)
        #expect(await tool.request() == .available)
    }

    // MARK: The tool's answer

    @Test func withoutAFilterTheAnswerIsNotActiveAndExplainsWhy() async throws {
        let result = try await run(DeviceFocusTool(store: Self.store()))
        #expect(Set(result.keys) == ["active", "quietAlerts", "hint"])
        #expect(result["active"] == .boolean(false))
        #expect(result["quietAlerts"] == .boolean(false))
        let hint = try #require(result["hint"]?.string)
        #expect(hint.contains("Settings") && hint.contains("Focus"))
    }

    @Test func anActiveFilterGivesItsNameNoteAndStartTime() async throws {
        let store = Self.store()
        store.apply(name: "Work", note: "In a meeting until noon. Keep replies short.", quietAlerts: true, now: Self.start)
        let result = try await run(DeviceFocusTool(store: store))
        #expect(result["active"] == .boolean(true))
        #expect(result["name"] == .string("Work"))
        #expect(result["note"] == .string("In a meeting until noon. Keep replies short."))
        #expect(result["quietAlerts"] == .boolean(true))
        #expect(result["since"] == .string("2026-09-21T14:13:20Z"))
        #expect(result["hint"]?.string?.isEmpty == false)
    }

    @Test func nameNoteAndStartAreLeftOutWhenTheyAreNotSet() async throws {
        let store = Self.store()
        store.apply(name: nil, note: nil, quietAlerts: true, now: Self.start)
        let result = try await run(DeviceFocusTool(store: store))
        #expect(Set(result.keys) == ["active", "quietAlerts", "hint", "since"])
    }

    @Test func aFilterThatTurnedOffReadsAsNotActiveWithNothingLeftOver() async throws {
        let store = Self.store()
        store.apply(name: "Sleep", note: "Do not call.", quietAlerts: true, now: Self.start)
        // iOS runs the filter again with its default values when the Focus turns off.
        store.apply(name: nil, note: nil, quietAlerts: false, now: Self.start.addingTimeInterval(3_600))
        let result = try await run(DeviceFocusTool(store: store))
        #expect(Set(result.keys) == ["active", "quietAlerts", "hint"])
        #expect(result["active"] == .boolean(false))
        #expect(result["quietAlerts"] == .boolean(false))
    }

    @Test func quietAlertsNeverReadsTrueForAFilterThatIsOff() {
        let stale = BighelpFocusFilterState(active: false, name: "Work", note: "x", quietAlerts: true, since: Self.start)
        let payload = DeviceFocusTool.payload(stale)
        #expect(payload["quietAlerts"] == .boolean(false))
        #expect(payload["name"] == nil && payload["note"] == nil && payload["since"] == nil)
    }

    @Test func currentTakesNoArgumentsAndNothingElseExists() async {
        let tool = DeviceFocusTool(store: Self.store())
        for arguments: [String: BighelpJSONValue] in [["name": .string("Work")], ["verbose": .boolean(true)], ["x": .null]] {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await self.run(tool, "focus.current", arguments) }
        }
        for operation in ["focus.set", "focus.list", "focus.turnOn", "contacts.list"] {
            await #expect(throws: AppleDeviceToolError.unsupportedOperation) { try await self.run(tool, operation) }
        }
    }

    @Test func currentReadsNothingWhenAuthorizationFails() async {
        let store = Self.store()
        store.apply(name: "Work", note: "Private note.", quietAlerts: false, now: Self.start)
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await self.run(DeviceFocusTool(store: store)) { throw AppleDeviceToolError.authorizationRequired }
        }
    }

    // MARK: What the filter saves

    @Test func iosRunningTheFilterWithDefaultsMeansTheFocusTurnedOff() {
        let on = BighelpFocusFilterState.applying(name: "Work", note: nil, quietAlerts: false, to: .inactive, now: Self.start)
        #expect(on.active)
        let off = BighelpFocusFilterState.applying(name: nil, note: nil, quietAlerts: false, to: on, now: Self.start)
        #expect(off == .inactive)
        // Blank text is the same as none.
        let blank = BighelpFocusFilterState.applying(name: "  ", note: "\n", quietAlerts: false, to: on, now: Self.start)
        #expect(blank == .inactive)
    }

    @Test func aQuietOnlyFilterIsStillActive() {
        let state = BighelpFocusFilterState.applying(name: nil, note: nil, quietAlerts: true, to: .inactive, now: Self.start)
        #expect(state == BighelpFocusFilterState(active: true, name: nil, note: nil, quietAlerts: true, since: Self.start))
    }

    @Test func sinceIsWhenTheFilterTurnedOnNotWhenItWasLastRun() {
        let first = BighelpFocusFilterState.applying(name: "Work", note: "Note", quietAlerts: true, to: .inactive, now: Self.start)
        let later = Self.start.addingTimeInterval(600)
        let again = BighelpFocusFilterState.applying(name: "Work", note: "Note", quietAlerts: true, to: first, now: later)
        #expect(again.since == Self.start, "the same filter run again is not a new start")
        let edited = BighelpFocusFilterState.applying(name: "Work", note: "A new note", quietAlerts: true, to: first, now: later)
        #expect(edited.since == later)
        let afterOff = BighelpFocusFilterState.applying(name: "Work", note: "Note", quietAlerts: true, to: .inactive, now: later)
        #expect(afterOff.since == later)
    }

    @Test func textIsTrimmedCleanedAndBounded() {
        let long = String(repeating: "n", count: 5_000)
        let state = BighelpFocusFilterState.applying(
            name: "  Wo\u{7}rk\u{0}  " + long, note: "Line one\nLine two\u{1B}[0m " + long, quietAlerts: false, to: .inactive, now: Self.start)
        #expect(state.name?.count == BighelpFocusFilterState.maximumNameLength)
        #expect(state.name?.hasPrefix("Work") == true)
        #expect(state.note?.count == BighelpFocusFilterState.maximumNoteLength)
        #expect(state.note?.hasPrefix("Line one\nLine two[0m") == true, "a line break stays; control characters go")
    }

    @Test func theStoreRoundTripsAndReadsGarbageAsNoFilter() throws {
        let store = Self.store()
        #expect(store.read() == .inactive)
        let state = BighelpFocusFilterState(active: true, name: "Work", note: "Note", quietAlerts: true, since: Self.start)
        store.write(state)
        #expect(store.read() == state)
        let defaults = try #require(store.defaults)
        defaults.set(Data("not json".utf8), forKey: BighelpFocusFilterState.key)
        #expect(store.read() == .inactive)
        defaults.set(Data(repeating: 0x20, count: 20_000), forKey: BighelpFocusFilterState.key)
        #expect(store.read() == .inactive)
        defaults.set("a string", forKey: BighelpFocusFilterState.key)
        #expect(store.read() == .inactive)
        #expect(BighelpFocusFilterStore(defaults: nil).read() == .inactive)
    }

    @Test func theStateLivesInTheSameGroupAsTheOtherAlertState() {
        #expect(BighelpFocusFilterState.key == "bighelp.focus-filter.v1")
        #expect(BighelpFocusFilterState.appGroup == BighelpRecentAlerts.appGroup)
    }

    #if !os(visionOS)
    @Test func theFilterSavesItsValuesAndClearsThemWhenTheFocusTurnsOff() async throws {
        let shared = BighelpFocusFilterStore.shared
        let before = shared.read()
        defer { shared.write(before) }

        let filter = BighelpFocusFilter()
        filter.name = "Work"
        filter.note = "Back at two."
        filter.quietAlerts = true
        _ = try await filter.perform()
        let on = shared.read()
        #expect(on.active && on.name == "Work" && on.note == "Back at two." && on.quietAlerts)
        #expect(on.since != nil)

        // What iOS runs when the Focus turns off: every value at its default.
        let off = BighelpFocusFilter()
        off.name = nil
        off.note = nil
        off.quietAlerts = false
        _ = try await off.perform()
        #expect(shared.read() == .inactive)
    }
    #endif

    // MARK: A filter iOS never turned off

    @Test func aFilterOlderThanADayReadsAsOffEverywhere() async throws {
        let clock = FocusClock()
        let store = Self.store(clock: clock)
        store.apply(name: "Work", note: "Note", quietAlerts: true, now: Self.start)
        let day = BighelpFocusFilterState.maximumAge
        #expect(day == 24 * 60 * 60)

        clock.now = Self.start.addingTimeInterval(day)
        #expect(store.read().active, "exactly a day is still on")
        #expect(try await run(DeviceFocusTool(store: store))["active"] == .boolean(true))

        clock.now = Self.start.addingTimeInterval(day + 1)
        #expect(store.read() == .inactive)
        let answer = try await run(DeviceFocusTool(store: store))
        #expect(Set(answer.keys) == ["active", "quietAlerts", "hint"])
        #expect(answer["active"] == .boolean(false) && answer["quietAlerts"] == .boolean(false))
        let content = makeContent()
        BighelpFocusFilterState.quiet(content, eventType: "session.completed", store: store)
        #expect(content.interruptionLevel == .active, "alerts must not stay quiet for a Focus that is long gone")
        #expect(content.sound != nil)
    }

    @Test func iosRunningTheFilterAgainStartsTheDayOver() {
        let clock = FocusClock()
        let store = Self.store(clock: clock)
        store.apply(name: "Work", note: nil, quietAlerts: true, now: Self.start)
        clock.now = Self.start.addingTimeInterval(BighelpFocusFilterState.maximumAge + 600)
        #expect(store.read() == .inactive)
        // The Focus turns on again: the same values are a new start, not the old one.
        store.apply(name: "Work", note: nil, quietAlerts: true)
        #expect(store.read().since == clock.now)
        #expect(store.read().quietAlerts)
    }

    @Test func anActiveStateWithoutAStartTimeIsNotTrusted() {
        let state = BighelpFocusFilterState(active: true, name: "Work", note: nil, quietAlerts: true, since: nil)
        #expect(state.current(now: Self.start) == .inactive)
        let store = Self.store()
        store.write(state)
        #expect(store.read() == .inactive)
    }

    // MARK: Quiet agent alerts

    @Test func everyKindOfAlertThatNeedsThePersonKeepsItsNormalLevel() {
        // Seen in the app: the sealed push and dashboard kinds, and the host's request names.
        let needsYou = [
            "approval.required", "clarification.required", "attention.required", "secret.required", "sudo.required",
            "approval.request", "clarify.request", "secret.request", "sudo.request",
        ]
        let store = Self.store()
        store.apply(name: nil, note: nil, quietAlerts: true, now: Self.start)
        for eventType in needsYou {
            #expect(BighelpFocusFilterState.needsThePerson(eventType: eventType), "\(eventType)")
            let content = makeContent()
            BighelpFocusFilterState.quiet(content, eventType: eventType, store: store)
            #expect(content.interruptionLevel == .active && content.sound != nil, "\(eventType)")
        }
        // Results and chatter are the quiet kind.
        let replies = [
            "session.completed", "session.failed", "subagent.completed", "subagent.failed", "scheduled.completed",
            "scheduled.failed", "delegation.completed", "delegation.started", "delegation.updated", "job.completed",
            "job.failed", "task.updated", "channel.message",
        ]
        for eventType in replies {
            #expect(!BighelpFocusFilterState.needsThePerson(eventType: eventType), "\(eventType)")
            let content = makeContent()
            BighelpFocusFilterState.quiet(content, eventType: eventType, store: store)
            #expect(content.interruptionLevel == .passive, "\(eventType)")
        }
    }

    private func makeContent(sound: Bool = true) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Avery"
        content.body = "Your report is ready."
        if sound { content.sound = .default }
        return content
    }

    @Test func quietAlertsDeliverRepliesPassivelyWithoutSound() {
        let store = Self.store()
        store.apply(name: "Work", note: nil, quietAlerts: true, now: Self.start)
        for eventType in ["session.completed", "session.failed", "subagent.completed", "scheduled.completed", "something.new"] {
            let content = makeContent()
            BighelpFocusFilterState.quiet(content, eventType: eventType, store: store)
            #expect(content.interruptionLevel == .passive, "\(eventType)")
            #expect(content.sound == nil, "\(eventType)")
            #expect(content.title == "Avery" && content.body == "Your report is ready.", "only the delivery changes")
        }
    }

    @Test func questionsAndApprovalsKeepTheirNormalLevelAndSound() {
        let store = Self.store()
        store.apply(name: "Work", note: nil, quietAlerts: true, now: Self.start)
        for eventType in ["approval.required", "clarification.required", "secret.required", "sudo.required"] {
            let content = makeContent()
            BighelpFocusFilterState.quiet(content, eventType: eventType, store: store)
            #expect(content.interruptionLevel == .active, "\(eventType) needs the person")
            #expect(content.sound != nil, "\(eventType)")
        }
    }

    @Test func nothingChangesWithoutAnActiveFilterThatAsksForQuiet() {
        let withoutQuiet = Self.store()
        withoutQuiet.apply(name: "Work", note: "Note", quietAlerts: false, now: Self.start)
        let wasOn = Self.store()
        wasOn.apply(name: "Work", note: nil, quietAlerts: true, now: Self.start)
        wasOn.apply(name: nil, note: nil, quietAlerts: false, now: Self.start)
        // A leftover flag from a filter that is not active must not quiet anything.
        let stale = Self.store()
        stale.write(BighelpFocusFilterState(active: false, name: nil, note: nil, quietAlerts: true, since: nil))
        for store in [Self.store(), withoutQuiet, wasOn, stale, BighelpFocusFilterStore(defaults: nil)] {
            let content = makeContent()
            BighelpFocusFilterState.quiet(content, eventType: "session.completed", store: store)
            #expect(content.interruptionLevel == .active)
            #expect(content.sound != nil)
        }
    }

    @Test func aQuietReplyStaysPassiveAfterTheGroupingRulesRun() {
        let store = Self.store()
        store.apply(name: nil, note: nil, quietAlerts: true, now: Self.start)
        let content = makeContent()
        BighelpNotificationGrouping.apply(to: content, eventType: "session.completed", agentName: "Avery")
        BighelpFocusFilterState.quiet(content, eventType: "session.completed", store: store)
        #expect(content.interruptionLevel == .passive)
        #expect(content.threadIdentifier == BighelpNotificationGrouping.thread(agentName: "Avery"))
    }
}

/// A clock a test can move.
private final class FocusClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_790_000_060)
}
