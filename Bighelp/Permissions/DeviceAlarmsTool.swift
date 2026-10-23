import Foundation
#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

/// What iOS says about alarm access.
enum DeviceAlarmAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized
}

/// The names the agent uses, in the order the week is listed to it.
enum DeviceAlarmWeekday: String, CaseIterable, Equatable, Sendable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday
}

struct DeviceAlarmClockTime: Equatable, Sendable {
    let hour: Int
    let minute: Int
}

/// When an alarm or timer goes off.
enum DeviceAlarmSchedule: Equatable, Sendable {
    /// A countdown that starts now.
    case timer(seconds: Int)
    /// One time, on this date.
    case once(Date)
    /// At this time of day: every listed weekday, or once at the next such time when none are listed.
    case clock(DeviceAlarmClockTime, weekdays: [DeviceAlarmWeekday])
}

enum DeviceAlarmState: String, Equatable, Sendable {
    case scheduled, countdown, paused, alerting
}

/// One alarm as AlarmKit reports it. AlarmKit keeps no label, so `DeviceAlarmLabelStoring` does.
struct DeviceAlarmRecord: Equatable, Sendable {
    let id: UUID
    let state: DeviceAlarmState
    let schedule: DeviceAlarmSchedule
}

enum DeviceAlarmProviderError: Error, Equatable, Sendable {
    /// AlarmKit holds a fixed number of alarms for an app.
    case limitReached
    case notAuthorized
    case failed
}

/// AlarmKit behind a seam, so the choices below can be tested without a device.
@MainActor
protocol DeviceAlarmProviding: AnyObject {
    var authorization: DeviceAlarmAuthorization { get }
    /// Asks iOS the first time. Throws when iOS can't ask (for example, the usage text is missing).
    func requestAuthorization() async throws -> DeviceAlarmAuthorization
    /// Only this app's alarms; AlarmKit never shows another app's.
    func alarms() throws -> [DeviceAlarmRecord]
    func schedule(id: UUID, label: String, schedule: DeviceAlarmSchedule) async throws
    func cancel(id: UUID) throws
}

/// The label an agent gave each alarm, kept on the phone: AlarmKit gives alarms back without one.
@MainActor
protocol DeviceAlarmLabelStoring: AnyObject {
    func label(for id: UUID) -> String?
    func setLabel(_ label: String, for id: UUID)
    func removeLabel(for id: UUID)
    /// Forgets the labels of alarms that are gone (one-time alarms end by themselves).
    func keepOnly(_ ids: Set<UUID>)
}

@MainActor
final class DeviceAlarmLabelStore: DeviceAlarmLabelStoring {
    static let key = "bighelp.device-tools.alarm-labels.v1"
    /// AlarmKit allows far fewer alarms; this only bounds a store that lost track of them.
    static let maximumLabels = 200

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func label(for id: UUID) -> String? { read()[Self.key(id)] }

    func setLabel(_ label: String, for id: UUID) {
        var labels = read()
        labels[Self.key(id)] = label
        if labels.count > Self.maximumLabels {
            for key in labels.keys.sorted().prefix(labels.count - Self.maximumLabels) where key != Self.key(id) {
                labels[key] = nil
            }
        }
        write(labels)
    }

    func removeLabel(for id: UUID) {
        var labels = read()
        guard labels.removeValue(forKey: Self.key(id)) != nil else { return }
        write(labels)
    }

    func keepOnly(_ ids: Set<UUID>) {
        let keep = Set(ids.map(Self.key))
        let labels = read()
        let kept = labels.filter { keep.contains($0.key) }
        if kept.count != labels.count { write(kept) }
    }

    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func read() -> [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    private func write(_ labels: [String: String]) {
        defaults.set(labels, forKey: Self.key)
    }
}

/// `alarms.list`, `alarms.create`, `alarms.update` and `alarms.delete`: the agent's `iphone_alarms` tool, alarms and timers through AlarmKit (iPhone and iPad, iOS 26 and later).
/// It sees and changes only bighelp's own alarms: AlarmKit never shows another app's.
@MainActor
final class DeviceAlarmsTool: DeviceCapabilityTool {
    enum Failure: String, DeviceToolFailure, Equatable {
        case notFound = "not_found"
        /// AlarmKit won't hold more alarms for the app.
        case limitReached = "alarm_limit_reached"

