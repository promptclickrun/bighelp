import CoreGraphics
import Foundation

// The rules behind a bot's Dashboard (`BoardDashboardView`): Feed, Ideas and Goals as piles of
// cards you swipe. Kept apart from the views so each rule is tested on its own.

// MARK: - Swipes

enum DashboardSwipeDirection: Equatable, Sendable {
    case left, right
}

enum DashboardSwipe {
    /// How far a card goes before letting go acts on it.
    static let threshold: CGFloat = 96
    /// A quick flick acts sooner, once the card has moved this far the same way.
    static let flickVelocity: CGFloat = 650
    static let flickMinimum: CGFloat = 24

    /// What letting go of a dragged card does: nil springs it back.
    static func decide(translation: CGFloat, velocity: CGFloat) -> DashboardSwipeDirection? {
        if abs(translation) >= threshold { return translation > 0 ? .right : .left }
        let isFlick = abs(velocity) >= flickVelocity && abs(translation) >= flickMinimum
            && (velocity > 0) == (translation > 0)
        return isFlick ? (translation > 0 ? .right : .left) : nil
    }

    /// How much of the stamp shows while dragging, 0 to 1.
    static func progress(_ translation: CGFloat) -> CGFloat {
        min(1, abs(translation) / threshold)
    }
}

/// What a swipe on a Dashboard card does. Right acts on the card, left puts it away.
enum DashboardCardAction: Equatable, Sendable {
    /// Feed, right: the bot's chat with the post in the message box. Nothing is sent.
    case ask
    /// Feed, left: the post's Clear (the host's dismiss), with Undo.
    case clear
    /// Ideas, right: Let's do it. The host records the yes, the chat opens with it in the box.
    case doIt
    /// Ideas, left: the idea's Not now (the host's dismiss; the plugin remembers it), with Undo.
    case notNow
    /// Goals, right: Mark done, with Undo (Mark active).
    case markDone
    /// Goals, left: off the Dashboard until tomorrow, on this device. It stays active on Goals.
    case notToday
    /// Templates, right: the blueprint, filled in if it has blanks, then in the bot's message box.
    case useTemplate
    /// Templates, left: the next one. Nothing is saved.
    case skipTemplate

    static func action(for kind: AgentBoardItem.Kind, _ direction: DashboardSwipeDirection) -> Self {
        switch (kind, direction) {
        case (.feed, .right): .ask
        case (.feed, .left): .clear
        case (.idea, .right): .doIt
        case (.idea, .left): .notNow
        case (.goal, .right): .markDone
        case (.goal, .left): .notToday
        }
    }

    /// The words on the stamp, the menu and the VoiceOver action.
    func title(botName: String) -> String {
        switch self {
        case .ask: String(localized: "Ask \(botName)")
        case .clear: BoardDismissAction(kind: .feed).title
        case .doIt: String(localized: "Do it")
        case .notNow: BoardDismissAction(kind: .idea).title
        case .markDone: String(localized: "Mark done")
        case .notToday: String(localized: "Not today")
        case .useTemplate: String(localized: "Use")
        case .skipTemplate: String(localized: "Skip")
        }
    }

    /// A short second line on the stamp, for the one swipe that leaves the page.
    var detail: String? {
        switch self {
        // Let's do it opens the chat with the yes in the box; the stamp says where it goes.
        case .doIt: String(localized: "To chat")
        default: nil
        }
    }

    var systemImage: String {
        switch self {
        case .ask: "bubble.left"
        case .clear: BoardDismissAction(kind: .feed).systemImage
        case .doIt: "checkmark"
        case .notNow: BoardDismissAction(kind: .idea).systemImage
        case .markDone: "checkmark"
        case .notToday: "moon"
        case .useTemplate: "arrow.up.right"
        case .skipTemplate: "xmark"
        }
    }

    /// Acting (right) stamps are filled with the person's color; putting away is outlined.
    var isPositive: Bool {
        switch self {
        case .ask, .doIt, .markDone, .useTemplate: true
        case .clear, .notNow, .notToday, .skipTemplate: false
        }
    }

    /// What the Undo bar says after it.
    func undoMessage(for title: String, botName: String) -> String {
        switch self {
        case .ask: String(localized: "Asked \(botName) about “\(title)”")
        case .clear: BoardDismissAction(kind: .feed).undoMessage(for: title)
        case .doIt: String(localized: "Took “\(title)” to the chat")
        case .notNow: BoardDismissAction(kind: .idea).undoMessage(for: title)
        case .markDone: String(localized: "Done: “\(title)”")
        case .notToday: String(localized: "Back on your Dashboard tomorrow")
        case .useTemplate: String(localized: "Opened in the chat")
        case .skipTemplate: String(localized: "Skipped")
        }
    }
}

// MARK: - Piles

