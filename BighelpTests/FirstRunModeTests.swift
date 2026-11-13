import Foundation
import Testing
@testable import Bighelp

/// "How do you want to start?" at the end of setup: each choice sets where the home opens and its view.
@MainActor
struct FirstRunHomeTests {
    private func settings() -> (SettingsStore, () -> Void) {
        let suite = "first-run-home-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func withABotOpensOnBots() {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        FirstRunHome.bots.apply(to: settings)
        #expect(settings.homeLanding == .bots)
        #expect(settings.homeView == .bots)
    }

    @Test func acrossChatsOpensOnChats() {
        let (settings, cleanUp) = settings()
        defer { cleanUp() }
        settings.homeLanding = .bots
        FirstRunHome.chats.apply(to: settings)
        #expect(settings.homeLanding == .chats)
        #expect(settings.homeView == .chats)
    }
}
