@preconcurrency import EventKit
import Foundation
@preconcurrency import HealthKit

@MainActor
protocol AppleDeviceToolNativeBoundary: AnyObject {
    func status(for capability: DeviceToolCapability) async -> DeviceToolSystemAccess
    func request(_ capability: DeviceToolCapability) async -> DeviceToolSystemAccess
    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue]
}

enum AppleDeviceToolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedOperation
    case invalidArguments
    case unsupportedRecurrence
    case identityMismatch
    case staleRevision
    case authorizationRequired
    case unavailable
    case resultLimitExceeded
    case nativeFailure

    var code: String {
        switch self {
        case .unsupportedOperation: "unsupported_operation"
        case .invalidArguments: "invalid_arguments"
        case .unsupportedRecurrence: "unsupported_recurrence"
        case .identityMismatch: "identity_mismatch"
        case .staleRevision: "stale_revision"
        case .authorizationRequired: "authorization_required"
        case .unavailable: "unavailable"
        case .resultLimitExceeded: "result_limit_exceeded"
        case .nativeFailure: "native_failure"
        }
    }

    var errorDescription: String? {
        "The device tool request could not be completed."
    }
}

private struct ReminderFetchResult: Sendable {
    let items: [BighelpJSONValue]
    let totalCount: Int
}

@MainActor
final class AppleDeviceToolService {
    static let commonHealthCatalog: [String] = [
        "step_count",
        "distance_walking_running",
        "active_energy_burned",
        "basal_energy_burned",
        "flights_climbed",
        "apple_exercise_time",
        "apple_stand_time",
        "sleep_analysis",
        "heart_rate",
        "resting_heart_rate",
        "walking_heart_rate_average",
        "heart_rate_variability_sdnn",
        "oxygen_saturation",
        "respiratory_rate",
        "blood_pressure_systolic",
        "blood_pressure_diastolic",
        "height",
        "body_mass",
        "body_mass_index",
        "lean_body_mass",
        "body_fat_percentage",
        "workout",
    ]

    private static let operations: Set<String> = [
        "health.read",
        "calendar.list", "calendar.create", "calendar.update", "calendar.delete",
        "reminders.list", "reminders.create", "reminders.update", "reminders.delete",
        "location.current",
    ]

    private let boundary: any AppleDeviceToolNativeBoundary

    convenience init() {
        self.init(boundary: LiveAppleDeviceToolNativeBoundary())
    }

    init(boundary: any AppleDeviceToolNativeBoundary) {
        self.boundary = boundary
    }

    func status(_ kind: DeviceToolCapability) async -> DeviceToolSystemAccess {
        await boundary.status(for: kind)
    }

    func request(_ kind: DeviceToolCapability) async -> DeviceToolSystemAccess {
        await boundary.request(kind)
    }

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        guard Self.operations.contains(operation) else {
            throw AppleDeviceToolError.unsupportedOperation
        }
        let mutation = operation.hasSuffix(".create")
            || operation.hasSuffix(".update")
            || operation.hasSuffix(".delete")
        try Self.validate(operation: operation, arguments: arguments)
        let guardedAuthorize: @MainActor () throws -> Void = {
            do { try authorize() }
            catch { throw AppleDeviceToolError.authorizationRequired }
        }
        do {
            try guardedAuthorize()
            if let capability = Self.capability(for: operation) {
                switch capability {
                case .health:
                    // HealthKit read authorization is intentionally opaque;
                    // never infer a read grant from a status probe.
                    break
                case .calendar, .reminders, .location:
                    let access = await boundary.status(for: capability)
                    switch access {
                    case .available:
                        break
                    case .unavailable:
                        throw AppleDeviceToolError.unavailable
                    case .notRequested, .managedByHealth, .denied:
                        throw AppleDeviceToolError.authorizationRequired
                    }
                    try guardedAuthorize()
                }
            }
            let result = try await boundary.execute(
                operation: operation,
                arguments: arguments,
                authorize: guardedAuthorize
            )
            try guardedAuthorize()
            if mutation {
                return try Self.sanitizeMutationResult(operation: operation, arguments: arguments, result: result)
            }
            try Self.validateReadResult(result: result)
            if operation == "health.read" {
                return Self.enrichHealthCoverage(arguments: arguments, result: result)
            }
            return result
        } catch let error as AppleDeviceToolError {
            throw error
        } catch {
            throw AppleDeviceToolError.nativeFailure
        }
    }
}

