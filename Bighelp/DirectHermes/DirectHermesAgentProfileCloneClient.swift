import Foundation

@MainActor
final class DirectHermesAgentProfileCloneClient: AgentProfileCloneClient {
    private struct Preparation {
        let plan: AgentProfileClonePlan
        let source: AgentProfile
        let expiresAt: Date
    }

    private let service: DirectHermesAgentProfileService
    private let now: @MainActor () -> Date
    private var preparation: Preparation?
    private var isCloning = false

    init(
        workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        now: @escaping @MainActor () -> Date = { Date.now }
    ) {
        service = DirectHermesAgentProfileService(workspace: workspace, owner: owner, currentOwner: currentOwner)
        self.now = now
    }

    func prepareClone(sourceProfileID: String, destinationProfileID: String, owner: WorkspaceOwner) async throws -> AgentProfileClonePlan {
        _ = try DirectHermesAgentProfileService.profileIdentifier(sourceProfileID)
        _ = try DirectHermesAgentProfileService.profileIdentifier(destinationProfileID)
        guard owner == service.owner, !isCloning, sourceProfileID != destinationProfileID else {
            throw WorkspaceClientError.invalidRequest
        }
        try service.requireCapability(.profilesClone, profileID: sourceProfileID)
        try service.requireCapability(.profilesEdit, profileID: destinationProfileID)
        let rows = try await service.rows()
        guard rows.count < DirectHermesAgentProfileService.maximumProfiles else {
            throw WorkspaceClientError.capacityExceeded
        }
        guard let source = rows.first(where: { $0.id == sourceProfileID }),
              !rows.contains(where: { $0.id == destinationProfileID }) else {
            throw WorkspaceClientError.conflict
        }
        let snapshot = try await service.snapshot(row: source)
        let plan = AgentProfileClonePlan(
            id: UUID(), owner: owner, sourceProfileID: sourceProfileID,
            destinationProfileID: destinationProfileID,
            includesCredentials: true, includesMemory: true, includesHistory: false,
            includesSkills: true, includesAvatar: snapshot.profile.avatar != nil
        )
        preparation = Preparation(plan: plan, source: snapshot.profile, expiresAt: now().addingTimeInterval(300))
        return plan
    }

    func clone(_ reviewedPlan: AgentProfileClonePlan) async throws -> WorkspaceMutationOutcome<AgentProfileMutationReceipt> {
        try service.requireOwner()
        guard !isCloning, let prepared = preparation, prepared.plan == reviewedPlan,
              prepared.expiresAt > now() else { throw WorkspaceClientError.conflict }
        preparation = nil
        isCloning = true
        defer { isCloning = false }
        let currentSource = try await service.snapshot(id: reviewedPlan.sourceProfileID)
        guard currentSource.profile == prepared.source else { throw WorkspaceClientError.conflict }
        let destination = reviewedPlan.destinationProfileID
        let rows = try await service.rows()
        guard rows.count < DirectHermesAgentProfileService.maximumProfiles else {
            throw WorkspaceClientError.capacityExceeded
        }
        guard !rows.contains(where: { $0.id == destination }) else {
            throw WorkspaceClientError.conflict
        }
        let response: [String: BighelpJSONValue]
        do {
            response = try await service.request(.profilesClone, [
                "name": .string(destination), "clone_from": .string(reviewedPlan.sourceProfileID),
                "clone_all": .boolean(false), "no_alias": .boolean(true),
                "mirror_credentials": .boolean(false), "description": .string(prepared.source.role)
            ], capability: .profilesClone, profileID: reviewedPlan.sourceProfileID)
        } catch {
            try service.requireOwner()
            return .unconfirmed
        }
        guard response["ok"]?.boolean == true, response["name"]?.string == destination else { return .unconfirmed }
        await service.sharePlugins(profileID: destination)
        let receipt = AgentProfileMutationReceipt(profileID: destination)
        var incomplete: Set<String> = []
        if let mirrored = response["mirrored"]?.object {
            if ["env", "auth", "model_inherited", "voice"].contains(where: { mirrored[$0]?.boolean != false }) {
                incomplete.insert("credential policy")
            }
        } else {
            incomplete.insert("credential policy")
        }
        do {
            let created = try await service.snapshot(id: destination)
            guard !created.profile.isDefault else { return .partial(value: receipt, unappliedFields: ["profile identity"]) }
            if created.profile.instructions != prepared.source.instructions { incomplete.insert("instructions") }
            guard let revision = created.row.namespaceRevision else {
                return .partial(value: receipt, unappliedFields: ["display settings"])
            }
            var namespace = created.row.namespace
            namespace["title"] = .string(destination)
            namespace["description"] = .string(prepared.source.summary)
            let configured = try await service.request(.profilesConfigure, [
                "name": .string(destination),
                "ui_meta": .object(["hermes-bots": .object(namespace)]),
                "ui_meta_expected_revisions": .object(["hermes-bots": .integer(revision)])
            ], capability: .profilesEdit, profileID: destination)
            if configured["applied"]?.object?["ui_meta"]?.boolean != true { incomplete.insert("display settings") }
            if reviewedPlan.includesAvatar {
                try await service.writeAvatar(prepared.source.avatar, profileID: destination)
            }
            let verified = try await service.snapshot(id: destination)
            if verified.profile.name != destination || verified.profile.summary != prepared.source.summary
                || verified.profile.role != prepared.source.role {
                incomplete.insert("display settings")
            }
            if verified.profile.instructions != prepared.source.instructions { incomplete.insert("instructions") }
            if verified.profile.avatar != prepared.source.avatar { incomplete.insert("avatar") }
        } catch {
            try service.requireOwner()
            return .partial(value: receipt, unappliedFields: ["unconfirmed follow-up settings"])
        }
        return incomplete.isEmpty ? .committed(receipt) : .partial(value: receipt, unappliedFields: incomplete.sorted())
    }
}
