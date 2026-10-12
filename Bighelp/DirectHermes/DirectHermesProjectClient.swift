import Foundation

@MainActor
final class DirectHermesProjectClient: HermesWorkspaceCatalogClient {
    private let scope: DirectHermesCoreRequestScope
    private let resolveSession: @MainActor (String) -> WorkspaceSessionCoordinate?

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
         resolveSession: @escaping @MainActor (String) -> WorkspaceSessionCoordinate?) {
        scope = .init(workspace: workspace, owner: owner, currentOwner: currentOwner)
        self.resolveSession = resolveSession
    }

    func load(agentID: String) async throws -> HermesWorkspaceCatalog {
        try await load(agentID: agentID, sessionID: nil)
    }

    func load(agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let payload = try await scope.perform(.projectsList, ["profile": .string(profile)])
        guard let sessionID else { return try catalog(payload) }
        let coordinate = try coordinate(sessionID, profile: profile)
        let info: [String: BighelpJSONValue]
        if coordinate.runtimeSessionID != nil {
            info = try await activateLiveSession(coordinate)
        } else {
            info = try await sessionDetail(coordinate)
        }
        guard let cwd = try WorkspaceManagementDecoder.optionalText(info["cwd"], maximum: 4_096), !cwd.isEmpty else {
            guard resolveSession(sessionID) == coordinate else { throw WorkspaceClientError.ownerChanged }
            return try catalog(payload)
        }
        _ = try WorkspaceManagementDecoder.path(.string(cwd))
        let association = try await scope.perform(.projectsForCwd, ["profile": .string(profile), "cwd": .string(cwd)])
        guard association["cwd"]?.string == cwd, resolveSession(sessionID) == coordinate else {
            throw WorkspaceClientError.conflict
        }
        let associatedID: String?
        switch association["project"] {
        case .null: associatedID = nil
        case .object(let row): associatedID = try WorkspaceManagementDecoder.project(row).id
        default: throw WorkspaceClientError.invalidResponse
        }
        return try catalog(payload, sessionProjectID: associatedID)
    }

    func select(id: String, agentID: String, sessionID: String?) async throws -> HermesWorkspaceCatalog {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let id = try DirectHermesCoreRequestScope.identifier(id)
        let project = try await get(id: id, profile: profile)
        guard !project.isArchived else { throw WorkspaceClientError.conflict }
        if let sessionID {
            let coordinate = try coordinate(sessionID, profile: profile)
            let path = try primaryPath(project)
            guard let stored = coordinate.storedSessionID else { throw WorkspaceClientError.invalidRequest }
            try scope.require(.sessionWorkspaceEdit, profile: profile)
            let moved = try await scope.perform(.sessionWorkspaceMove, [
                "profile": .string(profile), "session_key": .string(stored),
                "cwd": .string(path)
            ])
            guard let movedCWD = moved["cwd"]?.string,
                  movedCWD == path,
                  (try? WorkspaceManagementDecoder.path(.string(movedCWD))) != nil,
                  resolveSession(sessionID) == coordinate else {
                throw WorkspaceClientError.outcomeUnknown
            }
            let association = try await scope.perform(.projectsForCwd, [
                "profile": .string(profile), "cwd": .string(movedCWD)
            ])
            guard association["cwd"]?.string == movedCWD,
                  resolveSession(sessionID) == coordinate,
                  let associationProject = association["project"]?.object,
                  let associatedID = try? WorkspaceManagementDecoder.project(associationProject).id,
                  associatedID == id else {
                throw WorkspaceClientError.outcomeUnknown
            }
            let refreshed = try await scope.perform(.projectsList, ["profile": .string(profile)])
            guard resolveSession(sessionID) == coordinate else { throw WorkspaceClientError.outcomeUnknown }
            return try catalog(refreshed, sessionProjectID: id)
        }
        try scope.require(.projectsEdit, profile: profile)
        let selected = try await scope.perform(.projectsSetActive, ["profile": .string(profile), "id": .string(id)])
        guard selected["active_id"]?.string == id else { throw WorkspaceClientError.outcomeUnknown }
        let result = try await load(agentID: profile)
        guard result.activeWorkspaceID == id else { throw WorkspaceClientError.outcomeUnknown }
        return result
    }

    func selectedFolderPath(agentID: String) async throws -> String? {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let catalog = try await load(agentID: profile)
        guard let id = catalog.activeWorkspaceID else { return nil }
        let project: WorkspaceProject
        do { project = try await get(id: id, profile: profile) }
        catch WorkspaceClientError.rejected(code: "project_not_found", _) {
            try scope.check()
            return nil
        }
        // Archiving does not clear the stock host's active-project pointer.
        // A read racing with archival supplies no explicit cwd override.
        guard !project.isArchived else { return nil }
        return try primaryPath(project)
    }

    func create(name: String, folderPath: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try WorkspaceManagementDecoder.text(.string(name), maximum: 160)
        let path = try WorkspaceManagementDecoder.path(.string(folderPath))
        try scope.require(.projectsEdit, profile: profile)
        let result = try await scope.perform(.projectsCreate, [
            "profile": .string(profile), "name": .string(name),
            "folders": .array([.string(path)]), "primary_path": .string(path), "use": .boolean(true)
        ])
        guard let row = result["project"]?.object else { throw WorkspaceClientError.outcomeUnknown }
        let project = try WorkspaceManagementDecoder.project(row)
        guard project.name == name, !project.isArchived, try primaryPath(project) == path else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let refreshed = try await load(agentID: profile)
        guard refreshed.activeWorkspaceID == project.id else { throw WorkspaceClientError.outcomeUnknown }
        return refreshed
    }

    func archive(id: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let id = try DirectHermesCoreRequestScope.identifier(id)
        try scope.require(.projectsEdit, profile: profile)
        let payload = try await scope.perform(.projectsArchive, [
            "profile": .string(profile), "id": .string(id), "restore": .boolean(false)
        ])
        let projects = try WorkspaceManagementDecoder.projects(payload)
        guard projects.first(where: { $0.id == id })?.isArchived == true else { throw WorkspaceClientError.outcomeUnknown }
        return try catalog(payload)
    }

    func folderSuggestions(parentPath: String, prefix: String, offset: Int, limit: Int,
                           agentID: String) async throws -> HermesWorkspaceFolderPage {
        try scope.check()
        _ = try DirectHermesCoreRequestScope.profile(agentID)
        guard let direct = scope.workspace as? DirectHermesWorkspaceClient else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let response = try await direct.listFolder(path: parentPath, owner: scope.owner)
        try scope.check()
        return try HermesFolderListing.page(response, requestedPath: parentPath, prefix: prefix,
                                            offset: offset, limit: limit)
    }

    private func coordinate(_ visibleID: String, profile: String) throws -> WorkspaceSessionCoordinate {
        try scope.check()
        guard let coordinate = resolveSession(visibleID), coordinate.owner == scope.owner,
              DirectHermesSessionValidation.same(coordinate.profileID, profile),
              coordinate.storedSessionID != nil || coordinate.runtimeSessionID != nil else {
            throw WorkspaceClientError.unavailable(.identityContextUnavailable)
        }
        if let stored = coordinate.storedSessionID {
            _ = try DirectHermesCoreRequestScope.identifier(stored, maximum: 512)
        }
        if let runtime = coordinate.runtimeSessionID {
            _ = try DirectHermesCoreRequestScope.identifier(runtime, maximum: 512)
        }
        return coordinate
    }

    private func activateLiveSession(_ coordinate: WorkspaceSessionCoordinate) async throws -> [String: BighelpJSONValue] {
        guard let runtime = coordinate.runtimeSessionID else { throw WorkspaceClientError.invalidRequest }
        let response = try await scope.perform(.sessionActivate, [
            "profile": .string(coordinate.profileID), "session_id": .string(runtime),
            "omit_messages": .boolean(true)
        ])
        let returnedRuntime = try DirectHermesSessionValidation.string(response["session_id"])
        guard DirectHermesSessionValidation.same(returnedRuntime, runtime) else {
            throw WorkspaceClientError.invalidResponse
        }

        let stored: String
        if let value = response["session_key"] ?? response["stored_session_id"] ?? response["resumed"] {
            stored = try DirectHermesSessionValidation.string(value)
        } else {
            throw WorkspaceClientError.invalidResponse
        }
        for key in ["session_key", "stored_session_id", "resumed"] {
            if let value = response[key] {
                let returned = try DirectHermesSessionValidation.string(value)
                guard DirectHermesSessionValidation.same(returned, stored) else {
                    throw WorkspaceClientError.invalidResponse
                }
            }
        }
        if let expectedStored = coordinate.storedSessionID,
           !DirectHermesSessionValidation.same(expectedStored, stored) {
            throw WorkspaceClientError.invalidResponse
        }

        guard let info = response["info"]?.object else { throw WorkspaceClientError.invalidResponse }
        if let returnedProfile = info["profile_name"] {
            let profile = try DirectHermesSessionValidation.string(returnedProfile, maximum: 128)
            guard DirectHermesSessionValidation.same(profile, coordinate.profileID) else {
                throw WorkspaceClientError.invalidResponse
            }
        } else {
            // With no profile echo, only an already-attached runtime/stored pair
            // can establish the profile scope, matching SessionCatalog's binding rule.
            guard coordinate.storedSessionID != nil else { throw WorkspaceClientError.invalidResponse }
        }
        return info
    }

    private func sessionDetail(_ coordinate: WorkspaceSessionCoordinate) async throws -> [String: BighelpJSONValue] {
        guard let stored = coordinate.storedSessionID else { throw WorkspaceClientError.invalidRequest }
        let result = try await scope.perform(.sessionDetail, [
            "profile": .string(coordinate.profileID), "session_id": .string(stored)
        ])
        guard let returnedID = result["id"]?.string,
              DirectHermesSessionValidation.same(returnedID, stored),
              let returnedProfile = result["profile"]?.string,
              DirectHermesSessionValidation.same(returnedProfile, coordinate.profileID) else {
            throw WorkspaceClientError.invalidResponse
        }
        return result
    }

    func describe(id: String, description: String, agentID: String) async throws -> HermesWorkspaceCatalog {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let id = try DirectHermesCoreRequestScope.identifier(id)
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try WorkspaceManagementDecoder.text(.string(text), maximum: 500)
        try scope.require(.projectsEdit, profile: profile)
        _ = try await scope.perform(.projectsUpdate, [
            "profile": .string(profile), "id": .string(id), "description": .string(text)
        ])
        return try await load(agentID: profile)
    }

    private func get(id: String, profile: String) async throws -> WorkspaceProject {
        let result = try await scope.perform(.projectsGet, ["profile": .string(profile), "id": .string(id)])
        guard let row = result["project"]?.object else { throw WorkspaceClientError.invalidResponse }
        let project = try WorkspaceManagementDecoder.project(row)
        guard project.id == id else { throw WorkspaceClientError.invalidResponse }
        return project
    }

    private func primaryPath(_ project: WorkspaceProject) throws -> String {
        let primary = project.folders.filter(\.isPrimary)
        guard primary.count == 1 else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        return try WorkspaceManagementDecoder.path(.string(primary[0].path))
    }

    private func catalog(_ payload: [String: BighelpJSONValue], sessionProjectID: String? = nil) throws -> HermesWorkspaceCatalog {
        let projects = try WorkspaceManagementDecoder.projects(payload).filter { !$0.isArchived }
        let selectedID: String?
        switch payload["active_id"] {
        case .null: selectedID = nil
        case .string(let id): selectedID = try DirectHermesCoreRequestScope.identifier(id)
        default: throw WorkspaceClientError.invalidResponse
        }
        // Stock archive/delete deliberately leaves active_id in project_meta.
        // Ignore that stale selection locally; never mutate it or substitute
        // another project's cwd merely to create an ordinary conversation.
        let activeID = projects.contains(where: { $0.id == selectedID }) ? selectedID : nil
        guard sessionProjectID == nil || projects.contains(where: { $0.id == sessionProjectID }) else {
            throw WorkspaceClientError.conflict
        }
        return .init(activeWorkspaceID: activeID, sessionWorkspaceID: sessionProjectID,
            workspaces: projects.map {
                .init(id: $0.id, name: $0.name, description: $0.summary, folderCount: $0.folders.count, isActive: $0.id == activeID)
            })
    }
}
