import AppIntents
import Foundation

// Shortcuts actions beyond sending a chat. Every one reaches the computer
// through BighelpShortcutService, which waits for a host that answers and
// reconnects once. Actions that open bighelp hand it a link; the rest run
// without opening the app. Each can be set to a gateway: it runs there, and
// bighelp switches to that gateway first when it isn't the one in use.

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
        .workflows: .init(title: "Workflows", image: .init(systemName: "flowchart")),
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

/// The scheduled tasks on the action's gateway.
struct BighelpShortcutScheduledTaskQuery: EntityQuery {
    @IntentParameterDependency<BighelpRunScheduledTaskIntent>(\.$gateway) private var intent
    @Dependency private var service: BighelpShortcutService

    func entities(for identifiers: [String]) async throws -> [BighelpShortcutScheduledTaskEntity] {
        await service.savedScheduledTasks(identifiers, on: intent?.gateway.hostID)
            .map(BighelpShortcutScheduledTaskEntity.init)
    }

    func suggestedEntities() async throws -> [BighelpShortcutScheduledTaskEntity] {
        try await service.availableScheduledTasks(on: intent?.gateway.hostID).map(BighelpShortcutScheduledTaskEntity.init)
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

/// The group chats on the action's gateway.
struct BighelpShortcutGroupChatQuery: EntityQuery {
    @IntentParameterDependency<BighelpOpenGroupChatIntent>(\.$gateway) private var intent
    @Dependency private var service: BighelpShortcutService

    func entities(for identifiers: [String]) async throws -> [BighelpShortcutGroupChatEntity] {
        await service.savedGroupChats(identifiers, on: intent?.gateway.hostID).map(BighelpShortcutGroupChatEntity.init)
    }

    func suggestedEntities() async throws -> [BighelpShortcutGroupChatEntity] {
        try await service.availableGroupChats(on: intent?.gateway.hostID).map(BighelpShortcutGroupChatEntity.init)
    }
}

// MARK: - Workflows

struct BighelpShortcutWorkflowEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Workflow",
        numericFormat: "\(placeholder: .int) workflows"
    )
    static let defaultQuery = BighelpShortcutWorkflowQuery()

    let id: String
    let name: String
    let isPinned: Bool
    let stageCount: Int

    init(_ workflow: BighelpShortcutWorkflow) {
        id = workflow.id
        name = workflow.name
        isPinned = workflow.isPinned
        stageCount = workflow.stageCount
    }

    var displayRepresentation: DisplayRepresentation {
        let details = [isPinned ? "Pinned" : nil,
                       stageCount == 0 ? nil : stageCount == 1 ? "1 stage" : "\(stageCount) stages"].compactMap { $0 }
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(details.joined(separator: " · "))",
            image: .init(systemName: isPinned ? "pin.fill" : "flowchart")
        )
    }
}

/// Pinned workflows first: pinning one in bighelp makes it a favorite here.
struct BighelpShortcutWorkflowQuery: EntityQuery {
    @Dependency private var service: BighelpShortcutService

    func entities(for identifiers: [String]) async throws -> [BighelpShortcutWorkflowEntity] {
        // Names come from the computer when it answers. A workflow saved in a Shortcut keeps its computer,
        // so one on another computer still opens there.
        let live = (try? await service.availableWorkflows()) ?? []
        return identifiers.compactMap { id in
            (live.first { $0.id == id } ?? BighelpShortcutWorkflow(entityID: id)).map(BighelpShortcutWorkflowEntity.init)
        }
    }

    func suggestedEntities() async throws -> [BighelpShortcutWorkflowEntity] {
        try await service.availableWorkflows().map(BighelpShortcutWorkflowEntity.init)
    }
}

struct BighelpOpenWorkflowIntent: AppIntent {
    static let title: LocalizedStringResource = "Open workflow"
    static let description = IntentDescription(
        "Opens one of your workflows in bighelp, or its Run sheet to start a run. Pinned workflows come first.",
        categoryName: "Workflows"
    )
    static let openAppWhenRun = true

    /// Opens bighelp at once, without asking to continue in the app first.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Workflow")
    var workflow: BighelpShortcutWorkflowEntity

