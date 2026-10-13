import Foundation

enum ScheduledTaskStatus: String, CaseIterable, Codable, Equatable, Sendable {
    case active
    case paused
    case completed
    case failed

    var title: String { rawValue.capitalized }
}

enum ScheduledTaskFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case active
    case paused

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum Weekday: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    var id: Self { self }
    var title: String {
        switch self {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }

    var shortTitle: String { String(title.prefix(3)) }
}

enum ScheduleInput: Equatable, Sendable {
    case once(date: Date, timeZoneID: String)
    case daily(time: DateComponents, timeZoneID: String)
    case repeating(days: Set<Weekday>, time: DateComponents, timeZoneID: String)
    case weekly(day: Weekday, time: DateComponents, timeZoneID: String)
    case monthly(day: Int, time: DateComponents, timeZoneID: String)
    case naturalLanguage(String, timeZoneID: String)
    case hermes(request: String, display: String, timeZoneID: String)

    var timeZoneID: String {
        switch self {
        case .once(_, let timeZoneID), .daily(_, let timeZoneID),
             .repeating(_, _, let timeZoneID), .weekly(_, _, let timeZoneID),
             .monthly(_, _, let timeZoneID), .naturalLanguage(_, let timeZoneID),
             .hermes(_, _, let timeZoneID):
            timeZoneID
        }
    }

    var requestedTimeZoneID: String? {
        if case .hermes = self {
            nil
        } else {
            timeZoneID
        }
    }

    var timeZoneDisclosure: String {
        if requestedTimeZoneID == nil {
            "Time zone not confirmed by Hermes. Editing uses \(timeZoneID) as a device fallback."
        } else {
            "Requested time zone: \(timeZoneID). Hermes does not yet confirm the saved time zone."
        }
    }
}

enum ScheduledTaskPickerKind: String, CaseIterable, Identifiable, Sendable {
    case repeating = "Repeating"
    case monthly = "Monthly"
    case once = "Once"

    var id: Self { self }
}

struct ScheduledTaskEditorPickerState: Equatable, Sendable {
    var kind: ScheduledTaskPickerKind
    var selectedDays: Set<Weekday>
    var monthlyDay: Int
    var scheduledDate: Date
    var scheduledTime: Date
    let timeZoneID: String

    private let originalSchedule: ScheduleInput?
    private let initialKind: ScheduledTaskPickerKind
    private let initialSelectedDays: Set<Weekday>
    private let initialMonthlyDay: Int
    private let initialScheduledDate: Date
    private let initialScheduledTime: Date