private extension AppleDeviceToolService {
    static func validate(
        operation: String,
        arguments: [String: BighelpJSONValue]
    ) throws {
        switch operation {
        case "health.read":
            try validateRange(arguments, allowed: ["start", "end", "timeZone", "types", "limit"])
            if let types = arguments["types"] {
                guard let values = types.array,
                      !values.isEmpty,
                      values.count <= commonHealthCatalog.count,
                      values.allSatisfy({ value in
                          guard let value = value.string else { return false }
                          return commonHealthCatalog.contains(value)
                      }) else { throw AppleDeviceToolError.invalidArguments }
            }
        case "calendar.list":
            try validateRange(arguments, allowed: ["start", "end", "timeZone", "calendarIDs", "limit"])
            try validateStringArray(arguments["calendarIDs"])
        case "reminders.list":
            try validateKeys(arguments, allowed: [
                "start", "end", "timeZone", "listIDs", "limit", "completed", "includeUndated",
            ])
            try validateOptionalRange(arguments)
            try validateStringArray(arguments["listIDs"])
            try validateOptionalBool(arguments, key: "completed")
            try validateOptionalBool(arguments, key: "includeUndated")
        case "calendar.create":
            try validateKeys(arguments, allowed: [
                "title", "start", "end", "timeZone", "calendarID", "location", "notes", "url", "span",
            ])
            try requireString(arguments, key: "title")
            try validateDate(arguments, key: "start")
            try validateDate(arguments, key: "end")
            try validateDatePair(arguments, startKey: "start", endKey: "end")
            try validateTimeZone(arguments)
            try validateOptionalString(arguments, key: "calendarID", allowNull: false)
            try validateOptionalString(arguments, key: "location")
            try validateOptionalString(arguments, key: "notes")
            try validateOptionalURL(arguments, key: "url")
            try validateThisEventSpan(arguments)
        case "reminders.create":
            try validateKeys(arguments, allowed: [
                "title", "listID", "dueDate", "startDate", "timeZone", "notes", "priority",
            ])
            try requireString(arguments, key: "title")
            try validateOptionalString(arguments, key: "listID", allowNull: false)
            try validateOptionalDate(arguments, key: "dueDate")
            try validateOptionalDate(arguments, key: "startDate")
            if arguments["dueDate"] != nil || arguments["startDate"] != nil {
                try validateTimeZone(arguments)
            }
            try validateOptionalString(arguments, key: "notes")
            try validatePriority(arguments)
        case "calendar.update":
            try validateKeys(arguments, allowed: [
                "id", "expectedRevision", "title", "start", "end", "timeZone", "location", "notes", "url", "span", "occurrenceStart",
            ])
            try validateIdentity(arguments)
            try validateThisEventSpan(arguments)
            try validateOptionalDate(arguments, key: "occurrenceStart")
            if arguments["start"] != nil { try validateDate(arguments, key: "start") }
            if arguments["end"] != nil { try validateDate(arguments, key: "end") }
            try validateOptionalString(arguments, key: "title", allowNull: false)
            try validateOptionalString(arguments, key: "location")
            try validateOptionalString(arguments, key: "notes")
            try validateOptionalURL(arguments, key: "url")
            try validateDatePairIfPresent(arguments, startKey: "start", endKey: "end")
            if arguments["start"] != nil || arguments["end"] != nil { try validateTimeZone(arguments) }
        case "calendar.delete":
            try validateKeys(arguments, allowed: ["id", "expectedRevision", "span", "occurrenceStart"])
            try validateIdentity(arguments)
            try validateThisEventSpan(arguments)
            try validateOptionalDate(arguments, key: "occurrenceStart")
        case "reminders.update":
            try validateKeys(arguments, allowed: [
                "id", "expectedRevision", "title", "dueDate", "startDate", "timeZone", "notes", "priority", "completed",
            ])
            try validateIdentity(arguments)
            try validateOptionalString(arguments, key: "title", allowNull: false)
            try validateOptionalDate(arguments, key: "dueDate")
            try validateOptionalDate(arguments, key: "startDate")
            if arguments["dueDate"] != nil || arguments["startDate"] != nil { try validateTimeZone(arguments) }
            try validateOptionalString(arguments, key: "notes")
            try validatePriority(arguments)
            try validateOptionalBool(arguments, key: "completed")
        case "reminders.delete":
            try validateKeys(arguments, allowed: ["id", "expectedRevision"])
            try validateIdentity(arguments)
        case "location.current":
            // Where the phone is now; there's nothing for the agent to choose.
            try validateKeys(arguments, allowed: [])
        default:
            throw AppleDeviceToolError.unsupportedOperation
        }
    }

    static func capability(for operation: String) -> DeviceToolCapability? {
        switch operation {
        case "health.read": .health
        case "calendar.list", "calendar.create", "calendar.update", "calendar.delete": .calendar
        case "reminders.list", "reminders.create", "reminders.update", "reminders.delete": .reminders
        case "location.current": .location
        default: nil
        }
    }

    static func validateKeys(_ arguments: [String: BighelpJSONValue], allowed: Set<String>) throws {
        guard Set(arguments.keys).isSubset(of: allowed) else {
            throw AppleDeviceToolError.invalidArguments
        }
    }

    static func validateRange(
        _ arguments: [String: BighelpJSONValue],
        allowed: Set<String>
    ) throws {
        try validateKeys(arguments, allowed: allowed)
        let start = try parseDate(arguments, key: "start")
        let end = try parseDate(arguments, key: "end")
        guard end > start, end.timeIntervalSince(start) <= 31 * 24 * 60 * 60 else {
            throw AppleDeviceToolError.invalidArguments
        }
        try validateTimeZone(arguments)
        if let limit = arguments["limit"] {
            guard let limit = limit.integer, (1...200).contains(limit) else {
                throw AppleDeviceToolError.invalidArguments
            }
        }
    }

