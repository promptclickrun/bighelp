import Foundation
import UIKit

struct BighelpShortcutAgent: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let role: String
    let isDefault: Bool
    /// The gateway it's on; nil when bighelp doesn't know it (demo data, or an
    /// agent saved in a Shortcut before gateways, which means the one in use).
    var hostID: UUID? = nil
    var hostName: String? = nil
}

struct BighelpShortcutModel: Identifiable, Equatable, Hashable, Sendable {
    let providerID: String
    let providerName: String
    let modelID: String

    var id: String { "\(providerID):\(modelID)" }
}

enum BighelpShortcutReasoningLevel: String, CaseIterable, Equatable, Sendable {
    case automatic
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var sessionValue: String {
        self == .automatic ? "reset" : rawValue
    }
}

struct BighelpShortcutChatRequest: Equatable, Sendable {
    let message: String
    let agentID: String?
    let model: BighelpShortcutModel?
    let reasoning: BighelpShortcutReasoningLevel?
    let attachments: [ChatAttachment]
    let waitForResponse: Bool
}

struct BighelpShortcutChatResult: Equatable, Sendable {
    enum Delivery: Equatable, Sendable {
        case queued
        case completed(String)
    }

    let sessionID: String
    let agentName: String
    let delivery: Delivery
}

struct BighelpShortcutVoiceResult: Equatable, Sendable {
    let sessionID: String
    let agentName: String
}

enum BighelpShortcutServiceError: LocalizedError, Equatable {
    case connectionUnavailable
    case agentUnavailable
    case sessionUnavailable
    case modelUnavailable
    case reasoningUnavailable
    case deliveryFailed
    case responseUnavailable
    case foregroundUnavailable
    case emptyMessage
    case scheduledTaskUnavailable
    case scheduledTaskFailed
    case groupChatUnavailable
    case boardUnavailable
    case kanbanUnavailable
    case kanbanNoBoard
    case kanbanFailed
    case emptyTitle
    case workflowsUnavailable
    case workflowUnavailable
    case gatewayUnavailable
    case gatewayUnreachable
    case agentNotOnGateway

    var errorDescription: String? {
        switch self {
        case .connectionUnavailable:
            "bighelp couldn't reach your host. Check that it's online and connected, then try again."
        case .agentUnavailable:
            "That agent is not available in Hermes."
        case .sessionUnavailable:
            "bighelp could not create the chat session."
        case .modelUnavailable:
            "That model is not available for this session."
        case .reasoningUnavailable:
            "That reasoning level is not available for this session."
        case .deliveryFailed:
            "Hermes could not complete the message. Open bighelp and try again."
        case .responseUnavailable:
            "No final text response was received. Open the chat in bighelp to check its progress."
        case .foregroundUnavailable:
            "Open bighelp to wait for a response, or turn off Wait for response to send in the background."
        case .emptyMessage:
            "Enter a message for your agent."
        case .scheduledTaskUnavailable:
            "That scheduled task isn't on your computer anymore."
        case .scheduledTaskFailed:
            "bighelp couldn't start that scheduled task. Check that your computer is connected, then try again."
        case .groupChatUnavailable:
            "That group chat isn't on your computer anymore."
        case .boardUnavailable:
            "Update the bighelp plugin on your computer to see this."
        case .kanbanUnavailable:
            "This computer doesn't have Kanban. Update Hermes to use it."
        case .kanbanNoBoard:
            "Make a Kanban board in bighelp first."
        case .kanbanFailed:
            "bighelp couldn't add the card. Check that your computer is connected, then try again."
        case .emptyTitle:
            "Enter a title for the card."
        case .workflowsUnavailable:
            "This computer doesn't have Workflows. Update the bighelp plugin to use them."
        case .workflowUnavailable:
            "That workflow isn't on your computer anymore."
        case .gatewayUnavailable:
            "That gateway isn't in bighelp anymore. Pick another one in the Shortcut."
        case .gatewayUnreachable:
            "bighelp couldn't reach that gateway. Check that it's online, then try again."
        case .agentNotOnGateway:
            "That agent isn't on the gateway this Shortcut uses. Pick the agent again."
        }
    }
}

