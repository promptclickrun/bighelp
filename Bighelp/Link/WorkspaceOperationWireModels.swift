import Foundation

enum BighelpLinkWorkspaceOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case agentsList = "agents.list"
    case agentsAvatarGet = "agents.avatar.get"
    case agentsAvatarSet = "agents.avatar.set"
    case agentCreate = "agents.create"
    case agentUpdate = "agents.update"
    case sessionsList = "sessions.list"
    case sessionHistory = "sessions.history"
    case sessionsState = "sessions.state"
    case sessionsContent = "sessions.content"
    case voiceLiveStatus = "voice.live.status"
    case voiceLiveOffer = "voice.live.offer"
    case voiceLiveClose = "voice.live.close"
    case voiceLiveJobs = "voice.live.jobs"
    case voiceLiveControl = "voice.live.control"
    case sessionUpdate = "sessions.update"
    case sessionDelete = "sessions.delete"
    case attachmentsResolve = "attachments.resolve"
    case attachmentsFetch = "attachments.fetch"
    case generatedMediaResolve = "generated_media.resolve"
    case scheduledTasksList = "scheduled_tasks.list"
    case scheduledTaskDeliveryTargets = "scheduled_tasks.delivery_targets"
    case scheduledTaskCreate = "scheduled_tasks.create"
    case scheduledTaskUpdate = "scheduled_tasks.update"
    case scheduledTaskDelete = "scheduled_tasks.delete"
    case scheduledTaskPause = "scheduled_tasks.pause"
    case scheduledTaskResume = "scheduled_tasks.resume"
    case scheduledTaskRun = "scheduled_tasks.run"
    case voiceSettingsGet = "voice_settings.get"
    case voiceSettingsSet = "voice_settings.set"
    case agentDefaultsGet = "agent_defaults.get"
    case agentDefaultsSet = "agent_defaults.set"
    case skillsToolsList = "skills_tools.list"
    case skillsToolsGet = "skills_tools.get"
    case skillsToolsCreate = "skills_tools.create"
    case skillsToolsUpdate = "skills_tools.update"
    case skillsToolsImport = "skills_tools.import"
    case projectsList = "projects.list"
    case projectsSetActive = "projects.set_active"
    case projectsCreate = "projects.create"
    case projectsArchive = "projects.archive"
    case projectsListDirectory = "projects.list_directory"
    case projectsGitCapabilities = "projects.git.capabilities"
    case projectsGitStatus = "projects.git.status"
    case projectsGitDiff = "projects.git.diff"
    case projectsGitPrepare = "projects.git.prepare"
    case projectsGitExecute = "projects.git.execute"
    case dashboardLoad = "dashboard.load"
    case dashboardSetEventState = "dashboard.set_event_state"
    case dashboardDismissEvent = "dashboard.dismiss_event"
    case dashboardDismissEvents = "dashboard.dismiss_events"
    case approvalLoad = "approvals.load"
    case approvalRespond = "approvals.respond"
    case clarificationRespond = "clarifications.respond"
    case cardsTemplatesList = "cards.templates.list"
    case cardsTemplatesInstall = "cards.templates.install"
    case cardsTemplatesRemove = "cards.templates.remove"
    case wikiRoots = "wiki.roots"
    case wikiConnect = "wiki.connect"
    case wikiResolve = "wiki.resolve"
    case wikiList = "wiki.list"
    case wikiRead = "wiki.read"
    case wikiSearch = "wiki.search"
    case wikiImage = "wiki.image"
    case wikiSaveBegin = "wiki.save.begin"
    case wikiSaveChunk = "wiki.save.chunk"
    case wikiSaveCommit = "wiki.save.commit"
    case wikiSaveStatus = "wiki.save.status"
    case hostRuntimeStatus = "host_runtime.status"
    case groupsCapabilities = "groups.capabilities"
    case groupsList = "groups.list"
    case groupsCreate = "groups.create"
    case groupsState = "groups.state"
    case groupsSend = "groups.send"
    case groupsRename = "groups.rename"
    case groupsLog = "groups.log"
    case groupsDisband = "groups.disband"
    case groupsStop = "groups.stop"
    case groupsRetry = "groups.retry"
    case groupsApprove = "groups.approve"

    var requiresHostCapability: Bool {
        switch self {
        case .sessionsState, .sessionsContent,
             .voiceLiveStatus, .voiceLiveOffer, .voiceLiveClose, .voiceLiveJobs, .voiceLiveControl,
             .voiceSettingsGet, .voiceSettingsSet,
             .skillsToolsGet, .skillsToolsCreate, .skillsToolsUpdate, .skillsToolsImport,
             .cardsTemplatesList, .cardsTemplatesInstall, .cardsTemplatesRemove,
             .sessionUpdate, .sessionDelete, .generatedMediaResolve,
             .hostRuntimeStatus,
             .wikiRoots, .wikiConnect, .wikiResolve, .wikiList, .wikiRead, .wikiSearch, .wikiImage,
             .wikiSaveBegin, .wikiSaveChunk, .wikiSaveCommit, .wikiSaveStatus,
             .groupsCapabilities, .groupsList, .groupsCreate, .groupsState, .groupsSend,
             .groupsRename, .groupsLog, .groupsDisband, .groupsStop, .groupsRetry, .groupsApprove:
            true
        default:
            false
        }
    }
    var requiredCapability: String? {
        switch self {
        case .sessionsState, .sessionsContent:
            "session-state-v1"
        case .voiceLiveStatus, .voiceLiveOffer, .voiceLiveClose, .voiceLiveJobs, .voiceLiveControl:
            "live-voice-v1"
        case .voiceSettingsGet, .voiceSettingsSet:
            "voice-settings-v1"
        case .hostRuntimeStatus:
            "host-runtime-diagnostics-v1"
        case .wikiRoots, .wikiConnect, .wikiResolve, .wikiList, .wikiRead, .wikiSearch, .wikiImage,
             .wikiSaveBegin, .wikiSaveChunk, .wikiSaveCommit, .wikiSaveStatus:
            "wiki.v1"
        default:
            nil
        }
    }
}

enum BighelpLinkWorkspacePayloadLimits {
    static let standardBytes = 196_608
    static let avatarBytes = 2_800_000

    static func requestBytes(for operation: BighelpLinkWorkspaceOperation) -> Int {
        operation == .agentsAvatarSet || operation == .skillsToolsImport
            ? avatarBytes
            : standardBytes
    }

    static func resultBytes(for operation: BighelpLinkWorkspaceOperation) -> Int {
        operation == .agentsAvatarGet ? avatarBytes : standardBytes
    }

    static func requestStringBytes(for operation: BighelpLinkWorkspaceOperation) -> Int {
        operation == .agentsAvatarSet || operation == .skillsToolsImport
            ? avatarBytes
            : 256_000
    }
}
