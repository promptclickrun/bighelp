import Foundation

/// Native plugin reads use the existing content-derived Git tokens. They are
/// optimistic pre/post checks, not immutable filesystem or project-session leases.
@MainActor
final class DirectHermesProjectGitClient: ProjectGitClient {
    private struct Target: Equatable {
        let visibleSessionID: String
        let coordinate: WorkspaceSessionCoordinate
        let workspaceID: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.visibleSessionID.utf8.elementsEqual(rhs.visibleSessionID.utf8)
                && lhs.workspaceID.utf8.elementsEqual(rhs.workspaceID.utf8)
                && lhs.coordinate.owner == rhs.coordinate.owner
                && lhs.coordinate.profileID.utf8.elementsEqual(rhs.coordinate.profileID.utf8)
                && lhs.coordinate.sessionID.utf8.elementsEqual(rhs.coordinate.sessionID.utf8)
                && lhs.coordinate.storedSessionID.map({ Data($0.utf8) }) == rhs.coordinate.storedSessionID.map({ Data($0.utf8) })
                && lhs.coordinate.runtimeSessionID.map({ Data($0.utf8) }) == rhs.coordinate.runtimeSessionID.map({ Data($0.utf8) })
        }
    }

    private struct Observation {
        let target: Target
        let status: ProjectGitStatus
    }

    private let scope: DirectHermesCoreRequestScope
    private let resolveSession: @MainActor (String) -> WorkspaceSessionCoordinate?
    private var observations: [Observation] = []

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
         resolveSession: @escaping @MainActor (String) -> WorkspaceSessionCoordinate?) {
        scope = .init(workspace: workspace, owner: owner, currentOwner: currentOwner)
        self.resolveSession = resolveSession
    }

    func capabilities(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitCapabilities {
        let target = try target(agentID: agentID, sessionID: sessionID, workspaceID: workspaceID)
        let value = try await request(.projectsGitCapabilities, target: target)
        let capabilities = try BighelpLinkProjectGitClient.decodeCapabilities(value)
        let flags = capabilities.capabilities
        guard flags.status, !flags.stage, !flags.commit, !flags.fetch, !flags.pull, !flags.push, !flags.arbitraryCommand,
              capabilities.workspaces.count == 1, let workspace = capabilities.workspaces.first,
              workspace.workspaceID.utf8.elementsEqual(workspaceID.utf8),
              workspace.operations == [.status], !workspace.mutationsEnabled,
              workspace.remotes.isEmpty, workspace.branches.isEmpty else {
            throw WorkspaceClientError.invalidResponse
        }
        return capabilities
    }

    func status(agentID: String, sessionID: String, workspaceID: String) async throws -> ProjectGitStatus {
        let target = try target(agentID: agentID, sessionID: sessionID, workspaceID: workspaceID)
        let value = try await request(.projectsGitStatus, target: target)
        let status = try BighelpLinkProjectGitClient.decodeStatus(value)
        guard status.workspaceID.utf8.elementsEqual(workspaceID.utf8) else { throw WorkspaceClientError.invalidResponse }
        guard status.filesPage.isComplete, status.conflictsPage.isComplete,
              status.filesPage.offset == 0, status.conflictsPage.offset == 0,
              status.filesPage.nextOffset == nil, status.conflictsPage.nextOffset == nil else {
            throw WorkspaceClientError.capacityExceeded
        }
        try validateToken(status.statusToken)
        for file in status.files {
            try validatePath(file.path)
            if let original = file.originalPath { try validatePath(original) }
        }
        guard status.staged.files <= status.changes.files,
              status.conflicts.allSatisfy({ path in
                  status.files.contains { $0.kind == .unmerged && $0.path.utf8.elementsEqual(path.utf8) }
              }) else { throw WorkspaceClientError.invalidResponse }
        observations.removeAll { $0.target == target }
        observations.append(.init(target: target, status: status))
        if observations.count > 8 { observations.removeFirst(observations.count - 8) }
        return status
    }

    func diff(agentID: String, sessionID: String, workspaceID: String, path: String,
              side: ProjectGitDiffSide, statusToken: String, offset: Int, limit: Int) async throws -> ProjectGitDiffPage {
        let target = try target(agentID: agentID, sessionID: sessionID, workspaceID: workspaceID)
        try validatePath(path)
        try validateToken(statusToken)
        guard (0...100_000).contains(offset), (1...500).contains(limit) else { throw WorkspaceClientError.invalidRequest }
        let observation = try observation(target, token: statusToken)
        guard let file = observation.status.files.first(where: { $0.path.utf8.elementsEqual(path.utf8) }),
              file.availableDiffSides.contains(side) else { throw WorkspaceClientError.invalidRequest }
        guard file.kind != .unmerged else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let value = try await request(.projectsGitDiff, target: target, fields: [
            "path": .string(path), "side": .string(side.rawValue), "statusToken": .string(statusToken),
            "offset": .integer(offset), "limit": .integer(limit)
        ])
        _ = try self.observation(target, token: statusToken)
        let page = try BighelpLinkProjectGitClient.decodeDiffPage(value)
        guard page.path.utf8.elementsEqual(path.utf8), page.side == side, page.offset == offset,
              page.lines.count <= limit, page.lines.count <= 100_000 - offset else {
            throw WorkspaceClientError.invalidResponse
        }
        guard !page.lines.contains(where: { $0.kind == .hunk && $0.content.hasPrefix("@@@") }) else {
            throw WorkspaceClientError.rejected(code: "diff_unsupported")
        }
        if let next = page.nextOffset {
            guard !page.lines.isEmpty, next > offset, next == offset + page.lines.count else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        guard page.availability == .available || page.previewContent == nil else {
            throw WorkspaceClientError.invalidResponse
        }
        if let preview = page.previewContent {
            guard offset == 0, preview.utf8.count <= 65_536,
                  ["md", "markdown", "txt"].contains((path as NSString).pathExtension.lowercased()) else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        return page
    }

    func prepare(_ request: ProjectGitMutationRequest) async throws -> ProjectGitPreparedOperation {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }

    func execute(_ request: ProjectGitExecutionRequest) async throws -> ProjectGitExecutionResult {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }

    private func target(agentID: String, sessionID: String, workspaceID: String) throws -> Target {
        try scope.check()
        guard scope.owner.authority.kind == .direct else { throw WorkspaceClientError.authenticationRequired }
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        try validateCoordinate(profile, maximum: 64)
        try validateCoordinate(workspaceID, maximum: 80)
        guard let coordinate = resolveSession(sessionID), coordinate.owner == scope.owner,
              coordinate.profileID.utf8.elementsEqual(profile.utf8),
              coordinate.sessionID.utf8.elementsEqual(sessionID.utf8),
              let stored = coordinate.storedSessionID else {
            throw WorkspaceClientError.unavailable(.identityContextUnavailable)
        }
        try validateCoordinate(stored, maximum: 128)
        return Target(visibleSessionID: sessionID, coordinate: coordinate, workspaceID: workspaceID)
    }

    private func check(_ target: Target) throws {
        try scope.check()
        guard let current = resolveSession(target.visibleSessionID),
              Target(visibleSessionID: target.visibleSessionID, coordinate: current, workspaceID: target.workspaceID) == target else {
            observations.removeAll()
            throw WorkspaceClientError.ownerChanged
        }
    }

    private func request(_ operation: WorkspaceOperation, target: Target,
                         fields: [String: BighelpJSONValue] = [:]) async throws -> [String: BighelpJSONValue] {
        try check(target)
        guard let stored = target.coordinate.storedSessionID else { throw WorkspaceClientError.invalidRequest }
        var payload = fields
        payload["agentId"] = .string(target.coordinate.profileID)
        payload["sessionId"] = .string(stored)
        payload["workspaceId"] = .string(target.workspaceID)
        do {
            let value = try await scope.perform(operation, payload)
            try check(target)
            guard try JSONEncoder().encode(value).count <= 196_608 else { throw WorkspaceClientError.capacityExceeded }
            return value
        } catch {
            try check(target)
            observations.removeAll { $0.target == target }
            if case WorkspaceClientError.rejected(let code, _) = error {
                if code == "status_changed" {
                    throw Self.statusChanged
                }
                if code == "project_not_repository" {
                    throw BighelpLinkWorkspaceClientError.remote(status: .failed, code: code, message: nil)
                }
            }
            throw error
        }
    }

    private func observation(_ target: Target, token: String) throws -> Observation {
        guard let observation = observations.first(where: { $0.target == target }),
              observation.status.statusToken == token else { throw Self.statusChanged }
        return observation
    }

    private static var statusChanged: BighelpLinkWorkspaceClientError {
        .remote(status: .conflict, code: "status_changed", message: nil)
    }

    private func validateToken(_ token: String) throws {
        guard token.utf8.count == 71, token.hasPrefix("sha256:"),
              token.dropFirst(7).allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else {
            throw WorkspaceClientError.invalidRequest
        }
    }

    private func validateCoordinate(_ value: String, maximum: Int) throws {
        guard let first = value.first, value.utf8.count <= maximum,
              first.isASCII, first.isLetter || first.isNumber,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }) else {
            throw WorkspaceClientError.invalidRequest
        }
    }

    private func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4_096,
              !path.hasPrefix("/"), !path.hasPrefix("-"), !path.contains("\\"),
              !path.contains(where: { ":*?[]".contains($0) }),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceClientError.invalidRequest
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw WorkspaceClientError.invalidRequest }
    }
}
