import Foundation

/// Made-up plans for the demo's model pickers: one provider nearly through its
/// plan, one limited for a while, one that reports nothing.
enum DemoProviderPlans {
    static func plan(for providerID: String, now: Date = .now) -> ModelProviderPlan? {
        switch providerID {
        case "openai":
            ModelProviderPlan(windows: [
                .init(usedPercent: 83, resetsAt: now.addingTimeInterval(95 * 60)),
                .init(usedPercent: 40, resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)),
            ])
        case "anthropic":
            ModelProviderPlan(isLimited: true, limitResetsAt: now.addingTimeInterval(40 * 60))
        default:
            nil
        }
    }

    static func adding(to provider: BighelpLinkModelProvider) -> BighelpLinkModelProvider {
        BighelpLinkModelProvider(id: provider.id, name: provider.name, isCurrent: provider.isCurrent,
                                 isCustom: provider.isCustom, models: provider.models,
                                 fastModeModels: provider.fastModeModels, plan: plan(for: provider.id))
    }
}

@MainActor
final class DemoSessionControlMessaging: SessionRuntimeControlConfirming, SessionRuntimeControlSupporting, SessionFastModeControlling {
    private var models: [String: (provider: String, model: String)] = [:]
    private var reasoning: [String: String]
    private var fastModes: [String: FastMode] = [:]
    private var pickerAgents: [String: String] = [:]
    private var pendingConfirmation: SessionRuntimeModelConfirmation?
    private let defaults: (any AgentRuntimeDefaultsClient)?

    init(reasoning: [String: String] = [:], defaults: (any AgentRuntimeDefaultsClient)? = nil) {
        self.reasoning = reasoning
        self.defaults = defaults
        if ProcessInfo.processInfo.arguments.contains("-test-fast-mode") {
            models["demo-finance"] = ("openai", "gpt-5.6")
        }
    }

    func loadFastMode(sessionID: String, agentID: String) async throws -> SessionFastMode {
        let current = models[sessionID] ?? ("nous", "Hermes-4-405B")
        if fastModes[sessionID] == nil {
            fastModes[sessionID] = try await defaults?.loadDefaults(agentID: agentID).mainChats.fastMode ?? .off
        }
        let provider = BighelpLinkModelProvider(id: current.0, name: current.0, isCurrent: true,
            isCustom: false, models: [current.1], fastModeModels: ["gpt-5.6", "gpt-5.6-mini"])
        return SessionFastMode(mode: fastModes[sessionID],
            unavailableReason: FastMode.unavailableReason(provider: provider, model: current.1))
    }

    func setFastMode(_ mode: FastMode, sessionID: String, agentID: String) async throws -> SessionFastMode {
        let state = try await loadFastMode(sessionID: sessionID, agentID: agentID)
        guard state.unavailableReason == nil, mode == .on || mode == .off else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        fastModes[sessionID] = mode
        return SessionFastMode(mode: mode, unavailableReason: nil)
    }

