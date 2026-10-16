import Foundation

/// Native, feature-specific capability management destinations. This intentionally
/// cannot represent arbitrary host routes or RPC methods.
enum CapabilitiesManagementKind: String, CaseIterable, Identifiable, Sendable {
    case skills, mcp, plugins, toolsets

    var id: Self { self }

    init?(destination: WorkspaceDestination) {
        switch destination {
        case .skills: self = .skills
        case .mcp: self = .mcp
        case .plugins: self = .plugins
        case .toolsets: self = .toolsets
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .skills: "Skills Hub"
        case .mcp: "MCP Servers"
        case .plugins: "Plugins"
        case .toolsets: "Toolsets"
        }
    }
}

enum CapabilitiesHostSupport: Equatable, Sendable {
    case unknown
    case available
    case unavailable(String)
}

enum CapabilityWriteResult: Equatable, Sendable {
    case confirmed(String)
    case pending(receipt: CapabilityActionReceipt, message: String)
}

/// Exact launch identity returned by a capability mutation. Action names are
/// kept byte-for-byte; the shared Host Operations client remains responsible
/// for deciding which names are safe to address through its status route.
struct CapabilityActionReceipt: Equatable, Sendable {
    let actionName: String
    let processID: Int?
    let actionID: String?
    let admittedAt: Date

    init(
        actionName: String,
        processID: Int? = nil,
        actionID: String? = nil,
        admittedAt: Date = Date()
    ) {
        self.actionName = actionName
        self.processID = processID
        self.actionID = actionID
        self.admittedAt = admittedAt
    }

    @MainActor
    func hostReceipt(using client: any HermesHostActionStatusClient) throws -> HermesHostActionReceipt {
        let slot = try client.receipt(forActionName: actionName)
        return HermesHostActionReceipt(
            action: slot.action,
            processID: processID,
            actionID: actionID,
            archivePath: nil,
            admittedAt: admittedAt,
            admission: processID != nil || actionID != nil ? .launchAcknowledged : .actionSlotOnly
        )
    }
}

@MainActor
protocol CapabilityActionStatusProviding: AnyObject {
    var actionStatusClient: (any HermesHostActionStatusClient)? { get }
    var isCurrentActionOwner: Bool { get }
}

extension CapabilityActionStatusProviding {
    var actionStatusClient: (any HermesHostActionStatusClient)? { nil }
    var isCurrentActionOwner: Bool { true }
}

enum CapabilitiesManagementError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedHost(String)
    case invalidRequest
    case invalidResponse
    case capacityExceeded
    case staleOwner
    case rejected(String)
    case readbackFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedHost(let message): message
        case .invalidRequest: "Check the selected values and try again."
        case .invalidResponse: "Hermes returned an unsupported response. No change was confirmed."
        case .capacityExceeded: "The host response exceeded this screen’s safe display limit."
        case .staleOwner: "The selected host or profile changed. Reopen this page from the current workspace."
        case .rejected(let message): message
        case .readbackFailed: "Hermes accepted the request, but the requested state was not confirmed by readback. Refresh before trying again."
        }
    }
}

struct SkillHubSource: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let isAvailable: Bool?
    let isSearchable: Bool
    let isRateLimited: Bool
}

struct SkillHubItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let source: String
    let trustLevel: String
    let repository: String?
    let tags: [String]
    let category: String?
    let isInstalled: Bool
}

struct InstalledSkill: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String
    let category: String
    let isEnabled: Bool
    let provenance: String
    let usageCount: Int
    var id: String { name }
}

struct SkillHubSnapshot: Equatable, Sendable {
    let sources: [SkillHubSource]
    let featured: [SkillHubItem]
    let official: [SkillHubItem]
    let installedSkills: [InstalledSkill]
    let installedIdentifiers: Set<String>
    let indexAvailable: Bool
}

struct SkillHubSearchResult: Equatable, Sendable {
    let items: [SkillHubItem]
    let sourceCounts: [String: Int]
    let timedOutSources: [String]
}

struct SkillHubPreview: Equatable, Sendable {
    let item: SkillHubItem
    let skillMarkdown: String
    let files: [String]
}

struct SkillHubScanFinding: Identifiable, Equatable, Sendable {
    let severity: String
    let category: String
    let file: String
    let line: Int?
    let detail: String
    var id: String { "\(severity)\u{1f}\(category)\u{1f}\(file)\u{1f}\(line ?? -1)\u{1f}\(detail)" }
}

struct SkillHubScan: Equatable, Sendable {
    enum Policy: String, Equatable, Sendable { case allow, ask, block }
    let identifier: String
    let name: String
    let source: String
    let trustLevel: String
    let verdict: String
    let summary: String
    let policy: Policy
    let policyReason: String
    let findings: [SkillHubScanFinding]
    let severityCounts: [String: Int]
}

