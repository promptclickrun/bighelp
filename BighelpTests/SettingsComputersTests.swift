import Foundation
import Testing
@testable import Bighelp

/// Settings › Your computers: the one Show every computer setting, and the time zone row's value.
@MainActor
struct SettingsComputersTests {
    @Test func showEveryComputerKeepsTheOldAllHostsKey() {
        let suite = "settings-computers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)

        settings.showsEveryComputer = false
        #expect(defaults.object(forKey: "bighelp.hosts.all-hosts") as? Bool == false)
        settings.showsEveryComputer = true
        #expect(SettingsStore(defaults: defaults).showsEveryComputer)
        #expect(defaults.object(forKey: "bighelp.hosts.all-hosts") as? Bool == true, "The all-hosts key, kept")
    }

    @Test func timeZoneSaysNothingUntilTheComputerAnswers() {
        #expect(SettingsTimeZoneValue.text(load: .idle, timeZone: "", automatic: false) == nil)
        #expect(SettingsTimeZoneValue.text(load: .loading, timeZone: "Europe/Paris", automatic: true) == nil)
    }

    @Test func timeZoneSaysWhyItCantChangeWhileTheComputerIsNotReachable() {
        #expect(SettingsTimeZoneValue.text(load: .unavailable, timeZone: "", automatic: true)
            == "Connect your computer first.")
    }

    @Test func timeZoneShowsAutomaticTheZoneOrTheComputersOwn() {
        #expect(SettingsTimeZoneValue.text(load: .loaded, timeZone: "Europe/Paris", automatic: true) == "Automatic")
        #expect(SettingsTimeZoneValue.text(load: .loaded, timeZone: "America/New_York", automatic: false)
            == "America/New York")
        #expect(SettingsTimeZoneValue.text(load: .loaded, timeZone: "", automatic: false) == "The computer's own")
    }
}
