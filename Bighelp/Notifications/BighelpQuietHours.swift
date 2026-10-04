import Foundation

/// Quiet Hours: a daily window when this device's computers send it no notifications.
///
/// The device keeps the window and gives it, with its own time zone, to every computer
/// that sends it notifications. The computer checks it just before each alert and skips
/// the alert inside it, so nothing reaches the notification service. A skipped alert is
/// never sent later: the reply is in the chat. The start is inside the window and the end
/// is not; a window can cross midnight (22:00 to 07:00). Equal times make an empty window.
struct BighelpQuietHours: Codable, Equatable, Sendable {
    static let minutesPerDay = 1440
    static let key = "bighelp.notifications.quiet-hours"
    /// Plugins from the release after 3.4.9 keep the window with each notification grant.
    static let feature = "native-notification-quiet-hours-v1"
    static let route = "/notifications/quiet-hours"

    var enabled = false
    var startMinute = 22 * 60
    var endMinute = 7 * 60

    var isEmpty: Bool { startMinute == endMinute }
    var crossesMidnight: Bool { startMinute > endMinute }

    /// Whether a minute of the day (0 to 1439) is inside the window. Same rule as the plugin.
    func contains(minuteOfDay minute: Int) -> Bool {
        guard enabled, !isEmpty else { return false }
        if startMinute < endMinute { return startMinute <= minute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    /// Whether the window holds at `date` on a clock in `timeZone`.
    func isQuiet(at date: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return contains(minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// The window a computer keeps for this device: the setting and the device's time zone.
    struct Sent: Codable, Equatable, Sendable {
        let quietHours: BighelpQuietHours
        let timeZone: String
    }

    func body(grantID: String, timeZone: String) -> [String: BighelpJSONValue] {
        ["grantId": .string(grantID), "enabled": .boolean(enabled), "startMinute": .integer(startMinute),
         "endMinute": .integer(endMinute), "timeZone": .string(timeZone)]
    }

    var isValid: Bool {
        (0..<Self.minutesPerDay).contains(startMinute) && (0..<Self.minutesPerDay).contains(endMinute)
    }

    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return Self() }
        return value
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// An IANA ID the plugin accepts (`Europe/Berlin`). The device's zone always is one.
    static func timeZoneID(_ timeZone: TimeZone = .current) -> String {
        let identifier = timeZone.identifier
        guard (1...64).contains(identifier.utf8.count),
              identifier.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [43, 45, 47, 95].contains($0) }) else { return "UTC" }
        return identifier
    }
}

/// What happened when the device gave its Quiet Hours to its computers.
struct BighelpQuietHoursSyncResult: Equatable, Sendable {
    /// Computers whose plugin doesn't have Quiet Hours yet, by name.
    var needsPluginUpdate: [String] = []

    /// The short note Settings shows, or nil when every computer has it.
    var note: String? {
        let names = needsPluginUpdate
        guard !names.isEmpty else { return nil }
        let list = names.count < 3 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "Quiet Hours needs a plugin update on \(list)."
    }
}

/// How Settings › Notifications gives Quiet Hours to the computers.
struct BighelpQuietHoursSync: Sendable {
    let apply: @MainActor @Sendable () async -> BighelpQuietHoursSyncResult

    @MainActor
    static func live(_ registry: BighelpHostRegistry?) -> Self {
        Self { [weak registry] in
            await registry?.notificationSetup?.applyQuietHours() ?? BighelpQuietHoursSyncResult()
        }
    }

    #if DEBUG
    /// Demo mode: the demo computers have Quiet Hours. `-demo-quiet-hours-old-plugin`
    /// gives Studio Mac an older plugin.
    static let demo = Self {
        ProcessInfo.processInfo.arguments.contains("-demo-quiet-hours-old-plugin")
            ? BighelpQuietHoursSyncResult(needsPluginUpdate: ["Studio Mac"]) : BighelpQuietHoursSyncResult()
    }
    #endif
}
