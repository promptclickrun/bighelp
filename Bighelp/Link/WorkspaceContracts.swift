import Foundation

// Shared native workspace values; names retain source compatibility.
enum BighelpLinkWorkspaceClientError: Error, Equatable, LocalizedError {
    case invalidRequest
    case invalidResponse
    case remote(status: BighelpLinkWorkspaceResult.Status, code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The skill file or request is invalid."
        case .invalidResponse:
            "Hermes returned an invalid response."
        case .remote(_, _, let message):
            message ?? "Hermes could not complete this request."
        }
    }
}

struct BighelpCardTemplateProjection: Equatable, Sendable {
    let id: String
    let version: Int
    let name: String
    let summary: String
    let author: String
    let license: String
    let minimumCardVersion: Int
    let sha256: String

    init(_ value: BighelpJSONValue) throws {
        guard let object = value.object,
              Set(object.keys) == [
                "id", "version", "name", "summary", "author", "license",
                "minimum_card_version", "sha256",
              ],
              let id = object["id"]?.string,
              let version = object["version"]?.integer,
              let name = object["name"]?.string,
              let summary = object["summary"]?.string,
              let author = object["author"]?.string,
              let license = object["license"]?.string,
              let minimumCardVersion = object["minimum_card_version"]?.integer,
              let sha256 = object["sha256"]?.string,
              !id.isEmpty, version > 0, minimumCardVersion == 1,
              sha256.count == 64,
              sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        self.id = id
        self.version = version
        self.name = name
        self.summary = summary
        self.author = author
        self.license = license
        self.minimumCardVersion = minimumCardVersion
        self.sha256 = sha256
    }
}

struct HermesSkillSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let category: String
    let isEnabled: Bool
}

struct HermesPluginSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: String
    let version: String
    let description: String
    let isEnabled: Bool
    let capabilityCount: Int
}

struct HermesMCPServerSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let transport: String
    let isEnabled: Bool
    let toolCount: Int?
}

struct HermesSkillDocument: Equatable, Sendable {
    let agentID: String
    let skillID: String
    let content: String
    let sha256: String
}

enum HermesCapabilityCompatibilityError: LocalizedError {
    case updateRequired

    var errorDescription: String? {
        "This computer supports browsing only. Update Hermes and deploy the matching Bighelp plugin on the computer to edit, create, import, or manage capabilities."
    }
}

struct HermesCapabilityManagement: Equatable, Sendable {
    let canRead: Bool
    let canCreate: Bool
    let canUpdate: Bool
    let canImport: Bool
}

struct HermesToolsetSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let platform: String
    let isEnabled: Bool
    let toolCount: Int
}

struct HermesSkillsAndToolsCatalog: Equatable, Sendable {
    let agentID: String
    let skills: [HermesSkillSummary]
    let plugins: [HermesPluginSummary]
    let mcpServers: [HermesMCPServerSummary]
    var tools: [HermesToolsetSummary] = []
    var management: HermesCapabilityManagement? = nil
    var toolsNotice: String = ""
}

@MainActor
protocol HermesSkillsAndToolsCatalogClient: AnyObject {
    func control(kind: HermesCapabilityKind, id: String, agentID: String) async throws -> HermesCapabilityControl
    func setEnabled(_ enabled: Bool, control: HermesCapabilityControl) async throws -> HermesCapabilityControl
    func load(agentID: String) async throws -> HermesSkillsAndToolsCatalog
    func skill(id: String, agentID: String) async throws -> HermesSkillDocument
    func createSkill(
        name: String,
        content: String,
        category: String?,
        agentID: String
    ) async throws -> HermesSkillDocument
    func updateSkill(
        id: String,
        content: String,
        expectedSHA256: String,
        agentID: String
    ) async throws -> HermesSkillDocument
    func importSkill(
        data: Data,
        kind: String,
        category: String?,
        agentID: String
    ) async throws -> HermesSkillDocument
}

extension HermesSkillsAndToolsCatalogClient {
    func control(kind: HermesCapabilityKind, id: String, agentID: String) async throws -> HermesCapabilityControl {
        throw HermesCapabilityCompatibilityError.updateRequired
    }

    func setEnabled(_ enabled: Bool, control: HermesCapabilityControl) async throws -> HermesCapabilityControl {
        throw HermesCapabilityCompatibilityError.updateRequired
    }

    func skill(id: String, agentID: String) async throws -> HermesSkillDocument {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func createSkill(
        name: String,
        content: String,
        category: String?,
        agentID: String
    ) async throws -> HermesSkillDocument {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func updateSkill(
        id: String,
        content: String,
        expectedSHA256: String,
        agentID: String
    ) async throws -> HermesSkillDocument {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }

    func importSkill(
        data: Data,
        kind: String,
        category: String?,
        agentID: String
    ) async throws -> HermesSkillDocument {
        throw BighelpLinkWorkspaceClientError.invalidResponse
    }
}


struct HermesWorkspaceSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let folderCount: Int
    let isActive: Bool
}

struct HermesWorkspaceCatalog: Equatable, Sendable {
    let activeWorkspaceID: String?
    let sessionWorkspaceID: String?
    let workspaces: [HermesWorkspaceSummary]

    init(
        activeWorkspaceID: String?,
        sessionWorkspaceID: String? = nil,
        workspaces: [HermesWorkspaceSummary]
    ) {
        self.activeWorkspaceID = activeWorkspaceID
        self.sessionWorkspaceID = sessionWorkspaceID
        self.workspaces = workspaces
    }
}

struct HermesWorkspaceFolderSuggestion: Identifiable, Equatable, Sendable {
    let name: String
    let path: String

    var id: String { path }
}

struct HermesWorkspaceFolderPage: Equatable, Sendable {
    let parentPath: String
    let folders: [HermesWorkspaceFolderSuggestion]
    let nextOffset: Int?
}

@MainActor
protocol HermesWorkspaceCatalogClient: AnyObject {
    func load(agentID: String) async throws -> HermesWorkspaceCatalog
    func load(agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog
    func select(
        id: String,
        agentID: String,
        sessionID: String?
    ) async throws -> HermesWorkspaceCatalog
    func create(
        name: String,
        folderPath: String,
        agentID: String
    ) async throws -> HermesWorkspaceCatalog
    func archive(id: String, agentID: String) async throws -> HermesWorkspaceCatalog
    /// A project's one-line description, shown on its card.
    func describe(id: String, description: String, agentID: String) async throws -> HermesWorkspaceCatalog
    func folderSuggestions(
        parentPath: String,
        prefix: String,
        offset: Int,
        limit: Int,
        agentID: String
    ) async throws -> HermesWorkspaceFolderPage
}

extension HermesWorkspaceCatalogClient {
    func load(agentID: String, sessionID _: String?) async throws -> HermesWorkspaceCatalog {
        try await load(agentID: agentID)
    }
}

extension HermesWorkspaceCatalogClient {
    /// Clients without descriptions keep the project as created.
    func describe(id: String, description: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        try await load(agentID: agentID)
    }
}
