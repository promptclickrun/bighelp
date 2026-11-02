import Foundation
@preconcurrency import EventKit
import Testing
@testable import Bighelp

@MainActor
struct AppleDeviceToolServiceTests {
    @Test func reminderFetchCanFilterResultsDeliveredOnEventKitsBackgroundQueue() async throws {
        let boundary = LiveAppleDeviceToolNativeBoundary(eventStore: BackgroundReminderEventStore())
        let result = try await boundary.execute(operation: "reminders.list",
            arguments: ["completed": .boolean(true)], authorize: {})
        #expect(result["items"] == .array([]))
        #expect(result["truncated"] == .boolean(false))
    }
    @Test func commonHealthCatalogIsFiniteAndIncludesEachSupportedDomain() {
        let catalog = Set(AppleDeviceToolService.commonHealthCatalog)

        #expect(catalog.count == 22)
        #expect(catalog.contains("step_count"))
        #expect(catalog.contains("sleep_analysis"))
        #expect(catalog.contains("heart_rate"))
        #expect(catalog.contains("body_mass"))
        #expect(catalog.contains("workout"))
    }

    /// The row's detail names every kind of data the catalog can read (App Review 5.1.3(i)).
    @Test func healthRowNamesEveryKindOfDataItCanRead() {
        let detail = DeviceToolCapability.health.detail.lowercased()
        for words in ["steps", "distance", "active and resting energy", "flights climbed", "exercise and stand time",
                      "sleep", "heart rate", "resting and walking heart rate", "heart rate variability",
                      "blood oxygen", "breathing rate", "blood pressure", "height", "weight", "body mass index",
                      "lean body mass", "body fat", "workouts", "read only"] {
            #expect(detail.contains(words), "\(words)")
        }
        #expect(DeviceToolCatalog.capability(for: "health.read") == .health)
        #expect(DeviceToolCatalog.operations["health.read"]?.journaled == false)
        #expect(DeviceToolCatalog.operations["health.write"] == nil)
    }

