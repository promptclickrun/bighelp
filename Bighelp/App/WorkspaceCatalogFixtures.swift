import CryptoKit
import Foundation


@MainActor
final class FixtureSkillsAndToolsClient: HermesSkillsAndToolsCatalogClient {
    private var enabledStates: [String: Bool] = [:]

    func control(kind: HermesCapabilityKind, id: String, agentID: String) async throws -> HermesCapabilityControl {
        if ProcessInfo.processInfo.arguments.contains("-test-delayed-capability-control") {
            try await Task.sleep(for: .seconds(3))
        }
        let key = "\(agentID):\(kind.rawValue):\(id)"
        let enabled = enabledStates[key] ?? true
        return HermesCapabilityControl(agentID: agentID, kind: kind, itemID: id,
            isEnabled: enabled, canToggle: id != "loopdy",
            reason: id == "loopdy" ? "Bighelp carries this control connection." : "",
            scope: "Fixture profile", activation: "Applies to new fixture sessions.",
            revision: digest("\(key):\(enabled)"))
    }

    func setEnabled(_ enabled: Bool, control: HermesCapabilityControl) async throws -> HermesCapabilityControl {
        let current = try await self.control(kind: control.kind, id: control.itemID, agentID: control.agentID)
        guard current.canToggle, current.revision == control.revision else { throw BighelpLinkWorkspaceClientError.invalidResponse }
        enabledStates["\(control.agentID):\(control.kind.rawValue):\(control.itemID)"] = enabled
        return try await self.control(kind: control.kind, id: control.itemID, agentID: control.agentID)
    }

    private var documents: [String: String] = [
        "weather": """
        ---
        name: weather
        description: Look up current conditions and forecasts.
        ---

        Use current, authoritative weather sources.
        """,
    ]

    func load(agentID: String) async throws -> HermesSkillsAndToolsCatalog {
        HermesSkillsAndToolsCatalog(
            agentID: agentID,
            skills: documents.keys.sorted().map { id in
                .init(
                    id: id,
                    name: id == "weather" ? "Weather" : id,
                    description: id == "weather"
                        ? "Look up current conditions and forecasts."
                        : "Created in the skill editor.",
                    category: id == "weather" ? "Research" : "Custom",
                    isEnabled: enabledStates["\(agentID):skill:\(id)"] ?? true
                )
            },
            plugins: [.init(
                id: "loopdy",
                name: "Bighelp",
                kind: "platform",
                version: "Demo",
                description: "Secure Bighelp Link channel.",
                isEnabled: true,
                capabilityCount: 6
            )],
            mcpServers: [.init(id: "fixture-mcp", name: "Fixture MCP", transport: "stdio", isEnabled: enabledStates["\(agentID):mcpServer:fixture-mcp"] ?? true, toolCount: 2)],
            tools: [.init(id: "web", name: "Web", description: "Fixture web tools", platform: "loopdy", isEnabled: enabledStates["\(agentID):toolset:web"] ?? true, toolCount: 2)],
            management: .init(canRead: true, canCreate: true, canUpdate: true, canImport: true)
        )
    }

    func skill(id: String, agentID: String) async throws -> HermesSkillDocument {
        guard let content = documents[id] else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        return document(id: id, agentID: agentID, content: content)
    }

    func createSkill(
        name: String,
        content: String,
        category: String?,
        agentID: String
    ) async throws -> HermesSkillDocument {
        guard documents[name] == nil else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        documents[name] = content
        return document(id: name, agentID: agentID, content: content)
    }

    func updateSkill(
        id: String,
        content: String,
        expectedSHA256: String,
        agentID: String
    ) async throws -> HermesSkillDocument {
        guard
            let current = documents[id],
            digest(current) == expectedSHA256
        else { throw BighelpLinkWorkspaceClientError.invalidResponse }
        documents[id] = content
        return document(id: id, agentID: agentID, content: content)
    }

    func importSkill(
        data: Data,
        kind: String,
        category: String?,
        agentID: String
    ) async throws -> HermesSkillDocument {
        guard kind == "skillMd", let content = String(data: data, encoding: .utf8) else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        let id = "imported-skill"
        documents[id] = content
        return document(id: id, agentID: agentID, content: content)
    }

    private func document(id: String, agentID: String, content: String) -> HermesSkillDocument {
        HermesSkillDocument(
            agentID: agentID,
            skillID: id,
            content: content,
            sha256: digest(content)
        )
    }