/// The stores that must travel together for one shortcut invocation. Native
/// workspaces own their own stores, so an intent cannot safely borrow the
/// app-level Link stores after a host is selected.
@MainActor
struct BighelpShortcutWorkspace {
    let appState: AppState
    let agents: AgentDirectoryStore
    let runtimeDefaults: any AgentRuntimeDefaultsClient
    let catalog: SessionCatalogStore
    let featureStore: ShellFeatureStore
    let newChatCoordinator: NewChatCoordinator
    /// The host's group chats; nil where the connection has none.
    let rooms: BotModeRoomStore?

    init(
        appState: AppState,
        agents: AgentDirectoryStore,
        runtimeDefaults: any AgentRuntimeDefaultsClient,
        catalog: SessionCatalogStore,
        featureStore: ShellFeatureStore,
        newChatCoordinator: NewChatCoordinator,
        rooms: BotModeRoomStore? = nil
    ) {
        self.appState = appState
        self.agents = agents
        self.runtimeDefaults = runtimeDefaults
        self.catalog = catalog
        self.featureStore = featureStore
        self.newChatCoordinator = newChatCoordinator
        self.rooms = rooms
    }

    /// The chat for a session, attached to this workspace's live stream.
    static func chatModel(sessionID: String, in featureStore: ShellFeatureStore) throws -> ChatModel {
        let route = AppRoute.chat(conversationID: sessionID)
        guard
            featureStore.prepare(route),
            case .chat(let model)? = featureStore.preparedModel(for: route)
        else { throw BighelpShortcutServiceError.sessionUnavailable }
        return model
    }

    /// Creates a chat with the agent (or reuses `sessionID` while it still
    /// exists) and waits until it can take a message.
    func readyChat(agentID: String, reusing sessionID: String?) async throws -> (sessionID: String, chat: ChatModel) {
        let id: String
        if let sessionID, catalog.session(id: sessionID) != nil {
            id = sessionID
        } else {
            id = try await catalog.createDirect(agentID: agentID).id
        }
        let chat = try Self.chatModel(sessionID: id, in: featureStore)
        try await BighelpShortcutService.awaitTransportReady(chat)
        return (id, chat)
    }

    init(runtime: NativeWorkspaceRuntime) {
        self.init(
            appState: runtime.appState,
            agents: runtime.agents,
            runtimeDefaults: runtime.defaults,
            catalog: runtime.sessions,
            featureStore: runtime.features,
            newChatCoordinator: runtime.newChat,
            rooms: runtime.rooms
        )
    }
}

struct BighelpShortcutWorkspaceKey: Equatable, Sendable {
    let hostID: UUID?
    let registryGeneration: UUID
    let owner: WorkspaceOwner?

    func stillAdmits(_ current: Self) -> Bool {
        hostID == current.hostID
            && registryGeneration == current.registryGeneration
            && (owner == nil || owner == current.owner)
    }
}