    init(
        schedule: ScheduleInput?,
        fallbackTimeZoneID: String = TimeZone.current.identifier,
        now: Date = .now
    ) {
        let candidateTimeZoneID = schedule?.timeZoneID ?? fallbackTimeZoneID
        let timeZone = TimeZone(identifier: candidateTimeZoneID)
            ?? TimeZone(identifier: fallbackTimeZoneID)
            ?? .current
        let initialKind: ScheduledTaskPickerKind
        let initialDays: Set<Weekday>
        let initialMonthlyDay: Int
        let initialDate: Date

        switch schedule {
        case .once(let date, _):
            initialKind = .once
            initialDays = []
            initialMonthlyDay = 1
            initialDate = date
        case .repeating(let days, let time, _):
            initialKind = .repeating
            initialDays = days
            initialMonthlyDay = 1
            initialDate = Self.date(for: time, timeZone: timeZone, fallback: now)
        case .daily(let time, _):
            initialKind = .repeating
            initialDays = Set(Weekday.allCases)
            initialMonthlyDay = 1
            initialDate = Self.date(for: time, timeZone: timeZone, fallback: now)
        case .weekly(let day, let time, _):
            initialKind = .repeating
            initialDays = [day]
            initialMonthlyDay = 1
            initialDate = Self.date(for: time, timeZone: timeZone, fallback: now)
        case .monthly(let day, let time, _):
            initialKind = .monthly
            initialDays = []
            initialMonthlyDay = day
            initialDate = Self.date(for: time, timeZone: timeZone, fallback: now)
        case .naturalLanguage, .hermes, nil:
            initialKind = .repeating
            initialDays = Set(Weekday.allCases)
            initialMonthlyDay = 1
            initialDate = now
        }

        kind = initialKind
        selectedDays = initialDays
        monthlyDay = initialMonthlyDay
        scheduledDate = initialDate
        scheduledTime = initialDate
        timeZoneID = timeZone.identifier
        originalSchedule = schedule
        self.initialKind = initialKind
        initialSelectedDays = initialDays
        self.initialMonthlyDay = initialMonthlyDay
        initialScheduledDate = initialDate
        initialScheduledTime = initialDate
    }

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneID) ?? .current
    }

    var timeComponents: DateComponents {
        calendar.dateComponents([.hour, .minute], from: scheduledTime)
    }

    mutating func toggle(_ day: Weekday) {
        if selectedDays.contains(day) {
            selectedDays.remove(day)
        } else {
            selectedDays.insert(day)
        }
    }

    func schedule() -> ScheduleInput? {
        if originalUsesPicker, isUnchanged {
            return originalSchedule
        }

        let time = timeComponents
        switch kind {
        case .once:
            let dateParts = calendar.dateComponents([.year, .month, .day], from: scheduledDate)
            let merged = DateComponents(
                timeZone: timeZone,
                year: dateParts.year,
                month: dateParts.month,
                day: dateParts.day,
                hour: time.hour,
                minute: time.minute
            )
            guard let date = calendar.date(from: merged) else { return nil }
            return .once(date: date, timeZoneID: timeZoneID)
        case .monthly:
            guard (1...31).contains(monthlyDay) else { return nil }
            return .monthly(day: monthlyDay, time: time, timeZoneID: timeZoneID)
        case .repeating:
            guard !selectedDays.isEmpty else { return nil }
            if case .daily = originalSchedule, selectedDays == Set(Weekday.allCases) {
                return .daily(time: time, timeZoneID: timeZoneID)
            }
            if case .weekly = originalSchedule, selectedDays.count == 1,
               let day = selectedDays.first {
                return .weekly(day: day, time: time, timeZoneID: timeZoneID)
            }
            return .repeating(days: selectedDays, time: time, timeZoneID: timeZoneID)
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private var originalUsesPicker: Bool {
        switch originalSchedule {
        case .once, .daily, .repeating, .weekly, .monthly:
            true
        case .naturalLanguage, .hermes, nil:
            false
        }
    }

    private var isUnchanged: Bool {
        kind == initialKind
            && selectedDays == initialSelectedDays
            && monthlyDay == initialMonthlyDay
            && scheduledDate == initialScheduledDate
            && scheduledTime == initialScheduledTime
    }

    private static func date(
        for time: DateComponents,
        timeZone: TimeZone,
        fallback: Date
    ) -> Date {
        guard let hour = time.hour, let minute = time.minute else { return fallback }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2001,
            month: 1,
            day: 15,
            hour: hour,
            minute: minute
        )) ?? fallback
    }
}

struct ScheduledTaskIdentity: Hashable, Sendable {
    let profileID: String
    let jobID: String

    var accessibilitySuffix: String { "\(profileID.utf8.count):\(profileID):\(jobID)" }
    private var bytes: Data { Data(accessibilitySuffix.utf8) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bytes == rhs.bytes }
    func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
}

extension ScheduledTask {
    /// Hermes Desktop files an agent's routines as "[bot:<agent>] <routine>".
    /// People see the routine's own name; the tag stays on the host.
    static func routineName(_ name: String) -> String {
        guard let match = name.firstMatch(of: /^\[bot:[A-Za-z0-9][A-Za-z0-9_-]*\]\s*/) else { return name }
        let rest = String(name[match.range.upperBound...])
        return rest.isEmpty ? name : rest
    }

    var displayName: String { Self.routineName(name) }
}

struct ScheduledTask: Identifiable, Equatable, Sendable {
    let id: String
    let agentID: String
    var name: String
    var instructions: String
    var schedule: ScheduleInput
    var deliveryTarget: String = "loopdy"
    var scheduleDescription: String
    var nextRun: Date?
    var status: ScheduledTaskStatus
    var lastResult: String?
    var usesHostManagedExecution = false
    var lastRun: Date? = nil
    var lastError: String? = nil
    var model: String? = nil
    var provider: String? = nil

