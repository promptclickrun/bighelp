import CoreLocation
@preconcurrency import EventKit
import Foundation
import Testing
@testable import Bighelp

/// A reminder's place (`locationTrigger`): checked whole before anything changes, written as an
/// EventKit alarm with a structured location, and given back by `reminders.list`. iOS Reminders
/// watches the place itself, so none of this needs location permission. Every place is made up.
@MainActor
struct ReminderLocationTriggerTests {
    private static let trigger: BighelpJSONValue = .object([
        "name": .string("Pharmacy"), "latitude": .number(40.25), "longitude": .number(-75.5),
        "radiusMeters": .integer(250), "proximity": .string("arrive"),
    ])

    // MARK: Checking

    @Test func theContractShapeIsAccepted() throws {
        let parsed = try ReminderLocationTrigger.parse(Self.trigger)
        #expect(parsed == ReminderLocationTrigger(name: "Pharmacy", latitude: 40.25, longitude: -75.5,
                                                  radiusMeters: 250, proximity: .arrive))
        let leaving = try ReminderLocationTrigger.parse(.object([
            "name": .string("Office"), "latitude": .integer(41), "longitude": .integer(-76), "proximity": .string("leave"),
        ]))
        // No radius means iOS' usual 150 meters.
        #expect(leaving.radiusMeters == 150 && leaving.proximity == .leave)
        #expect(leaving.latitude == 41 && leaving.longitude == -76)
    }

    @Test func theEdgesOfTheRangesAreAccepted() throws {
        for radius in [100.0, 5000.0] {
            let parsed = try ReminderLocationTrigger.parse(Self.with(["radiusMeters": .number(radius)]))
            #expect(parsed.radiusMeters == radius)
        }
        _ = try ReminderLocationTrigger.parse(Self.with(["latitude": .number(-90), "longitude": .number(180)]))
        _ = try ReminderLocationTrigger.parse(Self.with(["name": .string(String(repeating: "a", count: 100))]))
    }

    @Test func badTriggersAreInvalidArguments() {
        let bad: [BighelpJSONValue] = [
            .null, .string("Pharmacy"), .array([]), .object([:]),
            Self.without("name"), Self.without("latitude"), Self.without("longitude"), Self.without("proximity"),
            Self.with(["name": .string("")]),
            Self.with(["name": .string("   ")]),
            Self.with(["name": .string(String(repeating: "a", count: 101))]),
            Self.with(["name": .string("Two\nlines")]),
            Self.with(["name": .integer(1)]),
            Self.with(["latitude": .number(90.1)]),
            Self.with(["latitude": .number(-90.1)]),
            Self.with(["longitude": .number(180.1)]),
            Self.with(["longitude": .number(-180.1)]),
            Self.with(["latitude": .string("40")]),
            Self.with(["radiusMeters": .integer(99)]),
            Self.with(["radiusMeters": .integer(5001)]),
            Self.with(["radiusMeters": .string("250")]),
            Self.with(["radiusMeters": .null]),
            Self.with(["proximity": .string("enter")]),
            Self.with(["proximity": .string("Arrive")]),
            Self.with(["proximity": .boolean(true)]),
            Self.with(["unexpected": .boolean(true)]),
        ]
        for value in bad {
            #expect(throws: AppleDeviceToolError.invalidArguments) { try ReminderLocationTrigger.parse(value) }
        }
    }

    // MARK: The alarm

    @Test func theTriggerBecomesAnAlarmWithAStructuredLocation() throws {
        let reminder = EKReminder(eventStore: EKEventStore())
        ReminderLocationTrigger.apply(try ReminderLocationTrigger.parse(Self.trigger), to: reminder)

        let alarm = try #require(reminder.alarms?.first)
        #expect(reminder.alarms?.count == 1)
        #expect(alarm.proximity == .enter)
        let place = try #require(alarm.structuredLocation)
        #expect(place.title == "Pharmacy")
        #expect(place.radius == 250)
        #expect(place.geoLocation?.coordinate.latitude == 40.25)
        #expect(place.geoLocation?.coordinate.longitude == -75.5)
        // iOS Reminders watches it, so there is no clock time on the alarm.
        #expect(alarm.absoluteDate == nil)
    }

    @Test func leavingBecomesProximityLeave() throws {
        let reminder = EKReminder(eventStore: EKEventStore())
        ReminderLocationTrigger.apply(try ReminderLocationTrigger.parse(Self.with(["proximity": .string("leave")])), to: reminder)
        #expect(reminder.alarms?.first?.proximity == .leave)
    }

    @Test func settingANewPlaceReplacesTheOldOneAndKeepsTimeAlarms() throws {
        let reminder = EKReminder(eventStore: EKEventStore())
        let timeAlarm = EKAlarm(relativeOffset: -600)
        reminder.addAlarm(timeAlarm)
        ReminderLocationTrigger.apply(try ReminderLocationTrigger.parse(Self.trigger), to: reminder)
        ReminderLocationTrigger.apply(try ReminderLocationTrigger.parse(Self.with(["name": .string("Office"), "proximity": .string("leave")])), to: reminder)

        let alarms = reminder.alarms ?? []
        #expect(alarms.count == 2)
        #expect(alarms.filter { $0.structuredLocation != nil }.count == 1)
        #expect(alarms.first { $0.structuredLocation != nil }?.structuredLocation?.title == "Office")
        #expect(alarms.contains { $0.structuredLocation == nil && $0.relativeOffset == -600 })
    }

    @Test func clearingRemovesOnlyThePlace() throws {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.addAlarm(EKAlarm(relativeOffset: -600))
        ReminderLocationTrigger.apply(try ReminderLocationTrigger.parse(Self.trigger), to: reminder)
        ReminderLocationTrigger.apply(nil, to: reminder)
        #expect(reminder.alarms?.count == 1)
        #expect(ReminderLocationTrigger.read(from: reminder) == nil)
    }

    // MARK: Reading

    @Test func readGivesBackWhatWasSet() throws {
        let reminder = EKReminder(eventStore: EKEventStore())
        ReminderLocationTrigger.apply(try ReminderLocationTrigger.parse(Self.trigger), to: reminder)
        let read = try #require(ReminderLocationTrigger.read(from: reminder)?.object)
        #expect(read["name"] == .string("Pharmacy"))
        #expect(read["latitude"] == .number(40.25) && read["longitude"] == .number(-75.5))
        #expect(read["radiusMeters"] == .integer(250))
        #expect(read["proximity"] == .string("arrive"))
        #expect(Set(read.keys) == ["name", "latitude", "longitude", "radiusMeters", "proximity"])
    }

    @Test func aReminderWithoutAPlaceReadsAsNone() {
        let reminder = EKReminder(eventStore: EKEventStore())
        #expect(ReminderLocationTrigger.read(from: reminder) == nil)
        reminder.addAlarm(EKAlarm(relativeOffset: -60))
        #expect(ReminderLocationTrigger.read(from: reminder) == nil)
    }

    @Test func aPlaceSetOutsideBighelpIsReadLeniently() throws {
        // Reminders (or another app) can leave a place with no name and a radius outside the range.
        let reminder = EKReminder(eventStore: EKEventStore())
        let place = EKStructuredLocation(title: "")
        place.geoLocation = CLLocation(latitude: 40.123_456_789, longitude: -75.987_654_321)
        place.radius = 20
        let alarm = EKAlarm()
        alarm.structuredLocation = place
        alarm.proximity = .leave
        reminder.addAlarm(alarm)

        let read = try #require(ReminderLocationTrigger.read(from: reminder)?.object)
        #expect(read["name"] == nil)
        #expect(read["latitude"] == .number(40.123457))
        #expect(read["longitude"] == .number(-75.987654))
        #expect(read["radiusMeters"] == .integer(100))
        #expect(read["proximity"] == .string("leave"))
    }

    // MARK: The tool's arguments

    @Test func createAndUpdateAcceptATriggerAndUpdateAcceptsClearing() async throws {
        let boundary = TriggerStubBoundary()
        let service = AppleDeviceToolService(boundary: boundary)
        _ = try await service.execute(operation: "reminders.create",
                                      arguments: ["title": .string("Pick up"), "locationTrigger": Self.trigger], authorize: {})
        _ = try await service.execute(operation: "reminders.update",
                                      arguments: Self.update(["locationTrigger": Self.trigger]), authorize: {})
        _ = try await service.execute(operation: "reminders.update",
                                      arguments: Self.update(["clearLocationTrigger": .boolean(true)]), authorize: {})
        _ = try await service.execute(operation: "reminders.update",
                                      arguments: Self.update(["clearLocationTrigger": .boolean(false), "locationTrigger": Self.trigger]),
                                      authorize: {})
        #expect(boundary.operations == ["reminders.create", "reminders.update", "reminders.update", "reminders.update"])
    }

    @Test func aBadTriggerOrAContradictionNeverReachesEventKit() async {
        let boundary = TriggerStubBoundary()
        let service = AppleDeviceToolService(boundary: boundary)
        let create: [[String: BighelpJSONValue]] = [
            ["title": .string("Pick up"), "locationTrigger": Self.with(["radiusMeters": .integer(5)])],
            ["title": .string("Pick up"), "locationTrigger": .string("Pharmacy")],
            ["title": .string("Pick up"), "clearLocationTrigger": .boolean(true)],
        ]
        for arguments in create {
            await #expect(throws: AppleDeviceToolError.invalidArguments) {
                try await service.execute(operation: "reminders.create", arguments: arguments, authorize: {})
            }
        }
        let update: [[String: BighelpJSONValue]] = [
            Self.update(["locationTrigger": Self.with(["proximity": .string("enter")])]),
            Self.update(["locationTrigger": Self.trigger, "clearLocationTrigger": .boolean(true)]),
            Self.update(["clearLocationTrigger": .string("yes")]),
        ]
        for arguments in update {
            await #expect(throws: AppleDeviceToolError.invalidArguments) {
                try await service.execute(operation: "reminders.update", arguments: arguments, authorize: {})
            }
        }
        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await service.execute(operation: "reminders.list", arguments: ["locationTrigger": Self.trigger], authorize: {})
        }
        #expect(boundary.operations.isEmpty)
    }

    // MARK: EventKit

    @Test func createSavesAReminderWithThePlace() async throws {
        let store = TriggerEventStore()
        let boundary = LiveAppleDeviceToolNativeBoundary(eventStore: store)
        _ = try await boundary.execute(operation: "reminders.create",
                                       arguments: ["title": .string("Pick up"), "locationTrigger": Self.trigger], authorize: {})
        let saved = try #require(store.saved.first)
        #expect(store.saved.count == 1)
        let place = try #require(saved.alarms?.first?.structuredLocation)
        #expect(place.title == "Pharmacy" && place.radius == 250)
        #expect(saved.alarms?.first?.proximity == .enter)
    }

    @Test func createWithoutATriggerAddsNoAlarm() async throws {
        let store = TriggerEventStore()
        let boundary = LiveAppleDeviceToolNativeBoundary(eventStore: store)
        _ = try await boundary.execute(operation: "reminders.create", arguments: ["title": .string("Pick up")], authorize: {})
        #expect(store.saved.first?.alarms?.isEmpty ?? true)
    }

    @Test func updateSetsReplacesAndClearsThePlaceAndOtherwiseLeavesItAlone() async throws {
        let store = TriggerEventStore()
        let boundary = LiveAppleDeviceToolNativeBoundary(eventStore: store)
        let reminder = store.makeTarget(title: "Pick up")
        let revision = try await Self.revision(of: boundary)

        func update(_ extra: [String: BighelpJSONValue]) async throws {
            var arguments: [String: BighelpJSONValue] = ["id": .string("reminder-1"), "expectedRevision": .string(revision)]
            arguments.merge(extra) { $1 }
            _ = try await boundary.execute(operation: "reminders.update", arguments: arguments, authorize: {})
        }

        try await update(["locationTrigger": Self.trigger])
        #expect(reminder.alarms?.first?.structuredLocation?.title == "Pharmacy")

        // An update about something else keeps the place.
        try await update(["notes": .string("Ask for the blue bag")])
        #expect(reminder.alarms?.first?.structuredLocation?.title == "Pharmacy")
        #expect(reminder.notes == "Ask for the blue bag")

        try await update(["locationTrigger": Self.with(["name": .string("Office"), "proximity": .string("leave")])])
        #expect(reminder.alarms?.count == 1)
        #expect(reminder.alarms?.first?.structuredLocation?.title == "Office")
        #expect(reminder.alarms?.first?.proximity == .leave)

        try await update(["clearLocationTrigger": .boolean(true)])
        #expect(reminder.alarms?.isEmpty ?? true)
        #expect(store.saved.count == 4)
    }

    @Test func listGivesTheTriggerOnlyWhenThereIsOne() async throws {
        let store = TriggerEventStore()
        let boundary = LiveAppleDeviceToolNativeBoundary(eventStore: store)
        let reminder = store.makeTarget(title: "Pick up")

        var items = try await Self.listed(boundary)
        #expect(items.first?["locationTrigger"] == nil)

        ReminderLocationTrigger.apply(try ReminderLocationTrigger.parse(Self.trigger), to: reminder)
        items = try await Self.listed(boundary)
        let trigger = try #require(items.first?["locationTrigger"]?.object)
        #expect(trigger["name"] == .string("Pharmacy"))
        #expect(trigger["proximity"] == .string("arrive"))
        #expect(trigger["radiusMeters"] == .integer(250))
        #expect(items.first?["title"] == .string("Pick up"))
    }

    // MARK: Helpers

    private static func with(_ changes: [String: BighelpJSONValue]) -> BighelpJSONValue {
        var fields = trigger.object ?? [:]
        fields.merge(changes) { $1 }
        return .object(fields)
    }

    private static func without(_ key: String) -> BighelpJSONValue {
        var fields = trigger.object ?? [:]
        fields[key] = nil
        return .object(fields)
    }

    private static func update(_ extra: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] {
        var arguments: [String: BighelpJSONValue] = ["id": .string("reminder-1"), "expectedRevision": .string("rev-1")]
        arguments.merge(extra) { $1 }
        return arguments
    }

    private static func listed(_ boundary: LiveAppleDeviceToolNativeBoundary) async throws -> [[String: BighelpJSONValue]] {
        let result = try await boundary.execute(operation: "reminders.list", arguments: [:], authorize: {})
        return (result["items"]?.array ?? []).compactMap(\.object)
    }

    private static func revision(of boundary: LiveAppleDeviceToolNativeBoundary) async throws -> String {
        try await listed(boundary).first?["revision"]?.string ?? ""
    }
}

