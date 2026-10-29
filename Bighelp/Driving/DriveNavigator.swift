import SwiftUI
import UIKit

/// The agent the person is talking to, as the driving bar shows it.
struct DriveAgent: Equatable, Sendable {
    let id: String
    let name: String
    let imageURL: URL?
}

/// Where the person was before a drive, for Return to chat.
struct DriveSnapshot: Equatable {
    var tab: AppTab
    var path: [AppRoute]
}

/// What a drive changes in the app. `AppDriveRouter` is the real one; tests use their own.
@MainActor
protocol DriveRouting: AnyObject {
    func snapshot() -> DriveSnapshot
    func restore(_ snapshot: DriveSnapshot)
    /// `bot`: the bot a profile step opens.
    func perform(_ move: DriveMove, bot: String?)
    /// Where a control is on screen now, if it is.
    func frame(_ target: String) -> CGRect?
}

/// Plays one place's playbook while the person watches (#662), under the driving overlay:
/// the island bar names the agent and the steps, the chat waits in the dock, and each step lights
/// only once the screen shows it happened (the next step's control appears). It ends pointing at
/// the place, or on its page. Return to chat puts the person back where they were; nothing a drive
/// does changes a setting.
@MainActor
@Observable
final class DriveNavigator {
    static let shared = DriveNavigator()

    enum Phase: Equatable {
        case idle
        /// Moving: the trail fills in.
        case driving
        /// At the place; the person can use it, stay, or go back.
        case arrived
        /// The dock grows back into the chat.
        case returning
    }

    /// An open bot profile takes a drive's later step (a tab, then a sheet) without a new push.
    struct ProfileRequest: Equatable {
        let agentID: String
        let opening: BotProfileOpening
        let serial: Int
    }

    private(set) var phase: Phase = .idle
    /// Changes with every drive, so the overlay plays its entrance again.
    private(set) var serial = 0
    private(set) var placeTitle = ""
    private(set) var trail: [String] = []
    /// How many of `trail` have happened.
    private(set) var lit = 0
    private(set) var note: String?
    private(set) var agent: DriveAgent?
    private(set) var chat: ChatModel?
    /// The control the touch dot is on, and a count that plays one press each time it grows.
    private(set) var touch: String?
    private(set) var presses = 0
    /// The control the arrival spotlight marks.
    private(set) var spotlight: String?
    private(set) var profileRequest: ProfileRequest?
    /// The chat as it looked when the drive began, for the dock's step-aside and its way back.
    private(set) var chatPicture: UIImage?
    /// With Reduce Motion: no touch dot, and cross-fades instead of moves.
    private(set) var reducesMotion = false

    /// Set by the shell: the app's navigation, its agents, the chat on screen, and how to take a
    /// picture of its window.
    private var router: (any DriveRouting)?
    private var agentLookup: (@MainActor (String) -> DriveAgent?)?
    private var chatOnScreen: (@MainActor () -> ChatModel?)?
    var capturePicture: (@MainActor () -> UIImage?)?

    private var saved: DriveSnapshot?
    private var task: Task<Void, Never>?
    private var ending: Task<Void, Never>?

    var isShowing: Bool { phase != .idle }
    var canDrive: Bool { router != nil }

    func attach(_ router: any DriveRouting, agent: @escaping @MainActor (String) -> DriveAgent?,
                chat: @escaping @MainActor () -> ChatModel?) {
        self.router = router
        agentLookup = agent
        chatOnScreen = chat
    }

    /// An agent or bot on the computer in use, by id.
    func agent(_ id: String) -> DriveAgent? { agentLookup?(id) }

