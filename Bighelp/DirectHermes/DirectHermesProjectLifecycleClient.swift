import Foundation

struct HermesProjectSession: Identifiable, Equatable, Sendable {
    let id: String
    let profileID: String
    let title: String
    let preview: String
    let cwd: String?
    let branch: String?
    let lastActive: Date?
    let pullRequest: HermesProjectPullRequest?
}

struct HermesProjectPullRequest: Identifiable, Equatable, Sendable {
    let number: Int
    let url: URL
    var id: Int { number }
}

struct HermesProjectLane: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let path: String?
    let isMain: Bool
    let isKanban: Bool
    let sessions: [HermesProjectSession]
}

struct HermesProjectRepository: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let path: String?
    let sessionCount: Int
    let lanes: [HermesProjectLane]
}

struct HermesProjectTreeNode: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let path: String?
    let color: String?
    let icon: String?
    let isAutomatic: Bool
    let isHome: Bool
    let sessionCount: Int
    let lastActive: Date?
    let totalTokens: Int
    let totalCostUSD: Double
    let repositories: [HermesProjectRepository]
    let previewSessions: [HermesProjectSession]
}

struct HermesDiscoveredRepository: Identifiable, Equatable, Sendable {
    let root: String
    let label: String
    let sessionCount: Int
    let lastActive: Date?
    var id: String { root }
}

struct HermesProjectOverview: Equatable, Sendable {
    let profileID: String
    let registeredProjects: [WorkspaceProject]
    let tree: [HermesProjectTreeNode]
    let discoveredRepositories: [HermesDiscoveredRepository]
    let activeProjectID: String?
    let scopedSessionIDs: [String]
}

struct HermesProjectDetail: Equatable, Sendable {
    let project: WorkspaceProject
    let tree: HermesProjectTreeNode
    let facts: StockGitProjectFacts?
}

enum HermesProjectLifecycleAction: Equatable, Sendable {
    case create(name: String, discoveredRoot: String)
    case addFolder(projectID: String, discoveredRoot: String, label: String?, makePrimary: Bool)
    case removeFolder(projectID: String, path: String)
    case setPrimary(projectID: String, path: String)
    case delete(projectID: String)

    var title: String {
        switch self {
        case .create: "Create project"
        case .addFolder: "Add project folder"
        case .removeFolder: "Remove project folder"
        case .setPrimary: "Set primary folder"
        case .delete: "Delete project registration"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .removeFolder, .delete: true
        default: false
        }
    }
}

struct HermesProjectPreparedAction: Identifiable, Equatable, Sendable {
    let id: UUID
    let confirmationToken: String
    let profileID: String
    let action: HermesProjectLifecycleAction
    let summary: String
}

@MainActor
protocol HermesProjectLifecycleManaging: AnyObject {
    func overview(profileID: String) async throws -> HermesProjectOverview
    func globalTree() async throws -> [HermesProjectTreeNode]
    func detail(projectID: String, profileID: String) async throws -> HermesProjectDetail
    func prepare(_ action: HermesProjectLifecycleAction, profileID: String) throws -> HermesProjectPreparedAction
    func execute(_ prepared: HermesProjectPreparedAction, confirmationToken: String) async throws -> HermesProjectOverview
}

