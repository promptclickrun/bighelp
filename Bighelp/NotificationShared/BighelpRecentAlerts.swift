import Foundation

/// Alerts this device already showed straight from the host (instant alerts,
/// `BighelpLiveAlertListener`), by event ID. Both copies of an alert carry the
/// same event ID, so a push of it that arrives later (its ack was lost) replaces
/// the first copy quietly instead of ringing again. Kept in the app group so the
/// notification extension reads it too.
struct BighelpRecentAlerts: @unchecked Sendable {
    static let appGroup = "group.app.loopdy.mobile.buzzkit"
    static let limit = 128
    /// Longer than any alert waits for its push (15 minutes at most).
    static let lifetime: TimeInterval = 3_600
    private static let key = "bighelp.instant-alerts.shown"
    private static let lock = NSLock()

    let defaults: UserDefaults?

    static var shared: BighelpRecentAlerts { BighelpRecentAlerts(defaults: UserDefaults(suiteName: appGroup)) }

    func contains(_ eventID: String, now: Date = Date()) -> Bool {
        guard let shown = entries()[eventID] else { return false }
        return now.timeIntervalSince1970 - shown < Self.lifetime
    }

    func insert(_ eventID: String, now: Date = Date()) {
        guard let defaults, !eventID.isEmpty, eventID.utf8.count <= 256 else { return }
        Self.lock.withLock {
            let time = now.timeIntervalSince1970
            var kept = entries().filter { time - $0.value < Self.lifetime }
            kept[eventID] = time
            if kept.count > Self.limit {
                for old in kept.sorted(by: { $0.value < $1.value }).prefix(kept.count - Self.limit) {
                    kept[old.key] = nil
                }
            }
            defaults.set(kept, forKey: Self.key)
        }
    }

    private func entries() -> [String: Double] {
        (defaults?.dictionary(forKey: Self.key) as? [String: Double]) ?? [:]
    }
}