        var code: String { rawValue }
    }

    static let maximumLabelLength = 60
    static let timerSeconds = 5...86_400
    static let maximumListed = 100
    private static let fieldKeys: Set<String> = ["label", "time", "weekdays", "date", "timerSeconds"]

    let capability = DeviceToolCapability.alarms
    private let provider: (any DeviceAlarmProviding)?
    private let labels: any DeviceAlarmLabelStoring
    private let now: () -> Date

    /// With no provider (a platform without AlarmKit) the tool says it's unavailable.
    init(provider: (any DeviceAlarmProviding)?, labels: any DeviceAlarmLabelStoring, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.labels = labels
        self.now = now
    }

    static func live(_ environment: DeviceToolEnvironment) -> DeviceAlarmsTool {
        if environment.usesFixtures {
            return DeviceAlarmsTool(provider: DemoDeviceAlarmProvider(), labels: DeviceAlarmMemoryLabels())
        }
        let labels = DeviceAlarmLabelStore(defaults: environment.defaults)
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return DeviceAlarmsTool(provider: LiveDeviceAlarmProvider(), labels: labels)
        }
        #endif
        return DeviceAlarmsTool(provider: nil, labels: labels)
    }

    // MARK: Access

    func status() async -> DeviceToolSystemAccess {
        guard let provider else { return .unavailable }
        return Self.access(provider.authorization)
    }

    func request() async -> DeviceToolSystemAccess {
        guard let provider else { return .unavailable }
        if provider.authorization == .notDetermined {
            do { _ = try await provider.requestAuthorization() } catch { return .unavailable }
        }
        return Self.access(provider.authorization)
    }

    private static func access(_ authorization: DeviceAlarmAuthorization) -> DeviceToolSystemAccess {
        switch authorization {
        case .notDetermined: .notRequested
        case .denied: .denied
        case .authorized: .available
        }
    }

