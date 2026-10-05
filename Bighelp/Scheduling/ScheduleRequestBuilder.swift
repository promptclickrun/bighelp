import Foundation

struct ValidatedHermesScheduleRequest: Equatable, Sendable {
    let expression: String
    let requestedTimeZoneID: String?
}

enum ScheduleRequestBuilder {
    static func display(forHermesRequest request: String) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("every "), lowercased.hasSuffix("m"),
           let minutes = Int(lowercased.dropFirst(6).dropLast()) {
            if minutes == 1 { return "Every minute" }
            if minutes == 60 { return "Every hour" }
            if minutes.isMultiple(of: 1_440) {
                let days = minutes / 1_440
                return days == 1 ? "Every day" : "Every \(days) days"
            }
            if minutes.isMultiple(of: 60) {
                let hours = minutes / 60
                return "Every \(hours) hours"
            }
            return "Every \(minutes) minutes"
        }
        if let date = ISO8601DateFormatter().date(from: trimmed) {
            return "Once on \(dateText(date, timeZone: .current)) at \(timeText(date, timeZone: .current))"
        }

        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 5 else { return trimmed }
        let cronCharacters = Set("0123456789*,-/")
        guard fields.prefix(5).allSatisfy({ field in
            !field.isEmpty && field.allSatisfy(cronCharacters.contains)
        }) else { return trimmed }
        guard let minute = Int(fields[0]), let hour = Int(fields[1]),
              (0...59).contains(minute), (0...23).contains(hour) else {
            return "Custom schedule"
        }
        let time = (try? timeText(DateComponents(hour: hour, minute: minute))) ?? "a selected time"
        let dayOfMonth = fields[2]
        let month = fields[3]
        let weekday = fields[4]
        if dayOfMonth == "*", month == "*", weekday == "*" {
            return "Every day at \(time)"
        }
        if dayOfMonth == "*", month == "*", ["1-5", "1,2,3,4,5"].contains(weekday) {
            return "Every weekday at \(time)"
        }
        if dayOfMonth == "*", month == "*", let days = weekdayTitles(weekday) {
            return "Every \(list(days)) at \(time)"
        }
        if month == "*", weekday == "*", let day = Int(dayOfMonth), (1...31).contains(day) {
            return "Every month on the \(ordinal(day)) at \(time)"
        }
        return "Custom schedule"
    }

    /// The picker's choice for a cron expression it could have made (daily, weekdays, days of the week,
    /// a day of the month), or nil for anything else.
    static func input(forCron expression: String, timeZoneID: String) -> ScheduleInput? {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]),
              (0...59).contains(minute), (0...23).contains(hour), fields[3] == "*" else { return nil }
        let time = DateComponents(hour: hour, minute: minute)
        switch (fields[2], fields[4]) {
        case ("*", "*"):
            return .daily(time: time, timeZoneID: timeZoneID)
        case ("*", let weekdays):
            var days = Set<Weekday>()
            for part in weekdays.split(separator: ",") {
                let bounds = part.split(separator: "-").compactMap { Int($0) }
                guard (1...2).contains(bounds.count), bounds.allSatisfy({ (0...6).contains($0) }),
                      bounds.first! <= bounds.last! else { return nil }
                for number in bounds.first!...bounds.last! {
                    guard let day = Weekday(rawValue: number + 1) else { return nil }
                    days.insert(day)
                }
            }
            guard !days.isEmpty else { return nil }
            return .repeating(days: days, time: time, timeZoneID: timeZoneID)
        case (let day, "*"):
            guard let day = Int(day), (1...31).contains(day) else { return nil }
            return .monthly(day: day, time: time, timeZoneID: timeZoneID)
        default:
            return nil
        }
    }

    static func validatedHermesRequest(
        for input: ScheduleInput,
        now: Date = .now
    ) throws -> ValidatedHermesScheduleRequest {
        let timeZone = try validatedTimeZone(for: input)
        let expression: String
        switch input {
        case .once(let date, _):
            guard date > now else { throw ScheduledTasksError.dateMustBeInFuture }
            expression = ISO8601DateFormatter().string(from: date)
        case .daily(let time, _):
            let clock = try cronClock(time)
            expression = "\(clock.minute) \(clock.hour) * * *"
        case .repeating(let days, let time, _):
            guard !days.isEmpty else { throw ScheduledTasksError.invalidSchedule }
            let clock = try cronClock(time)
            let weekdays = days
                .map { $0.rawValue - 1 }
                .sorted()
                .map(String.init)
                .joined(separator: ",")
            expression = "\(clock.minute) \(clock.hour) * * \(weekdays)"
        case .weekly(let day, let time, _):
            let clock = try cronClock(time)
            expression = "\(clock.minute) \(clock.hour) * * \(day.rawValue - 1)"
        case .monthly(let day, let time, _):
            guard (1...31).contains(day) else { throw ScheduledTasksError.invalidSchedule }
            let clock = try cronClock(time)
            expression = "\(clock.minute) \(clock.hour) \(day) * *"
        case .naturalLanguage(let description, _):
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ScheduledTasksError.unrecognizedDescription }
            expression = try naturalLanguageHermesRequest(
                trimmed,
                timeZone: timeZone,
                now: now
            )
        case .hermes(let request, _, _):
            let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ScheduledTasksError.invalidSchedule }
            expression = trimmed
        }
        return ValidatedHermesScheduleRequest(
            expression: expression,
            requestedTimeZoneID: input.requestedTimeZoneID.map { _ in timeZone.identifier }
        )
    }

    static func hermesRequest(for input: ScheduleInput, now: Date = .now) throws -> String {
        try validatedHermesRequest(for: input, now: now).expression
    }

    static func request(for input: ScheduleInput, now: Date = .now) throws -> String {
        _ = try validatedHermesRequest(for: input, now: now)
        let zone = try validatedTimeZone(for: input)
        switch input {
        case .once(let date, _):
            return "Once on \(dateText(date, timeZone: zone)) at \(timeText(date, timeZone: zone)) \(zone.identifier)"
        case .daily(let time, _):
            return "Every day at \(try timeText(time)) \(zone.identifier)"
        case .repeating(let days, let time, _):
            guard !days.isEmpty else { throw ScheduledTasksError.invalidSchedule }
            let orderedDays = Weekday.allCases.filter(days.contains)
            let prefix = orderedDays == [.monday, .tuesday, .wednesday, .thursday, .friday]
                ? "Every weekday"
                : "Every \(list(orderedDays.map(\.title)))"
            return "\(prefix) at \(try timeText(time)) \(zone.identifier)"
        case .weekly(let day, let time, _):
            return "Every \(day.title) at \(try timeText(time)) \(zone.identifier)"
        case .monthly(let day, let time, _):
            guard (1...31).contains(day) else { throw ScheduledTasksError.invalidSchedule }
            return "Every month on the \(ordinal(day)) at \(try timeText(time)) \(zone.identifier)"
        case .naturalLanguage(let description, _):
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ScheduledTasksError.unrecognizedDescription }
            return "\(trimmed) \(zone.identifier)"
        case .hermes(_, let display, _):
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ScheduledTasksError.invalidSchedule }
            return trimmed
        }
    }

    static func nextRun(for input: ScheduleInput, after date: Date) throws -> Date {
        let zone = try validatedTimeZone(for: input)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = zone

        switch input {
        case .once(let scheduled, _):
            guard scheduled > date else { throw ScheduledTasksError.dateMustBeInFuture }
            return scheduled
        case .daily(let time, _):
            return try next(calendar: calendar, after: date, matching: time)
        case .repeating(let days, let time, _):
            guard !days.isEmpty else { throw ScheduledTasksError.invalidSchedule }
            let candidates = try days.map { day -> Date in
                var matching = time
                matching.weekday = day.rawValue
                return try next(calendar: calendar, after: date, matching: matching)
            }
            guard let earliest = candidates.min() else { throw ScheduledTasksError.invalidSchedule }
            return earliest
        case .weekly(let day, let time, _):
            var matching = time
            matching.weekday = day.rawValue
            return try next(calendar: calendar, after: date, matching: matching)
        case .monthly(let day, let time, _):
            guard (1...31).contains(day) else { throw ScheduledTasksError.invalidSchedule }
            var matching = time
            matching.day = day
            return try next(calendar: calendar, after: date, matching: matching)
        case .naturalLanguage, .hermes:
            throw ScheduledTasksError.unrecognizedDescription
        }
    }

    private static func next(calendar: Calendar, after date: Date, matching: DateComponents) throws -> Date {
        guard let next = calendar.nextDate(
            after: date,
            matching: matching,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            throw ScheduledTasksError.invalidSchedule
        }
        return next
    }

    private static func validatedTimeZone(for input: ScheduleInput) throws -> TimeZone {
        guard let zone = TimeZone(identifier: input.timeZoneID) else {
            throw ScheduledTasksError.invalidSchedule
        }
        return zone
    }

    private static func timeText(_ time: DateComponents) throws -> String {
        guard let hour = time.hour, let minute = time.minute,
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw ScheduledTasksError.invalidSchedule
        }
        let suffix = hour < 12 ? "AM" : "PM"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return "\(displayHour):\(String(format: "%02d", minute)) \(suffix)"
    }

    private static func cronClock(_ time: DateComponents) throws -> (hour: Int, minute: Int) {
        guard let hour = time.hour, let minute = time.minute,
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw ScheduledTasksError.invalidSchedule
        }
        return (hour, minute)
    }

    private static func naturalLanguageHermesRequest(
        _ description: String,
        timeZone: TimeZone,
        now: Date
    ) throws -> String {
        let normalized = description
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let lowercased = normalized.lowercased()

        if let interval = try intervalRequest(lowercased) { return interval }
        if let scheduled = ISO8601DateFormatter().date(from: normalized) {
            guard scheduled > now else { throw ScheduledTasksError.dateMustBeInFuture }
            return normalized
        }

        guard let atRange = lowercased.range(of: " at ", options: .backwards),
              let clock = naturalLanguageClock(String(lowercased[atRange.upperBound...])) else {
            throw ScheduledTasksError.unrecognizedDescription
        }
        let subject = String(lowercased[..<atRange.lowerBound])
        let timePrefix = "\(clock.minute) \(clock.hour)"
        switch subject {
        case "every day", "daily":
            return "\(timePrefix) * * *"
        case "every weekday", "every weekdays", "weekdays":
            return "\(timePrefix) * * 1-5"
        case "tomorrow":
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
                throw ScheduledTasksError.invalidSchedule
            }
            let date = calendar.dateComponents([.year, .month, .day], from: tomorrow)
            guard let scheduled = calendar.date(from: DateComponents(
                timeZone: timeZone,
                year: date.year,
                month: date.month,
                day: date.day,
                hour: clock.hour,
                minute: clock.minute
            )) else { throw ScheduledTasksError.invalidSchedule }
            guard scheduled > now else { throw ScheduledTasksError.dateMustBeInFuture }
            return ISO8601DateFormatter().string(from: scheduled)
        default:
            break
        }

        if subject.hasPrefix("every month on the ") {
            let ordinalText = subject.dropFirst("every month on the ".count)
            let digits = ordinalText.prefix(while: \.isNumber)
            guard let day = Int(digits), (1...31).contains(day) else {
                throw ScheduledTasksError.unrecognizedDescription
            }
            return "\(timePrefix) \(day) * *"
        }

        if subject.hasPrefix("once on ") {
            let dateText = String(subject.dropFirst("once on ".count))
            guard let scheduled = naturalLanguageDate(
                dateText,
                hour: clock.hour,
                minute: clock.minute,
                timeZone: timeZone
            ) else { throw ScheduledTasksError.unrecognizedDescription }
            guard scheduled > now else { throw ScheduledTasksError.dateMustBeInFuture }
            return ISO8601DateFormatter().string(from: scheduled)
        }

        guard subject.hasPrefix("every ") else {
            throw ScheduledTasksError.unrecognizedDescription
        }
        let dayText = subject
            .dropFirst("every ".count)
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: " and ", with: " ")
        let names = dayText.split(whereSeparator: \.isWhitespace).map(String.init)
        let weekdaysByName = Dictionary(uniqueKeysWithValues: Weekday.allCases.map {
            ($0.title.lowercased(), $0.rawValue - 1)
        })
        let weekdays = names.compactMap { weekdaysByName[$0] }.sorted()
        guard weekdays.count == names.count, !weekdays.isEmpty else {
            throw ScheduledTasksError.unrecognizedDescription
        }
        return "\(timePrefix) * * \(weekdays.map(String.init).joined(separator: ","))"
    }

    private static func intervalRequest(_ description: String) throws -> String? {
        guard description.hasPrefix("every ") else { return nil }
        let value = String(description.dropFirst("every ".count))
        if value == "minute" { return "every 1m" }
        if value == "hour" { return "every 1h" }
        if value == "day" { return "every 1d" }
        let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count == 1, let suffix = parts[0].last, "mhd".contains(suffix),
           let amount = Int(parts[0].dropLast()) {
            guard amount > 0 else { throw ScheduledTasksError.intervalMustBePositive }
            return "every \(amount)\(suffix)"
        }
        guard parts.count == 2 else { return nil }
        let unit: Character?
        switch parts[1] {
        case "minute", "minutes": unit = "m"
        case "hour", "hours": unit = "h"
        case "day", "days": unit = "d"
        default: unit = nil
        }
        guard let unit, let amount = Int(parts[0]) else { return nil }
        guard amount > 0 else { throw ScheduledTasksError.intervalMustBePositive }
        return "every \(amount)\(unit)"
    }

    private static func naturalLanguageClock(_ value: String) -> (hour: Int, minute: Int)? {
        let compact = value.replacingOccurrences(of: " ", with: "").lowercased()
        let suffix: String?
        if compact.hasSuffix("am") { suffix = "am" }
        else if compact.hasSuffix("pm") { suffix = "pm" }
        else { suffix = nil }
        let digits = suffix == nil ? compact : String(compact.dropLast(2))
        let pieces = digits.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count), let rawHour = Int(pieces[0]),
              let minute = pieces.count == 2 ? Int(pieces[1]) : 0,
              (0...59).contains(minute) else { return nil }
        let hour: Int
        switch suffix {
        case "am":
            guard (1...12).contains(rawHour) else { return nil }
            hour = rawHour == 12 ? 0 : rawHour
        case "pm":
            guard (1...12).contains(rawHour) else { return nil }
            hour = rawHour == 12 ? 12 : rawHour + 12
        default:
            guard (0...23).contains(rawHour) else { return nil }
            hour = rawHour
        }
        return (hour, minute)
    }

    private static func naturalLanguageDate(
        _ value: String,
        hour: Int,
        minute: Int,
        timeZone: TimeZone
    ) -> Date? {
        let formats = ["MMMM d, yyyy", "MMM d, yyyy", "M/d/yyyy", "yyyy-MM-dd"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            guard let day = formatter.date(from: value) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            return calendar.date(from: DateComponents(
                timeZone: timeZone,
                year: components.year,
                month: components.month,
                day: components.day,
                hour: hour,
                minute: minute
            ))
        }
        return nil
    }

    private static func timeText(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private static func dateText(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: items.joined(separator: " and ")
        default: items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    private static func weekdayTitles(_ value: String) -> [String]? {
        let values = value.split(separator: ",").compactMap { Int($0) }
        guard !values.isEmpty, values.count == value.split(separator: ",").count,
              values.allSatisfy({ (0...7).contains($0) }) else { return nil }
        let titles = values.map { number -> String in
            let normalized = number == 7 ? 0 : number
            return Weekday(rawValue: normalized + 1)?.title ?? ""
        }
        return titles.allSatisfy { !$0.isEmpty } ? titles : nil
    }

    private static func ordinal(_ value: Int) -> String {
        let suffix: String
        if (11...13).contains(value % 100) {
            suffix = "th"
        } else {
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(value)\(suffix)"
    }
}