/// Typed stock Hermes Project lifecycle. Paths can enter a mutation only by being
/// selected from the host's registered folders or `projects.discover_repos`
/// snapshot; there is intentionally no arbitrary path entry point.
@MainActor
final class DirectHermesProjectLifecycleClient: HermesProjectLifecycleManaging {
    private enum Method: String {
        case list = "projects.list"
        case create = "projects.create"
        case tree = "projects.tree"
        case sessions = "projects.project_sessions"
        case discover = "projects.discover_repos"
        case addFolder = "projects.add_folder"
        case removeFolder = "projects.remove_folder"
        case setPrimary = "projects.set_primary"
        case delete = "projects.delete"
        case facts = "project.facts"
    }

    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private var overviews: [String: HermesProjectOverview] = [:]
    private var prepared: [UUID: HermesProjectPreparedAction] = [:]

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.rpc = rpc
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func overview(profileID rawProfile: String) async throws -> HermesProjectOverview {
        let profile = try profile(rawProfile)
        let registrationsValue = try await call(.list, profile: profile)
        let registered = try decodeRegistered(registrationsValue)
        let treeValue = try await call(.tree, profile: profile, params: [
            "preview_limit": .integer(3), "session_limit": .integer(2_000)
        ])
        var tree = try decodeTree(treeValue)
        let discoveredValue = try await call(.discover, profile: profile, params: ["scan": .boolean(false)])
        let discovered = try decodeDiscovered(discoveredValue)
        let previewIDs = tree.flatMap(\.previewSessions).map(\.id)
        let pullRequests = try await pullRequests(for: previewIDs)
        tree = attach(pullRequests, to: tree)
        try checkOwner()
        let active: String?
        if registrationsValue.object?["active_id"] == .null { active = nil }
        else { active = try registrationsValue.object?["active_id"].map { try identifier(text($0, maximum: 160)) } }
        let scoped = try stringArray(treeValue.object?["scoped_session_ids"], maximum: 20_000, itemMaximum: 512)
        let result = HermesProjectOverview(
            profileID: profile,
            registeredProjects: registered,
            tree: tree,
            discoveredRepositories: discovered,
            activeProjectID: active,
            scopedSessionIDs: scoped
        )
        overviews[profile] = result
        return result
    }

    /// Public REST all-profile tree. This is separate from the selected-profile
    /// RPC overview so profile ownership is never inferred from a merged node.
    func globalTree() async throws -> [HermesProjectTreeNode] {
        try checkOwner()
        let value = try await http.request(.init(
            path: "/api/profiles/projects/tree",
            method: .get,
            query: [
                .init(name: "preview_limit", value: "3"),
                .init(name: "session_limit", value: "2000")
            ],
            maximumResponseBytes: 2_097_152
        ))
        try checkOwner()
        var tree = try decodeTree(value)
        let ids = tree.flatMap(\.previewSessions).map(\.id)
        tree = attach(try await pullRequests(for: ids), to: tree)
        return tree
    }

    func detail(projectID rawProject: String, profileID rawProfile: String) async throws -> HermesProjectDetail {
        let profile = try profile(rawProfile)
        let projectID = try identifier(rawProject)
        let current: HermesProjectOverview
        if let observed = overviews[profile] {
            current = observed
        } else {
            current = try await overview(profileID: profile)
        }
        guard let project = current.registeredProjects.first(where: { $0.id == projectID }),
              !project.isArchived else { throw WorkspaceClientError.conflict }
        let value = try await call(.sessions, profile: profile, params: [
            "project_id": .string(projectID), "session_limit": .integer(5_000)
        ])
        guard let object = value.object, let rawTree = object["project"], rawTree != .null else {
            throw WorkspaceClientError.invalidResponse
        }
        var tree = try decodeTreeRow(rawTree)
        let ids = tree.repositories.flatMap(\.lanes).flatMap(\.sessions).map(\.id)
        let prs = try await pullRequests(for: ids)
        tree = attach(prs, to: tree)
        let facts: StockGitProjectFacts?
        if let primary = project.folders.first(where: \.isPrimary)?.path {
            facts = try? await projectFacts(cwd: try hostPath(primary))
        } else {
            facts = nil
        }
        try checkOwner()
        return .init(project: project, tree: tree, facts: facts)
    }

    func prepare(_ action: HermesProjectLifecycleAction, profileID rawProfile: String) throws -> HermesProjectPreparedAction {
        let profile = try profile(rawProfile)
        guard let overview = overviews[profile] else { throw WorkspaceClientError.conflict }
        let action = try validated(action, in: overview)
        let item = HermesProjectPreparedAction(
            id: UUID(),
            confirmationToken: UUID().uuidString.lowercased(),
            profileID: profile,
            action: action,
            summary: summary(action, overview: overview)
        )
        prepared[item.id] = item
        if prepared.count > 12, let oldest = prepared.keys.first { prepared.removeValue(forKey: oldest) }
        return item
    }