    // MARK: Operations

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        context: DeviceToolCallContext,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        switch operation {
        case "alarms.list": return try list(arguments, authorize: authorize)
        case "alarms.create": return try await create(arguments, authorize: authorize)
        case "alarms.update": return try await update(arguments, authorize: authorize)
        case "alarms.delete": return try delete(arguments, authorize: authorize)
        default: throw AppleDeviceToolError.unsupportedOperation
        }
    }

    private func list(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        guard arguments.isEmpty else { throw AppleDeviceToolError.invalidArguments }
        let provider = try ready(authorize)
        let records = try current(provider)
        labels.keepOnly(Set(records.map(\.id)))
        let described = records.map { ($0, name(for: $0)) }
            .sorted { ($0.1.lowercased(), $0.0.id.uuidString) < ($1.1.lowercased(), $1.0.id.uuidString) }
            .prefix(Self.maximumListed)
            .map { Self.json($0.0, label: $0.1) }
        return ["alarms": .array(Array(described))]
    }

    private func create(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        let fields = try Fields(arguments, allowing: Self.fieldKeys, now: now())
        guard let label = fields.label, let change = fields.schedule else { throw AppleDeviceToolError.invalidArguments }
        let schedule = try fields.resolve(change, replacing: nil)
        let provider = try ready(authorize)
        let id = UUID()
        try recheck(provider, authorize)
        do { try await provider.schedule(id: id, label: label, schedule: schedule) } catch { throw Self.mapped(error) }
        // The alarm exists now. Losing access from here on doesn't undo it, so the answer says so.
        labels.setLabel(label, for: id)
        return ["id": .string(Self.identifier(id))]
    }

    private func update(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        let id = try Self.parseID(arguments["id"])
        let fields = try Fields(arguments.filter { $0.key != "id" }, allowing: Self.fieldKeys, now: now(), forUpdate: true)
        let provider = try ready(authorize)
        guard let existing = try current(provider).first(where: { $0.id == id }) else { throw Failure.notFound }
        let schedule = try fields.resolve(fields.schedule, replacing: existing.schedule)
        let oldLabel = name(for: existing)
        let label = fields.label ?? oldLabel
        try recheck(provider, authorize)
        // AlarmKit has no edit: the same id is cancelled and scheduled again. If the new one is refused
        // the old one goes back, so a bad update never leaves the person without their alarm.
        do { try provider.cancel(id: id) } catch { throw Self.mapped(error) }
        do {
            try await provider.schedule(id: id, label: label, schedule: schedule)
        } catch {
            try? await provider.schedule(id: id, label: oldLabel, schedule: existing.schedule)
            throw Self.mapped(error)
        }
        labels.setLabel(label, for: id)
        return ["id": .string(Self.identifier(id))]
    }

    private func delete(
        _ arguments: [String: BighelpJSONValue], authorize: @MainActor () throws -> Void
    ) throws -> [String: BighelpJSONValue] {
        guard Set(arguments.keys) == ["id"] else { throw AppleDeviceToolError.invalidArguments }
        let id = try Self.parseID(arguments["id"])
        let provider = try ready(authorize)
        guard try current(provider).contains(where: { $0.id == id }) else { throw Failure.notFound }
        try recheck(provider, authorize)
        do { try provider.cancel(id: id) } catch { throw Self.mapped(error) }
        labels.removeLabel(for: id)
        return ["id": .string(Self.identifier(id)), "deleted": .boolean(true)]
    }

    // MARK: Checks

    /// The call still belongs to the chat that made it, and iOS still allows alarms.
    private func ready(_ authorize: @MainActor () throws -> Void) throws -> any DeviceAlarmProviding {
        guard let provider else { throw AppleDeviceToolError.unavailable }
        try recheck(provider, authorize)
        return provider
    }

    private func recheck(_ provider: any DeviceAlarmProviding, _ authorize: @MainActor () throws -> Void) throws {
        try authorize()
        switch provider.authorization {
        case .authorized: break
        case .notDetermined, .denied: throw AppleDeviceToolError.authorizationRequired
        }
    }

    private func current(_ provider: any DeviceAlarmProviding) throws -> [DeviceAlarmRecord] {
        do { return try provider.alarms() } catch { throw Self.mapped(error) }
    }

    private func name(for record: DeviceAlarmRecord) -> String {
        if let label = labels.label(for: record.id), !label.isEmpty { return label }
        if case .timer = record.schedule { return "Timer" }
        return "Alarm"
    }

    private static func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let failure = error as? any DeviceToolFailure { return failure }
        switch error as? DeviceAlarmProviderError {
        case .limitReached: return Failure.limitReached
        case .notAuthorized: return AppleDeviceToolError.authorizationRequired
        case .failed, nil: return AppleDeviceToolError.nativeFailure
        }
    }

    // MARK: Arguments

    /// What `create` and `update` accept, checked before anything is scheduled.
    @MainActor private struct Fields {
        enum Change {
            case timer(Int)
            case once(Date)
            case clock(DeviceAlarmClockTime)
        }

        var label: String?
        var schedule: Change?
        var weekdays: [DeviceAlarmWeekday]?

        init(_ arguments: [String: BighelpJSONValue], allowing allowed: Set<String>, now: Date, forUpdate: Bool = false) throws {
            guard Set(arguments.keys).isSubset(of: allowed) else { throw AppleDeviceToolError.invalidArguments }
            if let value = arguments["label"] { label = try Self.label(value) }
            let scheduleKeys = ["time", "date", "timerSeconds"].filter { arguments[$0] != nil }
            guard scheduleKeys.count <= 1 else { throw AppleDeviceToolError.invalidArguments }
            if let value = arguments["time"] {
                schedule = .clock(try Self.time(value))
            } else if let value = arguments["date"] {
                guard let text = value.string, text.count <= 64, let date = DeviceAlarmsTool.parseDate(text),
                      date > now.addingTimeInterval(1) else { throw AppleDeviceToolError.invalidArguments }
                schedule = .once(date)
            } else if let value = arguments["timerSeconds"] {
                guard let seconds = DeviceAlarmsTool.whole(value), DeviceAlarmsTool.timerSeconds.contains(seconds) else {
                    throw AppleDeviceToolError.invalidArguments
                }
                schedule = .timer(seconds)
            }
            if let value = arguments["weekdays"] {
                // Weekdays go with a time of day. An update may name them alone, for the alarm it already has.
                let fitsSchedule = schedule.map(Self.isClock) ?? forUpdate
                guard fitsSchedule else { throw AppleDeviceToolError.invalidArguments }
                weekdays = try Self.weekdays(value)
            }
            if forUpdate {
                guard label != nil || schedule != nil || weekdays != nil else { throw AppleDeviceToolError.invalidArguments }
            } else {
                guard label != nil, schedule != nil else { throw AppleDeviceToolError.invalidArguments }
            }
        }

        /// The schedule to set. An update that leaves the schedule out keeps it; a new time keeps the
        /// weekdays unless the update names others; weekdays alone only fit an alarm that has a time of day.
        func resolve(_ change: Change?, replacing existing: DeviceAlarmSchedule?) throws -> DeviceAlarmSchedule {
            switch change {
            case .timer(let seconds)?: return .timer(seconds: seconds)
            case .once(let date)?: return .once(date)
            case .clock(let time)?:
                if let weekdays { return .clock(time, weekdays: weekdays) }
                if case .clock(_, let kept)? = existing { return .clock(time, weekdays: kept) }
                return .clock(time, weekdays: [])
            case nil:
                guard let existing else { throw AppleDeviceToolError.invalidArguments }
                guard let weekdays else { return existing }
                guard case .clock(let time, _) = existing else { throw AppleDeviceToolError.invalidArguments }
                return .clock(time, weekdays: weekdays)
            }
        }

        private static func isClock(_ change: Change) -> Bool {
            if case .clock = change { return true }
            return false
        }

        private static func label(_ value: BighelpJSONValue) throws -> String {
            guard let raw = value.string else { throw AppleDeviceToolError.invalidArguments }
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...DeviceAlarmsTool.maximumLabelLength).contains(label.count),
                  !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw AppleDeviceToolError.invalidArguments
            }
            return label
        }

        private static func time(_ value: BighelpJSONValue) throws -> DeviceAlarmClockTime {
            guard let object = value.object, Set(object.keys) == ["hour", "minute"],
                  let hour = DeviceAlarmsTool.whole(object["hour"]), (0...23).contains(hour),
                  let minute = DeviceAlarmsTool.whole(object["minute"]), (0...59).contains(minute) else {
                throw AppleDeviceToolError.invalidArguments
            }
            return DeviceAlarmClockTime(hour: hour, minute: minute)
        }

        private static func weekdays(_ value: BighelpJSONValue) throws -> [DeviceAlarmWeekday] {
            guard let list = value.array, (1...7).contains(list.count) else { throw AppleDeviceToolError.invalidArguments }
            var days = Set<DeviceAlarmWeekday>()
            for item in list {
                guard let name = item.string, let day = DeviceAlarmWeekday(rawValue: name) else {
                    throw AppleDeviceToolError.invalidArguments
                }
                days.insert(day)
            }
            return DeviceAlarmWeekday.allCases.filter(days.contains)
        }
    }

    private static func whole(_ value: BighelpJSONValue?) -> Int? {
        switch value {
        case .integer(let number)?: return number
        case .number(let number)?:
            guard number.isFinite, number == number.rounded(), abs(number) < 1_000_000_000 else { return nil }
            return Int(number)
        default: return nil
        }
    }

    /// An ISO-8601 date with an offset or `Z`; without one the time would be a guess.
    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func parseID(_ value: BighelpJSONValue?) throws -> UUID {
        guard let text = value?.string, text.count <= 64, let id = UUID(uuidString: text) else {
            throw AppleDeviceToolError.invalidArguments
        }
        return id
    }

    // MARK: Results

    /// Lowercase, like every other ID the agent gets.
    static func identifier(_ id: UUID) -> String { id.uuidString.lowercased() }

    static func json(_ record: DeviceAlarmRecord, label: String) -> BighelpJSONValue {
        var fields: [String: BighelpJSONValue] = [
            "id": .string(identifier(record.id)),
            "label": .string(label),
            "state": .string(record.state.rawValue),
        ]
        switch record.schedule {
        case .timer(let seconds):
            fields["kind"] = .string("timer")
            fields["timerSeconds"] = .integer(seconds)
        case .once(let date):
            fields["kind"] = .string("alarm")
            fields["date"] = .string(timestamp(date))
        case .clock(let time, let weekdays):
            fields["kind"] = .string("alarm")
            fields["time"] = .object(["hour": .integer(time.hour), "minute": .integer(time.minute)])
            if !weekdays.isEmpty {
                fields["weekdays"] = .array(DeviceAlarmWeekday.allCases.filter(weekdays.contains).map { .string($0.rawValue) })
            }
        }
        return .object(fields)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// MARK: - Demo

/// Labels held in memory only, for demo mode and tests.
@MainActor
final class DeviceAlarmMemoryLabels: DeviceAlarmLabelStoring {
    private(set) var labels: [UUID: String] = [:]

    func label(for id: UUID) -> String? { labels[id] }
    func setLabel(_ label: String, for id: UUID) { labels[id] = label }
    func removeLabel(for id: UUID) { labels[id] = nil }
    func keepOnly(_ ids: Set<UUID>) { labels = labels.filter { ids.contains($0.key) } }
}

/// Demo mode: alarms live in memory, nothing reaches iOS and nothing rings.
@MainActor
final class DemoDeviceAlarmProvider: DeviceAlarmProviding {
    private(set) var authorization = DeviceAlarmAuthorization.notDetermined
    private var records: [UUID: DeviceAlarmRecord] = [:]

    func requestAuthorization() async throws -> DeviceAlarmAuthorization {
        authorization = .authorized
        return authorization
    }

    func alarms() throws -> [DeviceAlarmRecord] { Array(records.values) }

    func schedule(id: UUID, label: String, schedule: DeviceAlarmSchedule) async throws {
        guard records[id] == nil else { throw DeviceAlarmProviderError.failed }
        let state: DeviceAlarmState = if case .timer = schedule { .countdown } else { .scheduled }
        records[id] = DeviceAlarmRecord(id: id, state: state, schedule: schedule)
    }

    func cancel(id: UUID) throws {
        guard records.removeValue(forKey: id) != nil else { throw DeviceAlarmProviderError.failed }
    }
}

// MARK: - AlarmKit

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AlarmKit)
@available(iOS 26.0, *)
@MainActor
final class LiveDeviceAlarmProvider: DeviceAlarmProviding {
    // AlarmManager isn't Sendable, so nothing here holds it: each call that waits builds and uses it
    // inside one nonisolated function, and only Sendable values cross.
    var authorization: DeviceAlarmAuthorization { Self.map(AlarmManager.shared.authorizationState) }