@MainActor
final class BighelpShortcutService: @unchecked Sendable {
    private let fallbackWorkspace: BighelpShortcutWorkspace
    private let prepareConnection: @MainActor () async throws -> Void
    private var workspaceResolver: (@MainActor (BighelpShortcutWorkspaceKey) async throws -> BighelpShortcutWorkspace?)?
    private var nativeWorkspaceKey: (@MainActor () -> BighelpShortcutWorkspaceKey?)?
    private var reconnectHost: (@MainActor () async -> Void)?
    private var liveCheck: (key: BighelpShortcutWorkspaceKey?, task: Task<BighelpShortcutWorkspace, Error>)?
    private var preparation: (
        id: UUID,
        key: BighelpShortcutWorkspaceKey?,
        task: Task<BighelpShortcutWorkspace, Error>
    )?
    /// Host features outside the workspace stores (Feed, Kanban, the host's
    /// name). The app binds them; until then they're unavailable.
    var hostServices = BighelpShortcutHostServices()
    /// Opens a screen in bighelp the way a widget link does: it waits until
    /// the host answers. Tests record the links instead.
    var openLink: @MainActor (URL) -> Void = { BighelpIncomingLinkCenter.shared.open($0) }
    /// Where Kanban remembers the last board, the same place the app reads.
    var kanbanDefaults: UserDefaults = .standard
    /// The gateways Shortcuts can be set to. The app binds them; until then there are none.
    var gatewayDirectory: any BighelpShortcutGatewayDirectory = BighelpNoShortcutGateways()

    init(
        appState: AppState,
        agents: AgentDirectoryStore,
        runtimeDefaults: any AgentRuntimeDefaultsClient,
        catalog: SessionCatalogStore,
        featureStore: ShellFeatureStore,
        newChatCoordinator: NewChatCoordinator,
        botModeRooms: BotModeRoomStore? = nil,
        prepareConnection: @escaping @MainActor () async throws -> Void = {}
    ) {
        self.fallbackWorkspace = BighelpShortcutWorkspace(
            appState: appState,
            agents: agents,
            runtimeDefaults: runtimeDefaults,
            catalog: catalog,
            featureStore: featureStore,
            newChatCoordinator: newChatCoordinator,
            rooms: botModeRooms
        )
        self.prepareConnection = prepareConnection
    }

    /// Binds the current native workspace selection without changing the
    /// App Intent dependency. The resolver is deliberately invoked for every
    /// preparation flight so host retirement and cold launch cannot leave an
    /// intent using an old workspace.
    func bindNativeWorkspace(
        key: @escaping @MainActor () -> BighelpShortcutWorkspaceKey?,
        resolve: @escaping @MainActor (BighelpShortcutWorkspaceKey) async throws -> BighelpShortcutWorkspace?,
        reconnect: (@MainActor () async -> Void)? = nil
    ) {
        self.nativeWorkspaceKey = key
        self.workspaceResolver = resolve
        self.reconnectHost = reconnect
        preparation?.task.cancel()
        preparation = nil
    }

    /// The agents on the gateway in use, marked with it, so a Shortcut keeps that gateway.
    func availableAgents() async throws -> [BighelpShortcutAgent] {
        let workspace = try await liveWorkspace()
        let hostID = hostServices.hostID()
        let hostName = hostID == nil ? nil : hostServices.hostName()
        return workspace.agents.profiles.map {
            BighelpShortcutAgent(id: $0.id, name: $0.name, role: $0.role, isDefault: $0.isDefault,
                                 hostID: hostID, hostName: hostName)
        }
    }

    /// The app's own agents (demo data), for Shortcuts made before gateways when none is set up.
    var fallbackAgents: [BighelpShortcutAgent] {
        fallbackWorkspace.agents.profiles.map {
            BighelpShortcutAgent(id: $0.id, name: $0.name, role: $0.role, isDefault: $0.isDefault)
        }
    }

    /// Another gateway was picked: checks on the old one must not be shared with, or fail,
    /// what runs on the new one.
    func forgetWorkspaceChecks() {
        liveCheck?.task.cancel()
        liveCheck = nil
        preparation?.task.cancel()
        preparation = nil
    }

    func availableModels(agentID: String?) async throws -> [BighelpShortcutModel] {
        let workspace = try await liveWorkspace()
        let agent = try resolveAgent(explicitID: agentID, in: workspace)
        return try await workspace.runtimeDefaults.loadModelProviders(agentID: agent.id).flatMap {
            provider in
            provider.models.map {
                BighelpShortcutModel(
                    providerID: provider.id,
                    providerName: provider.name,
                    modelID: $0
                )
            }
        }
    }

