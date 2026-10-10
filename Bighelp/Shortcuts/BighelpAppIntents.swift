import AppIntents
import Foundation
import UniformTypeIdentifiers

// The intent, entity and enum type names below keep their original "Loopdy" names:
// Shortcuts people have already built refer to them by these names.

/// A gateway: a computer running Hermes. A Shortcut set to one runs there,
/// whichever one bighelp is using.
struct BighelpShortcutGatewayEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Gateway",
        numericFormat: "\(placeholder: .int) gateways"
    )
    static let defaultQuery = BighelpShortcutGatewayQuery()

    let id: String
    let name: String

    init(_ gateway: BighelpShortcutGateway) {
        id = gateway.id.uuidString
        name = gateway.name
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var hostID: UUID? { UUID(uuidString: id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "desktopcomputer"))
    }
}

struct BighelpShortcutGatewayQuery: EntityQuery {
    @Dependency private var service: BighelpShortcutService

    func entities(for identifiers: [String]) async throws -> [BighelpShortcutGatewayEntity] {
        let gateways = await service.availableGateways()
        // A gateway taken out of bighelp keeps its place, so running the Shortcut can say so.
        return identifiers.map { id in
            gateways.first { $0.id.uuidString == id }.map(BighelpShortcutGatewayEntity.init)
                ?? BighelpShortcutGatewayEntity(id: id, name: "Removed gateway")
        }
    }

    func suggestedEntities() async throws -> [BighelpShortcutGatewayEntity] {
        await service.availableGateways().map(BighelpShortcutGatewayEntity.init)
    }

    /// A new Shortcut starts on the gateway in use, and stays there when another one is used later.
    func defaultResult() async -> BighelpShortcutGatewayEntity? {
        await service.availableGateways().first(where: \.isInUse).map(BighelpShortcutGatewayEntity.init)
    }
}

struct LoopdyShortcutAgentEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "bighelp agent",
        numericFormat: "\(placeholder: .int) bighelp agents"
    )
    static let defaultQuery = BighelpShortcutAgentQuery()

    /// The agent and its gateway (`BighelpShortcutAgentReference`).
    let id: String
    let name: String
    let role: String
    let isDefault: Bool
    let hostID: UUID?
    let hostName: String?

    init(_ agent: BighelpShortcutAgent) {
        id = BighelpShortcutAgentReference(hostID: agent.hostID, agentID: agent.id).entityID
        name = agent.name
        role = agent.role
        isDefault = agent.isDefault
        hostID = agent.hostID
        hostName = agent.hostName
    }

    var reference: BighelpShortcutAgentReference {
        BighelpShortcutAgentReference(entityID: id) ?? BighelpShortcutAgentReference(hostID: hostID, agentID: id)
    }

    var domain: BighelpShortcutAgent {
        BighelpShortcutAgent(id: reference.agentID, name: name, role: role, isDefault: isDefault,
                             hostID: hostID, hostName: hostName)
    }

    var displayRepresentation: DisplayRepresentation {
        let details = [isDefault ? "Default agent" : nil, role.isEmpty ? nil : role, hostName.map { "on \($0)" }]
            .compactMap { $0 }
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(details.joined(separator: " · "))",
            image: .init(systemName: isDefault ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
        )
    }
}

/// The agents on the gateway the action is set to, else on the one in use.
struct BighelpShortcutAgentQuery: EntityQuery {
    @IntentParameterDependency<SendLoopdyChatIntent>(\.$gateway) private var ask
    @IntentParameterDependency<StartLoopdyVoiceChatIntent>(\.$gateway) private var voice
    @IntentParameterDependency<BighelpNewChatIntent>(\.$gateway) private var newChat
    @IntentParameterDependency<BighelpContinueChatIntent>(\.$gateway) private var continueChat
    @IntentParameterDependency<BighelpOpenAgentIntent>(\.$gateway) private var openAgent
    @IntentParameterDependency<BighelpSwitchAgentIntent>(\.$gateway) private var switchAgent
    @IntentParameterDependency<BighelpBoardItemsIntent>(\.$gateway) private var board
    @IntentParameterDependency<BighelpAddKanbanTaskIntent>(\.$gateway) private var kanban
    @Dependency private var service: BighelpShortcutService

    private var gateway: BighelpShortcutGatewayEntity? {
        ask?.gateway ?? voice?.gateway ?? newChat?.gateway ?? continueChat?.gateway ?? openAgent?.gateway
            ?? switchAgent?.gateway ?? board?.gateway ?? kanban?.gateway
    }

    /// From what this device last saw, never the network: a Shortcut starts at once.
    func entities(for identifiers: [String]) async throws -> [LoopdyShortcutAgentEntity] {
        await service.savedAgents(identifiers).map(LoopdyShortcutAgentEntity.init)
    }

    func suggestedEntities() async throws -> [LoopdyShortcutAgentEntity] {
        try await service.availableAgents(on: gateway?.hostID).map(LoopdyShortcutAgentEntity.init)
    }
}