    func requestAuthorization() async throws -> DeviceAlarmAuthorization {
        Self.map(try await Self.askForAccess())
    }

    func alarms() throws -> [DeviceAlarmRecord] {
        try AlarmManager.shared.alarms.compactMap(Self.record)
    }

    func schedule(id: UUID, label: String, schedule: DeviceAlarmSchedule) async throws {
        try await Self.submit(id: id, label: label, schedule: schedule)
    }

    func cancel(id: UUID) throws {
        do { try AlarmManager.shared.cancel(id: id) } catch { throw DeviceAlarmProviderError.failed }
    }

    private nonisolated static func askForAccess() async throws -> AlarmManager.AuthorizationState {
        try await AlarmManager.shared.requestAuthorization()
    }

    private nonisolated static func submit(id: UUID, label: String, schedule: DeviceAlarmSchedule) async throws {
        let manager = AlarmManager.shared
        do {
            _ = try await manager.schedule(id: id, configuration: configuration(label: label, schedule: schedule))
        } catch AlarmManager.AlarmError.maximumLimitReached {
            throw DeviceAlarmProviderError.limitReached
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // AlarmKit asks for access itself when the first alarm is scheduled; a refusal lands here.
            if manager.authorizationState == .authorized { throw DeviceAlarmProviderError.failed }
            throw DeviceAlarmProviderError.notAuthorized
        }
    }