    func execute(
        _ requested: HermesProjectPreparedAction,
        confirmationToken: String
    ) async throws -> HermesProjectOverview {
        let profile = try profile(requested.profileID)
        guard let item = prepared.removeValue(forKey: requested.id), item == requested,
              item.confirmationToken == confirmationToken,
              let before = overviews[profile] else { throw WorkspaceClientError.conflict }
        _ = try validated(item.action, in: before)
        do {
            try await perform(item.action, profile: profile)
        } catch {
            try checkOwner()
            if let reconciled = try? await overview(profileID: profile), confirms(item.action, in: reconciled) {
                return reconciled
            }
            throw error
        }
        let after = try await overview(profileID: profile)
        guard confirms(item.action, in: after) else { throw WorkspaceClientError.outcomeUnknown }
        return after
    }

    private func perform(_ action: HermesProjectLifecycleAction, profile: String) async throws {
        let result: BighelpJSONValue
        switch action {
        case .create(let name, let root):
            result = try await call(.create, profile: profile, params: [
                "name": .string(name), "folders": .array([.string(root)]),
                "primary_path": .string(root), "use": .boolean(false)
            ])
        case .addFolder(let projectID, let root, let label, let makePrimary):
            var params: [String: BighelpJSONValue] = [
                "id": .string(projectID), "path": .string(root), "is_primary": .boolean(makePrimary)
            ]
            params["label"] = label.map(BighelpJSONValue.string) ?? .null
            result = try await call(.addFolder, profile: profile, params: params)
        case .removeFolder(let projectID, let path):
            result = try await call(.removeFolder, profile: profile, params: ["id": .string(projectID), "path": .string(path)])
        case .setPrimary(let projectID, let path):
            result = try await call(.setPrimary, profile: profile, params: ["id": .string(projectID), "path": .string(path)])
        case .delete(let projectID):
            result = try await call(.delete, profile: profile, params: ["id": .string(projectID)])
        }
        guard result.object != nil else { throw WorkspaceClientError.invalidResponse }
    }

    private func call(
        _ method: Method,
        profile: String,
        params: [String: BighelpJSONValue] = [:]
    ) async throws -> BighelpJSONValue {
        try checkOwner()
        var payload = params
        payload["profile"] = .string(profile)
        let value = try await rpc.request(method.rawValue, params: payload)
        try checkOwner()
        guard ((try? JSONEncoder().encode(value).count) ?? Int.max) <= 2_097_152 else {
            throw WorkspaceClientError.capacityExceeded
        }
        return value
    }

    private func pullRequests(for rawIDs: [String]) async throws -> [String: HermesProjectPullRequest] {
        var seen = Set<Data>()
        let ids = rawIDs.filter { seen.insert(Data($0.utf8)).inserted }.prefix(2_000)
        guard !ids.isEmpty else { return [:] }
        try checkOwner()
        let value = try await http.request(.init(
            path: "/api/profiles/sessions/pull-requests",
            method: .post,
            body: ["ids": .array(ids.map(BighelpJSONValue.string))],
            maximumResponseBytes: 524_288
        ))
        try checkOwner()
        guard let object = value.object, let raw = object["pull_requests"]?.object,
              raw.count <= ids.count else { throw WorkspaceClientError.invalidResponse }
        var result: [String: HermesProjectPullRequest] = [:]
        for (sessionID, value) in raw {
            guard ids.contains(sessionID), let row = value.object,
                  let number = positiveCount(row["number"]),
                  let url = pullRequestURL(try text(row["url"], maximum: 2_048)) else {
                throw WorkspaceClientError.invalidResponse
            }
            result[sessionID] = .init(number: number, url: url)
        }
        return result
    }

    private func projectFacts(cwd: String) async throws -> StockGitProjectFacts? {
        try checkOwner()
        let value = try await rpc.request(Method.facts.rawValue, params: ["cwd": .string(cwd)])
        try checkOwner()
        guard let object = value.object else { throw WorkspaceClientError.invalidResponse }
        if object["facts"] == .null { return nil }
        guard let facts = object["facts"]?.object,
              let root = facts["root"]?.string else { throw WorkspaceClientError.invalidResponse }
        _ = try hostPath(root)
        return .init(
            root: root,
            kind: try optionalText(facts["kind"], maximum: 80),
            verifyCommands: try stringArray(facts["verifyCommands"], maximum: 20, itemMaximum: 2_000)
        )
    }

