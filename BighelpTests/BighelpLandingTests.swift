import Foundation
import Testing
@testable import Bighelp

/// Opens on: the home's four places, and how a screen saved before the one home maps to one.
@MainActor
struct BighelpLandingTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "landing-\(UUID().uuidString)")!
    }

    @Test func everyOldScreenMapsToItsPlace() {
        #expect(BighelpLandingScreen.allCases.map(\.homeLanding)
                == [.bots, .bots, .chats, .chats, .today, .today, .today, .work, .work])
    }

    @Test func opensOnReadsTheFourAndMapsTheOldOnes() {
        #expect(BighelpLanding.homeLanding(stored: "today") == .today)
        #expect(BighelpLanding.homeLanding(stored: "all-agents") == .bots)
        #expect(BighelpLanding.homeLanding(stored: "kanban") == .work)
        #expect(BighelpLanding.homeLanding(stored: "dashboard") == nil)
        #expect(BighelpLanding.homeLanding(stored: nil) == nil)
    }

    @Test func aPickedPlaceAppliesNextLaunch() {
        let saved = defaults()
        let settings = SettingsStore(defaults: saved)
        settings.homeLanding = .today
        #expect(settings.launchHomeLanding == .chats, "This launch already happened")
        #expect(SettingsStore(defaults: saved).launchHomeLanding == .today)
    }

    @Test func anOldOrUnknownSavedScreenStillOpensSomewhere() {
        let saved = defaults()
        saved.set("goals", forKey: BighelpLanding.screenKey)
        #expect(SettingsStore(defaults: saved).launchHomeLanding == .today)
        saved.set("dashboard", forKey: BighelpLanding.screenKey)
        #expect(SettingsStore(defaults: saved).launchHomeLanding == .chats)
    }
}
