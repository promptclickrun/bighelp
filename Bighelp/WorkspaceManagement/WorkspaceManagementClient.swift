import Foundation

@MainActor
protocol WorkspaceManagementClient: AnyObject {
    var editableDestinations: Set<WorkspaceDestination> { get }
    func load(_ destination: WorkspaceDestination, path: String?, root: String?) async throws -> WorkspaceManagementContent
    func apply(_ mutation: WorkspaceManagementMutation) async throws
    func previewFile(path: String, root: String) async throws -> WorkspaceFilePreview
    func nextFilePage(_ listing: WorkspaceFileListing) async throws -> WorkspaceFileListing
}

extension WorkspaceManagementClient {
    func nextFilePage(_ listing: WorkspaceFileListing) async throws -> WorkspaceFileListing {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
}

@MainActor
protocol WorkspaceManagementFilesClient: AnyObject {
    func load(path: String?, root: String?) async throws -> WorkspaceManagementContent
    func nextPage(_ listing: WorkspaceFileListing) async throws -> WorkspaceFileListing
    func preview(path: String, root: String) async throws -> WorkspaceFilePreview
}

@MainActor
final class NativeWorkspaceManagementClient: WorkspaceManagementClient {
    let owner: WorkspaceOwner
    let profileID: String
    private let servingProfileID: String?
    private let performer: any WorkspaceOperationPerforming
    private let fileClient: (any WorkspaceManagementFilesClient)?
    private let configuredNativeFileRoot: String?
    private let isCurrent: @MainActor () -> Bool
    private var observedNativeFileRoot: String?

    init(
        owner: WorkspaceOwner,
        profileID: String,
        servingProfileID: String? = nil,
        fileClient: (any WorkspaceManagementFilesClient)? = nil,
        configuredNativeFileRoot: String? = nil,
        performer: any WorkspaceOperationPerforming,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.owner = owner
        self.profileID = profileID
        self.servingProfileID = servingProfileID
        self.performer = performer
        self.fileClient = fileClient
        self.configuredNativeFileRoot = configuredNativeFileRoot
        self.isCurrent = isCurrent
    }

    private var profile: [String: BighelpJSONValue] { ["profile": .string(profileID)] }

    var editableDestinations: Set<WorkspaceDestination> {
        guard isCurrent(), performer.owner == owner else { return [] }
        let candidates: [(WorkspaceDestination, WorkspaceCapability)] = [
            (.projects, .projectsEdit), (.keys, .keysEdit), (.webhooks, .webhooksEdit)
        ]
        return Set(candidates.compactMap { destination, capability in
            guard performer.capabilities.supports(capability, owner: owner, profileID: profileID) else { return nil }
            return destination
        })
    }

    private func perform(
        _ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue]
    ) async throws -> [String: BighelpJSONValue] {
        try Task.checkCancellation()
        guard isCurrent(), performer.owner == owner else { throw WorkspaceManagementError.staleOwner }
        guard !profileID.isEmpty, profileID.utf8.count <= 128 else { throw WorkspaceManagementError.invalidInput }
        let result = try await performer.perform(operation, payload: payload, owner: owner)
        try Task.checkCancellation()
        guard isCurrent(), performer.owner == owner else { throw WorkspaceManagementError.staleOwner }
        guard try JSONEncoder().encode(result).count <= 2_097_152 else {
            throw WorkspaceManagementError.invalidResponse
        }
        return result
    }


    func load(_ destination: WorkspaceDestination, path: String? = nil, root: String? = nil) async throws -> WorkspaceManagementContent {
        switch destination {
        case .projects:
            return try .projects(WorkspaceManagementDecoder.projects(await perform(.projectsList, profile)))
        case .models:
            return try .models(WorkspaceManagementDecoder.models(await perform(.modelOptions, profile)))
        case .plugins:
            return try .inventory(WorkspaceInventoryDecoder.plugins(
                await perform(.pluginsList, profile.merging(["action": .string("list")]) { _, new in new })
            ))
        case .toolsets:
            return try .inventory(WorkspaceInventoryDecoder.toolsets(await perform(.toolsetsList, profile)))
        case .mcp:
            return try .inventory(WorkspaceInventoryDecoder.mcp(await perform(.mcpServersList, profile)))
        case .messaging:
            return try .inventory(WorkspaceInventoryDecoder.messaging(await perform(.messagingPlatformsList, profile)))
        case .usage:
            return try .inventory(WorkspaceInventoryDecoder.usage(
                await perform(.usageSummary, profile.merging(["days": .integer(30)]) { _, new in new })
            ))
        case .memory:
            return try .inventory(WorkspaceInventoryDecoder.memory(await perform(.memoryGet, [:])))
        case .webhooks:
            let payload = try await perform(.webhooksList, [:])
            return try .webhooks(WorkspaceInventoryDecoder.webhooks(payload), platformEnabled: WorkspaceInventoryDecoder.bool(payload, "enabled"))
        case .keys:
            return try .credentials(WorkspaceInventoryDecoder.keys(await perform(.keysList, profile)))
        case .system:
            return try .inventory(WorkspaceInventoryDecoder.system(await perform(.systemStatus, [:])))
        case .logs:
            let payload = try await perform(.logsList, ["file": .string("agent"), "lines": .integer(100)])
            guard payload["file"]?.string == "agent" else { throw WorkspaceManagementError.invalidResponse }
            return try .logs(WorkspaceManagementDecoder.logs(payload))
        case .files:
            if let fileClient {
                try checkOwner()
                let result = try await fileClient.load(path: path, root: root)
                try checkOwner()
                return result
            }
            let expectedRoot = configuredNativeFileRoot ?? observedNativeFileRoot
            guard root == nil || root == expectedRoot else { throw WorkspaceManagementError.fileRootNotConfined }
            let selectedPath = path ?? configuredNativeFileRoot
            if let selectedPath {
                _ = try WorkspaceManagementDecoder.path(.string(selectedPath))
                if let expectedRoot, !WorkspaceManagementDecoder.contains(root: expectedRoot, path: selectedPath) {
                    throw WorkspaceManagementError.fileRootNotConfined
                }
            }
            let payload = try await perform(.filesList, selectedPath.map { ["path": .string($0)] } ?? [:])
            let listing = try WorkspaceManagementDecoder.files(payload, expectedPath: selectedPath, expectedRoot: expectedRoot)
            observedNativeFileRoot = listing.root
            return .files(listing)
        default:
            throw WorkspaceManagementError.unavailable("Open this feature through its existing Workspace destination.")
        }
    }