    private func validated(
        _ action: HermesProjectLifecycleAction,
        in overview: HermesProjectOverview
    ) throws -> HermesProjectLifecycleAction {
        let projects = overview.registeredProjects
        switch action {
        case .create(let rawName, let rawRoot):
            let name = try displayText(rawName, maximum: 200)
            let root = try discoveredRoot(rawRoot, in: overview)
            guard !projects.contains(where: { $0.folders.contains { $0.path == root } }) else {
                throw WorkspaceClientError.conflict
            }
            return .create(name: name, discoveredRoot: root)
        case .addFolder(let rawID, let rawRoot, let rawLabel, let primary):
            let id = try identifier(rawID)
            guard let project = projects.first(where: { $0.id == id }), !project.isArchived else {
                throw WorkspaceClientError.conflict
            }
            let root = try discoveredRoot(rawRoot, in: overview)
            guard !project.folders.contains(where: { $0.path == root }) else { throw WorkspaceClientError.conflict }
            let label = try rawLabel.map { try displayText($0, maximum: 200) }
            return .addFolder(projectID: id, discoveredRoot: root, label: label, makePrimary: primary)
        case .removeFolder(let rawID, let rawPath):
            let id = try identifier(rawID)
            guard let project = projects.first(where: { $0.id == id }), project.folders.count > 1,
                  let folder = project.folders.first(where: { $0.path == rawPath }) else {
                throw WorkspaceClientError.conflict
            }
            return .removeFolder(projectID: id, path: try hostPath(folder.path))
        case .setPrimary(let rawID, let rawPath):
            let id = try identifier(rawID)
            guard let project = projects.first(where: { $0.id == id }),
                  let folder = project.folders.first(where: { $0.path == rawPath }), !folder.isPrimary else {
                throw WorkspaceClientError.conflict
            }
            return .setPrimary(projectID: id, path: try hostPath(folder.path))
        case .delete(let rawID):
            let id = try identifier(rawID)
            guard projects.contains(where: { $0.id == id }), overview.activeProjectID != id else {
                throw WorkspaceClientError.conflict
            }
            return .delete(projectID: id)
        }
    }

    private func confirms(_ action: HermesProjectLifecycleAction, in overview: HermesProjectOverview) -> Bool {
        switch action {
        case .create(let name, let root):
            return overview.registeredProjects.contains { $0.name == name && $0.folders.contains { $0.path == root && $0.isPrimary } }
        case .addFolder(let id, let root, _, let primary):
            return overview.registeredProjects.first(where: { $0.id == id })?.folders.contains {
                $0.path == root && (!primary || $0.isPrimary)
            } == true
        case .removeFolder(let id, let path):
            return overview.registeredProjects.first(where: { $0.id == id })?.folders.contains { $0.path == path } == false
        case .setPrimary(let id, let path):
            return overview.registeredProjects.first(where: { $0.id == id })?.folders.first(where: { $0.path == path })?.isPrimary == true
        case .delete(let id):
            return !overview.registeredProjects.contains(where: { $0.id == id })
        }
    }

    private func summary(_ action: HermesProjectLifecycleAction, overview: HermesProjectOverview) -> String {
        func project(_ id: String) -> String { overview.registeredProjects.first(where: { $0.id == id })?.name ?? "this project" }
        switch action {
        case .create(let name, let root): return "Register \(name) with the discovered computer folder \(root). No repository files will be copied or changed."
        case .addFolder(let id, let root, _, let primary): return "Add \(root) to \(project(id))\(primary ? " and make it the primary folder" : "")."
        case .removeFolder(let id, let path):
            let primary = overview.registeredProjects.first(where: { $0.id == id })?.folders.first(where: { $0.path == path })?.isPrimary == true
            return "Remove \(path) from \(project(id)). The folder and its files remain on the computer.\(primary ? " Hermes will select another registered folder as primary." : "")"
        case .setPrimary(let id, let path): return "Use \(path) as the primary folder for \(project(id))."
        case .delete(let id): return "Permanently delete the \(project(id)) registration and its folder associations. Files on the computer are not deleted."
        }
    }

    private func decodeRegistered(_ value: BighelpJSONValue) throws -> [WorkspaceProject] {
        guard let object = value.object else { throw WorkspaceClientError.invalidResponse }
        return try WorkspaceManagementDecoder.projects(object)
    }

