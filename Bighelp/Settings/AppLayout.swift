import Foundation

/// A place in bighelp that ☰ lists and the bottom bar can hold.
enum BighelpPlace: String, CaseIterable, Codable, Identifiable, Sendable {
    case feed, ideas, goals, files
    case agents, projects, kanban, workflows, scheduledTasks, usage
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .feed: "Feed"
        case .ideas: "Ideas"
        case .goals: "Goals"
        case .files: "Files"
        case .agents: "Agents"
        case .projects: "Projects"
        case .kanban: "Kanban"
        case .workflows: "Workflows"
        case .scheduledTasks: "Scheduled tasks"
        case .usage: "Usage"
        case .settings: "Settings"
        }
    }

    /// The symbol ☰ shows beside it.
    var symbol: String {
        switch self {
        case .feed: "newspaper"
        case .ideas: "lightbulb"
        case .goals: "checkmark.square"
        case .files: "square.on.circle"
        case .agents: "person.2"
        case .projects: "folder"
        case .kanban: "rectangle.split.3x1"
        case .workflows: "flowchart"
        case .scheduledTasks: "calendar.badge.clock"
        case .usage: "gauge.with.dots.needle.50percent"
        case .settings: "gearshape"
        }
    }

    /// The tab it opens as in the bottom bar.
    var tab: AppTab {
        switch self {
        case .feed: .feed
        case .ideas: .ideas
        case .goals: .goals
        case .files: .apps
        case .agents: .agents
        case .projects: .projects
        case .kanban: .kanban
        case .workflows: .workflows
        case .scheduledTasks: .scheduledTasks
        case .usage: .usage
        case .settings: .profile
        }
    }

    /// Settings stays in ☰, so it can always be reached.
    var canPin: Bool { self != .settings }

    /// Listed in ☰ even while the bar holds it: quick screens hide the bar, and
    /// these are how you get around from there.
    var staysInMenu: Bool { self == .agents || self == .settings }

    /// The selected agent's Feed, Ideas, Goals and Files.
    var isAgentBoard: Bool { tab.isAgentBoard }

    init?(tab: AppTab) {
        guard let place = BighelpPlace.allCases.first(where: { $0.tab == tab }) else { return nil }
        self = place
    }
}

/// What the bottom bar holds after Chat, and the order of ☰ (Settings › Appearance ›
/// App layout). ☰ lists every place the bar doesn't, plus Agents and Settings
/// always, so each stays one tap away.
struct BighelpAppLayout: Equatable, Sendable {
    /// Chat comes first; four more fill the bar.
    static let maximumPinned = 4

    private(set) var pinned: [BighelpPlace]
    private(set) var menuOrder: [BighelpPlace]

    static let standard = BighelpAppLayout(
        pinned: [.feed, .ideas, .goals, .files],
        menuOrder: [.agents, .projects, .kanban, .workflows, .scheduledTasks, .usage,
                    .feed, .ideas, .goals, .files, .settings])

    init(pinned: [BighelpPlace], menuOrder: [BighelpPlace]) {
        var seen = Set<BighelpPlace>()
        self.pinned = Array(pinned.filter { $0.canPin && seen.insert($0).inserted }.prefix(Self.maximumPinned))
        seen = []
        // Every place once: the saved order, then any place it didn't know.
        let known = menuOrder.filter { seen.insert($0).inserted }
        self.menuOrder = known + BighelpPlace.allCases.filter { !seen.contains($0) }
    }

    /// The bottom bar's tabs, Chat first.
    var barTabs: [AppTab] { [.sessions] + pinned.map(\.tab) }

    /// ☰'s places, in order: whatever the bar doesn't hold, and Agents and Settings.
    var menuPlaces: [BighelpPlace] { menuOrder.filter { $0.staysInMenu || !pinned.contains($0) } }

    var canPinMore: Bool { pinned.count < Self.maximumPinned }

    func isPinned(_ place: BighelpPlace) -> Bool { pinned.contains(place) }

    mutating func pin(_ place: BighelpPlace) {
        guard place.canPin, canPinMore, !pinned.contains(place) else { return }
        pinned.append(place)
    }

    mutating func unpin(_ place: BighelpPlace) {
        pinned.removeAll { $0 == place }
    }

    mutating func movePinned(from source: IndexSet, to destination: Int) {
        pinned.move(fromOffsets: source, toOffset: destination)
    }

    /// Moves within ☰'s list, which leaves out what's pinned. A pinned place taken out
    /// of the bar later comes back at the end.
    mutating func moveMenu(from source: IndexSet, to destination: Int) {
        var shown = menuPlaces
        shown.move(fromOffsets: source, toOffset: destination)
        menuOrder = shown + menuOrder.filter { !shown.contains($0) }
    }

    /// Saved as JSON text; anything unreadable is the standard layout.
    init(saved text: String?) {
        guard let text, text.utf8.count <= 4_096,
              let raw = try? JSONDecoder().decode(Raw.self, from: Data(text.utf8)) else {
            self = .standard
            return
        }
        // Names an older build doesn't know are dropped.
        self.init(pinned: raw.pinned.compactMap(BighelpPlace.init(rawValue:)),
                  menuOrder: raw.menu.compactMap(BighelpPlace.init(rawValue:)))
    }

    /// What UserDefaults holds: the saved JSON text, or a dictionary of names (how a
    /// launch argument like `-bighelp.app-layout '{pinned=(agents,feed);menu=();}'` arrives).
    init(savedObject object: Any?) {
        if let text = object as? String {
            self.init(saved: text)
        } else if let dictionary = object as? [String: Any],
                  let pinned = dictionary["pinned"] as? [String] {
            self.init(pinned: pinned.compactMap(BighelpPlace.init(rawValue:)),
                      menuOrder: ((dictionary["menu"] as? [String]) ?? []).compactMap(BighelpPlace.init(rawValue:)))
        } else {
            self = .standard
        }
    }

    var saved: String? {
        (try? JSONEncoder().encode(Raw(pinned: pinned.map(\.rawValue), menu: menuOrder.map(\.rawValue))))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    private struct Raw: Codable {
        let pinned: [String]
        let menu: [String]
    }
}
