import Foundation

/// One place in bighelp an agent can take the person to (issue #662): a page, a sheet or a control,
/// with the steps that reach it in each mode. `DriveCatalog` lists them; `DriveNavigator` plays one.
struct DrivePlace: Identifiable, Sendable {
    let id: String
    let title: String
    /// One plain sentence: what the person does there.
    let what: String
    /// Words a person might use for it, beside its title and `what`.
    let keywords: [String]
    let needs: Set<DriveNeed>
    /// The steps in each mode. A mode without steps can't reach the place.
    let playbooks: [BighelpMode: [DriveStep]]

    init(_ id: String, _ title: String, _ what: String, keywords: [String] = [], needs: Set<DriveNeed> = [],
         playbooks: [BighelpMode: [DriveStep]]) {
        self.id = id; self.title = title; self.what = what; self.keywords = keywords
        self.needs = needs; self.playbooks = playbooks
    }
}

enum DriveNeed: Hashable, Sendable {
    /// Settings › Nerd Mode is on. A drive never turns it on.
    case nerdMode
    /// One bot (its profile): the call names it, or it's the agent the person is talking to.
    case bot
}

/// One step of a playbook, as the trail names it ("Dashboard", "Templates").
struct DriveStep: Equatable, Sendable {
    /// What the trail says. "{Bot}" is the bot's name.
    let label: String
    /// What changes. Nil when the step before already did it (a profile opens on its tab).
    let move: DriveMove?
    /// The control for this step: the touch dot presses it before the move, or the spotlight
    /// marks it when the step points. Its showing up is also how the drive knows the step before
    /// it happened (`DriveTargets`).
    let target: String?
    /// The last step of a place that is a control: the drive marks it and never presses it.
    let points: Bool

    /// A step that changes where the app is.
    static func go(_ label: String, _ move: DriveMove, tap target: String? = nil) -> DriveStep {
        DriveStep(label: label, move: move, target: target, points: false)
    }

    /// A step that the move before it already showed, like the tab a profile opens on.
    static func shows(_ label: String, _ target: String? = nil) -> DriveStep {
        DriveStep(label: label, move: nil, target: target, points: false)
    }

    /// The control the person came for. The drive ends here, pointing at it.
    static func point(_ label: String, at target: String) -> DriveStep {
        DriveStep(label: label, move: nil, target: target, points: true)
    }

    /// The trail label with the bot's name in place of "{Bot}".
    func label(bot name: String?) -> String {
        label.replacingOccurrences(of: "{Bot}", with: name ?? String(localized: "Your bot"))
    }
}

/// What a step changes. `DriveRouter` performs each on `AppState` and the screen models; none of
/// them changes a setting.
enum DriveMove: Equatable, Sendable {
    /// Pushes a page over where the person is (the chat stays under it for Return to chat).
    case push(AppRoute)
    /// A root place without a route (Agents, the chat list).
    case tab(AppTab)
    /// The bot's profile, on a tab and with a sheet. A profile already open takes the change live.
    case botProfile(BotProfileOpening)
    /// The Settings sheet, on these pages.
    case settings([SettingsDestination])
}