    static func validateOptionalRange(_ arguments: [String: BighelpJSONValue]) throws {
        let hasStart = arguments["start"] != nil
        let hasEnd = arguments["end"] != nil
        let hasTimeZone = arguments["timeZone"] != nil
        guard hasStart == hasEnd, hasEnd == hasTimeZone else {
            throw AppleDeviceToolError.invalidArguments
        }
        if hasStart {
            let start = try parseDate(arguments, key: "start")
            let end = try parseDate(arguments, key: "end")
            guard end > start, end.timeIntervalSince(start) <= 31 * 24 * 60 * 60 else {
                throw AppleDeviceToolError.invalidArguments
            }
            try validateTimeZone(arguments)
        }
        if let limit = arguments["limit"] {
            guard let limit = limit.integer, (1...200).contains(limit) else {
                throw AppleDeviceToolError.invalidArguments
            }
        }
    }

    static func validateDatePair(
        _ arguments: [String: BighelpJSONValue],
        startKey: String,
        endKey: String
    ) throws {
        let start = try parseDate(arguments, key: startKey)
        let end = try parseDate(arguments, key: endKey)
        guard end > start else { throw AppleDeviceToolError.invalidArguments }
    }

    static func validateDatePairIfPresent(
        _ arguments: [String: BighelpJSONValue],
        startKey: String,
        endKey: String
    ) throws {
        guard arguments[startKey] != nil || arguments[endKey] != nil else { return }
        guard arguments[startKey] != nil, arguments[endKey] != nil else {
            return
        }
        try validateDatePair(arguments, startKey: startKey, endKey: endKey)
    }

    static func validateOptionalString(
        _ arguments: [String: BighelpJSONValue],
        key: String,
        allowNull: Bool = false
    ) throws {
        guard let value = arguments[key] else { return }
        switch value {
        case .string(let string):
            guard string.count <= 4_000 else { throw AppleDeviceToolError.invalidArguments }
        case .null where allowNull:
            break
        default:
            throw AppleDeviceToolError.invalidArguments
        }
    }

    static func validateOptionalDate(
        _ arguments: [String: BighelpJSONValue],
        key: String
    ) throws {
        guard arguments[key] != nil else { return }
        try validateDate(arguments, key: key)
    }

    static func validateOptionalURL(
        _ arguments: [String: BighelpJSONValue],
        key: String
    ) throws {
        guard let value = arguments[key] else { return }
        guard let string = value.string, string.count <= 4_000, URL(string: string) != nil else {
            throw AppleDeviceToolError.invalidArguments
        }
    }

    static func validateOptionalBool(
        _ arguments: [String: BighelpJSONValue],
        key: String
    ) throws {
        guard let value = arguments[key] else { return }
        guard value.boolean != nil else { throw AppleDeviceToolError.invalidArguments }
    }

    static func validateStringArray(_ value: BighelpJSONValue?) throws {
        guard let value else { return }
        guard let values = value.array,
              !values.isEmpty,
              values.count <= 50,
              values.allSatisfy({
                  guard let value = $0.string else { return false }
                  return !value.isEmpty && value.count <= 512
              }) else { throw AppleDeviceToolError.invalidArguments }
    }

    static func validateIdentity(_ arguments: [String: BighelpJSONValue]) throws {
        guard let id = arguments["id"]?.string, !id.isEmpty, id.count <= 512,
              let revision = arguments["expectedRevision"]?.string, !revision.isEmpty, revision.count <= 512
        else { throw AppleDeviceToolError.invalidArguments }
    }

    static func validateThisEventSpan(_ arguments: [String: BighelpJSONValue]) throws {
        guard let span = arguments["span"] else { return }
        guard span.string == "thisEvent" else { throw AppleDeviceToolError.unsupportedRecurrence }
    }

    static func validatePriority(_ arguments: [String: BighelpJSONValue]) throws {
        guard let priority = arguments["priority"] else { return }
        guard let priority = priority.integer, (0...9).contains(priority) else {
            throw AppleDeviceToolError.invalidArguments
        }
    }

    static func requireString(_ arguments: [String: BighelpJSONValue], key: String) throws {
        guard let value = arguments[key]?.string, !value.isEmpty, value.count <= 4_000 else {
            throw AppleDeviceToolError.invalidArguments
        }
    }

    static func validateDate(_ arguments: [String: BighelpJSONValue], key: String) throws {
        _ = try parseDate(arguments, key: key)
    }

    static func parseDate(_ arguments: [String: BighelpJSONValue], key: String) throws -> Date {
        guard let raw = arguments[key]?.string, let date = parseISO8601(raw) else {
            throw AppleDeviceToolError.invalidArguments
        }
        return date
    }

    static func validateTimeZone(_ arguments: [String: BighelpJSONValue]) throws {
        guard let identifier = arguments["timeZone"]?.string,
              TimeZone(identifier: identifier) != nil else {
            throw AppleDeviceToolError.invalidArguments
        }
    }

    static func sanitizeMutationResult(
        operation: String,
        arguments: [String: BighelpJSONValue],
        result: [String: BighelpJSONValue]
    ) throws -> [String: BighelpJSONValue] {
        guard let id = result["id"]?.string, !id.isEmpty,
              let revision = result["revision"]?.string, !revision.isEmpty else {
            throw AppleDeviceToolError.nativeFailure
        }
        if let expected = arguments["id"]?.string, expected != id {
            throw AppleDeviceToolError.identityMismatch
        }
        var safe: [String: BighelpJSONValue] = [
            "id": .string(id),
            "revision": .string(revision),
        ]
        if let deleted = result["deleted"]?.boolean {
            safe["deleted"] = .boolean(deleted)
        } else if operation.hasSuffix(".delete") {
            safe["deleted"] = .boolean(true)
        }
        return safe
    }