    var isPaused: Bool { status == .paused }
    var identity: ScheduledTaskIdentity { .init(profileID: agentID, jobID: id) }
}

struct ScheduledTaskDraft: Equatable, Sendable {
    let agentID: String
    var name: String
    var instructions: String
    var schedule: ScheduleInput
    var deliveryTarget: String

    init(
        agentID: String,
        name: String,
        instructions: String,
        schedule: ScheduleInput,
        deliveryTarget: String = "loopdy"
    ) {
        self.agentID = agentID
        self.name = name
        self.instructions = instructions
        self.schedule = schedule
        self.deliveryTarget = deliveryTarget
    }
}

struct ScheduledTaskChanges: Equatable, Sendable {
    var name: String
    var instructions: String
    var schedule: ScheduleInput
    var deliveryTarget: String

    init(
        name: String,
        instructions: String,
        schedule: ScheduleInput,
        deliveryTarget: String = "loopdy"
    ) {
        self.name = name
        self.instructions = instructions
        self.schedule = schedule
        self.deliveryTarget = deliveryTarget
    }
}

struct ScheduledTaskDeliveryTarget: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let homeTargetSet: Bool

    static let local = ScheduledTaskDeliveryTarget(
        id: "local",
        name: "Local (save only)",
        homeTargetSet: true
    )
}

struct ScheduledTaskRun: Identifiable, Equatable, Sendable {
    let id: String
    let agentID: String
    let title: String?
    let preview: String?
    let startedAt: Date
    let lastActiveAt: Date
    let endedAt: Date?
    let isActive: Bool
    let isArchived: Bool
    let model: String?
    let messageCount: Int
    let toolCallCount: Int

    var displayTitle: String {
        for candidate in [title, preview] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return "Scheduled run"
    }
}

enum ScheduledTaskBlueprintFieldKind: String, Equatable, Sendable {
    case enumeration = "enum"
    case text
    case time
    case weekdays
}

struct ScheduledTaskBlueprintField: Identifiable, Equatable, Sendable {
    let name: String
    let kind: ScheduledTaskBlueprintFieldKind
    let label: String
    let defaultValue: String?
    let options: [String]
    let isOptional: Bool
    let isStrict: Bool
    let help: String

    var id: String { name }
}

struct ScheduledTaskBlueprint: Identifiable, Equatable, Sendable {
    let key: String
    let title: String
    let summary: String
    let category: String
    let tags: [String]
    let fields: [ScheduledTaskBlueprintField]
    let scheduleDescription: String

    var id: String { key }

    func initialValues() -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.compactMap { field in
            field.defaultValue.map { (field.name, $0) }
        })
    }

    func validatedValues(_ values: [String: String]) throws -> [String: String] {
        guard Set(values.keys).isSubset(of: Set(fields.map(\.name))) else {
            throw ScheduledTasksError.invalidBlueprintValues
        }
        var resolved: [String: String] = [:]
        for field in fields {
            let value = (values[field.name] ?? field.defaultValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                guard field.isOptional else { throw ScheduledTasksError.invalidBlueprintValues }
                continue
            }
            guard value.utf8.count <= 8_192 else { throw ScheduledTasksError.invalidBlueprintValues }
            if field.isStrict, !field.options.isEmpty, !field.options.contains(value) {
                throw ScheduledTasksError.invalidBlueprintValues
            }
            if field.kind == .time {
                let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
                guard pieces.count == 2, pieces[0].count == 2, pieces[1].count == 2,
                      let hour = Int(pieces[0]), (0...23).contains(hour),
                      let minute = Int(pieces[1]), (0...59).contains(minute) else {
                    throw ScheduledTasksError.invalidBlueprintValues
                }
            }
            resolved[field.name] = value
        }
        return resolved
    }
}

enum ScheduledTaskDeliverySelection {
    static let manualID = "__manual__"

    /// Hermes names this app's delivery platform "loopdy"; people know it as bighelp.
    static func displayName(id: String, name: String) -> String {
        id.caseInsensitiveCompare("loopdy") == .orderedSame ? "\(BighelpBrand.appName) app" : name
    }