/// Just records what reaches EventKit.
@MainActor
private final class TriggerStubBoundary: AppleDeviceToolNativeBoundary {
    private(set) var operations: [String] = []

    func status(for capability: DeviceToolCapability) async -> DeviceToolSystemAccess { .available }
    func request(_ capability: DeviceToolCapability) async -> DeviceToolSystemAccess { .available }

    func execute(operation: String, arguments: [String: BighelpJSONValue],
                 authorize: @escaping @MainActor () throws -> Void) async throws -> [String: BighelpJSONValue] {
        operations.append(operation)
        return ["id": .string("reminder-1"), "revision": .string("rev-2")]
    }
}

/// A reminder store that keeps nobody's real reminders: saving only records, and the one reminder
/// a test builds is the one every lookup finds.
nonisolated private final class TriggerEventStore: EKEventStore, @unchecked Sendable {
    var saved: [EKReminder] = []
    var target: EKReminder?
    private var list: EKCalendar?

    private var calendar: EKCalendar {
        if let list { return list }
        let created = EKCalendar(for: .reminder, eventStore: self)
        list = created
        return created
    }

    func makeTarget(title: String) -> EKReminder {
        let reminder = EKReminder(eventStore: self)
        reminder.calendar = calendar
        reminder.title = title
        target = reminder
        return reminder
    }

    override func defaultCalendarForNewReminders() -> EKCalendar? { calendar }
    override func calendars(for entityType: EKEntityType) -> [EKCalendar] { [calendar] }
    override func save(_ reminder: EKReminder, commit: Bool) throws { saved.append(reminder) }
    override func calendarItem(withIdentifier identifier: String) -> EKCalendarItem? {
        identifier == "reminder-1" ? target : nil
    }
    override func predicateForReminders(in calendars: [EKCalendar]?) -> NSPredicate { NSPredicate(value: true) }
    override func fetchReminders(matching predicate: NSPredicate,
                                 completion: @escaping ([EKReminder]?) -> Void) -> Any {
        completion(target.map { [$0] } ?? [])
        return NSObject()
    }
}
