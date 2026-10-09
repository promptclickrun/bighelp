import Foundation

enum WorkspaceCapability: String, CaseIterable, Sendable {
    case profilesRead, profilesCreate, profilesEdit, profilesClone
    case canonicalAgentChat, sessionsRead, sessionsCreate, sessionsEdit, sessionsFork
    case chatSend, chatStop, chatSteer, chatQueue, slashCommands
    case modelsRead, sessionModelEdit, reasoningEdit, agentDefaultsEdit
    case schedulesRead, schedulesEdit, schedulesRun
    case projectsRead, projectsEdit, sessionWorkspaceEdit, projectChangesRead, projectChangesEdit
    case attachmentsUpload, attachmentsDownload, generatedMedia
    case approvalsRead, approvalsRespond, clarificationRespond, batchClarification
    case subagentsRead, subagentTail, subagentStop, subagentSteer
    case voiceOutput, liveVoice
    case groupsRead, groupsCreate, groupsSend, groupsRename, groupsStop
    case groupsRetry, groupsApprove, groupsDisband, groupActivity, groupPersonContext
    case dashboardRead, dashboardEdit, wikiRead, wikiEdit, wikiDisconnect, cards, forms, cardTemplates
    case phoneTools, watchCompanion, cloudNotifications
    case skillsRead, skillsEdit, personalitiesRead, personalitiesEdit
    case usageRead, logsRead, memoryRead, memoryEdit, toolsetsRead, pluginsRead
    case mcpServersRead, messagingPlatformsRead, webhooksRead, webhooksEdit
    case configRead, configEdit, keysRead, keysEdit, systemStatus, filesRead
    /// Feed, Ideas, Goals, Activity and Approvals history (plugin agent board).
    case agentBoard
    /// Thumbs down, reasons, read state and idea → goal (plugin 2.19.0).
    case agentBoardFeedback
    /// Goals carry a category from a fixed list (plugin `native-agent-board-goal-categories-v1`).
    case agentBoardGoalCategories
    /// Feed posts carry files (plugin `native-agent-board-files-v1`).
    case agentBoardFiles
    /// Let's do it records the idea by its ID (plugin `native-agent-board-answers-v1`).
    case agentBoardAnswers
}

enum WorkspaceUnavailableReason: String, Equatable, Sendable {
    case notConnected, authenticationRequired, unsupportedHost, unsupportedOperation
    case pluginRequired, driverUnavailable, permissionRequired, policyRestricted
    case hostRestartRequired, identityContextUnavailable
    case conversationDeletionUnsupported

    var message: String {
        switch self {
        case .notConnected: "Connect to this host before continuing."
        case .authenticationRequired: "Sign in to this Hermes host again."
        case .unsupportedHost: "This host does not support this feature."
        case .unsupportedOperation: "This operation is unavailable on this host."
        case .pluginRequired: "This feature requires a compatible bighelp plugin on the host."
        case .driverUnavailable: "The host's room driver is not running."
        case .permissionRequired: "This feature requires an explicit permission grant."
        case .policyRestricted: "The host's policy does not permit this operation."
        case .hostRestartRequired: "The host must activate its updated configuration before continuing."
        case .identityContextUnavailable: "This host cannot verify the identity context required for this action."
        case .conversationDeletionUnsupported: "Hermes can remove individual session records, but cannot confirm erasing every related conversation record."
        }
    }
}

enum WorkspaceAvailability: Equatable, Sendable {
    case unknown
    case available
    case unavailable(WorkspaceUnavailableReason)

    var isAvailable: Bool { self == .available }
}

struct WorkspaceCapabilities: Equatable, Sendable {
    let owner: WorkspaceOwner?
    private let values: [WorkspaceCapability: WorkspaceAvailability]
    private let profileValues: [String: [WorkspaceCapability: WorkspaceAvailability]]

    static let disconnected = WorkspaceCapabilities(owner: nil)

    init(owner: WorkspaceOwner?,
         values: [WorkspaceCapability: WorkspaceAvailability] = [:],
         profileValues: [String: [WorkspaceCapability: WorkspaceAvailability]] = [:]) {
        self.owner = owner
        self.values = values
        self.profileValues = profileValues
    }

    func availability(for capability: WorkspaceCapability, owner expectedOwner: WorkspaceOwner,
                      profileID: String? = nil) -> WorkspaceAvailability {
        guard owner == expectedOwner else { return .unavailable(.notConnected) }
        if let profileID, let value = profileValues[profileID]?[capability] { return value }
        return values[capability] ?? .unknown
    }

    func supports(_ capability: WorkspaceCapability, owner expectedOwner: WorkspaceOwner,
                  profileID: String? = nil) -> Bool {
        availability(for: capability, owner: expectedOwner, profileID: profileID).isAvailable
    }
}