@MainActor
protocol SkillsHubManagementClient: AnyObject, Sendable, CapabilityActionStatusProviding {
    var owner: WorkspaceOwner { get }
    var profileID: String { get }
    func load() async throws -> SkillHubSnapshot
    func search(query: String, source: String) async throws -> SkillHubSearchResult
    func preview(identifier: String) async throws -> SkillHubPreview
    func scan(identifier: String) async throws -> SkillHubScan
    func setEnabled(_ enabled: Bool, skillName: String) async throws -> InstalledSkill
    func install(identifier: String, preview: SkillHubPreview, scan: SkillHubScan) async throws -> CapabilityWriteResult
    func uninstall(name: String) async throws -> CapabilityWriteResult
    func updateInstalled() async throws -> CapabilityWriteResult
}

struct MCPEnvironmentRequirement: Identifiable, Equatable, Sendable {
    let name: String
    let prompt: String
    let isRequired: Bool
    var id: String { name }
}

struct MCPCatalogEntry: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String
    let source: String
    let transport: String
    let authType: String
    let requiredEnvironment: [MCPEnvironmentRequirement]
    let command: String?
    let arguments: [String]
    let url: String?
    let installURL: String?
    let installReference: String?
    let bootstrap: [String]
    let postInstall: String
    let needsInstall: Bool
    let isInstalled: Bool
    let isEnabled: Bool
    var id: String { name }
}

struct MCPServer: Identifiable, Equatable, Sendable {
    let name: String
    let transport: String
    let url: String?
    let command: String?
    let arguments: [String]
    let auth: String?
    let isEnabled: Bool
    let environmentKeys: [String]
    let headerNames: [String]
    var id: String { name }
}

struct MCPSnapshot: Equatable, Sendable {
    let servers: [MCPServer]
    let catalog: [MCPCatalogEntry]
    let diagnostics: [String]
}

struct MCPServerDraft: Equatable, Sendable {
    enum Transport: String, CaseIterable, Identifiable, Sendable {
        case http, stdio
        var id: Self { self }
    }
    enum Authentication: String, CaseIterable, Identifiable, Sendable {
        case none, oauth, bearer
        var id: Self { self }
    }

    var name = ""
    var transport: Transport = .http
    var url = ""
    var command = ""
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var authentication: Authentication = .none
    var bearerToken = ""
    var isEnabled = true
}

struct MCPProbeTool: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String
    let schemaCharacterCount: Int?
    var id: String { name }
}

struct MCPProbeResult: Equatable, Sendable {
    /// Some servers (a whole cloud provider's API) offer thousands of tools; Hermes
    /// keeps the ones its include list names. The screen lists the first few.
    static let displayedToolLimit = 200
    static let summaryCharacterLimit = 400

    let succeeded: Bool
    let error: String?
    /// The first `displayedToolLimit` tools.
    let tools: [MCPProbeTool]
    /// Every tool the server offers.
    let toolCount: Int
    let promptCount: Int
    let resourceCount: Int

    /// Reads a host's tool rows leniently: all of them are counted, the first
    /// few are kept, and long descriptions are shortened rather than refused.
    static func displayedTools(_ value: BighelpJSONValue?) throws -> (tools: [MCPProbeTool], count: Int) {
        let rows = try CapabilitiesPayload.array(value)
        let tools = try rows.prefix(displayedToolLimit).map { value in
            let row = try CapabilitiesPayload.object(value)
            let schemaCharacters = row["schema_chars"]?.integer
            if let schemaCharacters, !(0...2_000_000).contains(schemaCharacters) {
                throw CapabilitiesManagementError.invalidResponse
            }
            let summary = row["description"]?.string ?? ""
            return MCPProbeTool(
                name: try CapabilitiesPayload.text(row["name"], maximumBytes: 256),
                summary: summary.count > summaryCharacterLimit
                    ? String(summary.prefix(summaryCharacterLimit)) + "…" : summary,
                schemaCharacterCount: schemaCharacters
            )
        }
        return (tools, rows.count)
    }
}

struct MCPOAuthFlow: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case starting
        case authorizationRequired = "authorization_required"
        case approved
        case error
        case expired
        case unknown
    }
    let id: String
    let serverName: String
    let status: Status
    let authorizationURL: URL?
    let error: String?
    let tools: [MCPProbeTool]
}

