import Foundation

/// Lives within one verified workspace authority, across socket generations.
/// Hermes does not publish revisions for SOUL/avatar bytes, so these details
/// have a bounded freshness window; metadata is checked on each sync.
@MainActor
final class DirectHermesAgentReadCache {
    var entries: [String: (snapshot: DirectHermesAgentProfileSnapshot, fetchedAt: Date)] = [:]
    let now: () -> Date
    init(now: @escaping () -> Date = { .now }) { self.now = now }
    func clear() { entries.removeAll() }
}


@MainActor
final class DirectHermesAgentDirectoryClient: AgentDirectoryClient, AgentListPlacementWriting {
    private let readCache: DirectHermesAgentReadCache
    private let service: DirectHermesAgentProfileService
    private var baselines: [String: DirectHermesAgentProfileSnapshot] = [:]
    private var isMutating = false
    /// Any transport failure after dispatch leaves the create outcome unknown.
    /// No further create is admitted until an authoritative profile list has
    /// reconciled this exact destination.
    private var uncertainCreationID: String?

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
         readCache: DirectHermesAgentReadCache = DirectHermesAgentReadCache()) {
        self.readCache = readCache
        service = DirectHermesAgentProfileService(workspace: workspace, owner: owner, currentOwner: currentOwner)
    }

    func list() async throws -> [AgentProfile] {
        let rows = try await service.rows()
        let now = readCache.now()
        let cached = readCache.entries
        let snapshots = try await loadAgentDetails(rows) { [service] row in
            if let entry = cached[row.id], entry.snapshot.row == row,
               now.timeIntervalSince(entry.fetchedAt) >= 0, now.timeIntervalSince(entry.fetchedAt) < 60 {
                return entry.snapshot
            }
            return try await service.snapshot(row: row)
        }
        try service.requireOwner()
        readCache.entries = Dictionary(uniqueKeysWithValues: snapshots.map { snapshot in
            let previous = cached[snapshot.row.id]
            let reused = previous?.snapshot == snapshot && now.timeIntervalSince(previous!.fetchedAt) < 60
            return (snapshot.row.id, (snapshot, reused ? previous!.fetchedAt : now))
        })
        baselines = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.profile.id, $0) })
        uncertainCreationID = nil
        return snapshots.map(\.profile)
    }

    /// Writes the section and hidden keys with Hermes' per-key revision check.
    /// When another device changed the agent meanwhile, it reads again and
    /// tries once more, keeping that device's other settings.
    func setPlacement(_ placement: AgentListPlacement, profileID: String) async throws {
        _ = try DirectHermesAgentProfileService.profileIdentifier(profileID)
        for attempt in 0..<2 {
            guard let row = try await service.rows().first(where: { $0.id == profileID }) else {
                throw WorkspaceClientError.rejected(code: "profile_unavailable")
            }
            guard let revision = row.namespaceRevision else { throw WorkspaceClientError.unavailable(.unsupportedHost) }
            let namespace = placement.applied(to: row.namespace)
            guard namespace != row.namespace else { return }
            guard try JSONEncoder().encode(BighelpJSONValue.object(namespace)).count <= 65_536 else {
                throw WorkspaceClientError.capacityExceeded
            }
            let response = try await service.request(.profilesConfigure, [
                "name": .string(profileID),
                "ui_meta": .object(["hermes-bots": .object(namespace)]),
                "ui_meta_expected_revisions": .object(["hermes-bots": .integer(revision)]),
            ], capability: .profilesEdit, profileID: profileID)
            guard let applied = response["applied"]?.object else { throw WorkspaceClientError.invalidResponse }
            readCache.clear()
            if applied["ui_meta"]?.boolean == true { return }
            guard applied["ui_meta_conflicts"] != nil, attempt == 0 else { break }
        }
        throw WorkspaceClientError.conflict
    }

    func canonicalSession(profileID: String) throws -> DirectHermesCanonicalAgentSession? {
        try service.requireOwner()
        return baselines[profileID]?.row.canonicalSession
    }

    func resetForAccountBoundary() {
        service.invalidate()
        baselines.removeAll()
        readCache.clear()
        uncertainCreationID = nil
    }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        readCache.clear()
        let draft = try DirectHermesAgentProfileService.validatedDraft(draft)
        guard !isMutating, !draft.isDefault,
              !(draft.cloneSourceProfileID != nil && draft.skipBundledSkills) else {
            throw WorkspaceClientError.invalidRequest
        }
        guard uncertainCreationID == nil else { throw WorkspaceClientError.outcomeUnknown }
        try service.requireCapability(.profilesCreate)
        try service.requireCapability(.profilesEdit)
        isMutating = true
        defer { isMutating = false }
        let rows = try await service.rows()
        guard rows.count < DirectHermesAgentProfileService.maximumProfiles else {
            throw WorkspaceClientError.capacityExceeded
        }
        let id = AgentProfileID.generated(from: draft.name, occupied: Set(rows.map(\.id)))
        var request: [String: BighelpJSONValue] = [
            "name": .string(id), "description": .string(draft.role),
            "no_alias": .boolean(true), "mirror_credentials": .boolean(false),
            "no_skills": .boolean(draft.skipBundledSkills)
        ]
        if let source = draft.cloneSourceProfileID {
            guard source != id,
                  rows.contains(where: { $0.id == source }) else {
                throw WorkspaceClientError.invalidRequest
            }
            try service.requireCapability(.profilesClone, profileID: source)
            request["clone_from"] = .string(source)
            request["clone_all"] = .boolean(false)
        }
        let receipt: [String: BighelpJSONValue]
        do {
            receipt = try await service.request(
                draft.cloneSourceProfileID == nil ? .profilesCreate : .profilesClone,
                request,
                capability: draft.cloneSourceProfileID == nil ? .profilesCreate : .profilesClone,
                profileID: draft.cloneSourceProfileID
            )
        } catch {
            try service.requireOwner()
            uncertainCreationID = id
            throw WorkspaceClientError.outcomeUnknown
        }
        guard receipt["ok"]?.boolean == true, receipt["name"]?.string == id,
              let mirrored = receipt["mirrored"]?.object,
              ["env", "auth", "model_inherited", "voice"].allSatisfy({ mirrored[$0]?.boolean == false }) else {
            uncertainCreationID = id
            throw WorkspaceClientError.outcomeUnknown
        }
        if draft.cloneSourceProfileID != nil { await service.sharePlugins(profileID: id) }
        let initial: DirectHermesAgentProfileSnapshot
        do {
            initial = try await service.snapshot(id: id)
        } catch {
            try service.requireOwner()
            uncertainCreationID = id
            throw WorkspaceClientError.outcomeUnknown
        }
        baselines[id] = initial
        return try await apply(draft, baseline: initial)
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        _ = try DirectHermesAgentProfileService.profileIdentifier(id)
        readCache.clear()
        let draft = try DirectHermesAgentProfileService.validatedDraft(draft)
        guard !isMutating else { throw WorkspaceClientError.invalidRequest }
        guard let baseline = baselines[id] else { throw WorkspaceClientError.conflict }
        isMutating = true
        defer { isMutating = false }
        return try await apply(draft, baseline: baseline)
    }

    private func apply(_ draft: AgentDraft, baseline: DirectHermesAgentProfileSnapshot) async throws -> AgentProfile {
        let id = baseline.profile.id
        var current = try await service.snapshot(id: id)
        guard draft.isDefault == current.profile.isDefault else { throw WorkspaceClientError.invalidRequest }
        var pending = Self.changedFields(draft, comparedTo: baseline.profile)
        if pending.contains(.role), baseline.row.namespace["description"] == nil {
            pending.insert(.summary)
        }
        for field in pending where !Self.same(field, current.profile, baseline.profile) {
            throw WorkspaceClientError.conflict
        }
        guard !pending.isEmpty else {
            baselines[id] = current
            return current.profile
        }
        let metadataFields = pending.intersection([.name, .role, .summary])
        var request: [String: BighelpJSONValue] = ["name": .string(id)]
        if !metadataFields.intersection([.name, .summary]).isEmpty {
            guard let revision = current.row.namespaceRevision else {
                throw WorkspaceClientError.unavailable(.unsupportedHost)
            }
            var namespace = current.row.namespace
            if pending.contains(.name) { namespace["title"] = .string(draft.name) }
            if pending.contains(.summary) { namespace["description"] = .string(draft.summary) }
            guard try JSONEncoder().encode(BighelpJSONValue.object(namespace)).count <= 65_536 else {
                throw WorkspaceClientError.capacityExceeded
            }
            request["ui_meta"] = .object(["hermes-bots": .object(namespace)])
            request["ui_meta_expected_revisions"] = .object(["hermes-bots": .integer(revision)])
        }
        if pending.contains(.role) { request["description"] = .string(draft.role) }

        do {
            if !metadataFields.isEmpty {
                let response = try await service.request(.profilesConfigure, request, capability: .profilesEdit, profileID: id)
                guard let applied = response["applied"]?.object else { throw WorkspaceClientError.invalidResponse }
                current = try await service.snapshot(id: id)
                for field in metadataFields {
                    let flag = field == .role ? "description" : "ui_meta"
                    if applied[flag]?.boolean == true && Self.matches(field, draft: draft, profile: current.profile) {
                        pending.remove(field)
                    }
                }
                if !pending.intersection(metadataFields).isEmpty {
                    throw AgentDirectoryPartialMutationError(committedProfile: current.profile, unappliedFields: pending)
                }
            }
            if pending.contains(.instructions) {
                try await service.writeSoul(draft.instructions, profileID: id)
                current = try await service.snapshot(id: id)
                guard current.profile.instructions == draft.instructions else { throw WorkspaceClientError.conflict }
                pending.remove(.instructions)
            }
            if pending.contains(.avatar) {
                try await service.writeAvatar(draft.removesAvatar ? nil : draft.avatar, profileID: id)
                // The picture is what every app shows; the look only tells Hermes
                // Desktop how to draw it, so a host that can't take it keeps the picture.
                if !draft.removesAvatar, let look = draft.look { try? await writeLook(look, profileID: id) }
                try service.requireOwner()
                current = try await service.snapshot(id: id)
                pending.remove(.avatar)
            }
        } catch let partial as AgentDirectoryPartialMutationError {
            baselines[id] = current
            throw partial
        } catch {
            try service.requireOwner()
            baselines[id] = current
            throw AgentDirectoryPartialMutationError(
                committedProfile: current.profile, unappliedFields: pending, isOutcomeUncertain: true
            )
        }
        baselines[id] = current
        var profile = current.profile
        if profile.avatar == draft.avatar, !draft.removesAvatar { profile.avatarFileName = draft.avatarFileName }
        return profile
    }

    func petGallery() async throws -> [PetdexPet] {
        PetdexPolicy.pets(fromHost: try await service.request(.petGallery, [:], capability: .profilesRead))
    }

    func petThumbnail(_ pet: PetdexPet) async throws -> Data {
        var payload: [String: BighelpJSONValue] = ["slug": .string(pet.slug)]
        if let url = pet.spritesheetURL { payload["url"] = .string(url.absoluteString) }
        let response = try await service.request(.petThumb, payload, capability: .profilesRead)
        guard response["ok"]?.boolean == true, let uri = response["dataUri"]?.string else { throw PetdexError.unsupported }
        return try PetdexSprite.thumbnail(fromDataURI: uri)
    }

    /// Records the look in Bot Mode's metadata so Hermes Desktop draws the same
    /// face. A host without metadata revisions skips this, and a stale revision
    /// gets one fresh retry.
    private func writeLook(_ look: AgentAvatarLook, profileID: String) async throws {
        for _ in 0..<2 {
            guard let row = try await service.rows().first(where: { $0.id == profileID }),
                  let revision = row.namespaceRevision else { return }
            let namespace = look.applied(to: row.namespace, profileID: profileID)
            guard namespace != row.namespace else { return }
            guard try JSONEncoder().encode(BighelpJSONValue.object(namespace)).count <= 65_536 else { return }
            let response = try await service.request(.profilesConfigure, [
                "name": .string(profileID),
                "ui_meta": .object(["hermes-bots": .object(namespace)]),
                "ui_meta_expected_revisions": .object(["hermes-bots": .integer(revision)])
            ], capability: .profilesEdit, profileID: profileID)
            let applied = response["applied"]?.object
            if applied?["ui_meta"]?.boolean == true { return }
            guard applied?["ui_meta_conflicts"] != nil else { return }
        }
    }

    private static func changedFields(_ draft: AgentDraft, comparedTo profile: AgentProfile) -> Set<AgentDirectoryPartialMutationError.Field> {
        Set(AgentDirectoryPartialMutationError.Field.allCases.filter { !matches($0, draft: draft, profile: profile) })
    }

    private static func matches(_ field: AgentDirectoryPartialMutationError.Field, draft: AgentDraft, profile: AgentProfile) -> Bool {
        switch field {
        case .name: draft.name == profile.name
        case .role: draft.role == profile.role
        case .summary: draft.summary == profile.summary
        case .instructions: draft.instructions == profile.instructions
        case .avatar: (draft.removesAvatar ? nil : draft.avatar) == profile.avatar
        }
    }

    private static func same(_ field: AgentDirectoryPartialMutationError.Field, _ lhs: AgentProfile, _ rhs: AgentProfile) -> Bool {
        switch field {
        case .name: lhs.name == rhs.name
        case .role: lhs.role == rhs.role
        case .summary: lhs.summary == rhs.summary
        case .instructions: lhs.instructions == rhs.instructions
        case .avatar: lhs.avatar == rhs.avatar
        }
    }


}