    @Test func healthReadReportsRawQueryCoverageAndLimitEvidence() async throws {
        let boundary = RecordingAppleDeviceToolBoundary()
        boundary.response = ["items": .array([]), "truncated": .boolean(false)]
        let service = AppleDeviceToolService(boundary: boundary)

        let result = try await service.execute(
            operation: "health.read",
            arguments: Self.rangeArguments,
            authorize: { }
        )

        #expect(result["coverage"] == .object([
            "start": .string("2026-09-01T00:00:00Z"),
            "end": .string("2026-09-02T00:00:00Z"),
            "timeZone": .string("America/Chicago"),
            "limit": .integer(200),
            "returnedCount": .integer(0),
            "truncated": .boolean(false),
            "aggregation": .string("raw_samples"),
        ]))
    }

    @Test func healthReadKeepsToTheCatalogThirtyOneDaysAndTwoHundredRecords() async {
        let service = AppleDeviceToolService(boundary: RecordingAppleDeviceToolBoundary())
        let refused: [[String: BighelpJSONValue]] = [
            Self.rangeArguments.merging(["types": .array([.string("clinical_records")])]) { $1 },
            Self.rangeArguments.merging(["types": .array([])]) { $1 },
            Self.rangeArguments.merging(["limit": .integer(201)]) { $1 },
            Self.rangeArguments.merging(["end": .string("2026-10-03T00:00:00Z")]) { $1 },
            Self.rangeArguments.merging(["write": .boolean(true)]) { $1 },
        ]
        for arguments in refused {
            await #expect(throws: AppleDeviceToolError.invalidArguments) {
                try await service.execute(operation: "health.read", arguments: arguments, authorize: { })
            }
        }
    }

    @Test func statusAndRequestDelegateToTheNativeBoundary() async {
        let boundary = RecordingAppleDeviceToolBoundary()
        boundary.statuses[.calendar] = .available
        boundary.requestResults[.calendar] = .available
        let service = AppleDeviceToolService(boundary: boundary)

        #expect(await service.status(.calendar) == .available)
        #expect(await service.request(.calendar) == .available)
        #expect(boundary.statusRequests == [.calendar])
        #expect(boundary.permissionRequests == [.calendar])
    }

    @Test func unsupportedOperationUsesStableSanitizedError() async {
        let service = AppleDeviceToolService(boundary: RecordingAppleDeviceToolBoundary())

        await #expect(throws: AppleDeviceToolError.unsupportedOperation) {
            try await service.execute(
                operation: "health.write",
                arguments: Self.rangeArguments,
                authorize: { }
            )
        }
    }

    @Test func readsRequireExplicitISODateRangeAndTimeZone() async {
        let service = AppleDeviceToolService(boundary: RecordingAppleDeviceToolBoundary())
        var arguments = Self.rangeArguments
        arguments.removeValue(forKey: "timeZone")

        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await service.execute(
                operation: "calendar.list",
                arguments: arguments,
                authorize: { }
            )
        }
    }

    @Test func readsRejectRangesLongerThanThirtyOneDays() async {
        let service = AppleDeviceToolService(boundary: RecordingAppleDeviceToolBoundary())
        let arguments: [String: BighelpJSONValue] = [
            "start": .string("2026-01-01T00:00:00Z"),
            "end": .string("2026-02-02T00:00:00Z"),
            "timeZone": .string("America/Chicago"),
        ]

        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await service.execute(
                operation: "calendar.list",
                arguments: arguments,
                authorize: { }
            )
        }
    }

    @Test func readsRejectResultLimitsAboveTwoHundred() async {
        let service = AppleDeviceToolService(boundary: RecordingAppleDeviceToolBoundary())
        var arguments = Self.rangeArguments
        arguments["limit"] = .integer(201)

        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await service.execute(
                operation: "reminders.list",
                arguments: arguments,
                authorize: { }
            )
        }
    }

    @Test func mutationsRequireExactIDAndExpectedRevision() async {
        let service = AppleDeviceToolService(boundary: RecordingAppleDeviceToolBoundary())

        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await service.execute(
                operation: "calendar.update",
                arguments: ["id": .string("event-1")],
                authorize: { }
            )
        }
        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await service.execute(
                operation: "reminders.delete",
                arguments: ["expectedRevision": .string("rev-1")],
                authorize: { }
            )
        }
    }

    @Test func calendarUpdateRejectsNonIncreasingDateRange() async {
        let service = AppleDeviceToolService(boundary: RecordingAppleDeviceToolBoundary())
        let arguments: [String: BighelpJSONValue] = [
            "id": .string("event-1"),
            "expectedRevision": .string("rev-1"),
            "start": .string("2026-09-01T16:00:00Z"),
            "end": .string("2026-09-01T15:00:00Z"),
            "timeZone": .string("America/Chicago"),
        ]

        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await service.execute(operation: "calendar.update", arguments: arguments, authorize: { })
        }
    }

    @Test func calendarUpdateRejectsWrongOptionalFieldTypes() async {
        let service = AppleDeviceToolService(boundary: RecordingAppleDeviceToolBoundary())
        let arguments: [String: BighelpJSONValue] = [
            "id": .string("event-1"),
            "expectedRevision": .string("rev-1"),
            "title": .integer(7),
        ]

        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await service.execute(operation: "calendar.update", arguments: arguments, authorize: { })
        }
    }

    @Test func remindersListAcceptsExplicitCompletionAndUndatedFilters() async throws {
        let boundary = RecordingAppleDeviceToolBoundary()
        boundary.response = [
            "lists": .array([]),
            "items": .array([]),
            "truncated": .boolean(false),
        ]
        let service = AppleDeviceToolService(boundary: boundary)
        let arguments: [String: BighelpJSONValue] = [
            "listIDs": .array([.string("list-1")]),
            "completed": .boolean(true),
            "includeUndated": .boolean(true),
            "limit": .integer(25),
        ]

        _ = try await service.execute(operation: "reminders.list", arguments: arguments, authorize: { })

        #expect(boundary.operations == ["reminders.list"])
        #expect(boundary.argumentHistory == [arguments])
    }

    @Test func remindersListRequiresCompleteDateRangeWhenRangeIsUsed() async {
        let service = AppleDeviceToolService(boundary: RecordingAppleDeviceToolBoundary())
        let arguments: [String: BighelpJSONValue] = [
            "start": .string("2026-09-01T00:00:00Z"),
            "timeZone": .string("America/Chicago"),
        ]

        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await service.execute(operation: "reminders.list", arguments: arguments, authorize: { })
        }
    }

    @Test func calendarRecurringMutationRejectsWholeSeriesSpan() async {
        let service = AppleDeviceToolService(boundary: RecordingAppleDeviceToolBoundary())
        let arguments: [String: BighelpJSONValue] = [
            "id": .string("event-1"),
            "expectedRevision": .string("rev-1"),
            "span": .string("futureEvents"),
        ]

        await #expect(throws: AppleDeviceToolError.unsupportedRecurrence) {
            try await service.execute(
                operation: "calendar.delete",
                arguments: arguments,
                authorize: { }
            )
        }
    }

    @Test func mutationResultRejectsWrongReturnedIdentifier() async {
        let boundary = RecordingAppleDeviceToolBoundary()
        boundary.response = [
            "id": .string("different-event"),
            "revision": .string("rev-2"),
        ]
        let service = AppleDeviceToolService(boundary: boundary)

        await #expect(throws: AppleDeviceToolError.identityMismatch) {
            try await service.execute(
                operation: "calendar.update",
                arguments: [
                    "id": .string("event-1"),
                    "expectedRevision": .string("rev-1"),
                ],
                authorize: { }
            )
        }
    }

    @Test func staleNativeRevisionIsPreservedAsStableError() async {
        let boundary = RecordingAppleDeviceToolBoundary()
        boundary.failure = .staleRevision
        let service = AppleDeviceToolService(boundary: boundary)

        await #expect(throws: AppleDeviceToolError.staleRevision) {
            try await service.execute(
                operation: "reminders.delete",
                arguments: [
                    "id": .string("reminder-1"),
                    "expectedRevision": .string("rev-1"),
                ],
                authorize: { }
            )
        }
    }

    @Test(arguments: [
        "health.read",
        "calendar.list",
        "calendar.create",
        "calendar.update",
        "calendar.delete",
        "reminders.list",
        "reminders.create",
        "reminders.update",
        "reminders.delete",
    ])
    func everyAllowlistedOperationUsesAuthorizationImmediatelyAroundNativeCall(
        _ operation: String
    ) async throws {
        let boundary = RecordingAppleDeviceToolBoundary()
        let service = AppleDeviceToolService(boundary: boundary)
        var sequence: [String] = []

        _ = try await service.execute(
            operation: operation,
            arguments: Self.arguments(for: operation),
            authorize: { sequence.append("authorize") }
        )

        #expect(sequence.count >= 2)
        #expect(sequence.allSatisfy { $0 == "authorize" })
        #expect(boundary.operations == [operation])
    }

    @Test func boundaryReceivesAuthorizationClosureForCommitBoundary() async throws {
        let boundary = RecordingAppleDeviceToolBoundary()
        boundary.invokeAuthorizationDuringExecute = true
        let service = AppleDeviceToolService(boundary: boundary)
        var sequence: [String] = []

        _ = try await service.execute(
            operation: "calendar.update",
            arguments: [
                "id": .string("item-1"),
                "expectedRevision": .string("rev-1"),
            ],
            authorize: { sequence.append("outer") }
        )

        #expect(boundary.receivedAuthorizationClosure)
        #expect(sequence.count >= 3)
        #expect(sequence.allSatisfy { $0 == "outer" })
    }

    @Test func mutationResultsContainOnlySafeIdentityMetadata() async throws {
        let boundary = RecordingAppleDeviceToolBoundary()
        boundary.response = [
            "id": .string("event-1"),
            "revision": .string("rev-2"),
            "title": .string("Private appointment"),
            "notes": .string("Private notes"),
        ]
        let service = AppleDeviceToolService(boundary: boundary)

        let result = try await service.execute(
            operation: "calendar.update",
            arguments: [
                "id": .string("event-1"),
                "expectedRevision": .string("rev-1"),
            ],
            authorize: { }
        )

        #expect(Set(result.keys) == ["id", "revision"])
    }

    @Test func authorizationFailurePreventsNativeCallAndUsesStableError() async {
        let boundary = RecordingAppleDeviceToolBoundary()
        let service = AppleDeviceToolService(boundary: boundary)

        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await service.execute(
                operation: "calendar.list",
                arguments: Self.rangeArguments,
                authorize: { throw TestAuthorizationFailure.denied }
            )
        }

        #expect(boundary.operations.isEmpty)
    }

    @Test func deniedCalendarSystemAccessPreventsNativeCallEvenWithAppGrant() async {
        let boundary = RecordingAppleDeviceToolBoundary()
        boundary.statuses[.calendar] = .denied
        let service = AppleDeviceToolService(boundary: boundary)

        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await service.execute(
                operation: "calendar.list",
                arguments: Self.rangeArguments,
                authorize: { }
            )
        }

        #expect(boundary.operations.isEmpty)
    }

    @Test func deniedReminderSystemAccessPreventsNativeCallEvenWithAppGrant() async {
        let boundary = RecordingAppleDeviceToolBoundary()
        boundary.statuses[.reminders] = .denied
        let service = AppleDeviceToolService(boundary: boundary)

        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await service.execute(
                operation: "reminders.list",
                arguments: Self.rangeArguments,
                authorize: { }
            )
        }

        #expect(boundary.operations.isEmpty)
    }

    private static let rangeArguments: [String: BighelpJSONValue] = [
        "start": .string("2026-09-01T00:00:00Z"),
        "end": .string("2026-09-02T00:00:00Z"),
        "timeZone": .string("America/Chicago"),
    ]

    private static func arguments(for operation: String) -> [String: BighelpJSONValue] {
        switch operation {
        case "health.read", "calendar.list", "reminders.list":
            rangeArguments
        case "calendar.create":
            [
                "title": .string("Meeting"),
                "start": .string("2026-09-01T15:00:00Z"),
                "end": .string("2026-09-01T16:00:00Z"),
                "timeZone": .string("America/Chicago"),
            ]
        case "reminders.create":
            ["title": .string("Task")]
        case "calendar.update", "calendar.delete", "reminders.update", "reminders.delete":
            [
                "id": .string("item-1"),
                "expectedRevision": .string("rev-1"),
            ]
        default:
            [:]
        }
    }
}