    static func validateReadResult(result: [String: BighelpJSONValue]) throws {
        if let items = result["items"]?.array, items.count > 200 {
            throw AppleDeviceToolError.resultLimitExceeded
        }
    }

    static func enrichHealthCoverage(
        arguments: [String: BighelpJSONValue],
        result: [String: BighelpJSONValue]
    ) -> [String: BighelpJSONValue] {
        var enriched = result
        let items = result["items"]?.array ?? []
        let limit = arguments["limit"]?.integer ?? 200
        let truncated = result["truncated"]?.boolean ?? (items.count >= limit)
        enriched["coverage"] = .object([
            "start": arguments["start"] ?? .null,
            "end": arguments["end"] ?? .null,
            "timeZone": arguments["timeZone"] ?? .null,
            "limit": .integer(limit),
            "returnedCount": .integer(items.count),
            "truncated": .boolean(truncated),
            "aggregation": .string("raw_samples"),
        ])
        return enriched
    }

    nonisolated static var iso8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    nonisolated static func parseISO8601(_ raw: String) -> Date? {
        if let date = iso8601.date(from: raw) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

@MainActor
final class LiveAppleDeviceToolNativeBoundary: AppleDeviceToolNativeBoundary {
    private let healthStore: HKHealthStore
    private let eventStore: EKEventStore
    private let location: DeviceLocationTool

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        eventStore: EKEventStore = EKEventStore(),
        location: DeviceLocationTool? = nil
    ) {
        self.healthStore = healthStore
        self.eventStore = eventStore
        self.location = location ?? DeviceLocationTool(provider: LiveDeviceLocationProvider())
    }

    func status(for capability: DeviceToolCapability) async -> DeviceToolSystemAccess {
        switch capability {
        case .health: await healthStatus()
        case .calendar: eventKitStatus(.event)
        case .reminders: eventKitStatus(.reminder)
        case .location: await location.status()
        }
    }

    func request(_ capability: DeviceToolCapability) async -> DeviceToolSystemAccess {
        switch capability {
        case .health: await requestHealth()
        case .calendar: await requestFullCalendarAccess()
        case .reminders: await requestFullReminderAccess()
        case .location: await location.request()
        }
    }

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        switch operation {
        case "health.read": try await readHealth(arguments, authorize: authorize)
        case "calendar.list": try await listCalendarEvents(arguments, authorize: authorize)
        case "calendar.create": try createCalendarEvent(arguments, authorize: authorize)
        case "calendar.update": try updateCalendarEvent(arguments, authorize: authorize)
        case "calendar.delete": try deleteCalendarEvent(arguments, authorize: authorize)
        case "reminders.list": try await listReminders(arguments, authorize: authorize)
        case "reminders.create": try createReminder(arguments, authorize: authorize)
        case "reminders.update": try updateReminder(arguments, authorize: authorize)
        case "reminders.delete": try deleteReminder(arguments, authorize: authorize)
        case "location.current": try await location.current(authorize: authorize)
        default: throw AppleDeviceToolError.unsupportedOperation
        }
    }
}

private extension LiveAppleDeviceToolNativeBoundary {
    static let quantityIdentifiers: [String: HKQuantityTypeIdentifier] = [
        "step_count": .stepCount,
        "distance_walking_running": .distanceWalkingRunning,
        "active_energy_burned": .activeEnergyBurned,
        "basal_energy_burned": .basalEnergyBurned,
        "flights_climbed": .flightsClimbed,
        "apple_exercise_time": .appleExerciseTime,
        "apple_stand_time": .appleStandTime,
        "heart_rate": .heartRate,
        "resting_heart_rate": .restingHeartRate,
        "walking_heart_rate_average": .walkingHeartRateAverage,
        "heart_rate_variability_sdnn": .heartRateVariabilitySDNN,
        "oxygen_saturation": .oxygenSaturation,
        "respiratory_rate": .respiratoryRate,
        "blood_pressure_systolic": .bloodPressureSystolic,
        "blood_pressure_diastolic": .bloodPressureDiastolic,
        "height": .height,
        "body_mass": .bodyMass,
        "body_mass_index": .bodyMassIndex,
        "lean_body_mass": .leanBodyMass,
        "body_fat_percentage": .bodyFatPercentage,
    ]

