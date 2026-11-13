import Foundation

/// One home (#977): reads once what the three modes saved and decides where the home opens, which view
/// its first tab shows, whether every computer shows, and the edge swipes without the mode actions.
/// `SettingsStore.init` runs it while `markerKey` is unset. No key is renamed, and the old keys stay as
/// they were; only the new truth is written, and only what reading the old keys can't give by itself.
enum HomeSettingsMigration {
    static let markerKey = "bighelp.home.migrated-v1"

    /// What the modes saved, as plain values.
    struct Stored: Equatable, Sendable {
        var botsMode = false
        var codeMode = false
        /// Settings › Modes' Code as the home a launch opens in (`code-mode.open-in`).
        var codeOpensAtLaunch = false
        /// `loopdy.home.landing`: one of the nine old screens, or already one of the four new values.
        var landing: String?
        var allHosts: Bool?
        var multiGateway = false
        var leftEdge: String?
        var rightEdge: String?
        /// Anything saved before: an install that ran the modes. A new one has none of it.
        var isExistingInstall = false
    }

    struct Outcome: Equatable, Sendable {
        var landing: HomeLanding
        var view: HomeConversationsView
        var showsEveryComputer: Bool
        var leftEdge: WorkspaceSwipeAction
        var rightEdge: WorkspaceSwipeAction
    }

    static let defaultLeftEdge = WorkspaceSwipeAction.sessions
    static let defaultRightEdge = WorkspaceSwipeAction.newChat

    /// Where a person lands; the first row that matches wins (PLAN-shell § 4).
    static func outcome(_ stored: Stored) -> Outcome {
        let left = remapped(stored.leftEdge, edgeDefault: defaultLeftEdge)
        let right = remapped(stored.rightEdge, edgeDefault: defaultRightEdge)
        // A new install is asked at first run; skipped (a launch argument, a restored backup), it's Chats.
        guard stored.isExistingInstall else {
            return Outcome(landing: .chats, view: .chats, showsEveryComputer: true, leftEdge: left, rightEdge: right)
        }
        let wasAllHosts = stored.allHosts ?? false
        // Bots mode had its own swipes whatever was saved: from the left your bots, from the right this
        // bot's page. Written down, so nothing changes under the person's thumb.
        if stored.botsMode {
            return Outcome(landing: .bots, view: .bots, showsEveryComputer: stored.multiGateway,
                           leftEdge: .agents, rightEdge: .profile)
        }
        func landingOn(_ landing: HomeLanding, everyComputer: Bool) -> Outcome {
            Outcome(landing: landing, view: landing == .bots ? .bots : .chats, showsEveryComputer: everyComputer,
                    leftEdge: left, rightEdge: right)
        }
        // Code mode ignored Opens on, so Code as the launch home comes before it.
        if stored.codeMode, stored.codeOpensAtLaunch { return landingOn(.work, everyComputer: wasAllHosts) }
        if let screen = stored.landing.flatMap(BighelpLandingScreen.init(rawValue:)) {
            return landingOn(screen.homeLanding, everyComputer: screen == .allAgents || wasAllHosts)
        }
        if let landing = stored.landing.flatMap(HomeLanding.init(rawValue:)) {
            return landingOn(landing, everyComputer: wasAllHosts)
        }
        return landingOn(wasAllHosts ? .bots : .chats, everyComputer: wasAllHosts)
    }

    /// The mode swipes go: Bots mode becomes Bots; Next mode, Chat mode and Code mode become the edge's
    /// default. An unknown value is the default too, as `SettingsStore` reads it.
    static func remapped(_ raw: String?, edgeDefault: WorkspaceSwipeAction) -> WorkspaceSwipeAction {
        guard let raw, let action = WorkspaceSwipeAction(rawValue: raw) else { return edgeDefault }
        switch action {
        case .botsMode: return .agents
        case .nextMode, .chatMode, .codeMode: return edgeDefault
        case .inbox: return .home
        default: return action
        }
    }

