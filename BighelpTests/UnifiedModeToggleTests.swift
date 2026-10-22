import Foundation
import Testing
@testable import Bighelp

/// Bots, Chat and Code: the Unified Mode Toggle, the mode swipes and ⌃⌘1–⌃⌘3 all switch through
/// `SettingsStore.switchMode`, so these check the modes it offers and where each choice lands.
@MainActor
struct UnifiedModeToggleTests {
    private func store(_ setup: (UserDefaults) -> Void = { _ in }) -> (SettingsStore, () -> Void) {
        let suite = "unified-mode-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        setup(defaults)
        return (SettingsStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func theToggleIsOffOutOfTheBoxAndRemembered() {
        let suite = "unified-mode-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.unifiedModeToggleEnabled)
        settings.unifiedModeToggleEnabled = true
        #expect(SettingsStore(defaults: defaults).unifiedModeToggleEnabled)
    }

    @Test func codeIsOfferedOnlyWhileCodeModeIsOn() {
        let (settings, cleanup) = store()
        defer { cleanup() }
        #expect(settings.availableModes == [.bots, .chat])
        settings.codeModeEnabled = true
        #expect(settings.availableModes == [.bots, .chat, .code])
    }

    @Test func eachModeLandsOnItsHome() {
        let (settings, cleanup) = store()
        defer { cleanup() }
        settings.codeModeEnabled = true
        #expect(settings.currentMode == .chat)

        settings.switchMode(.code)
        #expect(settings.currentMode == .code)
        #expect(settings.experience == .code)
        #expect(!settings.simpleBotsEnabled)

        settings.switchMode(.bots)
        #expect(settings.currentMode == .bots)
        #expect(settings.simpleBotsEnabled)

        settings.switchMode(.chat)
        #expect(settings.currentMode == .chat)
        #expect(settings.experience == .bighelp)
        #expect(!settings.simpleBotsEnabled)
    }

    @Test func codeCanNotBePickedWhileCodeModeIsOff() {
        let (settings, cleanup) = store()
        defer { cleanup() }
        settings.switchMode(.code)
        #expect(settings.currentMode == .chat)
        #expect(settings.experience == .bighelp)
    }

    @Test func nextModeCyclesThroughWhatIsOffered() {
        let (settings, cleanup) = store()
        defer { cleanup() }
        #expect(settings.nextMode == .bots)
        settings.switchMode(settings.nextMode)
        #expect(settings.currentMode == .bots)
        #expect(settings.nextMode == .chat)

        settings.codeModeEnabled = true
        settings.switchMode(.chat)
        #expect(settings.nextMode == .code)
        settings.switchMode(settings.nextMode)
        #expect(settings.nextMode == .bots)
    }

    @Test func modeSwipesStayModeSwipesInBotsMode() {
        let (settings, cleanup) = store()
        defer { cleanup() }
        settings.leftEdgeSwipeAction = .chatMode
        settings.rightEdgeSwipeAction = .newChat
        settings.simpleBotsEnabled = true
        // Bots mode keeps its own swipes for places, but a mode swipe still brings you back out.
        #expect(settings.effectiveLeftEdgeSwipeAction == .chatMode)
        #expect(settings.effectiveRightEdgeSwipeAction == .profile)
        settings.simpleBotsEnabled = false
        #expect(settings.effectiveRightEdgeSwipeAction == .newChat)
    }

    @Test func aCodeSwipeDoesNothingOnceCodeModeIsOff() {
        let (settings, cleanup) = store()
        defer { cleanup() }
        settings.codeModeEnabled = true
        settings.leftEdgeSwipeAction = .codeMode
        #expect(settings.effectiveLeftEdgeSwipeAction == .codeMode)
        settings.codeModeEnabled = false
        #expect(settings.effectiveLeftEdgeSwipeAction == WorkspaceSwipeAction.none)
    }
}
