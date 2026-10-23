@preconcurrency import EventKit
import CoreLocation
import Foundation

/// A reminder's place: iOS Reminders itself watches it and alerts when the person arrives or
/// leaves, so it needs no location permission from bighelp. It's an `EKAlarm` with an
/// `EKStructuredLocation` and a proximity. `reminders.create` and `reminders.update` take it as
/// `locationTrigger`; `reminders.list` gives it back.
struct ReminderLocationTrigger: Equatable, Sendable {
    enum Proximity: String, Sendable {
        case arrive, leave
    }

    static let allowedKeys: Set<String> = ["name", "latitude", "longitude", "radiusMeters", "proximity"]
    static let radiusRange: ClosedRange<Double> = 100...5000
    static let defaultRadius: Double = 150
    static let maximumNameLength = 100

    let name: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let proximity: Proximity

    /// Checks everything before a reminder changes. A wrong type, an unknown key or an
    /// out-of-range value is `invalid_arguments`.
    static func parse(_ value: BighelpJSONValue) throws -> ReminderLocationTrigger {
        guard let fields = value.object, Set(fields.keys).isSubset(of: allowedKeys),
              let rawName = fields["name"]?.string,
              let latitude = fields["latitude"]?.number, let longitude = fields["longitude"]?.number,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              let proximityName = fields["proximity"]?.string,
              let proximity = Proximity(rawValue: proximityName)
        else { throw AppleDeviceToolError.invalidArguments }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maximumNameLength,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AppleDeviceToolError.invalidArguments }
        var radius = defaultRadius
        if let raw = fields["radiusMeters"] {
            guard let number = raw.number, number.isFinite, radiusRange.contains(number) else {
                throw AppleDeviceToolError.invalidArguments
            }
            radius = number
        }
        return ReminderLocationTrigger(name: name, latitude: latitude, longitude: longitude,
                                       radiusMeters: radius, proximity: proximity)
    }

    func makeAlarm() -> EKAlarm {
        let place = EKStructuredLocation(title: name)
        place.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        place.radius = radiusMeters
        let alarm = EKAlarm()
        alarm.structuredLocation = place
        alarm.proximity = proximity == .arrive ? .enter : .leave
        return alarm
    }

    /// Replaces the reminder's place alarm (nil removes it). Alarms that fire at a time stay.
    static func apply(_ trigger: ReminderLocationTrigger?, to reminder: EKReminder) {
        for alarm in reminder.alarms ?? [] where alarm.structuredLocation != nil {
            reminder.removeAlarm(alarm)
        }
        if let trigger { reminder.addAlarm(trigger.makeAlarm()) }
    }

    /// The reminder's place as the agent reads it, or nil when it has none. EventKit calls the
    /// reminder fetch on its own queue, so this touches nothing of the main actor.
    nonisolated static func read(from reminder: EKReminder) -> BighelpJSONValue? {
        guard let alarm = (reminder.alarms ?? []).first(where: {
                  $0.structuredLocation?.geoLocation != nil && $0.proximity != .none
              }),
              let place = alarm.structuredLocation, let location = place.geoLocation
        else { return nil }
        let name = String(String.UnicodeScalarView((place.title ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: BighelpJSONValue] = [
            "latitude": .number(rounded(location.coordinate.latitude)),
            "longitude": .number(rounded(location.coordinate.longitude)),
            "proximity": .string(alarm.proximity == .enter ? "arrive" : "leave"),
        ]
        if !name.isEmpty { fields["name"] = .string(String(name.prefix(maximumNameLength))) }
        if place.radius > 0 {
            let radius = min(max(place.radius, radiusRange.lowerBound), radiusRange.upperBound)
            fields["radiusMeters"] = radius.rounded() == radius ? .integer(Int(radius)) : .number(radius)
        }
        return .object(fields)
    }

    private nonisolated static func rounded(_ degrees: Double) -> Double {
        (degrees * 1_000_000).rounded() / 1_000_000
    }
}