    private func digest(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class FixtureHermesWorkspaceClient: HermesWorkspaceCatalogClient {
    private var activeIDs: [String: String] = [:]
    private var workspaceIDsBySession: [String: String] = [:]
    private var createdWorkspaces: [String: [HermesWorkspaceSummary]] = [:]
    private var archivedIDs: [String: Set<String>] = [:]

    func load(agentID: String) async throws -> HermesWorkspaceCatalog {
        catalog(agentID: agentID)
    }

    func load(agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog {
        catalog(
            agentID: agentID,
            sessionWorkspaceID: sessionID.flatMap { workspaceIDsBySession[$0] }
        )
    }

    func select(
        id: String,
        agentID: String,
        sessionID: String?
    ) async throws -> HermesWorkspaceCatalog {
        guard catalog(agentID: agentID).workspaces.contains(where: { $0.id == id }) else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        if let sessionID {
            workspaceIDsBySession[sessionID] = id
        } else {
            activeIDs[agentID] = id
        }
        return catalog(agentID: agentID, sessionWorkspaceID: sessionID.map { _ in id })
    }

    func create(
        name: String,
        folderPath: String,
        agentID: String
    ) async throws -> HermesWorkspaceCatalog {
        guard !name.isEmpty, folderPath.hasPrefix("/") else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        let identifier = "fixture-" + name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        var rows = createdWorkspaces[agentID] ?? []
        guard !rows.contains(where: { $0.id == identifier }) else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        rows.append(.init(
            id: identifier,
            name: name,
            description: folderPath,
            folderCount: 1,
            isActive: true
        ))
        createdWorkspaces[agentID] = rows
        activeIDs[agentID] = identifier
        return catalog(agentID: agentID)
    }

    func describe(id: String, description: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        guard let index = createdWorkspaces[agentID]?.firstIndex(where: { $0.id == id }),
              let row = createdWorkspaces[agentID]?[index] else { return catalog(agentID: agentID) }
        createdWorkspaces[agentID]?[index] = .init(id: row.id, name: row.name, description: description,
                                                   folderCount: row.folderCount, isActive: row.isActive)
        return catalog(agentID: agentID)
    }

    func archive(id: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        guard catalog(agentID: agentID).workspaces.contains(where: { $0.id == id }) else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        archivedIDs[agentID, default: []].insert(id)
        if activeIDs[agentID] == id {
            activeIDs[agentID] = nil
        }
        return catalog(agentID: agentID)
    }

    func folderSuggestions(
        parentPath: String,
        prefix: String,
        offset: Int,
        limit: Int,
        agentID _: String
    ) async throws -> HermesWorkspaceFolderPage {
        // Same shape as Hermes's folder listing, so the demo browses like a real host.
        let full = parentPath == "~" ? Self.fixtureHome
            : parentPath.hasPrefix("~/") ? Self.fixtureHome + parentPath.dropFirst() : parentPath
        guard let names = Self.fixtureFolders[full] else { throw WorkspaceClientError.rejected(code: "ENOENT") }
        let entries = names.map { name -> BighelpJSONValue in
            .object(["name": .string(name), "path": .string(full == "/" ? "/\(name)" : "\(full)/\(name)"),
                     "isDirectory": .boolean(true)])
        }
        return try HermesFolderListing.page(.object(["entries": .array(entries)]), requestedPath: full,
                                            prefix: prefix, offset: offset, limit: limit)
    }

    private static let fixtureHome = "/Users/demo"
    private static let fixtureFolders: [String: [String]] = [
        "/": ["Users", "srv"],
        "/Users": ["demo"],
        "/Users/demo": [".config", "Desktop", "Documents", "Projects"],
        "/Users/demo/Desktop": [],
        "/Users/demo/Documents": ["Notes", "Research"],
        "/Users/demo/Documents/Notes": [],
        "/Users/demo/Documents/Research": [],
        "/Users/demo/Projects": ["bighelp-native", "bighelp-web", "garden-planner"],
        "/Users/demo/Projects/bighelp-native": ["App", "Tests"],
        "/Users/demo/Projects/bighelp-web": [],
        "/Users/demo/Projects/garden-planner": [],
        "/srv": ["workspaces"],
        "/srv/workspaces": ["loopdy-native", "loopdy-web", "research"],
        "/srv/workspaces/loopdy-native": [],
        "/srv/workspaces/loopdy-web": [],
        "/srv/workspaces/research": [],
    ]

    private func catalog(
        agentID: String,
        sessionWorkspaceID: String? = nil
    ) -> HermesWorkspaceCatalog {
        let archived = archivedIDs[agentID] ?? []
        var rows: [HermesWorkspaceSummary] = [
            .init(
                id: "loopdy",
                name: "Bighelp",
                description: "Product workspace",
                folderCount: 1,
                isActive: false
            ),
            .init(
                id: "home",
                name: "Home",
                description: "Household workspace",
                folderCount: 2,
                isActive: false
            ),
        ]
        rows.append(contentsOf: createdWorkspaces[agentID] ?? [])
        rows.removeAll { archived.contains($0.id) }
        let preferredActiveID = activeIDs[agentID] ?? "loopdy"
        let activeID = rows.contains(where: { $0.id == preferredActiveID })
            ? preferredActiveID
            : nil
        return HermesWorkspaceCatalog(
            activeWorkspaceID: activeID,
            sessionWorkspaceID: sessionWorkspaceID,
            workspaces: rows.map { row in
                .init(
                    id: row.id,
                    name: row.name,
                    description: row.description,
                    folderCount: row.folderCount,
                    isActive: row.id == activeID
                )
            }
        )
    }
}