struct LoopdyShortcutModelEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "AI model",
        numericFormat: "\(placeholder: .int) AI models"
    )
    static let defaultQuery = BighelpShortcutModelQuery()

    let id: String
    let providerID: String
    let providerName: String
    let modelID: String

    init(_ model: BighelpShortcutModel) {
        id = model.id
        providerID = model.providerID
        providerName = model.providerName
        modelID = model.modelID
    }

    var domain: BighelpShortcutModel {
        BighelpShortcutModel(
            providerID: providerID,
            providerName: providerName,
            modelID: modelID
        )
    }

    var displayRepresentation: DisplayRepresentation {
        let brand = AIProviderBrandRegistry.resolve(id: providerID, name: providerName)
        let image = brand.logoAssetName.map {
            DisplayRepresentation.Image(named: $0)
        } ?? DisplayRepresentation.Image(systemName: "cpu")
        return DisplayRepresentation(
            title: "\(modelID)",
            subtitle: "\(providerName)",
            image: image
        )
    }
}

struct BighelpShortcutModelQuery: EntityQuery {
    @IntentParameterDependency<SendLoopdyChatIntent>(\.$agent)
    private var intent
    @Dependency private var service: BighelpShortcutService

    func entities(for identifiers: [String]) async throws -> [LoopdyShortcutModelEntity] {
        let identifiers = Set(identifiers)
        return try await models()
            .filter { identifiers.contains($0.id) }
            .map(LoopdyShortcutModelEntity.init)
    }

    func suggestedEntities() async throws -> [LoopdyShortcutModelEntity] {
        try await models().map(LoopdyShortcutModelEntity.init)
    }

    private func models() async throws -> [BighelpShortcutModel] {
        try await service.availableModels(for: intent?.agent.reference)
    }
}

enum LoopdyShortcutReasoning: String, AppEnum {
    case automatic
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reasoning level")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .automatic: .init(title: "Automatic", subtitle: "Use the agent default"),
        .none: .init(title: "Off", subtitle: "No explicit reasoning budget"),
        .minimal: .init(title: "Minimal", subtitle: "Smallest available budget"),
        .low: .init(title: "Low", subtitle: "Faster, lighter reasoning"),
        .medium: .init(title: "Medium", subtitle: "Balanced speed and depth"),
        .high: .init(title: "High", subtitle: "More deliberate reasoning"),
        .xhigh: .init(title: "X-High", subtitle: "Very deep reasoning"),
        .max: .init(title: "Max", subtitle: "Strongest supported level"),
        .ultra: .init(title: "Ultra", subtitle: "Deepest Hermes tier"),
    ]

    var domain: BighelpShortcutReasoningLevel {
        BighelpShortcutReasoningLevel(rawValue: rawValue) ?? .automatic
    }
}

enum BighelpShortcutAttachmentBuilder {
    static func make(
        images: [IntentFile],
        files: [IntentFile]
    ) throws -> [ChatAttachment] {
        let incoming = images + files
        guard incoming.count <= 10 else { throw ChatAttachmentError.invalidSize }
        guard incoming.reduce(0, { $0 + $1.data.count }) <= 24 * 1_024 * 1_024 else {
            throw ChatAttachmentError.invalidSize
        }
        return try incoming.map { file in
            let type = file.type
            let mimeType = type?.preferredMIMEType
                ?? (type?.conforms(to: .image) == true ? "image/jpeg" : "application/octet-stream")
            return try ChatAttachment(
                id: "shortcut_\(UUID().uuidString.lowercased())",
                fileName: file.filename,
                mimeType: mimeType,
                data: file.data
            )
        }
    }
}

struct SendLoopdyChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask an agent"
    static let description = IntentDescription(
        "Starts a new chat with your agent on the gateway you choose, with any pictures or files you add. Wait for response returns the answer to Shortcuts without opening bighelp. Turn it off to send and continue right away.",
        categoryName: "Chat"
    )
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background] }

    @Parameter(
        title: "Message",
        requestValueDialog: "What would you like to ask your agent?"
    )
    var message: String

    @Parameter(title: "Gateway")
    var gateway: BighelpShortcutGatewayEntity?

    @Parameter(title: "Agent")
    var agent: LoopdyShortcutAgentEntity?

    @Parameter(title: "Model")
    var model: LoopdyShortcutModelEntity?

    @Parameter(title: "Reasoning", default: .automatic)
    var reasoning: LoopdyShortcutReasoning

    @Parameter(
        title: "Images",
        supportedTypeIdentifiers: ["public.image"],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var images: [IntentFile]?

    @Parameter(
        title: "Files",
        supportedTypeIdentifiers: ["public.item"],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var files: [IntentFile]?

    @Parameter(title: "Wait for response", default: true)
    var waitForResponse: Bool

    @Dependency private var service: BighelpShortcutService

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let attachments = try BighelpShortcutAttachmentBuilder.make(
            images: images ?? [],
            files: files ?? []
        )
        try await service.useGateway(gateway?.hostID, for: agent?.reference)
        let result = try await service.send(
            BighelpShortcutChatRequest(
                message: message,
                agentID: agent?.reference.agentID,
                model: model?.domain,
                reasoning: reasoning.domain,
                attachments: attachments,
                waitForResponse: waitForResponse
            )
        )
        let output: String
        switch result.delivery {
        case .queued:
            output = "Sent to \(result.agentName). bighelp will notify you as the session progresses."
        case .completed(let response):
            output = response
        }
        return .result(value: output, dialog: "\(output)")
    }
}