    // MARK: Mapping

    private nonisolated static func map(_ state: AlarmManager.AuthorizationState) -> DeviceAlarmAuthorization {
        switch state {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        @unknown default: .denied
        }
    }

    private nonisolated static func record(_ alarm: Alarm) -> DeviceAlarmRecord? {
        let state: DeviceAlarmState
        switch alarm.state {
        case .scheduled: state = .scheduled
        case .countdown: state = .countdown
        case .paused: state = .paused
        case .alerting: state = .alerting
        @unknown default: state = .scheduled
        }
        let schedule: DeviceAlarmSchedule
        switch alarm.schedule {
        case .fixed(let date)?:
            schedule = .once(date)
        case .relative(let relative)?:
            var days: [DeviceAlarmWeekday] = []
            if case .weekly(let weekdays) = relative.repeats {
                let set = Set(weekdays.compactMap(DeviceAlarmWeekday.init))
                days = DeviceAlarmWeekday.allCases.filter(set.contains)
            }
            schedule = .clock(DeviceAlarmClockTime(hour: relative.time.hour, minute: relative.time.minute), weekdays: days)
        case nil:
            // A timer has no schedule, only the countdown it was set for.
            guard let seconds = alarm.countdownDuration?.preAlert, seconds.isFinite, seconds >= 0 else { return nil }
            schedule = .timer(seconds: Int(seconds.rounded()))
        @unknown default:
            return nil
        }
        return DeviceAlarmRecord(id: alarm.id, state: state, schedule: schedule)
    }

