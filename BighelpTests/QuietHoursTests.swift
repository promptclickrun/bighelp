import Foundation
import Testing
@testable import Bighelp

struct QuietHoursTests {
    private static let night = BighelpQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)

    @Test func aWindowAcrossMidnightCoversTheLateEveningAndTheEarlyMorning() {
        let night = Self.night
        #expect(night.crossesMidnight)
        #expect(!night.contains(minuteOfDay: 21 * 60 + 59))
        #expect(night.contains(minuteOfDay: 22 * 60), "The start is inside")
        #expect(night.contains(minuteOfDay: 23 * 60 + 59))
        #expect(night.contains(minuteOfDay: 0))
        #expect(night.contains(minuteOfDay: 6 * 60 + 59))
        #expect(!night.contains(minuteOfDay: 7 * 60), "The end is outside")
        #expect(!night.contains(minuteOfDay: 12 * 60))
    }

    @Test func aWindowOnOneDay() {
        let afternoon = BighelpQuietHours(enabled: true, startMinute: 13 * 60, endMinute: 15 * 60)
        #expect(!afternoon.crossesMidnight)
        #expect(!afternoon.contains(minuteOfDay: 12 * 60 + 59))
        #expect(afternoon.contains(minuteOfDay: 13 * 60))
        #expect(afternoon.contains(minuteOfDay: 14 * 60 + 59))
        #expect(!afternoon.contains(minuteOfDay: 15 * 60))
        #expect(!afternoon.contains(minuteOfDay: 23 * 60))
    }

    @Test func offOrEqualTimesAreNeverQuiet() {
        var off = Self.night
        off.enabled = false
        #expect(!off.contains(minuteOfDay: 23 * 60))
        let empty = BighelpQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 22 * 60)
        #expect(empty.isEmpty)
        for minute in [0, 22 * 60, 22 * 60 + 1, 1439] { #expect(!empty.contains(minuteOfDay: minute)) }
    }

    @Test func nowIsReadOnTheDevicesClockWithDaylightSavingTime() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        // 20:30 UTC is 22:30 in Berlin in summer (quiet) but 21:30 in winter (not yet).
        #expect(Self.night.isQuiet(at: try Self.date("2026-07-01T20:30:00Z"), in: berlin))
        #expect(!Self.night.isQuiet(at: try Self.date("2026-01-15T20:30:00Z"), in: berlin))
        // 05:30 UTC is 07:30 in summer (awake) and 06:30 in winter (still quiet).
        #expect(!Self.night.isQuiet(at: try Self.date("2026-07-01T05:30:00Z"), in: berlin))
        #expect(Self.night.isQuiet(at: try Self.date("2026-01-15T05:30:00Z"), in: berlin))
    }

    @Test func theDeviceKeepsTheSettingAndFallsBackToOffForBadData() throws {
        let suite = "bighelp.test.quiet-hours." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BighelpQuietHours.load(defaults) == BighelpQuietHours(), "Off, 22:00 to 07:00, until changed")
        Self.night.save(defaults)
        #expect(BighelpQuietHours.load(defaults) == Self.night)
        defaults.set(Data("{\"enabled\":true,\"startMinute\":1440,\"endMinute\":0}".utf8), forKey: BighelpQuietHours.key)
        #expect(BighelpQuietHours.load(defaults) == BighelpQuietHours())
    }

    @Test func theComputerGetsTheWindowAndTheDevicesTimeZone() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(BighelpQuietHours.timeZoneID(tokyo) == "Asia/Tokyo")
        #expect(Self.night.body(grantID: "grant", timeZone: "Asia/Tokyo") == [
            "grantId": .string("grant"), "enabled": .boolean(true), "startMinute": .integer(1320),
            "endMinute": .integer(420), "timeZone": .string("Asia/Tokyo"),
        ])
    }

    @Test func computersWithAnOlderPluginAreNamedInOneShortNote() {
        #expect(BighelpQuietHoursSyncResult().note == nil)
        #expect(BighelpQuietHoursSyncResult(needsPluginUpdate: ["Studio Mac"]).note
            == "Quiet Hours needs a plugin update on Studio Mac.")
        #expect(BighelpQuietHoursSyncResult(needsPluginUpdate: ["Studio Mac", "Home Server"]).note
            == "Quiet Hours needs a plugin update on Studio Mac and Home Server.")
        #expect(BighelpQuietHoursSyncResult(needsPluginUpdate: ["A", "B", "C"]).note
            == "Quiet Hours needs a plugin update on A, B and C.")
    }

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }
}