/// EventKit's legacy completion is not actor annotated. Reproduce its real
/// background callback without reading or modifying anyone's reminder database.
nonisolated private final class BackgroundReminderEventStore: EKEventStore, @unchecked Sendable {
    override func calendars(for entityType: EKEntityType) -> [EKCalendar] { [] }
    override func predicateForReminders(in calendars: [EKCalendar]?) -> NSPredicate { NSPredicate(value: true) }
    override func fetchReminders(matching predicate: NSPredicate,
                                 completion: @escaping ([EKReminder]?) -> Void) -> Any {
        let callback = ReminderCallback(completion: completion)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let reminder = EKReminder(eventStore: self)
            reminder.isCompleted = false
            callback.completion([reminder])
        }
        return NSObject()
    }

    private struct ReminderCallback: @unchecked Sendable {
        let completion: ([EKReminder]?) -> Void
    }
}

@MainActor
private final class RecordingAppleDeviceToolBoundary: AppleDeviceToolNativeBoundary {
    var statuses: [DeviceToolCapability: DeviceToolSystemAccess] = [
        .health: .available, .calendar: .available, .reminders: .available,
    ]
    var requestResults: [DeviceToolCapability: DeviceToolSystemAccess] = [:]
    var statusRequests: [DeviceToolCapability] = []
    var permissionRequests: [DeviceToolCapability] = []
    var operations: [String] = []
    var argumentHistory: [[String: BighelpJSONValue]] = []
    var response: [String: BighelpJSONValue] = [
        "id": .string("item-1"),
        "revision": .string("rev-2"),
    ]
    var failure: AppleDeviceToolError?
    var receivedAuthorizationClosure = false
    var invokeAuthorizationDuringExecute = false

    func status(for capability: DeviceToolCapability) async -> DeviceToolSystemAccess {
        statusRequests.append(capability)
        return statuses[capability] ?? .notRequested
    }

    func request(_ capability: DeviceToolCapability) async -> DeviceToolSystemAccess {
        permissionRequests.append(capability)
        return requestResults[capability] ?? .notRequested
    }

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        operations.append(operation)
        argumentHistory.append(arguments)
        receivedAuthorizationClosure = true
        if invokeAuthorizationDuringExecute { try authorize() }
        if let failure { throw failure }
        return response
    }
}

private enum TestAuthorizationFailure: Error {
    case denied
}