@MainActor
protocol MCPManagementClient: AnyObject, CapabilityActionStatusProviding {
    var owner: WorkspaceOwner { get }
    var profileID: String { get }
    func load() async throws -> MCPSnapshot
    func add(_ draft: MCPServerDraft) async throws -> MCPServer
    func installCatalog(name: String, environment: [String: String], enable: Bool) async throws -> CapabilityWriteResult
    func setEnabled(_ enabled: Bool, serverName: String) async throws -> MCPServer
    func remove(serverName: String) async throws
    func test(serverName: String) async throws -> MCPProbeResult
    func startOAuth(serverName: String) async throws -> MCPOAuthFlow
    func pollOAuth(flowID: String) async throws -> MCPOAuthFlow
    func cancelOAuth(flowID: String) async throws -> MCPOAuthFlow.Status
}

struct PluginCapabilitySummary: Equatable, Sendable {
    let tools: [String]
    let hooks: [String]
    let middleware: [String]
    let requiredEnvironment: [String]
}

struct PluginCatalogEntry: Identifiable, Equatable, Sendable {
    let name: String
    let repository: String
    let commitSHA: String
    let summary: String
    let maintainer: String
    let tier: String
    let requiredHermesVersion: String
    let documentationURL: URL?
    let platforms: [String]
    let capabilities: PluginCapabilitySummary
    let isInstalled: Bool
    let installedSHA: String?
    let updateAvailable: Bool
    let runtimeStatus: String?
    let removedReason: String?
    var id: String { name }
}

struct InstalledPlugin: Identifiable, Equatable, Sendable {
    let name: String
    let version: String
    let summary: String
    let source: String
    let runtimeStatus: String
    let canRemove: Bool
    let canUpdate: Bool
    let requiresAuthentication: Bool
    let authenticationCommand: String
    let removedReason: String?
    var id: String { name }
    var isEnabled: Bool { runtimeStatus == "enabled" }
}

struct PluginSnapshot: Equatable, Sendable {
    let installed: [InstalledPlugin]
    let catalog: [PluginCatalogEntry]
    let removedCatalogEntries: [String]
}

@MainActor
protocol PluginLifecycleManagementClient: AnyObject {
    var owner: WorkspaceOwner { get }
    func load() async throws -> PluginSnapshot
    func rescan() async throws -> PluginSnapshot
    func installCatalog(name: String, expectedCommitSHA: String) async throws -> InstalledPlugin
    func setEnabled(_ enabled: Bool, pluginName: String) async throws -> InstalledPlugin
    func update(pluginName: String) async throws -> InstalledPlugin
    func remove(pluginName: String) async throws
}

struct ToolsetSummary: Identifiable, Equatable, Sendable {
    let name: String
    let label: String
    let summary: String
    let platform: String
    let platformLabel: String
    let isEnabled: Bool
    let isConfigured: Bool
    let tools: [String]
    var id: String { name }
}

struct ToolsetEnvironmentField: Identifiable, Equatable, Sendable {
    let key: String
    let prompt: String
    let helpURL: URL?
    let defaultValue: String?
    let isSet: Bool
    var id: String { key }
}

struct ToolsetProvider: Identifiable, Equatable, Sendable {
    let name: String
    let badge: String
    let tag: String
    let environment: [ToolsetEnvironmentField]
    let postSetupKey: String?
    let requiresNousAuthentication: Bool
    let isActive: Bool
    let status: String
    let webBackend: String?
    let capabilities: [String]
    var id: String { name }
}

struct ToolsetConfiguration: Equatable, Sendable {
    let name: String
    let hasCategory: Bool
    let providers: [ToolsetProvider]
    let activeProvider: String?
    let activeSearchBackend: String?
    let activeExtractBackend: String?
}

struct ToolsetModel: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let speed: String
    let strengths: String
    let price: String
}

struct ToolsetModelCatalog: Equatable, Sendable {
    let name: String
    let hasModels: Bool
    let provider: String?
    let models: [ToolsetModel]
    let current: String?
    let defaultModel: String?
}

struct ToolsetSnapshot: Equatable, Sendable {
    let toolsets: [ToolsetSummary]
}

struct ToolsetDetail: Equatable, Sendable {
    let summary: ToolsetSummary
    let configuration: ToolsetConfiguration
    let models: ToolsetModelCatalog
}

enum ToolsetWebCapability: String, CaseIterable, Identifiable, Sendable {
    case search, extract
    var id: Self { self }
}

@MainActor
protocol ToolsetManagementClient: AnyObject, CapabilityActionStatusProviding {
    var owner: WorkspaceOwner { get }
    var profileID: String { get }
    func load() async throws -> ToolsetSnapshot
    func detail(name: String, modelProvider: String?) async throws -> ToolsetDetail
    func setEnabled(_ enabled: Bool, name: String) async throws -> ToolsetSummary
    func selectProvider(_ provider: String, name: String, capability: ToolsetWebCapability?) async throws -> ToolsetDetail
    func saveEnvironment(_ environment: [String: String], name: String) async throws -> ToolsetDetail
    func selectModel(_ model: String, provider: String?, name: String) async throws -> ToolsetDetail
    func runPostSetup(key: String, name: String) async throws -> CapabilityWriteResult
}