    func healthTypes(_ names: [String]) -> Set<HKObjectType> {
        var result = Set<HKObjectType>()
        for name in names {
            if let identifier = Self.quantityIdentifiers[name],
               let type = HKObjectType.quantityType(forIdentifier: identifier) {
                result.insert(type)
            } else if name == "sleep_analysis",
                      let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
                result.insert(type)
            } else if name == "workout" {
                result.insert(HKObjectType.workoutType())
            }
        }
        return result
    }

    func healthStatus() async -> DeviceToolSystemAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let status = await withCheckedContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(
                toShare: Set<HKSampleType>(),
                read: healthTypes(AppleDeviceToolService.commonHealthCatalog)
            ) { requestStatus, error in
                if error != nil {
                    continuation.resume(returning: DeviceToolSystemAccess.unavailable)
                } else if requestStatus == .shouldRequest {
                    continuation.resume(returning: DeviceToolSystemAccess.notRequested)
                } else {
                    continuation.resume(returning: DeviceToolSystemAccess.managedByHealth)
                }
            }
        }
        return status
    }

    func requestHealth() async -> DeviceToolSystemAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        return await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(
                toShare: Set<HKSampleType>(),
                read: healthTypes(AppleDeviceToolService.commonHealthCatalog)
            ) { _, error in
                continuation.resume(returning: error == nil ? .managedByHealth : .unavailable)
            }
        }
    }

    func eventKitStatus(_ entityType: EKEntityType) -> DeviceToolSystemAccess {
        switch EKEventStore.authorizationStatus(for: entityType) {
        case .notDetermined: .notRequested
        case .fullAccess: .available
        case .writeOnly, .denied: .denied
        case .restricted: .unavailable
        @unknown default: .unavailable
        }
    }

    func requestFullCalendarAccess() async -> DeviceToolSystemAccess {
        do {
            return try await eventStore.requestFullAccessToEvents() ? .available : .denied
        } catch { return .unavailable }
    }

    func requestFullReminderAccess() async -> DeviceToolSystemAccess {
        do {
            return try await eventStore.requestFullAccessToReminders() ? .available : .denied
        } catch { return .unavailable }
    }

    func readHealth(
        _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        let start = try date(arguments, key: "start")
        let end = try date(arguments, key: "end")
        let timeZone = try timeZone(arguments)
        let names = arguments["types"]?.array?.compactMap(\.string)
            ?? AppleDeviceToolService.commonHealthCatalog
        let limit = arguments["limit"]?.integer ?? 200
        var items: [BighelpJSONValue] = []
        var remaining = limit

        for name in names where remaining > 0 {
            let samples = try await queryHealthSamples(
                name: name,
                start: start,
                end: end,
                limit: remaining,
                timeZone: timeZone,
                authorize: authorize
            )
            for sample in samples {
                guard remaining > 0 else { break }
                items.append(sample)
                remaining -= 1
            }
        }
        return [
            "items": .array(items),
            "truncated": .boolean(remaining == 0),
            "coverage": .object([
                "start": arguments["start"] ?? .null,
                "end": arguments["end"] ?? .null,
                "timeZone": arguments["timeZone"] ?? .null,
                "limit": .integer(limit),
                "returnedCount": .integer(items.count),
                "truncated": .boolean(remaining == 0),
                "aggregation": .string("raw_samples"),
            ]),
        ]
    }

    func queryHealthSamples(
        name: String,
        start: Date,
        end: Date,
        limit: Int,
        timeZone: TimeZone,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [BighelpJSONValue] {
        guard let sampleType = sampleType(for: name) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        try authorize()
        let items = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[BighelpJSONValue], Error>) in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                do {
                    if let error { throw error }
                    let items = try (samples ?? []).map {
                        try LiveAppleDeviceToolNativeBoundary.healthItem($0, name: name, timeZone: timeZone)
                    }
                    continuation.resume(returning: items)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            healthStore.execute(query)
        }
        try authorize()
        return items
    }

    func sampleType(for name: String) -> HKSampleType? {
        if let identifier = Self.quantityIdentifiers[name] {
            return HKObjectType.quantityType(forIdentifier: identifier)
        }
        if name == "sleep_analysis" {
            return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        }
        if name == "workout" { return HKObjectType.workoutType() }
        return nil
    }

    nonisolated static func healthItem(
        _ sample: HKSample,
        name: String,
        timeZone: TimeZone
    ) throws -> BighelpJSONValue {
        var item: [String: BighelpJSONValue] = [
            "type": .string(name),
            "start": .string(Self.iso(sample.startDate, timeZone: timeZone)),
            "end": .string(Self.iso(sample.endDate, timeZone: timeZone)),
        ]
        if let quantitySample = sample as? HKQuantitySample {
            guard let unit = Self.unit(for: name) else { throw AppleDeviceToolError.nativeFailure }
            item["value"] = .number(quantitySample.quantity.doubleValue(for: unit))
            item["unit"] = .string(unit.description)
        } else if let categorySample = sample as? HKCategorySample {
            item["value"] = .string(Self.sleepValue(categorySample.value))
        } else if let workout = sample as? HKWorkout {
            item["activityType"] = .integer(Int(workout.workoutActivityType.rawValue))
            item["duration"] = .number(workout.duration)
            if let energy = workout.totalEnergyBurned {
                item["activeEnergyKilocalories"] = .number(energy.doubleValue(for: .kilocalorie()))
            }
            if let distance = workout.totalDistance {
                item["distanceMeters"] = .number(distance.doubleValue(for: .meter()))
            }
        }
        return .object(item)
    }

    nonisolated static func unit(for name: String) -> HKUnit? {
        switch name {
        case "step_count", "flights_climbed", "body_mass_index": .count()
        case "distance_walking_running": .meter()
        case "active_energy_burned", "basal_energy_burned": .kilocalorie()
        case "apple_exercise_time", "apple_stand_time": .minute()
        case "heart_rate", "resting_heart_rate", "walking_heart_rate_average", "respiratory_rate":
            .count().unitDivided(by: .minute())
        case "heart_rate_variability_sdnn": .secondUnit(with: .milli)
        case "oxygen_saturation", "body_fat_percentage": .percent()
        case "blood_pressure_systolic", "blood_pressure_diastolic": .millimeterOfMercury()
        case "height": .meter()
        case "body_mass", "lean_body_mass": .gramUnit(with: .kilo)
        default: nil
        }
    }

    nonisolated static func sleepValue(_ rawValue: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
        case .inBed: "inBed"
        case .awake: "awake"
        case .asleepCore: "asleepCore"
        case .asleepDeep: "asleepDeep"
        case .asleepREM: "asleepREM"
        case .asleepUnspecified: "asleepUnspecified"
        default: "unknown"
        }
    }

    func listCalendarEvents(
        _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        let start = try date(arguments, key: "start")
        let end = try date(arguments, key: "end")
        let timeZone = try timeZone(arguments)
        let calendars = try selectedCalendars(arguments["calendarIDs"], entityType: .event, authorize: authorize)
        try authorize()
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = eventStore.events(matching: predicate)
        try authorize()
        let limit = arguments["limit"]?.integer ?? 200
        let items = events.sorted { $0.startDate < $1.startDate }.prefix(limit).compactMap {
            eventItem($0, timeZone: timeZone)
        }
        return [
            "calendars": .array(calendarsMetadata(entityType: .event, calendars: calendars)),
            "items": .array(items),
            "truncated": .boolean(events.count > limit),
        ]
    }

    func createCalendarEvent(
        _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        let event = EKEvent(eventStore: eventStore)
        event.title = try string(arguments, key: "title")
        event.startDate = try date(arguments, key: "start")
        event.endDate = try date(arguments, key: "end")
        event.timeZone = try timeZone(arguments)
        // Destination lookup is an EventKit read and must be covered by the
        // app-level grant immediately before it occurs.
        try authorize()
        if let calendarID = arguments["calendarID"]?.string {
            let eventCalendars = eventStore.calendars(for: .event)
            guard let calendar = eventCalendars.first(where: { $0.calendarIdentifier == calendarID }) else {
                throw AppleDeviceToolError.identityMismatch
            }
            event.calendar = calendar
        } else {
            guard let calendar = eventStore.defaultCalendarForNewEvents else {
                throw AppleDeviceToolError.unavailable
            }
            event.calendar = calendar
        }
        event.location = arguments["location"]?.string
        event.notes = arguments["notes"]?.string
        if let url = arguments["url"]?.string { event.url = URL(string: url) }
        try authorize()
        do { try eventStore.save(event, span: .thisEvent, commit: true) }
        catch { throw AppleDeviceToolError.nativeFailure }
        return mutationMetadata(id: event.eventIdentifier, revision: Self.revision(event))
    }

    func updateCalendarEvent(
        _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        let id = try string(arguments, key: "id")
        let event = try eventForMutation(
            id: id,
            occurrenceStart: arguments["occurrenceStart"]?.string,
            authorize: authorize
        )
        try verifyRevision(arguments, item: event)
        if let title = arguments["title"]?.string { event.title = title }
        if arguments["start"] != nil { event.startDate = try date(arguments, key: "start") }
        if arguments["end"] != nil { event.endDate = try date(arguments, key: "end") }
        if arguments["timeZone"] != nil { event.timeZone = try timeZone(arguments) }
        if let location = arguments["location"]?.string { event.location = location }
        if let notes = arguments["notes"]?.string { event.notes = notes }
        if let url = arguments["url"]?.string { event.url = URL(string: url) }
        guard event.endDate > event.startDate else {
            throw AppleDeviceToolError.invalidArguments
        }
        try authorize()
        do { try eventStore.save(event, span: .thisEvent, commit: true) }
        catch { throw AppleDeviceToolError.nativeFailure }
        return mutationMetadata(id: event.eventIdentifier, revision: Self.revision(event))
    }

    func deleteCalendarEvent(
        _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        let id = try string(arguments, key: "id")
        let event = try eventForMutation(
            id: id,
            occurrenceStart: arguments["occurrenceStart"]?.string,
            authorize: authorize
        )
        try verifyRevision(arguments, item: event)
        try authorize()
        do { try eventStore.remove(event, span: .thisEvent, commit: true) }
        catch { throw AppleDeviceToolError.nativeFailure }
        return [
            "id": .string(id),
            "revision": arguments["expectedRevision"] ?? .string("deleted"),
            "deleted": .boolean(true),
        ]
    }

    func listReminders(
        _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        let start = arguments["start"].flatMap { Self.parseISO8601($0.string ?? "") }
        let end = arguments["end"].flatMap { Self.parseISO8601($0.string ?? "") }
        let timeZone = arguments["timeZone"]?.string.flatMap(TimeZone.init(identifier:)) ?? .current
        let completed = arguments["completed"]?.boolean
        let includeUndated = arguments["includeUndated"]?.boolean ?? false
        let limit = arguments["limit"]?.integer ?? 200
        let calendars = try selectedCalendars(arguments["listIDs"], entityType: .reminder, authorize: authorize)
        let predicate = eventStore.predicateForReminders(in: calendars)
        try authorize()
        let fetched: ReminderFetchResult = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ReminderFetchResult, Error>) in
            // EventKit invokes this legacy callback on its own queue. An
            // explicit Sendable closure prevents MainActor inheritance (and
            // its runtime trap); only immutable Sendable results cross back.
            eventStore.fetchReminders(matching: predicate) { @Sendable reminders in
                let reminders = (reminders ?? []).filter {
                    Self.reminderMatches(
                        $0,
                        start: start,
                        end: end,
                        completed: completed,
                        includeUndated: includeUndated
                    )
                }
                let items = reminders.prefix(limit + 1).compactMap {
                    LiveAppleDeviceToolNativeBoundary.reminderItem($0, timeZone: timeZone)
                }
                continuation.resume(returning: ReminderFetchResult(items: items, totalCount: reminders.count))
            }
        }
        try authorize()
        let items = Array(fetched.items.prefix(limit))
        return [
            "lists": .array(calendarsMetadata(entityType: .reminder, calendars: calendars)),
            "items": .array(items),
            "truncated": .boolean(fetched.totalCount > limit),
        ]
    }

    func createReminder(
        _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = try string(arguments, key: "title")
        // Destination lookup is an EventKit read and must be covered by the
        // app-level grant immediately before it occurs.
        try authorize()
        if let listID = arguments["listID"]?.string {
            let reminderCalendars = eventStore.calendars(for: .reminder)
            guard let calendar = reminderCalendars.first(where: { $0.calendarIdentifier == listID }) else {
                throw AppleDeviceToolError.identityMismatch
            }
            reminder.calendar = calendar
        } else {
            guard let calendar = eventStore.defaultCalendarForNewReminders() else {
                throw AppleDeviceToolError.unavailable
            }
            reminder.calendar = calendar
        }
        if let dueDate = arguments["dueDate"]?.string {
            reminder.dueDateComponents = components(for: try parseDate(dueDate), timeZone: try timeZone(arguments))
        }
        if let startDate = arguments["startDate"]?.string {
            reminder.startDateComponents = components(for: try parseDate(startDate), timeZone: try timeZone(arguments))
        }
        reminder.notes = arguments["notes"]?.string
        if let priority = arguments["priority"]?.integer { reminder.priority = priority }
        try authorize()
        do { try eventStore.save(reminder, commit: true) }
        catch { throw AppleDeviceToolError.nativeFailure }
        return mutationMetadata(id: reminder.calendarItemIdentifier, revision: Self.revision(reminder))
    }

    func updateReminder(
        _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        let id = try string(arguments, key: "id")
        try authorize()
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AppleDeviceToolError.identityMismatch
        }
        try verifyRevision(arguments, item: reminder)
        if let title = arguments["title"]?.string { reminder.title = title }
        if let dueDate = arguments["dueDate"]?.string {
            reminder.dueDateComponents = components(for: try parseDate(dueDate), timeZone: try timeZone(arguments))
        }
        if let startDate = arguments["startDate"]?.string {
            reminder.startDateComponents = components(for: try parseDate(startDate), timeZone: try timeZone(arguments))
        }
        if let notes = arguments["notes"]?.string { reminder.notes = notes }
        if let priority = arguments["priority"]?.integer { reminder.priority = priority }
        if let completed = arguments["completed"]?.boolean { reminder.isCompleted = completed }
        try authorize()
        do { try eventStore.save(reminder, commit: true) }
        catch { throw AppleDeviceToolError.nativeFailure }
        return mutationMetadata(id: reminder.calendarItemIdentifier, revision: Self.revision(reminder))
    }

    func deleteReminder(
        _ arguments: [String: BighelpJSONValue],
        authorize: @escaping @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        let id = try string(arguments, key: "id")
        try authorize()
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AppleDeviceToolError.identityMismatch
        }
        try verifyRevision(arguments, item: reminder)
        try authorize()
        do { try eventStore.remove(reminder, commit: true) }
        catch { throw AppleDeviceToolError.nativeFailure }
        return [
            "id": .string(id),
            "revision": arguments["expectedRevision"] ?? .string("deleted"),
            "deleted": .boolean(true),
        ]
    }

    func eventForMutation(
        id: String,
        occurrenceStart: String?,
        authorize: @escaping @MainActor () throws -> Void
    ) throws -> EKEvent {
        // EventKit documents that event(withIdentifier:) resolves the first
        // occurrence for a recurring series. Refuse that ambiguity unless the
        // caller supplies the occurrence's original start date.
        try authorize()
        guard let seed = eventStore.event(withIdentifier: id) else {
            throw AppleDeviceToolError.identityMismatch
        }
        guard let occurrenceStart else {
            guard seed.recurrenceRules?.isEmpty != false else {
                throw AppleDeviceToolError.identityMismatch
            }
            return seed
        }
        let target = try parseDate(occurrenceStart)
        guard let seedStartDate = seed.startDate else {
            throw AppleDeviceToolError.identityMismatch
        }
        if seed.recurrenceRules?.isEmpty != false {
            guard abs(seedStartDate.timeIntervalSince(target)) < 1 else {
                throw AppleDeviceToolError.identityMismatch
            }
            return seed
        }
        guard let seedEndDate = seed.endDate else {
            throw AppleDeviceToolError.identityMismatch
        }
        let duration = max(seedEndDate.timeIntervalSince(seedStartDate), 1)
        let start = target.addingTimeInterval(-1)
        let end = target.addingTimeInterval(duration + 1)
        try authorize()
        let candidates = eventStore.events(
            matching: eventStore.predicateForEvents(
                withStart: start,
                end: end,
                calendars: [seed.calendar]
            )
        )
        let externalID = seed.calendarItemExternalIdentifier
        guard let exact = candidates.first(where: { candidate in
            guard let candidateStart = candidate.startDate else { return false }
            let candidateOccurrence = candidate.occurrenceDate ?? candidateStart
            guard abs(candidateOccurrence.timeIntervalSince(target)) < 1 else { return false }
            if candidate.eventIdentifier == id { return true }
            return externalID != nil && candidate.calendarItemExternalIdentifier == externalID
        }) else {
            throw AppleDeviceToolError.identityMismatch
        }
        return exact
    }

    func selectedCalendars(
        _ value: BighelpJSONValue?,
        entityType: EKEntityType,
        authorize: @escaping @MainActor () throws -> Void
    ) throws -> [EKCalendar] {
        try authorize()
        let all = eventStore.calendars(for: entityType)
        guard let value else { return all }
        guard let ids = value.array?.compactMap(\.string), ids.count == value.array?.count else {
            throw AppleDeviceToolError.invalidArguments
        }
        let selected = ids.compactMap { id in
            all.first(where: { $0.calendarIdentifier == id })
        }
        guard selected.count == ids.count else {
            throw AppleDeviceToolError.identityMismatch
        }
        return selected
    }

    func calendarsMetadata(entityType: EKEntityType, calendars: [EKCalendar]) -> [BighelpJSONValue] {
        calendars.map {
            .object([
                "id": .string($0.calendarIdentifier),
                "title": .string($0.title),
                "entity": .string(entityType == .event ? "calendar" : "list"),
                "modifiable": .boolean($0.allowsContentModifications),
            ])
        }
    }

    func eventItem(_ event: EKEvent, timeZone: TimeZone) -> BighelpJSONValue? {
        guard let id = event.eventIdentifier else { return nil }
        var item: [String: BighelpJSONValue] = [
            "id": .string(id),
            "revision": .string(Self.revision(event)),
            "title": .string(event.title ?? ""),
            "start": .string(Self.iso(event.startDate, timeZone: timeZone)),
            "end": .string(Self.iso(event.endDate, timeZone: timeZone)),
            "occurrenceStart": .string(Self.iso(event.occurrenceDate ?? event.startDate, timeZone: timeZone)),
            "recurring": .boolean(event.recurrenceRules?.isEmpty == false),
            "allDay": .boolean(event.isAllDay),
            "calendarID": .string(event.calendar.calendarIdentifier),
        ]
        if let location = event.location { item["location"] = .string(location) }
        if let notes = event.notes { item["notes"] = .string(notes) }
        return .object(item)
    }

    nonisolated static func reminderMatches(
        _ reminder: EKReminder,
        start: Date?,
        end: Date?,
        completed: Bool?,
        includeUndated: Bool
    ) -> Bool {
        if let completed, reminder.isCompleted != completed { return false }
        guard let start, let end else { return true }
        guard let due = reminder.dueDateComponents else { return includeUndated }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = due.timeZone ?? .current
        guard let date = calendar.date(from: due) else { return includeUndated }
        return date >= start && date < end
    }

    nonisolated static func reminderItem(_ reminder: EKReminder, timeZone: TimeZone) -> BighelpJSONValue? {
        var item: [String: BighelpJSONValue] = [
            "id": .string(reminder.calendarItemIdentifier),
            "revision": .string(Self.revision(reminder)),
            "title": .string(reminder.title ?? ""),
            "completed": .boolean(reminder.isCompleted),
            "listID": .string(reminder.calendar.calendarIdentifier),
        ]
        if let due = reminder.dueDateComponents {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = due.timeZone ?? timeZone
            guard let date = calendar.date(from: due) else { return .object(item) }
            item["dueDate"] = .string(Self.iso(date, timeZone: timeZone))
        }
        if let notes = reminder.notes { item["notes"] = .string(notes) }
        return .object(item)
    }

    func verifyRevision(
        _ arguments: [String: BighelpJSONValue],
        item: EKCalendarItem
    ) throws {
        guard arguments["expectedRevision"]?.string == Self.revision(item) else {
            throw AppleDeviceToolError.staleRevision
        }
    }

    func mutationMetadata(id: String?, revision: String) -> [String: BighelpJSONValue] {
        [
            "id": .string(id ?? ""),
            "revision": .string(revision),
        ]
    }

    nonisolated static func revision(_ item: EKCalendarItem) -> String {
        if let date = item.lastModifiedDate { return Self.iso(date, timeZone: .gmt) }
        if let date = item.creationDate { return Self.iso(date, timeZone: .gmt) }
        return item.calendarItemIdentifier
    }

    func string(_ arguments: [String: BighelpJSONValue], key: String) throws -> String {
        guard let value = arguments[key]?.string, !value.isEmpty else {
            throw AppleDeviceToolError.invalidArguments
        }
        return value
    }

    func date(_ arguments: [String: BighelpJSONValue], key: String) throws -> Date {
        guard let value = arguments[key]?.string, let date = Self.parseISO8601(value) else {
            throw AppleDeviceToolError.invalidArguments
        }
        return date
    }

    func parseDate(_ value: String) throws -> Date {
        guard let date = Self.parseISO8601(value) else { throw AppleDeviceToolError.invalidArguments }
        return date
    }

    func timeZone(_ arguments: [String: BighelpJSONValue]) throws -> TimeZone {
        guard let value = arguments["timeZone"]?.string, let timeZone = TimeZone(identifier: value) else {
            throw AppleDeviceToolError.invalidArguments
        }
        return timeZone
    }

    func components(for date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: date)
    }

    nonisolated static func iso(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = Self.iso8601
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    nonisolated static var iso8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    nonisolated static func parseISO8601(_ raw: String) -> Date? {
        if let date = iso8601.date(from: raw) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
