import Testing
@testable import Bighelp

/// Settings › Your computers: which setting Show every computer changes, and the time zone row's value.
@MainActor
struct SettingsComputersTests {
    @Test func showEveryComputerIsBotsModesMultiGatewayWhileBotsModeIsOn() {
        #expect(SettingsEveryComputer.choice(botsModeOn: true, canSetAllHosts: true) == .botsMultiGateway)
        #expect(SettingsEveryComputer.choice(botsModeOn: true, canSetAllHosts: false) == .botsMultiGateway)
    }

    @Test func showEveryComputerIsTheAllHostsViewElsewhereWhenTheShellCanSetIt() {
        #expect(SettingsEveryComputer.choice(botsModeOn: false, canSetAllHosts: true) == .allHosts)
        #expect(SettingsEveryComputer.choice(botsModeOn: false, canSetAllHosts: false) == nil)
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