struct CapabilitiesManagementDependencies {
    let skills: any SkillsHubManagementClient
    let mcp: any MCPManagementClient
    let plugins: any PluginLifecycleManagementClient
    let toolsets: any ToolsetManagementClient

    init(
        skills: any SkillsHubManagementClient,
        mcp: any MCPManagementClient,
        plugins: any PluginLifecycleManagementClient,
        toolsets: any ToolsetManagementClient
    ) {
        self.skills = skills
        self.mcp = mcp
        self.plugins = plugins
        self.toolsets = toolsets
    }
}

/// Shared validation/projection helpers for the fixed Direct clients.
enum CapabilitiesPayload {
    static let maximumTextBytes = 32_768
    static let maximumDocumentBytes = 256_000
    /// Longer descriptions are shortened (`summary`); a curated plugin's ran past 10 KB.
    static let summaryCharacterLimit = 8_192

    static func object(_ value: BighelpJSONValue?) throws -> [String: BighelpJSONValue] {
        guard let value, let object = value.object else { throw CapabilitiesManagementError.invalidResponse }
        return object
    }

    /// A host list, any length: the connection's reply-size limit bounds it, and
    /// screens draw lazily.
    static func array(_ value: BighelpJSONValue?) throws -> [BighelpJSONValue] {
        guard let rows = value?.array else { throw CapabilitiesManagementError.invalidResponse }
        return rows
    }

    /// A host list's rows. A row that doesn't decode is left out, so one odd row
    /// hides itself instead of the whole page. Checks that confirm by absence use
    /// `listsName`, which still sees it.
    static func rows<Row>(_ value: BighelpJSONValue?, _ decode: (BighelpJSONValue) throws -> Row) throws -> [Row] {
        try array(value).compactMap { try? decode($0) }
    }

    /// Whether a host list has a row with this name, readable or not.
    static func listsName(_ name: String, in value: BighelpJSONValue?) throws -> Bool {
        try array(value).contains { $0.object?["name"]?.string == name }
    }

    /// Display-only host text such as a description: missing or null is empty,
    /// and a long one is shortened rather than refused.
    static func summary(_ value: BighelpJSONValue?) throws -> String {
        guard let value, value != .null else { return "" }
        let summary = try text(value, maximumBytes: .max, required: false)
        return summary.count > summaryCharacterLimit ? String(summary.prefix(summaryCharacterLimit)) + "…" : summary
    }

    static func text(
        _ value: BighelpJSONValue?, maximumBytes: Int = maximumTextBytes,
        required: Bool = true
    ) throws -> String {
        guard let string = value?.string, (!required || !string.isEmpty), string.utf8.count <= maximumBytes,
              !string.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t")).contains($0)
              }) else { throw CapabilitiesManagementError.invalidResponse }
        return string
    }

    static func optionalText(_ value: BighelpJSONValue?, maximumBytes: Int = maximumTextBytes) throws -> String? {
        guard let value, value != .null else { return nil }
        return try text(value, maximumBytes: maximumBytes, required: false)
    }

    static func strings(_ value: BighelpJSONValue?) throws -> [String] {
        try array(value).map { try text($0, maximumBytes: 4_096) }
    }

    static func boolean(_ value: BighelpJSONValue?) throws -> Bool {
        guard let value = value?.boolean else { throw CapabilitiesManagementError.invalidResponse }
        return value
    }

    static func integer(_ value: BighelpJSONValue?, range: ClosedRange<Int> = 0...1_000_000) throws -> Int {
        guard let value = value?.integer, range.contains(value) else {
            throw CapabilitiesManagementError.invalidResponse
        }
        return value
    }

    static func identifier(_ value: String, maximumBytes: Int = 160, allowsSlash: Bool = false) throws -> String {
        let allowedPunctuation = allowsSlash ? "._-/" : "._-"
        guard !value.isEmpty, value.utf8.count <= maximumBytes, value != ".", value != "..",
              !value.hasPrefix("/"), !value.hasSuffix("/"), !value.contains("//"),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || allowedPunctuation.contains($0)) }),
              !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CapabilitiesManagementError.invalidRequest
        }
        return value
    }

    @MainActor static func profile(_ value: String) throws -> String {
        try DirectHermesAgentProfileService.profileIdentifier(value)
    }

    static func safeRemoteMessage(_ value: BighelpJSONValue?, fallback: String) -> String {
        guard let message = value?.string, !message.isEmpty, message.utf8.count <= 240,
              !message.contains("/"), !message.contains("\\"),
              !message.lowercased().contains("token"), !message.lowercased().contains("secret") else {
            return fallback
        }
        return message
    }
}
