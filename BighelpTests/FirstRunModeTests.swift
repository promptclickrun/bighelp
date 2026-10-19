import Foundation
import Testing
import UIKit
@testable import Bighelp

/// "Choose your mode" at the end of setup: each card turns on its own home and turns the others off.
@MainActor
struct FirstRunModeTests {
    private func settings() -> (SettingsStore, () -> Void) {
        let suite = "first-run-mode-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func botsTurnsOnSimpleBotMode() {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        settings.codeModeEnabled = true
        FirstRunMode.bots.apply(to: settings)
        #expect(settings.simpleBotsEnabled)
        #expect(!settings.codeModeEnabled)
    }

    @Test func sessionsKeepsTheAppAsItComes() {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        settings.simpleBotsEnabled = true
        settings.codeModeEnabled = true
        FirstRunMode.sessions.apply(to: settings)
        #expect(!settings.simpleBotsEnabled)
        #expect(!settings.codeModeEnabled)
        #expect(settings.experience == .bighelp)
    }

    @Test func codeOpensInBighelpIDE() {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        settings.simpleBotsEnabled = true
        FirstRunMode.code.apply(to: settings)
        #expect(!settings.simpleBotsEnabled)
        #expect(settings.codeModeEnabled)
        #expect(settings.startExperience == .code)
        #expect(settings.experience == .code)
    }

    @Test func everyModeHasAPreviewInTheApp() {
        for mode in FirstRunMode.allCases {
            #expect(UIImage(named: mode.previewImage) != nil, "\(mode.title) needs its preview")
        }
    }
}