    func selectionSupport(sessionID: String, agentID: String) -> SessionRuntimeControlSupport { .available }

    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        pickerAgents[request.sessionID] = request.agentID
        switch request.kind {
        case .model:
            let current = models[request.sessionID] ?? ("nous", "Hermes-4-405B")
            var picker = try JSONDecoder().decode(
                BighelpLinkModelPicker.self,
                from: Data(
                    """
                    {
                      "version": 1,
                      "type": "picker.model",
                      "pickerId": "picker_model_fixture_0001",
                      "sessionId": "\(request.sessionID)",
                      "currentModel": "\(current.model)",
                      "currentProvider": "\(current.provider)",
                      "providers": [
                        {
                          "id": "nous",
                          "name": "Nous Research",
                          "isCurrent": \(current.provider == "nous"),
                          "isCustom": false,
                          "models": ["Hermes-4-405B", "Hermes-4-70B"]
                        },
                        {
                          "id": "openai",
                          "name": "OpenAI",
                          "isCurrent": \(current.provider == "openai"),
                          "isCustom": false,
                          "models": ["gpt-5.6", "gpt-5.6-mini"]
                        },
                        {
                          "id": "anthropic",
                          "name": "Anthropic",
                          "isCurrent": \(current.provider == "anthropic"),
                          "isCustom": false,
                          "models": ["claude-opus-4.1", "claude-sonnet-4.1"]
                        }
                      ],
                      "sentAt": 1788000000
                    }
                    """.utf8
                )
            )
            picker.providers = picker.providers.map(DemoProviderPlans.adding)
            return .model(picker)
        case .reasoning:
            let current = reasoning[request.sessionID] ?? "reset"
            return .choice(try JSONDecoder().decode(
                BighelpLinkChoicePicker.self,
                from: Data(
                    """
                    {
                      "version": 1,
                      "type": "picker.choice",
                      "pickerId": "picker_reason_fixture_0001",
                      "sessionId": "\(request.sessionID)",
                      "kind": "reasoning",
                      "title": "Reasoning effort",
                      "choices": [
                        {"value": "reset", "label": "Use default", "isCurrent": \(current == "reset")},
                        {"value": "low", "label": "Low", "isCurrent": \(current == "low")},
                        {"value": "medium", "label": "Medium", "isCurrent": \(current == "medium")},
                        {"value": "high", "label": "High", "isCurrent": \(current == "high")},
                        {"value": "max", "label": "Max", "isCurrent": \(current == "max")}
                      ],
                      "sentAt": 1788000000
                    }
                    """.utf8
                )
            ))
        }
    }

    func selectPicker(_ selection: BighelpLinkPickerSelection) async throws -> BighelpLinkPickerResult {
        if ProcessInfo.processInfo.arguments.contains("-test-model-confirmation"), selection.kind == .model {
            guard let agentID = pickerAgents[selection.sessionID] else { throw WorkspaceClientError.invalidRequest }
            let owner = WorkspaceOwner(authority: try .fixture(id: "model-confirmation"),
                                       authenticationGeneration: UUID(), connectionGeneration: UUID())
            let coordinate = try WorkspaceSessionCoordinate(
                owner: owner, profileID: agentID,
                sessionID: selection.sessionID, storedSessionID: selection.sessionID, runtimeSessionID: selection.sessionID
            )
            let confirmation = SessionRuntimeModelConfirmation(
                id: UUID(), selection: selection, coordinate: coordinate,
                message: "This demo model allows its vendor to train on prompts and completions. Approve to use it in this chat."
            )
            pendingConfirmation = confirmation
            throw SessionRuntimeModelConfirmationRequired(confirmation: confirmation)
        }
        return try applySelection(selection)
    }

    func confirmPicker(_ confirmation: SessionRuntimeModelConfirmation) async throws -> BighelpLinkPickerResult {
        guard pendingConfirmation == confirmation else { throw WorkspaceClientError.conflict }
        pendingConfirmation = nil
        return try applySelection(confirmation.selection)
    }

    func cancelPickerConfirmation(_ confirmation: SessionRuntimeModelConfirmation) {
        if pendingConfirmation == confirmation { pendingConfirmation = nil }
    }

    private func applySelection(_ selection: BighelpLinkPickerSelection) throws -> BighelpLinkPickerResult {
        switch selection.kind {
        case .model:
            if let provider = selection.provider, let model = selection.model {
                models[selection.sessionID] = (provider, model)
            }
        case .reasoning:
            if let value = selection.value {
                reasoning[selection.sessionID] = value
            }
        }
        return try JSONDecoder().decode(
            BighelpLinkPickerResult.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "picker.result",
                  "pickerId": "\(selection.pickerID)",
                  "sessionId": "\(selection.sessionID)",
                  "kind": "\(selection.kind.rawValue)",
                  "status": "completed",
                  "message": "Updated",
                  "sentAt": 1788000000
                }
                """.utf8
            )
        )
    }
}

@MainActor
final class DemoAgentDirectoryClient: AgentDirectoryClient, AgentListPlacementWriting {
    func setPlacement(_ placement: AgentListPlacement, profileID: String) async throws {
        var profiles = try repository.load()
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw WorkspaceClientError.rejected(code: "profile_unavailable")
        }
        profiles[index].placement = placement
        try repository.save(profiles)
    }

    /// `-test-long-soul`: a SOUL long enough to scroll inside its editor.
    private static var longSoulFixture: String? {
        guard ProcessInfo.processInfo.arguments.contains("-test-long-soul") else { return nil }
        return (1...60).map { "\($0). Help with financial planning: budgets, bills, savings goals and the reasoning behind each choice." }
            .joined(separator: "\n\n")
    }

    static let fixtureProfiles = [
        AgentProfile(
            id: "finance",
            name: "Avery Park",
            role: "Finance agent",
            summary: "Budget, planning, and financial decisions.",
            instructions: longSoulFixture ?? "Help with financial planning.",
            avatarFileName: nil,
            isDefault: true
        ),
        AgentProfile(
            id: "travel",
            name: "Mina Shah",
            role: "Travel agent",
            summary: "Trips and itineraries.",
            instructions: "Help with travel planning.",
            avatarFileName: nil,
            isDefault: false
        ),
        AgentProfile(
            id: "home",
            name: "Jordan Lee",
            role: "Home agent",
            summary: "Home and household planning.",
            instructions: "Help with home planning.",
            avatarFileName: nil,
            isDefault: false
        )
    ]

    private let repository: DemoRepository<[AgentProfile]>

    init(repository: DemoRepository<[AgentProfile]>) {
        self.repository = repository
    }

    func petGallery() async throws -> [PetdexPet] { PetdexFixtures.pets }

    func petThumbnail(_ pet: PetdexPet) async throws -> Data {
        guard let data = PetdexFixtures.thumbnail(slug: pet.slug) else { throw PetdexError.invalidImage }
        return data
    }

    func petSheet(_ pet: PetdexPet) async throws -> Data {
        guard let data = PetdexFixtures.sheet(slug: pet.slug) else { throw PetdexError.invalidImage }
        return data
    }

    func list() async throws -> [AgentProfile] {
        try repository.load()
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        var profiles = try repository.load()
        let profile = AgentProfile(
            id: UUID().uuidString,
            name: draft.name,
            role: draft.role,
            summary: draft.summary,
            instructions: draft.instructions,
            avatarFileName: draft.avatarFileName,
            isDefault: draft.isDefault,
            look: draft.look
        )
        profiles.append(profile)
        try repository.save(profiles)
        try repository.removeOrphanedAvatarFiles(keeping: Set(profiles.compactMap(\.avatarFileName)))
        return profile
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        var profiles = try repository.load()
        let profile = AgentProfile(
            id: id,
            name: draft.name,
            role: draft.role,
            summary: draft.summary,
            instructions: draft.instructions,
            avatarFileName: draft.avatarFileName,
            isDefault: draft.isDefault,
            look: draft.removesAvatar ? nil : draft.look ?? profiles.first { $0.id == id }?.look
        )
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        profiles[index] = profile
        try repository.save(profiles)
        try repository.removeOrphanedAvatarFiles(keeping: Set(profiles.compactMap(\.avatarFileName)))
        return profile
    }
}

#if DEBUG
/// `-test-bot-activity`: on the demo data, Mina is browsing the web in her Bot Chat and Jordan needs
/// you, so the home's working states show without a host (UI tests and screenshots).
@MainActor
final class DemoBotChatActivity: BotChatActivityReading {
    static let launchArgument = "-test-bot-activity"
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    func activity(agentIDs: [String]) async -> [String: BotChatActivity]? {
        var result: [String: BotChatActivity] = [:]
        for id in agentIDs {
            result[id] = switch id {
            case "travel": .working(tool: "web_search")
            case "home": .waiting
            default: .idle
            }
        }
        return result
    }
}

/// `-test-live-voice-report` (with `-test-live-voice`): a call that connects at once and keeps a made-up
/// sound report, so UI tests and screenshots see what Settings › Voice › Debug puts on the call screen.
/// Never reaches the microphone, network or provider.
@MainActor
final class DemoLiveVoiceReportCall {
    static let launchArgument = "-test-live-voice-report"
    private weak var model: LiveVoiceModel?

    static func model(owner: LiveVoiceOwner, agentName: String) -> LiveVoiceModel {
        let call = DemoLiveVoiceReportCall()
        let control = LiveVoiceControlClient(owner: owner, operation: { name, fields in
            let id = fields["voiceId"]?.string ?? ""
            switch name {
            case "voice.live.status": return ["available": .boolean(true)]
            case "voice.live.offer":
                Task { @MainActor in
                    call.model?.receive(["voiceId": .string(id), "event": .object(["kind": .string("started")])],
                                        owner: owner)
                }
                return ["voiceId": .string(id), "sdp": .string(Peer.sdp)]
            default: return ["voiceId": .string(id), "closed": .boolean(true)]
            }
        }, isOwnerCurrent: { $0 == owner })
        let model = LiveVoiceModel(agentName: agentName, client: control, makePeer: { Peer() })
        call.model = model
        return model
    }

    @MainActor
    private final class Peer: LiveVoiceAudioPeer, LiveVoiceAudioReporting {
        static let sdp = "v=0\r\na=fingerprint:sha-256 00:11\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
        var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)?
        var onAudioRoute: (@MainActor (String) -> Void)?
        var onInterruption: (@MainActor (Bool) -> Void)?
        func makeOffer() async throws -> String { Self.sdp }
        func applyAnswer(_ sdp: String) async throws { onConnectionState?(.connected) }
        func setMuted(_ muted: Bool) {}
        func setPlaybackMuted(_ muted: Bool) {}
        func setSpeakerEnabled(_ enabled: Bool) throws {}
        func setDefaultSpeakerOutput() throws {}
        func resumeAudio() throws {}
        func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics { .init(audioDeviceRunning: true) }
        func close() {}
        func audioReport() -> String {
            GeminiLiveAudioDiagnostics.text(
                seconds: 12, counts: .init(receivedChunks: 48, receivedBytes: 196_608, scheduledBuffers: 48,
                                           finishedBuffers: 46),
                mixer: (0.42, 0.081, 0.61), moving: "moving", state: Self.state,
                events: [(0.4, "Engine started"), (0.6, "Configuration change"), (0.7, "Engine restarted")],
                lastDeactivation: nil)
        }
        private static var state: GeminiLiveAudioState {
            var state = GeminiLiveAudioState()
            state.engineRunning = true
            state.playerPlaying = true
            state.playerPosition = 288_000
            state.voiceProcessing = "in on, out on"
            state.outputFormat = "48000 Hz × 1"
            state.mixerFormat = "48000 Hz × 2"
            state.category = "PlayAndRecord"
            state.mode = "VoiceChat"
            state.outputVolume = 0.6
            state.sampleRate = 48_000
            state.outputs = ["Speaker"]
            state.inputs = ["MicrophoneBuiltIn"]
            return state
        }
        func restartPlayback() {}
    }
}
#endif
