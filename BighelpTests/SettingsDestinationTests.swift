import Testing
@testable import Bighelp

@MainActor
struct SettingsDestinationTests {
    @Test func openingSettingsAtPagesPresentsThemInOrder() {
        let state = AppState()

        state.openSettings(at: [.section(.appearance), .thinking])

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
        state.openSettings(at: [.section(.appearance), .thinking])

        state.openSettings(at: [.section(.chat)])

        #expect(state.isSettingsPresented)
        #expect(state.settingsPath.count == 1)
    }

    @Test func closingSettingsDismissesItAndForgetsThePages() {
        let state = AppState()
        state.openSettings(at: [.section(.chat), .chatLayout])

        state.closeSettings()

        #expect(!state.isSettingsPresented)
        #expect(state.settingsPath.isEmpty)
    }

    /// A computer added in Settings becomes the one in use, and every computer has its own
    /// `AppState`. Settings is one for the whole app, so it is still open for the new computer:
    /// kept per computer, it closed there and a blank Add a computer sheet took its place.
    @Test func settingsStaysOpenWhenTheComputerInUseChanges() {
        let home = HomeSelection()
        let first = AppState(home: home), second = AppState(home: home)

        first.openSettings(at: [.section(.chat)])

        #expect(second.isSettingsPresented)
        #expect(second.settingsPath.count == 1)
        second.closeSettings()
        #expect(!first.isSettingsPresented)
        #expect(first.settingsPath.isEmpty)
    }

    @Test func settingsClosesWhenTheComputerChangesButNotWhileItAddsOne() {
        #expect(SettingsOnComputerChange.closes(hadComputer: true, isAddingComputer: false), "Use this computer, or one removed")
        #expect(!SettingsOnComputerChange.closes(hadComputer: true, isAddingComputer: true),
                "The added computer becomes the one in use under its own sheet")
        #expect(!SettingsOnComputerChange.closes(hadComputer: false, isAddingComputer: false), "A launch")
    }
}