    static func resolve(
        selectedID: String,
        manualValue: String,
        targets: [ScheduledTaskDeliveryTarget]
    ) throws -> String {
        if selectedID != manualID {
            guard targets.contains(where: { $0.id == selectedID && $0.homeTargetSet }) else {
                throw ScheduledTasksError.invalidDeliveryTarget
            }
            return selectedID
        }

        guard
            !manualValue.isEmpty,
            manualValue == manualValue.trimmingCharacters(in: .whitespacesAndNewlines),
            manualValue.utf8.count <= 512,
            !manualValue.contains(","),
            !manualValue.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            }),
            let separator = manualValue.firstIndex(of: ":")
        else { throw ScheduledTasksError.invalidDeliveryTarget }

        let platform = String(manualValue[..<separator])
        let destination = String(manualValue[manualValue.index(after: separator)...])
        guard
            !platform.isEmpty,
            platform != ScheduledTaskDeliveryTarget.local.id,
            !destination.isEmpty,
            !destination.hasPrefix(":"),
            targets.contains(where: { $0.id == platform && !$0.id.contains(":") })
        else { throw ScheduledTasksError.invalidDeliveryTarget }
        return manualValue
    }
}

struct ScheduledTaskMutation: Equatable, Sendable {
    let id: String
    let agentID: String
}

enum ScheduledTaskAction: CaseIterable, Sendable {
    case edit
    case pauseOrResume
    case runNow
    case duplicate
    case delete
}

struct ScheduledTaskActionAvailability: Equatable, Sendable {
    let isVisible: Bool
    let isEnabled: Bool
    let reason: String?
}

struct ScheduledTaskPresentation: Sendable {
    let task: ScheduledTask
    let agentName: String?

    init(task: ScheduledTask, agentName: String?) {
        self.task = task
        self.agentName = agentName
    }

    var resolvedAgentName: String { agentName ?? "Unavailable agent" }

    var lastResultCopy: String {
        if let result = task.lastResult { return "Last result: \(result)" }
        if task.status == .completed { return "Task completed; no result text was reported" }
        if task.status == .failed { return "No result text was reported" }
        return "Last result: No completed runs yet"
    }

    var rowAccessibilityLabel: String {
        "\(task.name). \(resolvedAgentName). \(task.status.title). \(nextRunCopy). \(lastResultCopy)"
    }

    var deleteConfirmationTitle: String {
        "Delete \(task.name) for \(resolvedAgentName)?"
    }

    var deleteConfirmationMessage: String {
        "This removes \(task.name) for \(resolvedAgentName). This action cannot be undone."
    }

    func action(_ action: ScheduledTaskAction) -> ScheduledTaskActionAvailability {
        if task.status == .completed, [.edit, .pauseOrResume, .runNow].contains(action) {
            return .init(isVisible: true, isEnabled: false, reason: "This task has completed. Create a new schedule for more work.")
        }
        if task.status == .failed, [.pauseOrResume, .runNow].contains(action) {
            return .init(isVisible: true, isEnabled: false, reason: "Review the failed schedule on Hermes before running it again.")
        }
        if task.usesHostManagedExecution, [.edit, .duplicate].contains(action) {
            return .init(isVisible: true, isEnabled: false, reason: "This task uses host-managed scripts or skills. Edit its execution on Hermes.")
        }
        switch action {
        case .edit, .pauseOrResume, .runNow:
            return ScheduledTaskActionAvailability(
                isVisible: true,
                isEnabled: agentName != nil,
                reason: agentName == nil ? "Agent unavailable" : nil
            )
        case .duplicate, .delete:
            return ScheduledTaskActionAvailability(isVisible: true, isEnabled: true, reason: nil)
        }
    }

    var nextRunCopy: String {
        if task.status == .completed { return "Completed; no future run is scheduled" }
        if task.status == .failed { return "Scheduling failed; review this task on Hermes" }
        guard let nextRun = task.nextRun else { return "Next run will be confirmed by the agent" }
        let date = nextRun.formatted(date: .abbreviated, time: .shortened)
        return task.isPaused ? "Paused; next run \(date)" : "Next run \(date)"
    }
}

