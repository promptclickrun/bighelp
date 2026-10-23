import Foundation
import Testing
@testable import Bighelp

/// The agent's `iphone_alarms` tool on the phone: the switch and iOS permission, what it accepts,
/// and that an update never leaves the person without their alarm. Every label here is made up.
@MainActor
struct DeviceAlarmsToolTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z

    // MARK: Catalog

    @Test func alarmsAreOneJournaledWriteSetAndOneRead() {
        #expect(DeviceToolCatalog.operations["alarms.list"]?.journaled == false)
        for operation in ["alarms.create", "alarms.update", "alarms.delete"] {
            #expect(DeviceToolCatalog.operations[operation]?.journaled == true)
            #expect(DeviceToolCatalog.capability(for: operation) == .alarms)
        }
        #expect(DeviceToolCapability.alarms.pluginFeature == "native-device-alarms-v1")
    }

    @Test func writeResultsHoldOnlyWhatTheJournalKeeps() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", ["label": .string("Stand up"), "timerSeconds": .integer(60)])
        let id = try #require(created["id"]?.string)
        let updated = try await fixture.run("alarms.update", ["id": .string(id), "label": .string("Stretch")])
        let deleted = try await fixture.run("alarms.delete", ["id": .string(id)])
        for result in [created, updated, deleted] {
            #expect(Set(result.keys).isSubset(of: DeviceToolCatalog.durableKeys), "A journal entry would lose \(result.keys)")
        }
        #expect(deleted["deleted"] == .boolean(true))
    }

    // MARK: Access

    @Test func statusMapsIOSAuthorizationWithoutAsking() async {
        let cases: [(DeviceAlarmAuthorization, DeviceToolSystemAccess)] = [
            (.notDetermined, .notRequested), (.denied, .denied), (.authorized, .available),
        ]
        for (authorization, expected) in cases {
            let fixture = AlarmFixture(authorization: authorization)
            #expect(await fixture.tool.status() == expected)
            #expect(fixture.provider.authorizationRequests == 0)
        }
    }

    @Test func turningTheSwitchOnAsksIOSOnlyTheFirstTime() async {
        let fixture = AlarmFixture(authorization: .notDetermined)
        fixture.provider.answerToRequest = .authorized
        #expect(await fixture.tool.request() == .available)
        #expect(fixture.provider.authorizationRequests == 1)
        #expect(await fixture.tool.request() == .available)
        #expect(fixture.provider.authorizationRequests == 1, "Asking again after an answer only annoys the person")

        let refused = AlarmFixture(authorization: .notDetermined)
        refused.provider.answerToRequest = .denied
        #expect(await refused.tool.request() == .denied)

        let denied = AlarmFixture(authorization: .denied)
        #expect(await denied.tool.request() == .denied)
        #expect(denied.provider.authorizationRequests == 0)
    }

    @Test func aQuestionIOSCannotAskIsUnavailableNotDenied() async {
        let fixture = AlarmFixture(authorization: .notDetermined)
        fixture.provider.requestFails = true
        #expect(await fixture.tool.request() == .unavailable)
    }

    @Test func aPlatformWithoutAlarmKitIsUnavailableAndRunsNothing() async {
        let tool = DeviceAlarmsTool(provider: nil, labels: DeviceAlarmMemoryLabels(), now: { Self.now })
        #expect(await tool.status() == .unavailable)
        #expect(await tool.request() == .unavailable)
        await #expect(throws: AppleDeviceToolError.unavailable) {
            try await tool.execute(operation: "alarms.list", arguments: [:], context: AlarmFixture.context, authorize: {})
        }
    }

    @Test func noAlarmIsTouchedWithoutIOSAccess() async {
        for authorization in [DeviceAlarmAuthorization.notDetermined, .denied] {
            let fixture = AlarmFixture(authorization: authorization)
            for (operation, arguments) in [
                ("alarms.list", [:]),
                ("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)]),
                ("alarms.delete", ["id": .string(UUID().uuidString)]),
            ] as [(String, [String: BighelpJSONValue])] {
                await #expect(throws: AppleDeviceToolError.authorizationRequired) {
                    try await fixture.run(operation, arguments)
                }
            }
            #expect(fixture.provider.scheduled.isEmpty && fixture.provider.cancelled.isEmpty)
        }
    }

    @Test func aCallThatLostItsChatSchedulesNothing() async {
        let fixture = AlarmFixture()
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)],
                                  authorize: { throw AppleDeviceToolError.authorizationRequired })
        }
        #expect(fixture.provider.scheduled.isEmpty)
    }

    @Test func accessEndingBeforeTheLastCheckSchedulesNothing() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)])
        let id = try #require(created["id"]?.string)
        let writes = fixture.provider.scheduled.count
        var checks = 0
        // The first check passes; the second, right before the change, finds the switch off.
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await fixture.run("alarms.update", ["id": .string(id), "timerSeconds": .integer(600)], authorize: {
                checks += 1
                if checks > 1 { throw AppleDeviceToolError.authorizationRequired }
            })
        }
        #expect(fixture.provider.scheduled.count == writes && fixture.provider.cancelled.isEmpty,
                "The old alarm must still be there when the update is refused")
        let alarmID = try #require(UUID(uuidString: id))
        #expect(fixture.provider.records[alarmID] != nil)
    }

    // MARK: Create

    @Test func aTimerCountsDownFromNowAndComesBackInTheList() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)])
        #expect(Set(created.keys) == ["id"])
        let id = try #require(created["id"]?.string)
        #expect(id == id.lowercased() && UUID(uuidString: id) != nil)
        #expect(fixture.provider.scheduled.map(\.schedule) == [.timer(seconds: 300)])

        let listed = try #require(try await fixture.run("alarms.list", [:])["alarms"]?.array?.first?.object)
        #expect(listed["id"] == .string(id))
        #expect(listed["label"] == .string("Tea"))
        #expect(listed["kind"] == .string("timer"))
        #expect(listed["state"] == .string("countdown"))
        #expect(listed["timerSeconds"] == .integer(300))
        #expect(listed["time"] == nil && listed["date"] == nil && listed["weekdays"] == nil, "Fields appear only as set")
    }

    @Test func aTimeOfDayWithWeekdaysRepeatsEveryWeek() async throws {
        let fixture = AlarmFixture()
        _ = try await fixture.run("alarms.create", [
            "label": .string("Gym"),
            "time": .object(["hour": .integer(6), "minute": .integer(45)]),
            "weekdays": .array([.string("friday"), .string("monday"), .string("friday"), .string("wednesday")]),
        ])
        #expect(fixture.provider.scheduled.map(\.schedule)
            == [.clock(DeviceAlarmClockTime(hour: 6, minute: 45), weekdays: [.monday, .wednesday, .friday])],
                "Duplicates fold into one and the week keeps its order")
        let listed = try #require(try await fixture.run("alarms.list", [:])["alarms"]?.array?.first?.object)
        #expect(listed["kind"] == .string("alarm") && listed["state"] == .string("scheduled"))
        #expect(listed["time"] == .object(["hour": .integer(6), "minute": .integer(45)]))
        #expect(listed["weekdays"] == .array([.string("monday"), .string("wednesday"), .string("friday")]))
    }

    @Test func aTimeOfDayWithoutWeekdaysRingsOnceAtTheNextSuchTime() async throws {
        let fixture = AlarmFixture()
        _ = try await fixture.run("alarms.create", [
            "label": .string("Flight"), "time": .object(["hour": .integer(23), "minute": .integer(59)]),
        ])
        #expect(fixture.provider.scheduled.map(\.schedule) == [.clock(DeviceAlarmClockTime(hour: 23, minute: 59), weekdays: [])])
        let listed = try #require(try await fixture.run("alarms.list", [:])["alarms"]?.array?.first?.object)
        #expect(listed["weekdays"] == nil)
    }

    @Test func aDateRingsOnceAndReadsBackInUTC() async throws {
        let fixture = AlarmFixture()
        _ = try await fixture.run("alarms.create", [
            "label": .string("Pick up parcel"), "date": .string("2026-09-22T09:00:00+02:00"),
        ])
        let expected = Date(timeIntervalSince1970: 1_790_000_000 + 60_400) // 2026-09-22T07:00:00Z
        #expect(fixture.provider.scheduled.map(\.schedule) == [.once(expected)])
        let listed = try #require(try await fixture.run("alarms.list", [:])["alarms"]?.array?.first?.object)
        #expect(listed["date"] == .string("2026-09-22T07:00:00Z"))
        #expect(listed["kind"] == .string("alarm"))
    }

    @Test func fractionalSecondsInADateAreAccepted() async throws {
        let fixture = AlarmFixture()
        _ = try await fixture.run("alarms.create", ["label": .string("Soon"), "date": .string("2026-09-22T07:00:00.500Z")])
        #expect(fixture.provider.scheduled.count == 1)
    }

    @Test func theLimitsOfEachFieldAreAllowed() async throws {
        let fixture = AlarmFixture()
        let longest = String(repeating: "x", count: DeviceAlarmsTool.maximumLabelLength)
        for arguments: [String: BighelpJSONValue] in [
            ["label": .string(longest), "timerSeconds": .integer(5)],
            ["label": .string("Day"), "timerSeconds": .integer(86_400)],
            ["label": .string("Midnight"), "time": .object(["hour": .integer(0), "minute": .integer(0)])],
            ["label": .string("Late"), "time": .object(["hour": .integer(23), "minute": .integer(59)]),
             "weekdays": .array(DeviceAlarmWeekday.allCases.map { .string($0.rawValue) })],
            ["label": .string("  padded  "), "timerSeconds": .number(90)],
        ] {
            _ = try await fixture.run("alarms.create", arguments)
        }
        #expect(fixture.provider.scheduled.count == 5)
        #expect(fixture.provider.scheduled.last?.label == "padded", "Labels are trimmed")
        #expect(fixture.provider.scheduled.last?.schedule == .timer(seconds: 90), "A whole number written as 90.0 is a whole number")
    }

    @Test func badArgumentsScheduleNothing() async {
        let clock: BighelpJSONValue = .object(["hour": .integer(7), "minute": .integer(0)])
        let bad: [(String, [String: BighelpJSONValue])] = [
            ("no label", ["timerSeconds": .integer(60)]),
            ("empty label", ["label": .string("   "), "timerSeconds": .integer(60)]),
            ("label too long", ["label": .string(String(repeating: "x", count: 61)), "timerSeconds": .integer(60)]),
            ("label with a line break", ["label": .string("a\nb"), "timerSeconds": .integer(60)]),
            ("label not text", ["label": .integer(4), "timerSeconds": .integer(60)]),
            ("nothing to ring", ["label": .string("x")]),
            ("time and timer", ["label": .string("x"), "time": clock, "timerSeconds": .integer(60)]),
            ("time and date", ["label": .string("x"), "time": clock, "date": .string("2026-09-22T07:00:00Z")]),
            ("hour 24", ["label": .string("x"), "time": .object(["hour": .integer(24), "minute": .integer(0)])]),
            ("minute 60", ["label": .string("x"), "time": .object(["hour": .integer(1), "minute": .integer(60)])]),
            ("negative hour", ["label": .string("x"), "time": .object(["hour": .integer(-1), "minute": .integer(0)])]),
            ("time without minute", ["label": .string("x"), "time": .object(["hour": .integer(1)])]),
            ("time with a second", ["label": .string("x"), "time": .object(["hour": .integer(1), "minute": .integer(0), "second": .integer(0)])]),
            ("time as text", ["label": .string("x"), "time": .string("07:00")]),
            ("timer of 4 seconds", ["label": .string("x"), "timerSeconds": .integer(4)]),
            ("timer over a day", ["label": .string("x"), "timerSeconds": .integer(86_401)]),
            ("timer with a fraction", ["label": .string("x"), "timerSeconds": .number(90.5)]),
            ("timer as text", ["label": .string("x"), "timerSeconds": .string("60")]),
            ("timer as a flag", ["label": .string("x"), "timerSeconds": .boolean(true)]),
            ("date in the past", ["label": .string("x"), "date": .string("2026-09-21T14:13:00Z")]),
            ("date with no offset", ["label": .string("x"), "date": .string("2026-09-22T07:00:00")]),
            ("date as a day only", ["label": .string("x"), "date": .string("2026-09-22")]),
            ("date as a number", ["label": .string("x"), "date": .integer(1_790_100_000)]),
            ("weekdays with a date", ["label": .string("x"), "date": .string("2026-09-22T07:00:00Z"), "weekdays": .array([.string("monday")])]),
            ("weekdays with a timer", ["label": .string("x"), "timerSeconds": .integer(60), "weekdays": .array([.string("monday")])]),
            ("weekdays alone", ["label": .string("x"), "weekdays": .array([.string("monday")])]),
            ("no weekdays listed", ["label": .string("x"), "time": clock, "weekdays": .array([])]),
            ("unknown weekday", ["label": .string("x"), "time": clock, "weekdays": .array([.string("funday")])]),
            ("weekday in capitals", ["label": .string("x"), "time": clock, "weekdays": .array([.string("Monday")])]),
            ("weekdays as text", ["label": .string("x"), "time": clock, "weekdays": .string("monday")]),
            ("unknown key", ["label": .string("x"), "timerSeconds": .integer(60), "sound": .string("bell")]),
            ("an id on create", ["label": .string("x"), "timerSeconds": .integer(60), "id": .string(UUID().uuidString)]),
        ]
        let fixture = AlarmFixture()
        for (name, arguments) in bad {
            await #expect(throws: AppleDeviceToolError.invalidArguments, "\(name)") {
                try await fixture.run("alarms.create", arguments)
            }
        }
        #expect(fixture.provider.scheduled.isEmpty, "A refused request must change nothing")
        #expect(fixture.labels.labels.isEmpty)
    }

    @Test func whenAlarmKitHoldsNoMoreTheAgentIsToldAndNoLabelIsKept() async {
        let fixture = AlarmFixture()
        fixture.provider.maximumAlarms = 1
        _ = try? await fixture.run("alarms.create", ["label": .string("One"), "timerSeconds": .integer(60)])
        await #expect(throws: DeviceAlarmsTool.Failure.limitReached) {
            try await fixture.run("alarms.create", ["label": .string("Two"), "timerSeconds": .integer(60)])
        }
        #expect(DeviceAlarmsTool.Failure.limitReached.code == "alarm_limit_reached")
        #expect(fixture.labels.labels.count == 1)
    }

    @Test func aRefusalFromIOSAfterAccessEndsReadsAsNeedingAccess() async {
        let fixture = AlarmFixture()
        fixture.provider.scheduleFailure = .notAuthorized
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(60)])
        }
        fixture.provider.scheduleFailure = .failed
        await #expect(throws: AppleDeviceToolError.nativeFailure) {
            try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(60)])
        }
    }

    // MARK: List

    @Test func listTakesNoArgumentsAndNamesAlarmsItDoesNotKnow() async throws {
        let fixture = AlarmFixture()
        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await fixture.run("alarms.list", ["limit": .integer(5)])
        }
        // AlarmKit gives alarms back without a label; one made before the labels were kept still lists.
        try await fixture.provider.schedule(id: UUID(), label: "lost", schedule: .timer(seconds: 30))
        try await fixture.provider.schedule(
            id: UUID(), label: "lost", schedule: .clock(DeviceAlarmClockTime(hour: 8, minute: 0), weekdays: []))
        let labels = try await fixture.run("alarms.list", [:])["alarms"]?.array?.compactMap { $0.object?["label"]?.string }
        #expect(Set(labels ?? []) == ["Timer", "Alarm"])
    }

    @Test func listForgetsLabelsOfAlarmsThatEndedAndKeepsTheOrderSteady() async throws {
        let fixture = AlarmFixture()
        var ids: [String] = []
        for label in ["banana", "Apple", "cherry"] {
            let created = try await fixture.run("alarms.create", ["label": .string(label), "timerSeconds": .integer(60)])
            ids.append(try #require(created["id"]?.string))
        }
        let first = try await fixture.run("alarms.list", [:])["alarms"]?.array?.compactMap { $0.object?["label"]?.string }
        #expect(first == ["Apple", "banana", "cherry"])
        // A one-time alarm that rang is gone from AlarmKit on its own.
        fixture.provider.records[try #require(UUID(uuidString: ids[0]))] = nil
        let second = try await fixture.run("alarms.list", [:])["alarms"]?.array?.compactMap { $0.object?["label"]?.string }
        #expect(second == ["Apple", "cherry"])
        #expect(fixture.labels.labels.count == 2)
    }

    @Test func listIsBounded() async throws {
        let fixture = AlarmFixture()
        fixture.provider.maximumAlarms = 1_000
        for index in 0..<(DeviceAlarmsTool.maximumListed + 20) {
            try await fixture.provider.schedule(id: UUID(), label: "n\(index)", schedule: .timer(seconds: 60))
        }
        let listed = try await fixture.run("alarms.list", [:])["alarms"]?.array
        #expect(listed?.count == DeviceAlarmsTool.maximumListed)
        let size = try JSONEncoder().encode(try await fixture.run("alarms.list", [:])).count
        #expect(size < 128 * 1_024, "The native result limit is 128 KB")
    }

    // MARK: Update

    @Test func updateReplacesTheScheduleUnderTheSameIDAndKeepsTheLabel() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)])
        let id = try #require(created["id"]?.string)
        let updated = try await fixture.run("alarms.update", ["id": .string(id), "timerSeconds": .integer(480)])
        #expect(updated == ["id": .string(id)])
        #expect(fixture.provider.cancelled == [UUID(uuidString: id)])
        let listed = try #require(try await fixture.run("alarms.list", [:])["alarms"]?.array)
        #expect(listed.count == 1)
        #expect(listed.first?.object?["id"] == .string(id))
        #expect(listed.first?.object?["timerSeconds"] == .integer(480))
        #expect(listed.first?.object?["label"] == .string("Tea"))
    }

    @Test func updateCanOnlyRenameAnAlarmAndKeepItsTime() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", [
            "label": .string("Gym"), "time": .object(["hour": .integer(6), "minute": .integer(45)]),
            "weekdays": .array([.string("monday"), .string("friday")]),
        ])
        let id = try #require(created["id"]?.string)
        _ = try await fixture.run("alarms.update", ["id": .string(id), "label": .string("Swim")])
        let rescheduled = try #require(fixture.provider.scheduled.last)
        #expect(rescheduled.label == "Swim")
        #expect(rescheduled.schedule == .clock(DeviceAlarmClockTime(hour: 6, minute: 45), weekdays: [.monday, .friday]))
    }

    @Test func aNewTimeKeepsTheWeekdaysUnlessTheyAreNamed() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", [
            "label": .string("Gym"), "time": .object(["hour": .integer(6), "minute": .integer(45)]),
            "weekdays": .array([.string("monday"), .string("friday")]),
        ])
        let id = try #require(created["id"]?.string)
        _ = try await fixture.run("alarms.update", ["id": .string(id), "time": .object(["hour": .integer(7), "minute": .integer(15)])])
        #expect(fixture.provider.scheduled.last?.schedule
            == .clock(DeviceAlarmClockTime(hour: 7, minute: 15), weekdays: [.monday, .friday]))
        _ = try await fixture.run("alarms.update", ["id": .string(id), "weekdays": .array([.string("sunday")])])
        #expect(fixture.provider.scheduled.last?.schedule
            == .clock(DeviceAlarmClockTime(hour: 7, minute: 15), weekdays: [.sunday]), "Weekdays alone keep the time")
        _ = try await fixture.run("alarms.update", [
            "id": .string(id), "time": .object(["hour": .integer(9), "minute": .integer(0)]), "weekdays": .array([.string("tuesday")]),
        ])
        #expect(fixture.provider.scheduled.last?.schedule == .clock(DeviceAlarmClockTime(hour: 9, minute: 0), weekdays: [.tuesday]))
    }

    @Test func aTimerCanBecomeAnAlarmUnderTheSameID() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)])
        let id = try #require(created["id"]?.string)
        _ = try await fixture.run("alarms.update", ["id": .string(id), "date": .string("2026-09-22T07:00:00Z")])
        let listed = try #require(try await fixture.run("alarms.list", [:])["alarms"]?.array?.first?.object)
        #expect(listed["kind"] == .string("alarm") && listed["timerSeconds"] == nil)
        #expect(listed["id"] == .string(id))
    }

    @Test func aRefusedUpdatePutsTheOldAlarmBack() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)])
        let id = try #require(created["id"]?.string)
        fixture.provider.failNextSchedule = .failed
        await #expect(throws: AppleDeviceToolError.nativeFailure) {
            try await fixture.run("alarms.update", ["id": .string(id), "label": .string("Coffee"), "timerSeconds": .integer(60)])
        }
        let alarmID = try #require(UUID(uuidString: id))
        let record = try #require(fixture.provider.records[alarmID])
        #expect(record.schedule == .timer(seconds: 300), "The person must not lose their alarm to a refused change")
        let listed = try #require(try await fixture.run("alarms.list", [:])["alarms"]?.array?.first?.object)
        #expect(listed["label"] == .string("Tea"))
    }

    @Test func updateRefusesWhatItCannotMean() async throws {
        let fixture = AlarmFixture()
        let timer = try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)])
        let id = try #require(timer["id"]?.string)
        let writes = fixture.provider.scheduled.count
        let bad: [(String, [String: BighelpJSONValue])] = [
            ("no id", ["label": .string("x")]),
            ("not an id", ["id": .string("tea"), "label": .string("x")]),
            ("id as a number", ["id": .integer(3), "label": .string("x")]),
            ("nothing to change", ["id": .string(id)]),
            ("weekdays on a timer", ["id": .string(id), "weekdays": .array([.string("monday")])]),
            ("two schedules", ["id": .string(id), "timerSeconds": .integer(60), "date": .string("2026-09-22T07:00:00Z")]),
            ("timer too short", ["id": .string(id), "timerSeconds": .integer(1)]),
            ("unknown key", ["id": .string(id), "label": .string("x"), "volume": .integer(3)]),
        ]
        for (name, arguments) in bad {
            await #expect(throws: AppleDeviceToolError.invalidArguments, "\(name)") {
                try await fixture.run("alarms.update", arguments)
            }
        }
        #expect(fixture.provider.scheduled.count == writes && fixture.provider.cancelled.isEmpty)
    }

    @Test func anAlarmThatIsNotThereIsNotFound() async {
        let fixture = AlarmFixture()
        let missing = UUID().uuidString.lowercased()
        for (operation, arguments) in [
            ("alarms.update", ["id": .string(missing), "label": .string("x")]),
            ("alarms.delete", ["id": .string(missing)]),
        ] as [(String, [String: BighelpJSONValue])] {
            await #expect(throws: DeviceAlarmsTool.Failure.notFound) { try await fixture.run(operation, arguments) }
        }
        #expect(DeviceAlarmsTool.Failure.notFound.code == "not_found")
        #expect(fixture.provider.scheduled.isEmpty && fixture.provider.cancelled.isEmpty)
    }

    @Test func idsAreAcceptedInAnyCase() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)])
        let id = try #require(created["id"]?.string)
        let result = try await fixture.run("alarms.delete", ["id": .string(id.uppercased())])
        #expect(result["id"] == .string(id), "The agent always gets the lowercase form back")
    }

    // MARK: Delete

    @Test func deleteTurnsTheAlarmOffAndForgetsItsLabel() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)])
        let other = try await fixture.run("alarms.create", ["label": .string("Eggs"), "timerSeconds": .integer(600)])
        let id = try #require(created["id"]?.string)
        let result = try await fixture.run("alarms.delete", ["id": .string(id)])
        #expect(result == ["id": .string(id), "deleted": .boolean(true)])
        #expect(fixture.provider.cancelled == [UUID(uuidString: id)])
        #expect(fixture.labels.labels.keys.map { $0.uuidString.lowercased() } == [try #require(other["id"]?.string)])
        await #expect(throws: DeviceAlarmsTool.Failure.notFound) { try await fixture.run("alarms.delete", ["id": .string(id)]) }
    }

    @Test func deleteTakesOnlyAnID() async throws {
        let fixture = AlarmFixture()
        let created = try await fixture.run("alarms.create", ["label": .string("Tea"), "timerSeconds": .integer(300)])
        let id = try #require(created["id"]?.string)
        for arguments: [String: BighelpJSONValue] in [[:], ["id": .string(id), "label": .string("x")], ["id": .string("")]] {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await fixture.run("alarms.delete", arguments) }
        }
        #expect(fixture.provider.cancelled.isEmpty)
    }

    @Test func anUnknownOperationIsRefused() async {
        let fixture = AlarmFixture()
        await #expect(throws: AppleDeviceToolError.unsupportedOperation) { try await fixture.run("alarms.snooze", [:]) }
    }

    // MARK: Label store

    @Test func labelsSurviveARestartAndAreBounded() throws {
        let suite = "bighelp.test.alarm-labels." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DeviceAlarmLabelStore(defaults: defaults)
        let id = UUID()
        first.setLabel("Tea", for: id)
        #expect(DeviceAlarmLabelStore(defaults: defaults).label(for: id) == "Tea")

        for _ in 0..<(DeviceAlarmLabelStore.maximumLabels + 30) { first.setLabel("x", for: UUID()) }
        let stored = defaults.dictionary(forKey: DeviceAlarmLabelStore.key)?.count
        #expect(stored == DeviceAlarmLabelStore.maximumLabels)

        let other = UUID()
        first.setLabel("Eggs", for: other)
        #expect(first.label(for: other) == "Eggs", "The newest label is never the one dropped")
        first.removeLabel(for: other)
        #expect(first.label(for: other) == nil)
    }

    @Test func keepingOnlyTheAlarmsThatExistDropsTheRest() throws {
        let suite = "bighelp.test.alarm-labels." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeviceAlarmLabelStore(defaults: defaults)
        let kept = UUID(), gone = UUID()
        store.setLabel("Keep", for: kept)
        store.setLabel("Gone", for: gone)
        store.keepOnly([kept])
        #expect(store.label(for: kept) == "Keep")
        #expect(store.label(for: gone) == nil)
    }

    // MARK: Demo

    @Test func demoAlarmsWorkWithoutIOS() async throws {
        let tool = DeviceAlarmsTool(provider: DemoDeviceAlarmProvider(), labels: DeviceAlarmMemoryLabels())
        #expect(await tool.status() == .notRequested)
        #expect(await tool.request() == .available)
        let created = try await tool.execute(
            operation: "alarms.create", arguments: ["label": .string("Demo"), "timerSeconds": .integer(30)],
            context: AlarmFixture.context, authorize: {})
        let listed = try await tool.execute(operation: "alarms.list", arguments: [:], context: AlarmFixture.context, authorize: {})
        #expect(listed["alarms"]?.array?.first?.object?["id"] == created["id"])
    }
}