    @Parameter(title: "Start a run", default: false)
    var startsRun: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$startsRun, .equalTo, true, {
            Summary("Open \(\.$workflow) and start a run") { \.$startsRun }
        }, otherwise: {
            Summary("Open \(\.$workflow)") { \.$startsRun }
        })
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult {
        try await service.openWorkflow(id: workflow.id, startsRun: startsRun)
        return .result()
    }
}

// MARK: - Chat

struct BighelpNewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New chat"
    static let description = IntentDescription(
        "Opens bighelp on a new chat with the agent you choose, on the gateway you choose.",
        categoryName: "Chat"
    )
    static let openAppWhenRun = true

    /// Opens bighelp at once, without asking to continue in the app first.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("New chat with \(\.$agent) on \(\.$gateway)")
    }

    @Dependency private var service: BighelpShortcutService

    /// Hands off at once: bighelp connects and opens the chat itself.
    func perform() async throws -> some IntentResult {
        try await service.startNewChat(gatewayID: gateway?.hostID, agent: agent?.reference)
        return .result()
    }
}

struct BighelpContinueChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue last chat"
    static let description = IntentDescription(
        "Opens your most recent chat with the agent, or a new one if you haven't chatted yet.",
        categoryName: "Chat"
    )
    static let openAppWhenRun = true

    /// Opens bighelp at once, without asking to continue in the app first.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Continue last chat with \(\.$agent) on \(\.$gateway)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult {
        try await service.useGateway(gateway?.hostID, for: agent?.reference)
        _ = try await service.continueLastChat(agentID: agent?.reference.agentID)
        return .result()
    }
}

struct BighelpOpenGroupChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open group chat"
    static let description = IntentDescription(
        "Opens one of your group chats in bighelp.",
        categoryName: "Chat"
    )
    static let openAppWhenRun = true

    /// Opens bighelp at once, without asking to continue in the app first.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    @Parameter(title: "Group chat")
    var group: BighelpShortcutGroupChatEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$group) on \(\.$gateway)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult {
        try await service.useGateway(gateway?.hostID)
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

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    @Parameter(title: "Scheduled task")
    var task: BighelpShortcutScheduledTaskEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$task) on \(\.$gateway) now")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await service.useGateway(gateway?.hostID)
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

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to Kanban on \(\.$gateway)") {
            \.$notes
            \.$agent
        }
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await service.useGateway(gateway?.hostID, for: agent?.reference)
        let added = try await service.addKanbanTask(title: title, notes: notes ?? "",
                                                    assigneeID: agent?.reference.agentID)
        return .result(dialog: "Added \(added.title) to Later on \(added.boardName).")
    }
}

struct BighelpHostStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get computer status"
    static let description = IntentDescription(
        "Says whether bighelp can reach your gateway, how many agents it has and how many chats are working. Checking a gateway doesn't switch bighelp to it.",
        categoryName: "Automation"
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the status of \(\.$gateway)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let status = await service.hostStatus(gatewayID: gateway?.hostID)
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

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$section) from \(\.$agent) on \(\.$gateway)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try await service.useGateway(gateway?.hostID, for: agent?.reference)
        let result = try await service.boardItems(section, agentID: agent?.reference.agentID)
        return .result(value: result.text, dialog: "\(result.text)")
    }
}

// MARK: - Navigation

struct BighelpOpenSectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in bighelp"
    static let description = IntentDescription(
        "Opens bighelp on Chats, Agents, Feed, Ideas, Goals, Projects, Kanban, Workflows, Scheduled tasks or Settings.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun = true

    /// Opens bighelp at once, without asking to continue in the app first.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Place", default: .chats)
    var section: BighelpShortcutDestination

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$section) on \(\.$gateway) in bighelp")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult {
        try await service.open(section, gatewayID: gateway?.hostID)
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

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$agent) on \(\.$gateway)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await service.useGateway(gateway?.hostID, for: agent.reference)
        let switched = try await service.switchAgent(to: agent.reference.agentID)
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

    /// Opens bighelp at once, without asking to continue in the app first.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$agent) on \(\.$gateway)")
    }

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult {
        try await service.openAgentHome(gatewayID: gateway?.hostID, agent: agent.reference)
        return .result()
    }
}
