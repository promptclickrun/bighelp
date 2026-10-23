import Foundation
import UserNotifications

/// What bighelp's Focus filter (`BighelpFocusFilter`) last told the app: which filter is on, the
/// person's note for agents, and whether agent alerts should stay quiet. iOS runs the filter when a
/// Focus turns on or off and gives the app nothing else about Focus, so this is the only source.
/// Kept in the app group: the app answers `focus.current` from it and the notification extension
/// reads it to deliver agent alerts passively.
struct BighelpFocusFilterState: Codable, Equatable, Sendable {
    static let appGroup = "group.app.loopdy.mobile.buzzkit"
    static let key = "bighelp.focus-filter.v1"
    static let maximumNameLength = 100
    static let maximumNoteLength = 1_000

    var active: Bool
    var name: String?
    var note: String?
    var quietAlerts: Bool
    /// When this filter turned on. Only while `active`.
    var since: Date?

    static let inactive = BighelpFocusFilterState(active: false, name: nil, note: nil, quietAlerts: false, since: nil)

    /// The state after iOS runs the filter with these values. When a Focus turns off, iOS runs it
    /// again with every value at its default (a missing name and note, Quiet agent alerts off), and
    /// the filter has no other way to say it is off. A filter set up with nothing filled in reads
    /// the same, and says nothing worth keeping.
    static func applying(name: String?, note: String?, quietAlerts: Bool, to previous: BighelpFocusFilterState,
                         now: Date = Date()) -> BighelpFocusFilterState {
        let name = clean(name, limit: maximumNameLength)
        let note = clean(note, limit: maximumNoteLength)
        guard name != nil || note != nil || quietAlerts else { return .inactive }
        let unchanged = previous.active && previous.name == name && previous.note == note
            && previous.quietAlerts == quietAlerts
        // iOS can run an active filter again with the same values; that is not a new start.
        let since = unchanged ? (previous.since ?? now) : now
        return BighelpFocusFilterState(active: true, name: name, note: note, quietAlerts: quietAlerts, since: since)
    }

    /// Text from the person: bounded, without control characters (a line break stays), or nil when blank.
    static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let visible = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
        }))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    /// How long a filter counts as on after iOS last said so. iOS tells the app only when a Focus
    /// turns on or off; if the off call never comes (the filter was removed from an active Focus,
    /// bighelp could not launch), a saved "on" would quiet alerts and answer agents forever.
    static let maximumAge: TimeInterval = 24 * 60 * 60

    /// This state as of `now`: inactive once it is older than `maximumAge` (or has no start).
    func current(now: Date) -> BighelpFocusFilterState {
        guard active, let since, now.timeIntervalSince(since) <= Self.maximumAge else { return .inactive }
        return self
    }

    /// Alert kinds that need the person (`approval.required`, `clarification.required`,
    /// `attention.required`, and any other `.required`) and the host's own request names for the same
    /// things (`clarify.request`, `approval.request`, `sudo.request`, `secret.request`). A Focus that
    /// quiets replies lets these through at their usual level. Unknown kinds count as replies.
    static func needsThePerson(eventType: String) -> Bool {
        eventType.hasSuffix(".required") || eventType.hasSuffix(".request")
    }

    /// Delivers an ordinary agent alert passively (Notification Center only, no banner or sound)
    /// while a filter with Quiet agent alerts is on.
    static func quiet(_ content: UNMutableNotificationContent, eventType: String,
                      store: BighelpFocusFilterStore = .shared) {
        guard !needsThePerson(eventType: eventType) else { return }
        let state = store.read()
        guard state.active, state.quietAlerts else { return }
        content.interruptionLevel = .passive
        content.sound = nil
    }
}

/// Reads and writes the filter's state in the app group. The filter runs in the app's process (in
/// the background) and the notification extension is its own process, so they share it by `UserDefaults`.
struct BighelpFocusFilterStore: @unchecked Sendable {
    let defaults: UserDefaults?
    /// What "now" is when reading a state's age. Tests set it.
    let clock: @Sendable () -> Date

    init(defaults: UserDefaults?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
    }

    static var shared: BighelpFocusFilterStore {
        BighelpFocusFilterStore(defaults: UserDefaults(suiteName: BighelpFocusFilterState.appGroup))
    }

    /// Anything missing, from a newer or older writer, or unreadable reads as no filter.
    func read() -> BighelpFocusFilterState {
        guard let data = defaults?.data(forKey: BighelpFocusFilterState.key),
              data.count <= 8_192,
              let state = try? JSONDecoder().decode(BighelpFocusFilterState.self, from: data) else { return .inactive }
        return state.current(now: clock())
    }

    func write(_ state: BighelpFocusFilterState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults?.set(data, forKey: BighelpFocusFilterState.key)
    }

    /// Runs the filter's values through `applying` and keeps the result.
    @discardableResult
    func apply(name: String?, note: String?, quietAlerts: Bool, now: Date? = nil) -> BighelpFocusFilterState {
        let now = now ?? clock()
        let state = BighelpFocusFilterState.applying(name: name, note: note, quietAlerts: quietAlerts,
                                                     to: read(), now: now)
        write(state)
        return state
    }
}