    func apply(_ mutation: WorkspaceManagementMutation) async throws {
        guard editableDestinations.contains(mutation.destination) else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        switch mutation {
        case .archiveProject(let id, let restore):
            let response = try await perform(.projectsArchive, profile.merging([
                "id": .string(try validIdentifier(id)), "restore": .boolean(restore)
            ]) { _, new in new })
            let projects = try WorkspaceManagementDecoder.projects(response)
            guard let project = projects.first(where: { $0.id == id }), project.isArchived == !restore else {
                throw WorkspaceManagementError.unconfirmedMutation
            }
        case .renameProject(let id, let name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 200 else { throw WorkspaceManagementError.invalidInput }
            let response = try await perform(.projectsUpdate, profile.merging([
                "id": .string(try validIdentifier(id)), "name": .string(name)
            ]) { _, new in new })
            guard let row = response["project"]?.object else { throw WorkspaceManagementError.unconfirmedMutation }
            let project = try WorkspaceManagementDecoder.project(row)
            guard project.id == id, project.name == name else { throw WorkspaceManagementError.unconfirmedMutation }
        case .replaceCredential(let key, let value):
            guard WorkspaceInventoryDecoder.validKey(key), !value.isEmpty, value.utf8.count <= 8_192,
                  !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
                throw WorkspaceManagementError.invalidInput
            }
            guard case .credentials(let keys) = try await load(.keys),
                  keys.contains(where: { $0.id == key && $0.canReplace }) else {
                throw WorkspaceManagementError.unavailable("This credential is managed by its Hermes connection flow.")
            }
            let response = try await perform(.keysSet, profile.merging([
                "key": .string(key), "value": .string(value)
            ]) { _, new in new })
            guard response["ok"]?.boolean == true, response["key"]?.string == key else {
                throw WorkspaceManagementError.unconfirmedMutation
            }
            guard case .credentials(let keys) = try await load(.keys),
                  keys.contains(where: { $0.id == key && $0.isSet }) else {
                throw WorkspaceManagementError.unconfirmedMutation
            }
        case .setWebhookEnabled(let name, let enabled):
            let response = try await perform(.webhooksSetEnabled, [
                "name": .string(try validIdentifier(name)), "enabled": .boolean(enabled)
            ])
            guard response["ok"]?.boolean == true, response["name"]?.string == name,
                  response["enabled"]?.boolean == enabled else { throw WorkspaceManagementError.unconfirmedMutation }
        }
    }

    func previewFile(path: String, root: String) async throws -> WorkspaceFilePreview {
        if let fileClient {
            try checkOwner()
            let result = try await fileClient.preview(path: path, root: root)
            try checkOwner()
            return result
        }
        _ = try WorkspaceManagementDecoder.path(.string(path))
        guard root == (configuredNativeFileRoot ?? observedNativeFileRoot), WorkspaceManagementDecoder.contains(root: root, path: path) else {
            throw WorkspaceManagementError.fileRootNotConfined
        }
        let payload = try await perform(.filesRead, ["path": .string(path)])
        return try WorkspaceManagementDecoder.file(payload, expectedPath: path, root: root)
    }

    func nextFilePage(_ listing: WorkspaceFileListing) async throws -> WorkspaceFileListing {
        guard let fileClient else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
        try checkOwner()
        let result = try await fileClient.nextPage(listing)
        try checkOwner()
        return result
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard isCurrent(), performer.owner == owner else { throw WorkspaceManagementError.staleOwner }
    }

    private func validIdentifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              value != ".", value != ".." else { throw WorkspaceManagementError.invalidInput }
        return value
    }
}