enum ScheduledTasksError: Error, Equatable, LocalizedError {
    case agentRequired
    case taskNotFound
    case ambiguousTask
    case invalidCatalog
    case requestInProgress
    case unrecognizedDescription
    case invalidSchedule
    case dateMustBeInFuture
    case intervalMustBePositive
    case invalidDeliveryTarget
    case invalidBlueprint
    case invalidBlueprintValues

    var errorDescription: String? {
        switch self {
        case .agentRequired: "Choose an agent before creating this task."
        case .taskNotFound: "This task is no longer available."
        case .ambiguousTask: "More than one profile has this task ID. Open the task from its owning profile."
        case .invalidCatalog: "Hermes returned duplicate tasks for the same profile. Refresh before changing them."
        case .requestInProgress: "That change is already being saved."
        case .unrecognizedDescription: "We could not understand that description. Try Pick a schedule, then keep this draft or adjust the wording."
        case .invalidSchedule: "Choose a valid date, time, and time zone."
        case .dateMustBeInFuture: "Choose a date and time in the future."
        case .intervalMustBePositive: "Choose an interval greater than zero."
        case .invalidDeliveryTarget: "Choose an available output channel or enter a valid platform:channel[:thread] value."
        case .invalidBlueprint: "This automation blueprint is no longer available. Refresh and choose it again."
        case .invalidBlueprintValues: "Complete every required blueprint field with a supported value."
        }
    }
}

@MainActor
protocol ScheduledTasksClient {
    func list(agentID: String?) async throws -> [ScheduledTask]
    func detail(id: String, agentID: String) async throws -> ScheduledTask
    func runs(id: String, agentID: String, limit: Int) async throws -> [ScheduledTaskRun]
    func blueprints() async throws -> [ScheduledTaskBlueprint]
    func instantiate(_ blueprint: ScheduledTaskBlueprint, values: [String: String], agentID: String) async throws -> ScheduledTask
    func deliveryTargets() async throws -> [ScheduledTaskDeliveryTarget]
    func create(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask
    func update(id: String, agentID: String, changes: ScheduledTaskChanges) async throws -> ScheduledTask
    func setPaused(_ paused: Bool, id: String, agentID: String) async throws -> ScheduledTask
    func runNow(id: String, agentID: String) async throws -> ScheduledTask
    func delete(id: String, agentID: String) async throws
}

extension ScheduledTasksClient {
    func detail(id: String, agentID: String) async throws -> ScheduledTask {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func runs(id: String, agentID: String, limit: Int) async throws -> [ScheduledTaskRun] {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func blueprints() async throws -> [ScheduledTaskBlueprint] {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func instantiate(_ blueprint: ScheduledTaskBlueprint, values: [String: String], agentID: String) async throws -> ScheduledTask {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    func deliveryTargets() async throws -> [ScheduledTaskDeliveryTarget] { [.local] }
}

extension ScheduleInput {
    static let dailyFixture = ScheduleInput.daily(
        time: DateComponents(hour: 8, minute: 0),
        timeZoneID: "America/Chicago"
    )
}

extension ScheduledTaskDraft {
    static func fixture(agentID: String) -> ScheduledTaskDraft {
        ScheduledTaskDraft(
            agentID: agentID,
            name: "Daily brief",
            instructions: "Prepare a concise morning summary.",
            schedule: .dailyFixture
        )
    }
}

extension ScheduledTask {
    static func fixture(
        id: String = UUID().uuidString,
        agentID: String,
        name: String = "Daily brief",
        instructions: String = "Prepare a concise morning summary.",
        schedule: ScheduleInput = .dailyFixture,
        deliveryTarget: String = "loopdy",
        isPaused: Bool = false,
        nextRun: Date? = nil,
        lastResult: String? = nil
    ) -> ScheduledTask {
        ScheduledTask(
            id: id,
            agentID: agentID,
            name: name,
            instructions: instructions,
            schedule: schedule,
            deliveryTarget: deliveryTarget,
            scheduleDescription: (try? ScheduleRequestBuilder.request(for: schedule)) ?? "Schedule unavailable",
            nextRun: nextRun,
            status: isPaused ? .paused : .active,
            lastResult: lastResult
        )
    }
}