    func send(
        _ request: BighelpShortcutChatRequest,
        continueInForeground: @MainActor () async throws -> Void = {}
    ) async throws -> BighelpShortcutChatResult {
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw BighelpShortcutServiceError.emptyMessage }
        try Task.checkCancellation()
        // Waiting no longer requires bighelp in the foreground. The intent runs
        // in the app process, which keeps the Hermes socket alive while
        // Shortcuts waits. The hook stays for callers that still opt in.
        _ = continueInForeground
        Self.holdsHostConnection += 1
        // Ask iOS for background execution while the reply streams, so the
        // socket is not frozen when Shortcuts owns the foreground.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "bighelp Shortcut")
        defer {
            Self.holdsHostConnection -= 1
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        try Task.checkCancellation()
        let workspace = try await liveWorkspace()
        let agent = try resolveAgent(explicitID: request.agentID, in: workspace)
        defer { workspace.featureStore.flushChatPersistence() }
        let session = try await workspace.catalog.createDirect(agentID: agent.id)
        if request.waitForResponse {
            // Establish the visible handoff as soon as the host has created a
            // real session. Canvas/model preparation can perform additional
            // local restoration and must not leave the app on Sessions when it
            // is the only remaining step.
            workspace.appState.activateConversation(id: session.id, source: .newChat)
        }
        let model = try prepareChat(sessionID: session.id, in: workspace.featureStore)

        if let selection = request.model {
            try await applyModel(selection, to: model)
        }
        if let reasoning = request.reasoning, reasoning != .automatic {
            try await applyReasoning(reasoning, to: model)
        }

        // A just-created session is still attaching its event stream. send()
        // silently declines until then, which made waited Shortcuts report
        // "no response" and queued ones fail. Wait for the real readiness gate.
        try await Self.awaitTransportReady(model)

        if request.waitForResponse {
            let existingIDs = Set(model.items.map(\.id))
            model.draft = message
            for attachment in request.attachments {
                try model.addDraftAttachment(attachment)
            }
            var finished = false
            let turn = Task { @MainActor in await model.send(); finished = true }
            let deadline = ContinuousClock.now + responseWait
            while !finished, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(150))
            }
            try Task.checkCancellation()
            if !finished {
                // The system gives intents a limited budget. Stop waiting,
                // leave the turn running, and let notifications deliver it.
                return BighelpShortcutChatResult(
                    sessionID: session.id, agentName: agent.name, delivery: .queued)
            }
            _ = await turn.value
            guard model.failureMessage == nil else {
                throw BighelpShortcutServiceError.deliveryFailed
            }
            // Interim assistant messages can have their own identities. The
            // first new assistant item is not necessarily the final answer.
            let response = model.items.last { item in
                guard item.role == .assistant, !existingIDs.contains(item.id),
                      item.metadata.delivery != "Streaming",
                      case .message = item.content else { return false }
                return true
            }
            guard let response, case .message(let text) = response.content,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw BighelpShortcutServiceError.responseUnavailable }
            // A person asked, so a bare marker gets Hermes' notice (ChatSilentReply).
            let result = BighelpShortcutChatResult(
                sessionID: session.id,
                agentName: agent.name,
                delivery: .completed(ChatSilentReply.isMarker(text) ? ChatSilentReply.notice : text)
            )
            return result
        }

        try await model.submitWithoutWaiting(
            message: message,
            attachments: request.attachments
        )
        let result = BighelpShortcutChatResult(
            sessionID: session.id,
            agentName: agent.name,
            delivery: .queued
        )
        return result
    }

    /// iOS grants a background intent roughly 30 seconds. Hand off before
    /// the system suspends bighelp so the Shortcut ends cleanly instead of
    /// failing; the running turn still finishes and notifies.
    var responseWait: Duration = .seconds(25)

    /// True while a Shortcut or the Watch is sending or waiting. Backgrounding
    /// the scene must not retire the host socket underneath it.
    static private(set) var holdsHostConnection = 0

    /// Keeps the host socket open until the returned closure runs, without
    /// background time: CarPlay keeps bighelp running while it's connected.
    static func holdHostConnection() -> @MainActor () -> Void {
        holdsHostConnection += 1
        var released = false
        return {
            guard !released else { return }
            released = true
            holdsHostConnection -= 1
        }
    }

    /// Keeps the host socket open, and asks iOS for background time, while
    /// work started outside the app (a Shortcut, the Watch) runs.
    static func holdingHostConnection<Value>(
        named name: String,
        _ work: @MainActor () async throws -> Value
    ) async rethrows -> Value {
        holdsHostConnection += 1
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name)
        defer {
            holdsHostConnection -= 1
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        return try await work()
    }

    static func awaitTransportReady(_ model: ChatModel, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(model.directTransportIsReady && !model.isAwaitingAuthoritativeSessionAllocation) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw BighelpShortcutServiceError.connectionUnavailable }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A host that answers, for the agent in the room on Vision Pro. Reconnects
    /// once if the socket went quiet, like every other outside entry point.
    func connectedWorkspace() async throws -> BighelpShortcutWorkspace {
        try await liveWorkspace()
    }

    /// A new chat started from outside the app (a widget or link). The app
    /// drops its host connection in the background, so wait for a host that
    /// answers (reconnecting once) before creating the chat on it.
    @discardableResult
    func openNewChat(agentID: String?) async throws -> BighelpShortcutVoiceResult {
        try await openChat(agentID: agentID).1
    }

    func openChat(agentID: String?) async throws -> (BighelpShortcutWorkspace, BighelpShortcutVoiceResult) {
        let workspace = try await liveWorkspace()
        // A widget remembers the agent it last drew; if that agent is gone, use the default.
        let known = agentID.flatMap { id in workspace.agents.profiles.contains { $0.id == id } ? id : nil }
        let agent = try resolveAgent(explicitID: known, in: workspace)
        let outcome = try await workspace.newChatCoordinator.start(explicitAgentID: agent.id)
        guard case .opened(let sessionID, _) = outcome else {
            throw BighelpShortcutServiceError.sessionUnavailable
        }
        return (workspace, BighelpShortcutVoiceResult(sessionID: sessionID, agentName: agent.name))
    }

    func resolveAgent(
        explicitID: String?,
        in workspace: BighelpShortcutWorkspace
    ) throws -> AgentProfile {
        guard let agent = workspace.agents.resolvedAgent(explicitID: explicitID) else {
            throw BighelpShortcutServiceError.agentUnavailable
        }
        return agent
    }

    /// A workspace whose host actually answers. In the background the app closes
    /// its connection, and iOS can drop it while the app is suspended, yet the
    /// workspace may still look ready. Reading the agent list (small, and needed
    /// anyway) proves the connection; if the host is unreachable, reconnect once
    /// and try again before anything is sent.
    /// Simultaneous entity queries share one check, so their directory loads
    /// never supersede (and cancel) each other.
    func liveWorkspace() async throws -> BighelpShortcutWorkspace {
        let requestedKey = nativeWorkspaceKey?()
        if let liveCheck {
            if Self.keysCanShare(liveCheck.key, requestedKey) { return try await liveCheck.task.value }
            // The host changed underneath: stop the old check, never reuse it.
            liveCheck.task.cancel()
            self.liveCheck = nil
        }
        let check = Task { @MainActor in
            let workspace = try await self.prepareForUse()
            do {
                try await workspace.agents.load()
                return workspace
            } catch let error as WorkspaceClientError where error == .transportUnavailable || error == .ownerChanged {
                guard let reconnectHost = self.reconnectHost else { throw error }
                await reconnectHost()
                try Task.checkCancellation()
                let reconnected = try await self.prepareForUse()
                try await reconnected.agents.load()
                return reconnected
            }
        }
        liveCheck = (requestedKey, check)
        defer { if liveCheck?.task == check { liveCheck = nil } }
        return try await check.value
    }

    /// Shortcuts may run before a scene exists, and can resolve agent and model
    /// entities concurrently. Share readiness and directory loading across them.
    private func prepareForUse() async throws -> BighelpShortcutWorkspace {
        try Task.checkCancellation()
        let requestedKey = nativeWorkspaceKey?()
        let flight: (
            id: UUID,
            key: BighelpShortcutWorkspaceKey?,
            task: Task<BighelpShortcutWorkspace, Error>
        )
        if let preparation {
            guard Self.keysCanShare(preparation.key, requestedKey) else {
                preparation.task.cancel()
                self.preparation = nil
                throw BighelpShortcutServiceError.connectionUnavailable
            }
            flight = preparation
        } else {
            let workspaceResolver = self.workspaceResolver
            let fallbackWorkspace = self.fallbackWorkspace
            let prepareConnection = self.prepareConnection
            let nativeWorkspaceKey = self.nativeWorkspaceKey
            flight = (UUID(), requestedKey, Task { @MainActor in
                if let requestedKey {
                    guard let workspaceResolver,
                          let workspace = try await workspaceResolver(requestedKey) else {
                        throw BighelpShortcutServiceError.connectionUnavailable
                    }
                    guard let currentKey = nativeWorkspaceKey?(),
                          requestedKey.stillAdmits(currentKey) else {
                        throw BighelpShortcutServiceError.connectionUnavailable
                    }
                    return workspace
                }
                try await prepareConnection()
                try Task.checkCancellation()
                try await fallbackWorkspace.agents.load()
                return fallbackWorkspace
            })
            preparation = flight
        }
        defer {
            if preparation?.id == flight.id { preparation = nil }
        }
        let workspace = try await flight.task.value
        try Task.checkCancellation()
        return workspace
    }

    private static func keysCanShare(
        _ lhs: BighelpShortcutWorkspaceKey?,
        _ rhs: BighelpShortcutWorkspaceKey?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (.some(lhs), .some(rhs)):
            return lhs.stillAdmits(rhs) || rhs.stillAdmits(lhs)
        default:
            return false
        }
    }

    private func prepareChat(sessionID: String, in featureStore: ShellFeatureStore) throws -> ChatModel {
        try BighelpShortcutWorkspace.chatModel(sessionID: sessionID, in: featureStore)
    }

    private func applyModel(
        _ selection: BighelpShortcutModel,
        to model: ChatModel
    ) async throws {
        guard let controls = model.runtimeControls else {
            throw BighelpShortcutServiceError.modelUnavailable
        }
        await controls.loadModelPicker()
        guard controls.errorMessage == nil else {
            throw BighelpShortcutServiceError.modelUnavailable
        }
        await controls.selectModel(
            providerID: selection.providerID,
            modelID: selection.modelID
        )
        guard
            controls.errorMessage == nil,
            controls.currentProvider == selection.providerID,
            controls.currentModel == selection.modelID
        else { throw BighelpShortcutServiceError.modelUnavailable }
    }

    private func applyReasoning(
        _ reasoning: BighelpShortcutReasoningLevel,
        to model: ChatModel
    ) async throws {
        guard let controls = model.runtimeControls else {
            throw BighelpShortcutServiceError.reasoningUnavailable
        }
        await controls.loadReasoningPicker()
        guard controls.errorMessage == nil else {
            throw BighelpShortcutServiceError.reasoningUnavailable
        }
        await controls.selectReasoning(value: reasoning.sessionValue)
        guard
            controls.errorMessage == nil,
            controls.currentReasoningValue == reasoning.sessionValue
        else { throw BighelpShortcutServiceError.reasoningUnavailable }
    }
}