    private func decodeDiscovered(_ value: BighelpJSONValue) throws -> [HermesDiscoveredRepository] {
        guard let rows = value.object?["repos"]?.array, rows.count <= 500 else {
            throw WorkspaceClientError.invalidResponse
        }
        let result = try rows.map { raw -> HermesDiscoveredRepository in
            guard let row = raw.object, let sessions = count(row["sessions"]) else {
                throw WorkspaceClientError.invalidResponse
            }
            return .init(
                root: try hostPath(text(row["root"], maximum: 4_096)),
                label: try text(row["label"], maximum: 300),
                sessionCount: sessions,
                lastActive: date(row["last_active"])
            )
        }
        guard Set(result.map(\.root)).count == result.count else { throw WorkspaceClientError.invalidResponse }
        return result
    }

    private func decodeTree(_ value: BighelpJSONValue) throws -> [HermesProjectTreeNode] {
        guard let rows = value.object?["projects"]?.array, rows.count <= 2_000 else {
            throw WorkspaceClientError.invalidResponse
        }
        let result = try rows.map(decodeTreeRow)
        guard Set(result.map(\.id)).count == result.count else { throw WorkspaceClientError.invalidResponse }
        return result
    }

    private func decodeTreeRow(_ value: BighelpJSONValue) throws -> HermesProjectTreeNode {
        guard let row = value.object, let automatic = row["isAuto"]?.boolean,
              let home = row["isNoProject"]?.boolean, let sessions = count(row["sessionCount"]),
              let totalTokens = count(row["totalTokens"]), let totalCost = row["totalCostUsd"]?.number,
              totalCost.isFinite, totalCost >= 0,
              let repoRows = row["repos"]?.array, repoRows.count <= 500,
              let previewRows = row["previewSessions"]?.array, previewRows.count <= 20 else {
            throw WorkspaceClientError.invalidResponse
        }
        let repos = try repoRows.map(decodeRepository)
        let previews = try previewRows.map(decodeSession)
        return .init(
            id: try text(row["id"], maximum: 4_096),
            label: try text(row["label"], maximum: 300),
            path: try optionalHostPath(row["path"]),
            color: try optionalText(row["color"], maximum: 100),
            icon: try optionalText(row["icon"], maximum: 100),
            isAutomatic: automatic,
            isHome: home,
            sessionCount: sessions,
            lastActive: date(row["lastActive"]),
            totalTokens: totalTokens,
            totalCostUSD: totalCost,
            repositories: repos,
            previewSessions: previews
        )
    }

    private func decodeRepository(_ value: BighelpJSONValue) throws -> HermesProjectRepository {
        guard let row = value.object, let sessionCount = count(row["sessionCount"]),
              let laneRows = row["groups"]?.array, laneRows.count <= 500 else {
            throw WorkspaceClientError.invalidResponse
        }
        let lanes = try laneRows.map(decodeLane)
        return .init(
            id: try text(row["id"], maximum: 4_096),
            label: try text(row["label"], maximum: 300),
            path: try optionalHostPath(row["path"]),
            sessionCount: sessionCount,
            lanes: lanes
        )
    }

