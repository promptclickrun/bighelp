import AppIntents
import Foundation

// Shortcuts actions beyond sending a chat. Every one reaches the computer
// through BighelpShortcutService, which waits for a host that answers and
// reconnects once. Actions that open bighelp hand it a link; the rest run
// without opening the app.

// MARK: - Choices

extension BighelpShortcutBoardSection: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Feed, Ideas or Goals")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .feed: .init(title: "Feed", image: .init(systemName: "newspaper")),
        .ideas: .init(title: "Ideas", image: .init(systemName: "lightbulb")),
        .goals: .init(title: "Goals", image: .init(systemName: "target")),
    ]
}

extension BighelpShortcutDestination: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Place in bighelp")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .chats: .init(title: "Chats", image: .init(systemName: "bubble.left.and.bubble.right")),
        .agents: .init(title: "Agents", subtitle: "Your agents and group chats", image: .init(systemName: "person.2")),
        .feed: .init(title: "Feed", image: .init(systemName: "newspaper")),
        .ideas: .init(title: "Ideas", image: .init(systemName: "lightbulb")),
        .goals: .init(title: "Goals", image: .init(systemName: "target")),
        .projects: .init(title: "Projects", image: .init(systemName: "folder")),
        .kanban: .init(title: "Kanban", image: .init(systemName: "rectangle.split.3x1")),
        .scheduledTasks: .init(title: "Scheduled tasks", image: .init(systemName: "calendar.badge.clock")),
        .settings: .init(title: "Settings", image: .init(systemName: "gearshape")),
    ]
}

// MARK: - Scheduled tasks and group chats

struct BighelpShortcutScheduledTaskEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Scheduled task",
        numericFormat: "\(placeholder: .int) scheduled tasks"
    )
    static let defaultQuery = BighelpShortcutScheduledTaskQuery()

    let id: String
    let name: String
    let agentName: String
    let schedule: String
    let isPaused: Bool

    init(_ task: BighelpShortcutScheduledTask) {
        id = task.id
        name = task.name
        agentName = task.agentName
        schedule = task.schedule
        isPaused = task.isPaused
    }

    var displayRepresentation: DisplayRepresentation {
        let details = [isPaused ? "Paused" : nil, agentName, schedule.isEmpty ? nil : schedule].compactMap { $0 }
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(details.joined(separator: " · "))",
            image: .init(systemName: isPaused ? "pause.circle" : "calendar.badge.clock")
        )
    }
}

struct BighelpShortcutScheduledTaskQuery: EntityQuery {
    @Dependency private var service: BighelpShortcutService

    func entities(for identifiers: [String]) async throws -> [BighelpShortcutScheduledTaskEntity] {
        let identifiers = Set(identifiers)
        return try await service.availableScheduledTasks()
            .filter { identifiers.contains($0.id) }
            .map(BighelpShortcutScheduledTaskEntity.init)
    }

    func suggestedEntities() async throws -> [BighelpShortcutScheduledTaskEntity] {
        try await service.availableScheduledTasks().map(BighelpShortcutScheduledTaskEntity.init)
    }
}

struct BighelpShortcutGroupChatEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Group chat",
        numericFormat: "\(placeholder: .int) group chats"
    )
    static let defaultQuery = BighelpShortcutGroupChatQuery()

    let id: String
    let name: String
    let memberNames: [String]

    init(_ group: BighelpShortcutGroupChat) {
        id = group.id
        name = group.name
        memberNames = group.memberNames
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(memberNames.joined(separator: ", "))",
            image: .init(systemName: "person.3")
        )
    }
}

struct BighelpShortcutGroupChatQuery: EntityQuery {
    @Dependency private var service: BighelpShortcutService

    func entities(for identifiers: [String]) async throws -> [BighelpShortcutGroupChatEntity] {
        let identifiers = Set(identifiers)
        return try await service.availableGroupChats()
            .filter { identifiers.contains($0.id) }
            .map(BighelpShortcutGroupChatEntity.init)
    }

    func suggestedEntities() async throws -> [BighelpShortcutGroupChatEntity] {
        try await service.availableGroupChats().map(BighelpShortcutGroupChatEntity.init)
    }
}

