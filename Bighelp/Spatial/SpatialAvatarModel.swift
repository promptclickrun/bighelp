import Foundation
import Observation
import SwiftUI

/// Window IDs for Vision Pro's scenes. The main window has one everywhere.
enum SpatialAvatarSceneID {
    static let main = "main"
    static let avatar = "agent-in-room"
}

extension EnvironmentValues {
    /// The agent in the room, for Settings and the main window (Vision Pro only).
    @Entry var spatialAvatar: SpatialAvatarModel?
}

/// Your agent in the room on Vision Pro. A quick pinch talks or types (Settings
/// decides); both go into one ongoing chat, started on first use and kept
/// until you ask for a new one. Plain logic, so it runs anywhere for tests.
@MainActor
@Observable
final class SpatialAvatarModel {
    struct Agent: Equatable {
        let id: String
        let name: String
        let imageURL: URL?
    }

    enum Connection: Equatable {
        case connecting
        case ready
        case unavailable(String)
    }

    /// What a pinch asks the room to show.
    enum PinchOutcome: Equatable {
        case prompt
        case voice
        case retrying
    }

    private(set) var agent: Agent?
    private(set) var connection: Connection = .connecting
    private(set) var sessionID: String?
    /// Voice running in the panel beside the avatar.
    private(set) var voice: VoicePresentation?
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?
    var draft = ""
    var isPromptPresented = false
    /// A look being tried on in Agent Studio, shown in the room until the
    /// avatar designer closes.
    var previewAppearance: CompanionAppearance?
    /// Pinch-and-hold explains how to move and anchor the avatar.
    var isShowingMoveTip = false
    /// Which windows are open, so the avatar reopens the main window only when needed.
    var isVolumeOpen = false
    var isMainWindowOpen = true
    /// Simple mode was chosen: the main window closes itself once the avatar is up.
    var entersSimpleMode = false

    private(set) var chat: ChatModel?
    @ObservationIgnored private var workspace: BighelpShortcutWorkspace?
    @ObservationIgnored private let connect: @MainActor () async throws -> BighelpShortcutWorkspace
    private var seenItemIDs: Set<String> = []

    init(connect: @escaping @MainActor () async throws -> BighelpShortcutWorkspace) {
        self.connect = connect
    }

    // MARK: What the room shows

    /// What the agent is doing, from the chat's live stream.
    var activity: AgentActivityKind { chat?.liveActivityKind ?? .idle }

    /// How the face rests between moves.
    var restingState: AgentLiveState {
        if voice != nil || isPromptPresented { return .listening }
        if reply != nil, activity == .idle { return .happy }
        return .idle
    }

    /// The newest answer since you last asked, still arriving or finished.
    var reply: String? {
        guard let chat else { return nil }
        // Hermes' silence rules (ChatSilentReply): a silent answer is skipped, and a bare
        // marker answering your own question shows Hermes' notice.
        for index in chat.items.indices.reversed() {
            let item = chat.items[index]
            guard item.role == .assistant, !seenItemIDs.contains(item.id),
                  case .message(let text) = item.content else { continue }
            let previous = chat.items[..<index].last(where: ChatSilentReply.isConversationMessage)
            switch ChatSilentReply.presentation(of: item, after: previous, lane: .chat) {
            case .hide: continue
            case .notice: return ChatSilentReply.notice
            case .show:
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }

    /// One short line under the avatar.
    func status(pinch: SpatialAvatarPinchAction) -> String {
        if case .unavailable = connection { return "Can't reach your computer. Pinch to try again." }
        if connection == .connecting { return "Connecting…" }
        if voice != nil { return "Listening" }
        if isSubmitting { return "Sending…" }
        if activity != .idle { return activity.label }
        if isPromptPresented { return "Type your message" }
        return pinch == .talk ? "Pinch to talk" : "Pinch to type"
    }

    // MARK: Actions

    /// Connects and learns who the agent is. Safe to call again to retry.
    func connectIfNeeded() async {
        if connection == .ready, workspace != nil { return }
        connection = .connecting
        do {
            let workspace = try await connect()
            self.workspace = workspace
            refreshAgent(in: workspace)
            connection = agent == nil ? .unavailable("No agent yet") : .ready
        } catch is CancellationError {
        } catch {
            connection = .unavailable(Self.message(for: error))
        }
    }

    func pinch(_ action: SpatialAvatarPinchAction) -> PinchOutcome {
        isShowingMoveTip = false
        guard connection == .ready else { return .retrying }
        switch action {
        case .talk:
            isPromptPresented = false
            return .voice
        case .type:
            isPromptPresented = true
            return .prompt
        }
    }

    /// Sends what's typed into the ongoing chat. The answer shows as `reply`.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let chat = try await readyChat()
            seenItemIDs = Set(chat.items.map(\.id))
            chat.draft = text
            draft = ""
            isPromptPresented = false
            // A running turn takes this as a steer, like the chat's Send.
            Task { await chat.send() }
        } catch is CancellationError {
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Voice for the ongoing chat, shown in the panel beside the avatar.
    func startVoice(_ settings: SettingsStore) async -> VoicePresentation? {
        errorMessage = nil
        do {
            let chat = try await readyChat()
            guard let workspace, let sessionID else { return nil }
            seenItemIDs = Set(chat.items.map(\.id))
            let preference = settings.voicePreference(computer: voiceComputer, agentID: agent?.id)
            let presentation = workspace.featureStore.makeVoicePresentation(
                for: sessionID,
                mode: settings.voiceMode,
                transcription: settings.voiceTranscription,
                conversationMode: preference.mode,
                liveProvider: preference.liveProvider,
                liveVoice: preference.liveVoice
            )
            voice = presentation
            return presentation
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    func endVoice() {
        voice = nil
    }

    /// The computer the agent is on (`cacheScopeID`), which its own voice choices are kept under.
    var voiceComputer: String? { workspace?.catalog.currentHostID() }

    func dismissReply() {
        seenItemIDs = Set(chat?.items.map(\.id) ?? [])
    }

    /// The next pinch starts a fresh chat.
    func startNewConversation() {
        sessionID = nil
        chat = nil
        seenItemIDs = []
        isPromptPresented = false
    }

    /// Shows the ongoing chat in the main window. Returns false with no chat yet.
    @discardableResult
    func openConversation() -> Bool {
        guard let workspace, let sessionID else { return false }
        workspace.appState.activateConversation(id: sessionID, source: .quickSwitch)
        return true
    }

    // MARK: Private

    private func readyChat() async throws -> ChatModel {
        await connectIfNeeded()
        guard let workspace else { throw BighelpShortcutServiceError.connectionUnavailable }
        refreshAgent(in: workspace)
        guard let agent else { throw BighelpShortcutServiceError.agentUnavailable }
        if let chat, let sessionID, workspace.catalog.session(id: sessionID) != nil {
            return chat
        }
        let ready = try await workspace.readyChat(agentID: agent.id, reusing: sessionID)
        sessionID = ready.sessionID
        chat = ready.chat
        return ready.chat
    }

    /// The default agent can change while the avatar stands in the room.
    private func refreshAgent(in workspace: BighelpShortcutWorkspace) {
        guard let profile = workspace.agents.resolvedAgent(explicitID: nil) else {
            agent = nil
            return
        }
        let next = Agent(id: profile.id, name: profile.name, imageURL: workspace.agents.avatarURL(for: profile))
        if next.id != agent?.id { startNewConversation() }
        agent = next
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Try again."
    }
}
