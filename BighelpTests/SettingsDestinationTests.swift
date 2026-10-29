import Testing
@testable import Bighelp

@MainActor
struct SettingsDestinationTests {
    @Test func openingSettingsAtPagesPresentsThemInOrder() {
        let state = AppState()

        state.openSettings(at: [.section(.appearance), .appLayout])

        #expect(state.isSettingsPresented)
        #expect(state.settingsPath.count == 2)
    }

    @Test func openingSettingsWithoutPagesShowsTheFirstScreen() {
        let state = AppState()

        state.openSettings()

        #expect(state.isSettingsPresented)
        #expect(state.settingsPath.isEmpty)
    }

    @Test func openingAgainReplacesThePagesOfTheOpenSettings() {
        let state = AppState()
        state.openSettings(at: [.section(.connectivityAndNotifications), .connection])

        state.openSettings(at: [.bots(.chat)])

        #expect(state.isSettingsPresented)
        #expect(state.settingsPath.count == 1)
    }

    @Test func closingSettingsDismissesItAndForgetsThePages() {
        let state = AppState()
        state.openSettings(at: [.allSettings, .section(.chat)])

        state.closeSettings()

        #expect(!state.isSettingsPresented)
        #expect(state.settingsPath.isEmpty)
    }
}