// MARK: - Chat

struct BighelpNewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New chat"
    static let description = IntentDescription(
        "Opens bighelp on a new chat with the agent you choose.",
        categoryName: "Chat"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("New chat with \(\.$agent)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await service.openNewChat(agentID: agent?.id)
        return .result(dialog: "Started a new chat with \(result.agentName).")
    }
}

struct BighelpContinueChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue last chat"
    static let description = IntentDescription(
        "Opens your most recent chat with the agent, or a new one if you haven't chatted yet.",
        categoryName: "Chat"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Continue last chat with \(\.$agent)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await service.continueLastChat(agentID: agent?.id)
        let dialog: IntentDialog = result.isNew
            ? "You had no chats with \(result.agentName) yet, so bighelp started one."
            : "Opening your last chat with \(result.agentName)."
        return .result(dialog: dialog)
    }
}

struct BighelpOpenGroupChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open group chat"
    static let description = IntentDescription(
        "Opens one of your group chats in bighelp.",
        categoryName: "Chat"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Group chat")
    var group: BighelpShortcutGroupChatEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$group)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult {
        _ = try await service.openGroupChat(id: group.id)
        return .result()
    }
}

// MARK: - Automation

struct BighelpRunScheduledTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Run scheduled task now"
    static let description = IntentDescription(
        "Runs one of your scheduled tasks right away, without waiting for its next time. It uses your AI provider, like any run.",
        categoryName: "Automation"
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @Parameter(title: "Scheduled task")
    var task: BighelpShortcutScheduledTaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$task) now")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ran = try await service.runScheduledTask(id: task.id)
        return .result(dialog: "Started \(ran.name) for \(ran.agentName).")
    }
}

struct BighelpAddKanbanTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Kanban task"
    static let description = IntentDescription(
        "Adds a card to Later on your Kanban board. Nothing starts until you move it to Ready.",
        categoryName: "Automation"
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @Parameter(title: "Title", requestValueDialog: "What's the task?")
    var title: String

    @Parameter(title: "Notes", inputOptions: .init(multiline: true))
    var notes: String?

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to Kanban") {
            \.$notes
            \.$agent
        }
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let added = try await service.addKanbanTask(title: title, notes: notes ?? "", assigneeID: agent?.id)
        return .result(dialog: "Added \(added.title) to Later on \(added.boardName).")
    }
}

struct BighelpHostStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get computer status"
    static let description = IntentDescription(
        "Says whether bighelp can reach your computer, how many agents it has and how many chats are working.",
        categoryName: "Automation"
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let status = await service.hostStatus()
        return .result(value: status, dialog: "\(status)")
    }
}

struct BighelpBoardItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Feed, Ideas or Goals"
    static let description = IntentDescription(
        "Returns up to 10 items from an agent's Feed, Ideas or Goals as text, one per line.",
        categoryName: "Automation"
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @Parameter(title: "Section", default: .feed)
    var section: BighelpShortcutBoardSection

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$section) from \(\.$agent)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await service.boardItems(section, agentID: agent?.id)
        return .result(value: result.text, dialog: "\(result.text)")
    }
}

// MARK: - Navigation

struct BighelpOpenSectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in bighelp"
    static let description = IntentDescription(
        "Opens bighelp on Chats, Agents, Feed, Ideas, Goals, Projects, Kanban, Scheduled tasks or Settings.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Place", default: .chats)
    var section: BighelpShortcutDestination

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$section) in bighelp")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult {
        await service.open(section)
        return .result()
    }
}

// MARK: - Agents

struct BighelpSwitchAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch agent"
    static let description = IntentDescription(
        "Makes the agent the one bighelp opens on, the same as picking it in the app.",
        categoryName: "Agents"
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$agent)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let switched = try await service.switchAgent(to: agent.id)
        return .result(dialog: "bighelp now opens on \(switched.name).")
    }
}

struct BighelpOpenAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Open agent"
    static let description = IntentDescription(
        "Opens the agent's home in bighelp: its latest chat, with Feed, Ideas and Goals a tap away.",
        categoryName: "Agents"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$agent)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult {
        await service.openAgentHome(agentID: agent.id)
        return .result()
    }
}