// MARK: - Fakes

/// What the tool needs to run, with a clock that doesn't move.
@MainActor
private final class AlarmFixture {
    static let context = DeviceToolCallContext(requestID: "request", hostID: "host", agentID: "agent",
                                               sessionID: "session", turnID: "turn")

    let provider = FakeAlarmProvider()
    let labels = DeviceAlarmMemoryLabels()
    let tool: DeviceAlarmsTool

    init(authorization: DeviceAlarmAuthorization = .authorized) {
        provider.authorization = authorization
        tool = DeviceAlarmsTool(provider: provider, labels: labels, now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    @discardableResult
    func run(
        _ operation: String, _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void = {}
    ) async throws -> [String: BighelpJSONValue] {
        try await tool.execute(operation: operation, arguments: arguments, context: Self.context, authorize: authorize)
    }
}

/// AlarmKit as far as the tool can tell: alarms come back without labels, a timer counts down at once,
/// scheduling an id that already exists fails (so an update has to cancel first), and the app can only
/// hold so many.
@MainActor
private final class FakeAlarmProvider: DeviceAlarmProviding {
    struct Scheduled: Equatable {
        let id: UUID
        let label: String
        let schedule: DeviceAlarmSchedule
    }

    var authorization = DeviceAlarmAuthorization.authorized
    var answerToRequest = DeviceAlarmAuthorization.authorized
    var requestFails = false
    var maximumAlarms = 64
    var scheduleFailure: DeviceAlarmProviderError?
    var failNextSchedule: DeviceAlarmProviderError?
    var records: [UUID: DeviceAlarmRecord] = [:]
    private(set) var authorizationRequests = 0
    private(set) var scheduled: [Scheduled] = []
    private(set) var cancelled: [UUID] = []

    func requestAuthorization() async throws -> DeviceAlarmAuthorization {
        authorizationRequests += 1
        if requestFails { throw DeviceAlarmProviderError.failed }
        authorization = answerToRequest
        return authorization
    }

    func alarms() throws -> [DeviceAlarmRecord] { Array(records.values) }

    func schedule(id: UUID, label: String, schedule: DeviceAlarmSchedule) async throws {
        if let failure = failNextSchedule {
            failNextSchedule = nil
            throw failure
        }
        if let failure = scheduleFailure { throw failure }
        guard records[id] == nil else { throw DeviceAlarmProviderError.failed }
        guard records.count < maximumAlarms else { throw DeviceAlarmProviderError.limitReached }
        let state: DeviceAlarmState = if case .timer = schedule { .countdown } else { .scheduled }
        records[id] = DeviceAlarmRecord(id: id, state: state, schedule: schedule)
        scheduled.append(Scheduled(id: id, label: label, schedule: schedule))
    }

    func cancel(id: UUID) throws {
        guard records.removeValue(forKey: id) != nil else { throw DeviceAlarmProviderError.failed }
        cancelled.append(id)
    }
}