    /// The tool's way in: shows the person `place` for the agent they're talking to, in the chat on
    /// screen. Nil while the shell isn't ready to drive.
    func open(_ place: DrivePlace, steps: [DriveStep], bot: (id: String, name: String)?, note: String?,
              agentID: String) -> [String]? {
        guard canDrive else { return nil }
        let agent = agent(agentID) ?? DriveAgent(id: agentID, name: String(localized: "Your agent"), imageURL: nil)
        return start(title: place.title, steps: steps, bot: bot, agent: agent, note: note, chat: chatOnScreen?(),
                     reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    /// Starts showing the person `steps` (one place's playbook in this mode) and returns the trail.
    /// A drive already running gives way to this one; Return to chat still goes back to where the
    /// first one began.
    @discardableResult
    func start(title: String, steps: [DriveStep], bot: (id: String, name: String)?, agent: DriveAgent,
               note: String?, chat: ChatModel?, reduceMotion: Bool) -> [String] {
        guard let router, !steps.isEmpty else { return [] }
        task?.cancel()
        ending?.cancel()
        if saved == nil || phase == .idle || phase == .returning {
            saved = router.snapshot()
            chatPicture = reduceMotion ? nil : capturePicture?()
        }
        serial &+= 1
        placeTitle = title
        trail = steps.map { $0.label(bot: bot?.name) }
        lit = 0
        self.note = note
        self.agent = agent
        self.chat = chat
        touch = nil
        spotlight = nil
        reducesMotion = reduceMotion
        phase = .driving
        let drive = serial
        task = Task { [weak self] in await self?.play(steps, bot: bot?.id, drive: drive) }
        return trail
    }

    /// Puts the person back in the chat, as it was before the drive.
    func returnToChat() {
        guard phase != .idle, phase != .returning else { return }
        task?.cancel()
        touch = nil
        spotlight = nil
        profileRequest = nil
        if let saved { router?.restore(saved) }
        phase = .returning
        let drive = serial
        ending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.reducesMotion == true ? 250 : 650))
            guard let self, !Task.isCancelled, self.serial == drive else { return }
            self.finish()
        }
    }

    /// Leaves the person on the place and puts the overlay away. The chat is still under it
    /// (Back reaches it).
    func stay() {
        guard phase != .idle else { return }
        task?.cancel()
        finish()
    }

    private func finish() {
        phase = .idle
        touch = nil
        spotlight = nil
        profileRequest = nil
        saved = nil
        chatPicture = nil
        chat = nil
    }

    private func play(_ steps: [DriveStep], bot: String?, drive: Int) async {
        // The island grows and the chat steps aside before anything moves.
        guard await pause(reducesMotion ? 200 : 650), serial == drive, let router else { return }
        for (index, step) in steps.enumerated() {
            guard serial == drive else { return }
            if step.points, let target = step.target {
                await appear(target)
                touch = nil
                spotlight = target
            } else {
                if step.move != nil, let target = step.target, !reducesMotion, router.frame(target) != nil {
                    touch = target
                    guard await pause(450) else { return }
                    presses &+= 1
                    guard await pause(180) else { return }
                }
                if let move = step.move { perform(move, bot: bot, router: router) }
                // Proof the step happened: the next control a step needs shows up.
                if let next = steps.dropFirst(index + 1).compactMap(\.target).first {
                    await appear(next)
                } else {
                    guard await pause(reducesMotion ? 300 : 700) else { return }
                }
            }
            guard !Task.isCancelled, serial == drive else { return }
            lit = index + 1
        }
        touch = nil
        phase = .arrived
    }

    private func perform(_ move: DriveMove, bot: String?, router: any DriveRouting) {
        if case .botProfile(let opening) = move, let bot,
           case .simpleBotProfile(let shown, _)? = router.snapshot().path.last, shown == bot {
            profileRequest = ProfileRequest(agentID: bot, opening: opening, serial: (profileRequest?.serial ?? 0) &+ 1)
            return
        }
        router.perform(move, bot: bot)
    }

    /// Waits up to 3 seconds for a control to show. A place that never shows it (a slow computer,
    /// a part this bot doesn't have) still ends the drive; the trail stops where the screen did.
    private func appear(_ target: String) async {
        for _ in 0..<60 {
            if router?.frame(target) != nil || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func pause(_ milliseconds: Int) async -> Bool {
        (try? await Task.sleep(for: .milliseconds(milliseconds))) != nil
    }
}

/// The real moves, on the shell's `AppState`. Pages go on top of the chat, so it's there to come
/// back to; Settings is its sheet.
@MainActor
final class AppDriveRouter: DriveRouting {
    private let appState: AppState

    init(appState: AppState) { self.appState = appState }

    func snapshot() -> DriveSnapshot { DriveSnapshot(tab: appState.selectedTab, path: appState.path) }

    func restore(_ snapshot: DriveSnapshot) {
        appState.closeSettings()
        appState.selectedTab = snapshot.tab
        appState.path = snapshot.path
    }

    func perform(_ move: DriveMove, bot: String?) {
        switch move {
        case .settings(let pages):
            appState.openSettings(at: pages)
        case .push(let route):
            appState.closeSettings()
            if appState.path.last != route { appState.open(route) }
        case .tab(let tab):
            appState.closeSettings()
            appState.select(tab)
        case .botProfile(let opening):
            guard let bot else { return }
            appState.closeSettings()
            appState.open(.simpleBotProfile(agentID: bot, opening: opening))
        }
    }

    func frame(_ target: String) -> CGRect? { DriveTargets.shared.frame(target) }
}
