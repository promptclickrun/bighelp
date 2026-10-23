// AlarmKit is iPhone and iPad only (iOS 26 and later). Mac Catalyst marks all of it unavailable
// and Vision Pro doesn't have it, so this file is empty there.
#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AlarmKit)
import AlarmKit
import AppIntents
import Foundation

/// What the alarm's Live Activity shows that AlarmKit doesn't hand back later: the label an agent chose.
/// Both the app (when it schedules) and the Live Activity extension (when it draws) use this type.
@available(iOS 26.0, *)
struct BighelpAlarmMetadata: AlarmMetadata {
    enum Kind: String, Codable, Hashable, Sendable {
        case alarm, timer
    }

    var label: String
    var kind: Kind
}

/// The buttons on a running timer's Live Activity. They run in the app, which is how AlarmKit
/// expects a countdown to be changed. `isDiscoverable` keeps them out of the Shortcuts app.
@available(iOS 26.0, *)
struct BighelpAlarmPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause timer"
    static let isDiscoverable = false

    @Parameter(title: "Alarm")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try AlarmManager.shared.pause(id: id) }
        return .result()
    }
}

@available(iOS 26.0, *)
struct BighelpAlarmResumeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume timer"
    static let isDiscoverable = false

    @Parameter(title: "Alarm")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try AlarmManager.shared.resume(id: id) }
        return .result()
    }
}

@available(iOS 26.0, *)
struct BighelpAlarmCancelIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel timer"
    static let isDiscoverable = false

    @Parameter(title: "Alarm")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try AlarmManager.shared.cancel(id: id) }
        return .result()
    }
}
#endif