enum DashboardPiles {
    /// A pile's cards, top first: Feed and Ideas newest first; Goals the active ones, the one the
    /// bot touched last first. Put away for now (`hidden`: snoozed goals, cards taken to the
    /// chat) are left out.
    static func cards(_ kind: AgentBoardItem.Kind, items: [AgentBoardItem], hidden: Set<String>) -> [AgentBoardItem] {
        let shown = items.filter { $0.kind == kind && !$0.dismissed && !hidden.contains($0.id) }
        switch kind {
        case .feed, .idea:
            return shown.sorted { $0.createdAt > $1.createdAt }
        case .goal:
            return shown.filter { !$0.isDone }.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// True while the board has never had anything of this kind: the plain empty state, not
    /// "all caught up". Dismissed and done items still count as having had some.
    static func neverHad(_ kind: AgentBoardItem.Kind, items: [AgentBoardItem]) -> Bool {
        !items.contains { $0.kind == kind }
    }
}

// MARK: - Not today

/// Goals put away with Not today, on this device only: Hermes has no "snooze" for a goal, and the
/// goal stays active on Goals. Keyed by computer (its cache scope), bot and goal, so another
/// computer's goal with the same ID is unaffected. Each lasts until the start of the next day.
struct DashboardSnoozes {
    static let defaultsKey = "bighelp.dashboard.not-today"
    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    static func key(scope: String, agentID: String, goalID: String) -> String {
        [scope, agentID, goalID].joined(separator: "\u{1F}")
    }

    /// Off the Dashboard until the start of tomorrow.
    func snooze(goalID: String, scope: String, agentID: String, now: Date = .now) {
        var all = stored(now: now)
        let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        all[Self.key(scope: scope, agentID: agentID, goalID: goalID)] = tomorrow.timeIntervalSince1970
        defaults.set(all, forKey: Self.defaultsKey)
    }

    func unsnooze(goalID: String, scope: String, agentID: String, now: Date = .now) {
        var all = stored(now: now)
        all[Self.key(scope: scope, agentID: agentID, goalID: goalID)] = nil
        defaults.set(all, forKey: Self.defaultsKey)
    }

    /// The bot's goals still put away now.
    func snoozedGoalIDs(scope: String, agentID: String, now: Date = .now) -> Set<String> {
        let prefix = Self.key(scope: scope, agentID: agentID, goalID: "")
        return Set(stored(now: now).keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    /// What's saved, without the ones that have run out.
    private func stored(now: Date) -> [String: Double] {
        let raw = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        return raw.compactMapValues { $0 as? Double }.filter { $0.value > now.timeIntervalSince1970 }
    }
}

// MARK: - Tutorial

/// The swipe tutorial shows once per device, the first time a Dashboard has a card to swipe;
/// never on a brand-new bot whose piles are all empty.
struct DashboardTutorial {
    static let seenKey = "bighelp.dashboard.swipe-tutorial-seen"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var hasBeenSeen: Bool { defaults.bool(forKey: Self.seenKey) }

    func shouldShow(cardCount: Int) -> Bool { cardCount > 0 && !hasBeenSeen }

    func markSeen() { defaults.set(true, forKey: Self.seenKey) }
}

/// The tutorial's practice card, step by step: left first, then right.
enum DashboardTutorialStep: Equatable {
    case swipeLeft, swipeRight, done

    var expected: DashboardSwipeDirection? {
        switch self {
        case .swipeLeft: .left
        case .swipeRight: .right
        case .done: nil
        }
    }

    /// A swipe the other way snaps back and the step stays.
    func after(_ direction: DashboardSwipeDirection) -> Self {
        guard direction == expected else { return self }
        return self == .swipeLeft ? .swipeRight : .done
    }
}

// MARK: - Templates

/// The Templates deck for one page: its blueprints in the order the page's list shows them
/// (by topic), one at a time. Skip moves on and saves nothing; it can be undone.
struct DashboardTemplateDeck: Equatable {
    let blueprints: [BoardBlueprint]
    private(set) var position = 0

    init(blueprints: [BoardBlueprint]) { self.blueprints = blueprints }

    @MainActor
    init(kind: AgentBoardItem.Kind, catalog: BoardBlueprintCatalog) {
        self.init(blueprints: catalog.groups(for: kind).flatMap(\.blueprints))
    }

    var current: BoardBlueprint? { blueprints.indices.contains(position) ? blueprints[position] : nil }
    /// The top card and the few under it.
    func upcoming(_ count: Int) -> [BoardBlueprint] { Array(blueprints.dropFirst(position).prefix(count)) }
    var isFinished: Bool { position >= blueprints.count }
    var remaining: Int { max(0, blueprints.count - position) }

    mutating func advance() { if !isFinished { position += 1 } }
    mutating func back() { if position > 0 { position -= 1 } }
}

extension BoardBlueprint {
    /// No [blanks]: Use puts it straight in the message box, without the fill-in page.
    var needsFilling: Bool { !BlueprintAdLib(text).blanks.isEmpty }
}
