import Foundation

@MainActor
final class DemoSessionControlMessaging: BighelpLinkSessionControlMessaging, SessionFastModeControlling {
    private var models: [String: (provider: String, model: String)] = [:]
    private var reasoning: [String: String]
    private var fastModes: [String: FastMode] = [:]
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

    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        switch request.kind {
        case .model:
            let current = models[request.sessionID] ?? ("nous", "Hermes-4-405B")
            return .model(try JSONDecoder().decode(
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
            ))
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