    // MARK: Configuration

    /// The accent of the Live Activity and the system's alarm screens. One fixed color: AlarmKit stores it.
    private nonisolated static var tint: Color {
        Color(widgetHex: (BighelpWidgetSnapshot.load().darkPalette ?? .emberDark).accentHex)
    }

    private nonisolated static func configuration(
        label: String, schedule: DeviceAlarmSchedule
    ) -> AlarmManager.AlarmConfiguration<BighelpAlarmMetadata> {
        let tint = tint
        // Interpolated, so a label with a percent sign or a brace is shown as typed.
        let title = LocalizedStringResource("\(label)")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title)
        } else {
            alert = AlarmPresentation.Alert(
                title: title, stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        }
        switch schedule {
        case .timer(let seconds):
            // A countdown needs the Live Activity in the widget extension (BighelpAlarmLiveActivity).
            let presentation = AlarmPresentation(
                alert: alert,
                countdown: AlarmPresentation.Countdown(
                    title: title, pauseButton: AlarmButton(text: "Pause", textColor: tint, systemImageName: "pause.fill")),
                paused: AlarmPresentation.Paused(
                    title: "Paused", resumeButton: AlarmButton(text: "Resume", textColor: tint, systemImageName: "play.fill")))
            let attributes = AlarmAttributes(
                presentation: presentation, metadata: BighelpAlarmMetadata(label: label, kind: .timer), tintColor: tint)
            return .timer(duration: TimeInterval(seconds), attributes: attributes)
        case .once(let date):
            return .alarm(schedule: .fixed(date), attributes: alarmAttributes(alert, label: label, tint: tint))
        case .clock(let time, let weekdays):
            let repeats: Alarm.Schedule.Relative.Recurrence = weekdays.isEmpty
                ? .never : .weekly(weekdays.map(\.localeWeekday))
            let relative = Alarm.Schedule.Relative(
                time: Alarm.Schedule.Relative.Time(hour: time.hour, minute: time.minute), repeats: repeats)
            return .alarm(schedule: .relative(relative), attributes: alarmAttributes(alert, label: label, tint: tint))
        }
    }

    /// A plain alarm shows only its alert. The countdown and paused screens are for timers; leaving them
    /// out means the alarm needs nothing from the widget extension to ring.
    private nonisolated static func alarmAttributes(
        _ alert: AlarmPresentation.Alert, label: String, tint: Color
    ) -> AlarmAttributes<BighelpAlarmMetadata> {
        AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: BighelpAlarmMetadata(label: label, kind: .alarm), tintColor: tint)
    }
}

private extension DeviceAlarmWeekday {
    var localeWeekday: Locale.Weekday {
        switch self {
        case .monday: .monday
        case .tuesday: .tuesday
        case .wednesday: .wednesday
        case .thursday: .thursday
        case .friday: .friday
        case .saturday: .saturday
        case .sunday: .sunday
        }
    }

    init?(_ weekday: Locale.Weekday) {
        switch weekday {
        case .monday: self = .monday
        case .tuesday: self = .tuesday
        case .wednesday: self = .wednesday
        case .thursday: self = .thursday
        case .friday: self = .friday
        case .saturday: self = .saturday
        case .sunday: self = .sunday
        @unknown default: return nil
        }
    }
}
#endif