// Preserve the supported foreground continuation on iOS 17 and 18. iOS 26
// reads supportedModes above instead of the legacy marker protocol.
@available(iOS, deprecated: 26.0)
extension SendLoopdyChatIntent: ForegroundContinuableIntent {}

struct StartLoopdyVoiceChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Start voice chat"
    static let description = IntentDescription(
        "Opens your agent's Bot Chat on the gateway you choose and starts talking right away.",
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
        Summary("Start a voice chat with \(\.$agent) on \(\.$gateway)")
    }

    @Dependency private var service: BighelpShortcutService

    /// Hands off at once: bighelp shows the voice stage and opens the chat itself.
    func perform() async throws -> some IntentResult {
        try await service.startVoiceChat(gatewayID: gateway?.hostID, agent: agent?.reference)
        return .result()
    }
}

/// The ready-made Shortcuts (Siri, Spotlight and bighelp's page in the
/// Shortcuts app). An app may have at most 10, so these are the ten people
/// reach for most; Add Kanban task and Open agent stay ordinary actions.
/// Phrases with an agent, scheduled task or group chat make one tile each;
/// `BighelpShortcutParameters` refreshes them when those lists change.
struct BighelpAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendLoopdyChatIntent(),
            phrases: [
                "Send a chat with \(.applicationName)",
                "Ask an agent with \(.applicationName)",
                "Ask \(\.$agent) in \(.applicationName)",
            ],
            shortTitle: "Ask an agent",
            systemImageName: "message.badge.waveform"
        )
        AppShortcut(
            intent: BighelpNewChatIntent(),
            phrases: [
                "Start a new chat in \(.applicationName)",
                "New chat with \(\.$agent) in \(.applicationName)",
            ],
            shortTitle: "New chat",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: BighelpContinueChatIntent(),
            phrases: [
                "Continue my last chat in \(.applicationName)",
                "Continue my chat with \(\.$agent) in \(.applicationName)",
            ],
            shortTitle: "Continue last chat",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: StartLoopdyVoiceChatIntent(),
            phrases: [
                "Start a voice chat with \(.applicationName)",
                "Talk with an agent in \(.applicationName)",
                "Talk with \(\.$agent) in \(.applicationName)",
            ],
            shortTitle: "Start voice chat",
            systemImageName: "waveform.circle.fill"
        )
        AppShortcut(
            intent: BighelpOpenGroupChatIntent(),
            phrases: [
                "Open a group chat in \(.applicationName)",
                "Open \(\.$group) in \(.applicationName)",
            ],
            shortTitle: "Open group chat",
            systemImageName: "person.3"
        )
        AppShortcut(
            intent: BighelpRunScheduledTaskIntent(),
            phrases: [
                "Run a scheduled task in \(.applicationName)",
                "Run \(\.$task) in \(.applicationName)",
            ],
            shortTitle: "Run scheduled task",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: BighelpBoardItemsIntent(),
            // No phrase names the section: its tiles would be another "Feed",
            // "Ideas" and "Goals", indistinguishable from Open in bighelp's.
            phrases: [
                "Get my Feed from \(.applicationName)",
                "Read my agent's Feed in \(.applicationName)",
            ],
            shortTitle: "Get Feed, Ideas or Goals",
            systemImageName: "list.bullet.rectangle"
        )
        AppShortcut(
            intent: BighelpHostStatusIntent(),
            phrases: [
                "Check my computer in \(.applicationName)",
                "Is my computer online in \(.applicationName)",
            ],
            shortTitle: "Computer status",
            systemImageName: "desktopcomputer"
        )
        AppShortcut(
            intent: BighelpOpenSectionIntent(),
            // One phrase names the place: each such phrase makes a full row of tiles.
            phrases: [
                "Show \(\.$section) in \(.applicationName)",
                "Open a page in \(.applicationName)",
            ],
            shortTitle: "Open in bighelp",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: BighelpSwitchAgentIntent(),
            phrases: [
                "Switch agents in \(.applicationName)",
                "Switch to \(\.$agent) in \(.applicationName)",
            ],
            shortTitle: "Switch agent",
            systemImageName: "arrow.left.arrow.right.circle"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .orange }
}
