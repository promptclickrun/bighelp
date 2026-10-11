import CryptoKit
import Foundation

/// Direct adapters for Hermes' public skill and capability routes.
///
/// Hermes 0.21 exposes skill bytes through `/api/skills/content`, skill
/// creation/update through `/api/skills`, and enablement through
/// `/api/skills/toggle`. The application operation performer owns the HTTP
/// route mapping; this file only validates and projects the host responses.
@MainActor
final class DirectHermesSkillsAndToolsClient: HermesSkillsAndToolsCatalogClient {
    private let service: DirectHermesAgentProfileService
    private var skillStates: [String: [String: Bool]] = [:]

    init(
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        service = DirectHermesAgentProfileService(
            workspace: workspace, owner: owner, currentOwner: currentOwner
        )
    }

    func load(agentID: String) async throws -> HermesSkillsAndToolsCatalog {
        let agentID = try Self.profile(agentID)
        let skillsPayload = try await service.request(
            .skillsToolsList, ["profile": .string(agentID)],
            capability: .skillsRead, profileID: agentID
        )
        let pluginsPayload = try await service.request(
            .pluginsList, ["profile": .string(agentID)],
            capability: .pluginsRead, profileID: agentID
        )
        let mcpPayload = try await service.request(
            .mcpServersList, ["profile": .string(agentID)],
            capability: .mcpServersRead, profileID: agentID
        )
        let toolsetsPayload = try await service.request(
            .toolsetsList, ["profile": .string(agentID)],
            capability: .toolsetsRead, profileID: agentID
        )

        let skills = try Self.decodeSkills(skillsPayload)
        let plugins = try Self.decodePlugins(pluginsPayload)
        let mcpServers = try Self.decodeMCPServers(mcpPayload)
        let toolsets = try Self.decodeToolsets(toolsetsPayload)
        skillStates[agentID] = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0.isEnabled) })

        let editAvailable = service.workspace.capabilities.supports(
            .skillsEdit, owner: service.owner, profileID: agentID
        )
        return HermesSkillsAndToolsCatalog(
            agentID: agentID,
            skills: skills,
            plugins: plugins,
            mcpServers: mcpServers,
            tools: toolsets,
            management: HermesCapabilityManagement(
                canRead: true, canCreate: editAvailable, canUpdate: editAvailable, canImport: false
            ),
            toolsNotice: editAvailable
                ? "Skill archive import is unavailable on this host. You can create and edit skills here."
                : "Skill archive import is unavailable on this host."
        )
    }

    func skill(id: String, agentID: String) async throws -> HermesSkillDocument {
        let agentID = try Self.profile(agentID)
        let id = try Self.identifier(id, maximumBytes: 64)
        let payload = try await service.request(
            .skillsToolsGet, ["profile": .string(agentID), "name": .string(id)],
            capability: .skillsRead, profileID: agentID
        )
        return try Self.decodeDocument(payload, agentID: agentID, skillID: id)
    }

    func createSkill(
        name: String,
        content: String,
        category: String?,
        agentID: String
    ) async throws -> HermesSkillDocument {
        let agentID = try Self.profile(agentID)
        let name = try Self.skillName(name)
        let content = try Self.content(content)
        let category = try Self.category(category)
        try service.requireCapability(.skillsEdit, profileID: agentID)
        var request: [String: BighelpJSONValue] = [
            "profile": .string(agentID), "name": .string(name), "content": .string(content)
        ]
        if let category { request["category"] = .string(category) }
        let receipt = try await service.request(
            .skillsToolsCreate, request, capability: .skillsEdit, profileID: agentID
        )
        try Self.requireSuccess(receipt)
        // The create response intentionally contains a host path but no
        // document bytes. Read the public content route back before returning.
        return try await skill(id: name, agentID: agentID)
    }

    func updateSkill(
        id: String,
        content: String,
        expectedSHA256: String,
        agentID: String
    ) async throws -> HermesSkillDocument {
        let agentID = try Self.profile(agentID)
        let id = try Self.identifier(id, maximumBytes: 64)
        let content = try Self.content(content)
        let expectedSHA256 = try Self.digest(expectedSHA256)
        try service.requireCapability(.skillsEdit, profileID: agentID)

        // There is no server-side conditional field on Hermes' public PUT.
        // Compare the caller's baseline immediately before the write instead.
        let current = try await skill(id: id, agentID: agentID)
        guard current.sha256 == expectedSHA256 else { throw WorkspaceClientError.conflict }
        let receipt = try await service.request(
            .skillsToolsUpdate,
            ["profile": .string(agentID), "name": .string(id), "content": .string(content)],
            capability: .skillsEdit, profileID: agentID
        )
        try Self.requireSuccess(receipt)
        return try await skill(id: id, agentID: agentID)
    }

    func importSkill(
        data: Data,
        kind: String,
        category: String?,
        agentID: String
    ) async throws -> HermesSkillDocument {
        guard !data.isEmpty, data.count <= 1_500_000,
              ["skillMd", "zip"].contains(kind) else { throw WorkspaceClientError.invalidRequest }
        _ = try Self.profile(agentID)
        _ = try Self.category(category)
        // `/api/skills/hub/install` accepts a Hub identifier and performs a
        // host-side download. It is not an upload endpoint and cannot safely
        // represent the caller's bytes, so do not invent a transport here.
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }

    func control(kind: HermesCapabilityKind, id: String, agentID: String) async throws -> HermesCapabilityControl {
        guard kind == .skill else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
        let agentID = try Self.profile(agentID)
        let id = try Self.identifier(id, maximumBytes: 64)
        let enabled: Bool
        if let cached = skillStates[agentID]?[id] {
            enabled = cached
        } else {
            let catalog = try await load(agentID: agentID)
            guard let skill = catalog.skills.first(where: { $0.id == id }) else {
                throw WorkspaceClientError.rejected(code: "skill_unavailable")
            }
            enabled = skill.isEnabled
        }
        return HermesCapabilityControl(
            agentID: agentID, kind: .skill, itemID: id, isEnabled: enabled, canToggle: true,
            reason: "", scope: "profile", activation: "Applied by Hermes skill toggle.",
            revision: Self.controlRevision(agentID: agentID, id: id, enabled: enabled)
        )
    }

    func setEnabled(_ enabled: Bool, control: HermesCapabilityControl) async throws -> HermesCapabilityControl {
        guard control.kind == .skill, control.canToggle else { throw WorkspaceClientError.invalidRequest }
        let agentID = try Self.profile(control.agentID)
        let id = try Self.identifier(control.itemID, maximumBytes: 64)
        guard skillStates[agentID]?[id] == control.isEnabled,
              control.revision == Self.controlRevision(agentID: agentID, id: id, enabled: control.isEnabled) else {
            throw WorkspaceClientError.conflict
        }
        let receipt = try await service.request(
            .skillsToolsUpdate,
            ["profile": .string(agentID), "name": .string(id), "enabled": .boolean(enabled)],
            capability: .skillsEdit, profileID: agentID
        )
        guard receipt["ok"]?.boolean == true,
              receipt["name"]?.string == id,
              receipt["enabled"]?.boolean == enabled else {
            throw WorkspaceClientError.invalidResponse
        }
        skillStates[agentID, default: [:]][id] = enabled
        return try await self.control(kind: .skill, id: id, agentID: agentID)
    }

    private static func decodeSkills(_ payload: [String: BighelpJSONValue]) throws -> [HermesSkillSummary] {
        let rows = try array(payload["skills"])
        var ids = Set<String>()
        return try rows.map { value in
            guard let row = value.object,
                  let rawName = row["name"]?.string,
                  ids.insert(rawName).inserted else { throw WorkspaceClientError.invalidResponse }
            let name = try skillName(rawName)
            let description = try catalogDescription(row["description"]?.string ?? "", maximumBytes: 4_096)
            let category = try text(row["category"]?.string ?? "", maximumBytes: 64)
            // Hermes filters disabled skills from this endpoint. Older hosts
            // may omit `enabled`; presence in this response means enabled.
            let enabled = row["enabled"]?.boolean ?? true
            return HermesSkillSummary(
                id: name, name: name, description: description, category: category, isEnabled: enabled
            )
        }
    }

    private static func decodePlugins(_ payload: [String: BighelpJSONValue]) throws -> [HermesPluginSummary] {
        let rows = try array(payload["plugins"])
        var ids = Set<String>()
        return try rows.map { value in
            guard let row = value.object,
                  let rawID = (row["key"]?.string ?? row["name"]?.string),
                  let rawName = row["name"]?.string,
                  ids.insert(rawID).inserted else { throw WorkspaceClientError.invalidResponse }
            let id = try identifier(rawID, maximumBytes: 160)
            let name = try text(rawName, maximumBytes: 256)
            let kind = try text(row["kind"]?.string ?? row["source"]?.string ?? "plugin", maximumBytes: 80)
            let version = try text(row["version"]?.string ?? "", maximumBytes: 128)
            let description = try catalogDescription(row["description"]?.string ?? "", maximumBytes: 4_096)
            let isEnabled = row["enabled"]?.boolean ?? (row["status"]?.string?.lowercased() == "enabled")
            let capabilityCount: Int
            if let count = row["capabilityCount"]?.integer {
                guard count >= 0 else { throw WorkspaceClientError.invalidResponse }
                capabilityCount = count
            } else if let provides = row["provides"]?.array {
                capabilityCount = provides.count
            } else {
                capabilityCount = 0
            }
            return HermesPluginSummary(
                id: id, name: name, kind: kind, version: version, description: description,
                isEnabled: isEnabled, capabilityCount: capabilityCount
            )
        }
    }

    private static func decodeMCPServers(_ payload: [String: BighelpJSONValue]) throws -> [HermesMCPServerSummary] {
        let rows = try array(payload["servers"])
        var ids = Set<String>()
        return try rows.map { value in
            guard let row = value.object, let rawName = row["name"]?.string,
                  ids.insert(rawName).inserted else { throw WorkspaceClientError.invalidResponse }
            let name = try identifier(rawName, maximumBytes: 160)
            let transport = try text(row["transport"]?.string ?? "", maximumBytes: 80)
            let enabled = row["enabled"]?.boolean ?? false
            let toolCount: Int?
            if let tools = row["tools"]?.array {
                toolCount = tools.count
            } else if row["tools"] == nil || row["tools"] == .null || row["tools"]?.object != nil {
                // Hermes returns the persisted include/exclude filter object here. It is
                // configuration metadata, not a discovered tool list, so keep the count
                // unknown rather than deriving a misleading value from filter entries.
                toolCount = nil
            } else {
                throw WorkspaceClientError.invalidResponse
            }
            return HermesMCPServerSummary(
                id: name, name: name, transport: transport, isEnabled: enabled, toolCount: toolCount
            )
        }
    }

    private static func decodeToolsets(_ payload: [String: BighelpJSONValue]) throws -> [HermesToolsetSummary] {
        let rows = try array(payload["toolsets"])
        var ids = Set<String>()
        return try rows.map { value in
            guard let row = value.object,
                  let rawID = row["name"]?.string,
                  let rawName = row["label"]?.string,
                  let rawPlatform = row["platform"]?.string,
                  let enabled = row["enabled"]?.boolean,
                  ids.insert(rawID).inserted else { throw WorkspaceClientError.invalidResponse }
            let id = try identifier(rawID, maximumBytes: 160)
            let name = try text(rawName, maximumBytes: 160)
            let description = try catalogDescription(row["description"]?.string ?? "", maximumBytes: 4_096)
            let platform = try text(rawPlatform, maximumBytes: 80)
            let count: Int
            if let tools = row["tools"]?.array {
                count = tools.count
            } else if let legacy = row["toolCount"]?.integer, legacy >= 0 {
                count = legacy
            } else {
                throw WorkspaceClientError.invalidResponse
            }
            return HermesToolsetSummary(
                id: id, name: name, description: description, platform: platform,
                isEnabled: enabled, toolCount: count
            )
        }
    }

    private static func decodeDocument(
        _ payload: [String: BighelpJSONValue], agentID: String, skillID: String
    ) throws -> HermesSkillDocument {
        guard payload["name"]?.string == skillID, let rawContent = payload["content"]?.string else {
            throw WorkspaceClientError.invalidResponse
        }
        let content = try Self.content(rawContent)
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        if let remote = payload["sha256"]?.string, remote != digest { throw WorkspaceClientError.invalidResponse }
        return HermesSkillDocument(agentID: agentID, skillID: skillID, content: content, sha256: digest)
    }

    private static func requireSuccess(_ payload: [String: BighelpJSONValue]) throws {
        try requireSuccess(payload, code: "hermes_skill_write_rejected")
    }

    private static func requireSuccess(_ payload: [String: BighelpJSONValue], code: String) throws {
        guard payload["success"]?.boolean == true || payload["ok"]?.boolean == true else {
            throw WorkspaceClientError.rejected(code: code)
        }
    }

    private static func array(_ value: BighelpJSONValue?) throws -> [BighelpJSONValue] {
        guard let rows = value?.array else { throw WorkspaceClientError.invalidResponse }
        return rows
    }

    private static func profile(_ value: String) throws -> String {
        try DirectHermesAgentProfileService.profileIdentifier(value)
    }

    private static func identifier(_ value: String, maximumBytes: Int) throws -> String {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains(where: \.isWhitespace) else { throw WorkspaceClientError.invalidRequest }
        return value
    }

    private static func skillName(_ value: String) throws -> String {
        guard value.utf8.count <= 64,
              value.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private static func category(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.utf8.count <= 64,
              value.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private static func content(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 100_000,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t")).contains($0)
              }) else { throw WorkspaceClientError.invalidRequest }
        return value
    }

    private static func text(_ value: String, maximumBytes: Int) throws -> String {
        guard value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceClientError.invalidResponse
        }
        return value
    }

    private static func catalogDescription(_ value: String, maximumBytes: Int) throws -> String {
        guard value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t")).contains($0)
              }) else {
            throw WorkspaceClientError.invalidResponse
        }
        return value
    }

    private static func digest(_ value: String) throws -> String {
        guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private static func controlRevision(agentID: String, id: String, enabled: Bool) -> String {
        let value = "\(agentID)\u{1f}\(id)\u{1f}\(enabled ? "1" : "0")"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Direct personality projection for Hermes' public `/api/config` contract.
///
/// Hermes does not publish built-in personality definitions or a custom
/// personality CRUD route. This client therefore returns configured custom
/// definitions and supports changing the active configured name only.
@MainActor
final class DirectHermesPersonalityClient: PersonalityClient {
    private let service: DirectHermesAgentProfileService
    private let profileID: String

    init(
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        profileID: String,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.profileID = (try? DirectHermesAgentProfileService.profileIdentifier(profileID)) ?? profileID
        service = DirectHermesAgentProfileService(
            workspace: workspace, owner: owner, currentOwner: currentOwner
        )
    }

    func load() async throws -> PersonalityCatalog {
        let profileID = try validatedProfile()
        let payload = try await service.request(
            .personalitiesList, ["profile": .string(profileID), "action": .string("load")],
            capability: .personalitiesRead, profileID: profileID
        )
        return try Self.decodeCatalog(payload)
    }

    func mutate(_ request: PersonalityMutation) async throws -> PersonalityCatalog {
        let profileID = try validatedProfile()
        if request.action == .delete {
            // Config PUT is a deep merge and cannot remove a custom map key.
            // Hermes has no public custom-personality delete endpoint.
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let current = try await load()
        guard current.revision == request.expectedRevision else { throw WorkspaceClientError.conflict }
        try service.requireCapability(.personalitiesEdit, profileID: profileID)

        switch request.action {
        case .save:
            guard let input = request.draft else { throw WorkspaceClientError.invalidRequest }
            let draft = try PersonalityDraft.validated(
                originalName: input.originalName, name: input.name, description: input.description,
                systemPrompt: input.systemPrompt, tone: input.tone, style: input.style
            )
            // PUT /api/config can add or replace a map value. A rename would
            // leave the old key behind because that endpoint only deep-merges.
            if let originalName = draft.originalName, originalName != draft.name {
                throw WorkspaceClientError.unavailable(.unsupportedOperation)
            }
            let definition: [String: BighelpJSONValue] = [
                "system_prompt": .string(draft.systemPrompt), "description": .string(draft.description),
                "tone": .string(draft.tone), "style": .string(draft.style)
            ]
            let receipt = try await service.request(
                .personalitiesList,
                [
                    "profile": .string(profileID), "action": .string("save"),
                    "config": .object(["agent": .object([
                        "personalities": .object([draft.name: .object(definition)])
                    ])])
                ],
                capability: .personalitiesEdit, profileID: profileID
            )
            try Self.requireSuccess(receipt, code: "personality_write_rejected")
            return try await load()

        case .activate:
            guard let rawName = request.name else { throw WorkspaceClientError.invalidRequest }
            let name = try Self.personalityName(rawName)
            guard name.isEmpty || current.personalities.contains(where: { $0.name == name }) || name == current.activeName else {
                // Built-in names are intentionally not guessed or copied into
                // the app; Hermes offers no public built-in catalog for validation.
                throw WorkspaceClientError.unavailable(.unsupportedOperation)
            }
            let receipt = try await service.request(
                .personalitiesList,
                [
                    "profile": .string(profileID), "action": .string("activate"), "name": .string(name),
                    "config": .object(["display": .object(["personality": .string(name)])])
                ],
                capability: .personalitiesEdit, profileID: profileID
            )
            try Self.requireSuccess(receipt, code: "personality_write_rejected")
            let readback = try await load()
            guard readback.activeName == name else { throw WorkspaceClientError.conflict }
            return readback

        case .delete:
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    private static func requireSuccess(_ payload: [String: BighelpJSONValue], code: String) throws {
        guard payload["ok"]?.boolean == true || payload["success"]?.boolean == true else {
            throw WorkspaceClientError.rejected(code: code)
        }
    }

    private func validatedProfile() throws -> String {
        try DirectHermesAgentProfileService.profileIdentifier(profileID)
    }

    private static func decodeCatalog(_ payload: [String: BighelpJSONValue]) throws -> PersonalityCatalog {
        let display = try object(payload["display"])
        let activeName = try personalityName(display["personality"]?.string ?? "")
        var merged: [String: BighelpJSONValue] = [:]
        if let root = payload["personalities"], root != .null {
            merged = try object(root)
        }
        if let agent = payload["agent"], agent != .null {
            let agentObject = try object(agent)
            if let custom = agentObject["personalities"], custom != .null {
                for (name, value) in try object(custom) { merged[name] = value }
            }
        }
        var definitions: [PersonalityDefinition] = []
        for (rawName, value) in merged.sorted(by: { $0.key < $1.key }) {
            let name = try personalityName(rawName)
            let (prompt, description, tone, style) = try decodeDefinition(value)
            _ = try PersonalityDraft.validated(
                originalName: nil, name: name, description: description,
                systemPrompt: prompt, tone: tone, style: style
            )
            definitions.append(PersonalityDefinition(
                name: name, description: description, systemPrompt: prompt,
                tone: tone, style: style, isBuiltIn: false, isCustomized: true
            ))
        }
        let fingerprint = Self.fingerprint(activeName: activeName, definitions: definitions)
        return PersonalityCatalog(
            revision: Self.revision(fingerprint), activeName: activeName, personalities: definitions
        )
    }

    private static func decodeDefinition(_ value: BighelpJSONValue) throws -> (
        prompt: String, description: String, tone: String, style: String
    ) {
        if let prompt = value.string {
            return (try text(prompt, maximumBytes: 20_000, allowsEmpty: false), "", "", "")
        }
        if let values = value.array {
            let prompt = try values.map { item -> String in
                guard let value = item.string else { throw WorkspaceClientError.invalidResponse }
                return value
            }.joined(separator: "\n")
            return (try text(prompt, maximumBytes: 20_000, allowsEmpty: false), "", "", "")
        }
        guard let object = value.object else { throw WorkspaceClientError.invalidResponse }
        let prompt = try text(
            object["system_prompt"]?.string ?? object["systemPrompt"]?.string ?? "",
            maximumBytes: 20_000, allowsEmpty: false
        )
        let description = try text(object["description"]?.string ?? "", maximumBytes: 240, allowsEmpty: true)
        let tone = try text(object["tone"]?.string ?? "", maximumBytes: 240, allowsEmpty: true)
        let style = try text(object["style"]?.string ?? "", maximumBytes: 240, allowsEmpty: true)
        return (prompt, description, tone, style)
    }

    private static func object(_ value: BighelpJSONValue?) throws -> [String: BighelpJSONValue] {
        guard let value, value != .null else { return [:] }
        guard let object = value.object else { throw WorkspaceClientError.invalidResponse }
        return object
    }

    private static func text(_ value: String, maximumBytes: Int, allowsEmpty: Bool) throws -> String {
        guard (allowsEmpty || !value.isEmpty), value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t")).contains($0)
              }) else { throw WorkspaceClientError.invalidResponse }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func personalityName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.utf8.count <= 64,
              name.isEmpty || name.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil else {
            throw WorkspaceClientError.invalidResponse
        }
        return name
    }

    private static func fingerprint(activeName: String, definitions: [PersonalityDefinition]) -> String {
        let values = definitions.map {
            [$0.name, $0.description, $0.systemPrompt, $0.tone, $0.style].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        return SHA256.hash(data: Data("\(activeName)\u{1d}\(values)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func revision(_ fingerprint: String) -> Int {
        let prefix = String(fingerprint.prefix(15))
        return Int(UInt64(prefix, radix: 16)! % UInt64(Int.max))
    }
}