    /// Runs once: while the marker is unset (UI tests can pin `-bighelp.home.migrated-v1 NO` to run it at
    /// every launch, or `YES` never to run it).
    static func runIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: markerKey) else { return }
        let stored = Stored(reading: defaults)
        write(outcome(stored), over: stored, to: defaults)
        defaults.set(true, forKey: markerKey)
    }

    /// Writes only what differs from what the keys already say. A new install gets nothing: first run asks,
    /// and an unset "Show every computer" reads as on.
    static func write(_ outcome: Outcome, over stored: Stored, to defaults: UserDefaults) {
        guard stored.isExistingInstall else { return }
        // An old screen that maps to the same place stays as it is; the old shell still reads it.
        if BighelpLanding.homeLanding(stored: stored.landing) != outcome.landing {
            defaults.set(outcome.landing.rawValue, forKey: BighelpLanding.screenKey)
        }
        defaults.set(outcome.view.rawValue, forKey: Keys.homeView)
        if stored.allHosts != outcome.showsEveryComputer {
            defaults.set(outcome.showsEveryComputer, forKey: Keys.everyComputer)
        }
        if (stored.leftEdge ?? defaultLeftEdge.rawValue) != outcome.leftEdge.rawValue {
            defaults.set(outcome.leftEdge.rawValue, forKey: Keys.leftEdge)
        }
        if (stored.rightEdge ?? defaultRightEdge.rawValue) != outcome.rightEdge.rawValue {
            defaults.set(outcome.rightEdge.rawValue, forKey: Keys.rightEdge)
        }
    }

    enum Keys {
        /// `HomeConversationsView`: the first tab's view when the home opens on Today or Work.
        static let homeView = "bighelp.home.view"
        /// "Show every computer": the all-hosts view's key, kept.
        static let everyComputer = "bighelp.hosts.all-hosts"
        static let simpleBots = "bighelp.settings.simple-bots"
        static let codeMode = "bighelp.settings.code-mode"
        static let codeOpenIn = "bighelp.settings.code-mode.open-in"
        static let multiGateway = "bighelp.simple-bots.multi-gateway"
        static let leftEdge = "loopdy.workspace.leftEdgeSwipeAction"
        static let rightEdge = "loopdy.workspace.rightEdgeSwipeAction"

        /// Keys any earlier run leaves behind. First run's own step key is written only once it shows, after
        /// `SettingsStore` is made, so a new install has none of these.
        static let existingInstall = [
            simpleBots, codeMode, codeOpenIn, multiGateway, leftEdge, rightEdge,
            Keys.everyComputer, BighelpLanding.screenKey, BighelpLanding.legacyOpensChatKey,
            BighelpLanding.startAgentKey, AIDataConsent.key, FirstRunOnboarding.afterConnectKey,
            "loopdy.onboarding.first-run-v1.step", "bighelp.app-layout", "loopdy.settings.nerd-mode",
            "loopdy.demo.appearance", "bighelp.settings.unified-mode-toggle", "bighelp.settings.chat-switcher",
        ]
    }
}

extension HomeSettingsMigration.Stored {
    init(reading defaults: UserDefaults) {
        typealias Keys = HomeSettingsMigration.Keys
        botsMode = defaults.bool(forKey: Keys.simpleBots)
        codeMode = defaults.bool(forKey: Keys.codeMode)
        codeOpensAtLaunch = defaults.string(forKey: Keys.codeOpenIn) == BighelpExperience.code.rawValue
        landing = defaults.string(forKey: BighelpLanding.screenKey)
        allHosts = defaults.object(forKey: Keys.everyComputer) == nil
            ? nil : defaults.bool(forKey: Keys.everyComputer)
        multiGateway = defaults.bool(forKey: Keys.multiGateway)
        leftEdge = defaults.string(forKey: Keys.leftEdge)
        rightEdge = defaults.string(forKey: Keys.rightEdge)
        isExistingInstall = Keys.existingInstall.contains { defaults.object(forKey: $0) != nil }
    }
}