    private func decodeLane(_ value: BighelpJSONValue) throws -> HermesProjectLane {
        guard let row = value.object, let main = row["isMain"]?.boolean,
              let kanban = row["isKanban"]?.boolean,
              let sessionRows = row["sessions"]?.array, sessionRows.count <= 5_000 else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            id: try text(row["id"], maximum: 4_096),
            label: try text(row["label"], maximum: 300),
            path: try optionalHostPath(row["path"]),
            isMain: main,
            isKanban: kanban,
            sessions: try sessionRows.map(decodeSession)
        )
    }

    private func decodeSession(_ value: BighelpJSONValue) throws -> HermesProjectSession {
        guard let row = value.object else { throw WorkspaceClientError.invalidResponse }
        return .init(
            id: try text(row["id"], maximum: 512),
            profileID: try optionalText(row["profile"], maximum: 128) ?? "",
            title: try optionalText(row["title"], maximum: 2_000) ?? "Untitled chat",
            preview: try optionalText(row["preview"], maximum: 16_384) ?? "",
            cwd: try optionalHostPath(row["cwd"]),
            branch: try optionalText(row["git_branch"], maximum: 300),
            lastActive: date(row["last_active"] ?? row["started_at"]),
            pullRequest: nil
        )
    }

    private func attach(_ prs: [String: HermesProjectPullRequest], to tree: [HermesProjectTreeNode]) -> [HermesProjectTreeNode] {
        tree.map { attach(prs, to: $0) }
    }

    private func attach(_ prs: [String: HermesProjectPullRequest], to node: HermesProjectTreeNode) -> HermesProjectTreeNode {
        func session(_ value: HermesProjectSession) -> HermesProjectSession {
            .init(id: value.id, profileID: value.profileID, title: value.title, preview: value.preview,
                  cwd: value.cwd, branch: value.branch, lastActive: value.lastActive, pullRequest: prs[value.id])
        }
        return .init(
            id: node.id, label: node.label, path: node.path, color: node.color, icon: node.icon,
            isAutomatic: node.isAutomatic, isHome: node.isHome, sessionCount: node.sessionCount,
            lastActive: node.lastActive, totalTokens: node.totalTokens, totalCostUSD: node.totalCostUSD,
            repositories: node.repositories.map { repo in
                .init(id: repo.id, label: repo.label, path: repo.path, sessionCount: repo.sessionCount,
                      lanes: repo.lanes.map { lane in
                    .init(id: lane.id, label: lane.label, path: lane.path, isMain: lane.isMain,
                          isKanban: lane.isKanban, sessions: lane.sessions.map(session))
                })
            },
            previewSessions: node.previewSessions.map(session)
        )
    }

    private func discoveredRoot(_ raw: String, in overview: HermesProjectOverview) throws -> String {
        guard let root = overview.discoveredRepositories.first(where: { $0.root == raw })?.root else {
            throw WorkspaceClientError.conflict
        }
        return try hostPath(root)
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard owner.authority.kind == .direct, currentOwner() == owner else {
            overviews.removeAll(); prepared.removeAll()
            throw WorkspaceClientError.ownerChanged
        }
    }

    private func profile(_ value: String) throws -> String {
        try checkOwner()
        return try DirectHermesCoreRequestScope.profile(value)
    }

    private func identifier(_ value: String) throws -> String {
        try DirectHermesCoreRequestScope.identifier(value)
    }

    private func displayText(_ value: String, maximum: Int) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceClientError.invalidRequest
        }
        return value
    }

    private func text(_ value: BighelpJSONValue?, maximum: Int) throws -> String {
        guard let value = value?.string, !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkspaceClientError.invalidResponse
        }
        return value
    }

    private func optionalText(_ value: BighelpJSONValue?, maximum: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let string = value.string, string.utf8.count <= maximum,
              !string.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkspaceClientError.invalidResponse
        }
        return string
    }

    private func stringArray(_ value: BighelpJSONValue?, maximum: Int, itemMaximum: Int) throws -> [String] {
        guard let rows = value?.array, rows.count <= maximum else { throw WorkspaceClientError.invalidResponse }
        let result = try rows.map { try text($0, maximum: itemMaximum) }
        guard Set(result).count == result.count else { throw WorkspaceClientError.invalidResponse }
        return result
    }

    private func count(_ value: BighelpJSONValue?) -> Int? {
        guard let count = value?.integer, count >= 0 else { return nil }
        return count
    }

    private func positiveCount(_ value: BighelpJSONValue?) -> Int? {
        guard let count = value?.integer, count > 0 else { return nil }
        return count
    }

    private func date(_ value: BighelpJSONValue?) -> Date? {
        guard let seconds = value?.number, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func hostPath(_ value: String) throws -> String {
        let isPOSIX = value.hasPrefix("/") && !value.hasPrefix("//")
        let isDrive = value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
        let isUNC = value.hasPrefix("\\\\")
        guard value.utf8.count <= 4_096, isPOSIX || isDrive || isUNC,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains(where: { $0 == "." || $0 == ".." }) else {
            throw WorkspaceClientError.invalidResponse
        }
        return value
    }

    private func optionalHostPath(_ value: BighelpJSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        return try hostPath(try text(value, maximum: 4_096))
    }

    private func pullRequestURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host?.lowercased() == "github.com",
              url.path.range(of: #"^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*/*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return url
    }
}
