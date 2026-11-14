import CryptoKit
import Foundation

struct HermesProfileLifecycleItem: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let descriptionIsAutomatic: Bool
    let isDefaultProfile: Bool
    let providerID: String?
    let modelID: String?
    let skillCount: Int
    let hasEnvironment: Bool
    let hasAlias: Bool
    let gatewayRunning: Bool
    let distributionName: String?
    let distributionVersion: String?
    let distributionSource: String?
}

struct HermesActiveProfileSnapshot: Equatable, Sendable {
    /// Sticky default used by subsequent Hermes commands and gateways.
    let activeProfileID: String
    /// Profile serving the selected connection. Lifecycle code must not retarget it.
    let currentProfileID: String
}

struct HermesProfileLifecycleCatalog: Equatable, Sendable {
    let selectedProfileID: String
    let profiles: [HermesProfileLifecycleItem]
    let active: HermesActiveProfileSnapshot
}

enum HermesProfileLifecycleChange: Equatable, Sendable {
    case renamed(from: String, to: String)
    case deleted(profileID: String)
    case defaultActivated(profileID: String)
    case imported(profileID: String)
    case descriptionChanged(profileID: String)
    case onboardingFactsSaved(profileID: String)

    var affectedProfileIDs: Set<String> {
        switch self {
        case .renamed(let from, let to): [from, to]
        case .deleted(let profileID), .defaultActivated(let profileID),
             .imported(let profileID), .descriptionChanged(let profileID),
             .onboardingFactsSaved(let profileID): [profileID]
        }
    }
}

struct HermesProfileRenameReview: Equatable, Sendable {
    let profile: HermesProfileLifecycleItem
    let active: HermesActiveProfileSnapshot
    let requestedName: String
    fileprivate let reviewToken: Data
}

struct HermesProfileDeleteReview: Equatable, Sendable {
    let profile: HermesProfileLifecycleItem
    let active: HermesActiveProfileSnapshot
    fileprivate let reviewToken: Data
}

struct HermesProfileActivationReview: Equatable, Sendable {
    let profile: HermesProfileLifecycleItem
    let active: HermesActiveProfileSnapshot
    fileprivate let reviewToken: Data
}

struct HermesProfileLifecycleResult: Equatable, Sendable {
    let change: HermesProfileLifecycleChange
    let catalog: HermesProfileLifecycleCatalog
    let profile: HermesProfileLifecycleItem?
}

struct HermesProfileArchiveExport: Equatable, Sendable {
    let profileID: String
    let archivePath: String
}

struct HermesProfileArchiveImportReview: Equatable, Sendable {
    let archivePath: String
    let requestedProfileID: String?
}

struct HermesProfileAutoDescriptionResult: Equatable, Sendable {
    let profileID: String
    let succeeded: Bool
    let reason: String
    let description: String
    let profile: HermesProfileLifecycleItem
}

struct HermesProfileSetupCommand: Equatable, Sendable {
    let profileID: String
    let command: String
}

struct HermesOnboardingFacts: Equatable, Sendable {
    var preferredName = ""
    var context = ""
    var focusAreas: [String] = []
    var tools: [String] = []
    var desktopTheme = ""
    var desktopAccent = ""
    var desktopLayout = ""
}

struct HermesOnboardingFactsReceipt: Equatable, Sendable {
    let saved: Bool
    let profileID: String
    let target: String
}

enum HermesProfileLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case ownerChanged
    case invalidRequest
    case invalidResponse
    case currentProfileProtected
    case activeDefaultProtected
    case reviewChanged
    case outcomeUnknown
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .ownerChanged: "The selected Hermes computer changed. Reopen Profile Lifecycle."
        case .invalidRequest: "This profile lifecycle request is invalid."
        case .invalidResponse: "Hermes returned an unsupported profile lifecycle response."
        case .currentProfileProtected: "The profile serving this connection cannot be renamed or deleted here. Switch to another serving profile first."
        case .activeDefaultProtected: "Choose another sticky default before deleting this profile."
        case .reviewChanged: "The reviewed profile changed. Refresh the review before continuing."
        case .outcomeUnknown: "Hermes did not confirm the profile operation. Refresh before trying it again."
        case .rejected(let reason): reason
        }
    }
}

@MainActor
protocol HermesProfileLifecycleManaging: AnyObject {
    var ownsScope: Bool { get }
    func catalog(selectedProfileID: String) async throws -> HermesProfileLifecycleCatalog
    func prepareRename(profileID: String, newName: String) async throws -> HermesProfileRenameReview
    func rename(
        reviewed: HermesProfileRenameReview,
        retireProfileOwnership: @MainActor (HermesProfileLifecycleChange) async throws -> Void
    ) async throws -> HermesProfileLifecycleResult
    func prepareDelete(profileID: String) async throws -> HermesProfileDeleteReview
    func delete(
        reviewed: HermesProfileDeleteReview,
        retireProfileOwnership: @MainActor (HermesProfileLifecycleChange) async throws -> Void
    ) async throws -> HermesProfileLifecycleResult
    func prepareDefaultActivation(profileID: String) async throws -> HermesProfileActivationReview
    func activateDefault(
        reviewed: HermesProfileActivationReview,
        retireProfileOwnership: @MainActor (HermesProfileLifecycleChange) async throws -> Void
    ) async throws -> HermesProfileLifecycleResult
    func exportProfile(profileID: String, outputPath: String?) async throws -> HermesProfileArchiveExport
    func prepareImport(archivePath: String, requestedProfileID: String?) throws -> HermesProfileArchiveImportReview
    func importProfile(reviewed: HermesProfileArchiveImportReview) async throws -> HermesProfileLifecycleResult
    func describeAutomatically(profileID: String, overwrite: Bool) async throws -> HermesProfileAutoDescriptionResult
    func setupCommand(profileID: String) async throws -> HermesProfileSetupCommand
    func rememberOnboardingFacts(_ facts: HermesOnboardingFacts, profileID: String) async throws -> HermesOnboardingFactsReceipt
}

/// Fixed, owner-bound profile lifecycle adapter. Archive paths are passed only
/// to Hermes' stock profile import/export endpoints, preserving their archive
/// confinement and scanner policy. This client never opens or extracts them.
@MainActor
final class DirectHermesProfileLifecycleClient: HermesProfileLifecycleManaging {
    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?

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

    var ownsScope: Bool { owner.authority.kind == .direct && currentOwner() == owner }

    func catalog(selectedProfileID: String) async throws -> HermesProfileLifecycleCatalog {
        let selected = try Self.profile(selectedProfileID)
        let profileValue = try await requestHTTP(.init(
            path: "/api/profiles", method: .get, maximumResponseBytes: 256 * 1_024
        ))
        guard let rows = profileValue.object?["profiles"]?.array, rows.count <= 256 else {
            throw HermesProfileLifecycleError.invalidResponse
        }
        var seen = Set<Data>()
        let profiles = try rows.map { value -> HermesProfileLifecycleItem in
            let item = try Self.item(value)
            guard seen.insert(Data(item.id.utf8)).inserted else {
                throw HermesProfileLifecycleError.invalidResponse
            }
            return item
        }
        let active = try await activeSnapshot()
        guard profiles.contains(where: { Self.exact($0.id, selected) }),
              profiles.contains(where: { Self.exact($0.id, active.activeProfileID) }),
              profiles.contains(where: { Self.exact($0.id, active.currentProfileID) }) else {
            throw HermesProfileLifecycleError.invalidResponse
        }
        return .init(selectedProfileID: selected, profiles: profiles, active: active)
    }

    func prepareRename(profileID: String, newName: String) async throws -> HermesProfileRenameReview {
        let profileID = try Self.profile(profileID)
        let catalog = try await catalog(selectedProfileID: profileID)
        let target = try Self.exactProfile(profileID, in: catalog)
        let requested: String
        if target.isDefaultProfile {
            requested = try Self.displayName(newName)
        } else {
            requested = try Self.profile(newName)
        }
        guard !Self.exact(target.id, catalog.active.currentProfileID) else {
            throw HermesProfileLifecycleError.currentProfileProtected
        }
        guard target.isDefaultProfile || !Self.exact(target.id, requested),
              target.isDefaultProfile || !catalog.profiles.contains(where: { Self.exact($0.id, requested) }) else {
            throw HermesProfileLifecycleError.invalidRequest
        }
        return .init(
            profile: target, active: catalog.active, requestedName: requested,
            reviewToken: try Self.reviewToken(target, active: catalog.active)
        )
    }

    func rename(
        reviewed: HermesProfileRenameReview,
        retireProfileOwnership: @MainActor (HermesProfileLifecycleChange) async throws -> Void
    ) async throws -> HermesProfileLifecycleResult {
        let current = try await catalog(selectedProfileID: reviewed.profile.id)
        let target = try Self.exactProfile(reviewed.profile.id, in: current)
        guard try Self.reviewToken(target, active: current.active) == reviewed.reviewToken else {
            throw HermesProfileLifecycleError.reviewChanged
        }
        let expectedID = target.isDefaultProfile ? target.id : reviewed.requestedName
        let change = HermesProfileLifecycleChange.renamed(from: target.id, to: expectedID)
        try await retireProfileOwnership(change)
        let finalReview = try await catalog(selectedProfileID: target.id)
        let finalTarget = try Self.exactProfile(target.id, in: finalReview)
        guard try Self.reviewToken(finalTarget, active: finalReview.active) == reviewed.reviewToken else {
            throw HermesProfileLifecycleError.reviewChanged
        }
        let value = try await mutateHTTP(.init(
            path: "/api/profiles/\(try Self.pathComponent(target.id))", method: .patch,
            body: ["new_name": .string(reviewed.requestedName)], maximumResponseBytes: 64 * 1_024
        ))
        guard value.object?["ok"]?.boolean == true,
              Self.exact(value.object?["name"]?.string, expectedID) else {
            throw HermesProfileLifecycleError.outcomeUnknown
        }
        let readback = try await catalog(selectedProfileID: expectedID)
        let renamed = try Self.exactProfile(expectedID, in: readback)
        if target.isDefaultProfile {
            guard Self.exact(renamed.displayName, reviewed.requestedName) else {
                throw HermesProfileLifecycleError.outcomeUnknown
            }
        } else {
            guard !readback.profiles.contains(where: { Self.exact($0.id, target.id) }) else {
                throw HermesProfileLifecycleError.outcomeUnknown
            }
        }
        return .init(change: change, catalog: readback, profile: renamed)
    }

    func prepareDelete(profileID: String) async throws -> HermesProfileDeleteReview {
        let profileID = try Self.profile(profileID)
        let catalog = try await catalog(selectedProfileID: profileID)
        let target = try Self.exactProfile(profileID, in: catalog)
        guard !target.isDefaultProfile,
              !Self.exact(target.id, catalog.active.currentProfileID) else {
            throw HermesProfileLifecycleError.currentProfileProtected
        }
        guard !Self.exact(target.id, catalog.active.activeProfileID) else {
            throw HermesProfileLifecycleError.activeDefaultProtected
        }
        return .init(
            profile: target, active: catalog.active,
            reviewToken: try Self.reviewToken(target, active: catalog.active)
        )
    }

    func delete(
        reviewed: HermesProfileDeleteReview,
        retireProfileOwnership: @MainActor (HermesProfileLifecycleChange) async throws -> Void
    ) async throws -> HermesProfileLifecycleResult {
        let current = try await catalog(selectedProfileID: reviewed.profile.id)
        let target = try Self.exactProfile(reviewed.profile.id, in: current)
        guard try Self.reviewToken(target, active: current.active) == reviewed.reviewToken else {
            throw HermesProfileLifecycleError.reviewChanged
        }
        guard !target.isDefaultProfile, !Self.exact(target.id, current.active.currentProfileID) else {
            throw HermesProfileLifecycleError.currentProfileProtected
        }
        guard !Self.exact(target.id, current.active.activeProfileID) else {
            throw HermesProfileLifecycleError.activeDefaultProtected
        }
        let change = HermesProfileLifecycleChange.deleted(profileID: target.id)
        try await retireProfileOwnership(change)
        let finalReview = try await catalog(selectedProfileID: target.id)
        let finalTarget = try Self.exactProfile(target.id, in: finalReview)
        guard try Self.reviewToken(finalTarget, active: finalReview.active) == reviewed.reviewToken else {
            throw HermesProfileLifecycleError.reviewChanged
        }
        let fallbackID = current.profiles.first(where: { $0.isDefaultProfile })?.id ?? "default"
        // Hermes stops the agent's gateway (up to 10 s) and its other processes
        // before removing it, so give it the longest wait. If the answer still
        // gets lost, the profile list says whether the delete happened.
        let value: BighelpJSONValue
        do {
            value = try await mutateHTTP(.init(
                path: "/api/profiles/\(try Self.pathComponent(target.id))", method: .delete,
                maximumResponseBytes: 64 * 1_024, timeout: DirectHermesHTTP.longestRequestSeconds
            ))
        } catch {
            let readback = try await catalog(selectedProfileID: fallbackID)
            guard !readback.profiles.contains(where: { Self.exact($0.id, target.id) }) else { throw error }
            return .init(change: change, catalog: readback, profile: nil)
        }
        guard value.object?["ok"]?.boolean == true else {
            throw HermesProfileLifecycleError.outcomeUnknown
        }
        let readback = try await catalog(selectedProfileID: fallbackID)
        guard !readback.profiles.contains(where: { Self.exact($0.id, target.id) }) else {
            throw HermesProfileLifecycleError.outcomeUnknown
        }
        return .init(change: change, catalog: readback, profile: nil)
    }

    func prepareDefaultActivation(profileID: String) async throws -> HermesProfileActivationReview {
        let profileID = try Self.profile(profileID)
        let catalog = try await catalog(selectedProfileID: profileID)
        let target = try Self.exactProfile(profileID, in: catalog)
        guard !Self.exact(target.id, catalog.active.activeProfileID) else {
            throw HermesProfileLifecycleError.invalidRequest
        }
        return .init(
            profile: target, active: catalog.active,
            reviewToken: try Self.reviewToken(target, active: catalog.active)
        )
    }

    func activateDefault(
        reviewed: HermesProfileActivationReview,
        retireProfileOwnership: @MainActor (HermesProfileLifecycleChange) async throws -> Void
    ) async throws -> HermesProfileLifecycleResult {
        let current = try await catalog(selectedProfileID: reviewed.profile.id)
        let target = try Self.exactProfile(reviewed.profile.id, in: current)
        guard try Self.reviewToken(target, active: current.active) == reviewed.reviewToken else {
            throw HermesProfileLifecycleError.reviewChanged
        }
        let change = HermesProfileLifecycleChange.defaultActivated(profileID: target.id)
        try await retireProfileOwnership(change)
        let finalReview = try await catalog(selectedProfileID: target.id)
        let finalTarget = try Self.exactProfile(target.id, in: finalReview)
        guard try Self.reviewToken(finalTarget, active: finalReview.active) == reviewed.reviewToken else {
            throw HermesProfileLifecycleError.reviewChanged
        }
        let value = try await mutateHTTP(.init(
            path: "/api/profiles/active", method: .post,
            body: ["name": .string(target.id)], maximumResponseBytes: 32 * 1_024
        ))
        guard value.object?["ok"]?.boolean == true,
              Self.exact(value.object?["active"]?.string, target.id) else {
            throw HermesProfileLifecycleError.outcomeUnknown
        }
        let readback = try await catalog(selectedProfileID: target.id)
        guard Self.exact(readback.active.activeProfileID, target.id),
              Self.exact(readback.active.currentProfileID, reviewed.active.currentProfileID) else {
            throw HermesProfileLifecycleError.outcomeUnknown
        }
        return .init(change: change, catalog: readback, profile: try Self.exactProfile(target.id, in: readback))
    }

    func exportProfile(profileID: String, outputPath: String? = nil) async throws -> HermesProfileArchiveExport {
        let profileID = try Self.profile(profileID)
        _ = try await catalog(selectedProfileID: profileID)
        let output = try outputPath.map(Self.backendPath) ?? ""
        let value = try await mutateHTTP(.init(
            path: "/api/profiles/\(try Self.pathComponent(profileID))/export", method: .post,
            body: ["output": .string(output), "extra_files": .object([:])],
            maximumResponseBytes: 64 * 1_024
        ))
        guard value.object?["ok"]?.boolean == true,
              let archive = try Self.optionalText(value.object?["archive"], maximum: 4_096),
              !archive.isEmpty else { throw HermesProfileLifecycleError.outcomeUnknown }
        _ = try await catalog(selectedProfileID: profileID)
        return .init(profileID: profileID, archivePath: archive)
    }

    func prepareImport(
        archivePath: String,
        requestedProfileID: String? = nil
    ) throws -> HermesProfileArchiveImportReview {
        let archive = try Self.backendPath(archivePath)
        let requested = try requestedProfileID.map(Self.profile)
        return .init(archivePath: archive, requestedProfileID: requested)
    }

    func importProfile(reviewed: HermesProfileArchiveImportReview) async throws -> HermesProfileLifecycleResult {
        let archive = try Self.backendPath(reviewed.archivePath)
        var body: [String: BighelpJSONValue] = ["archive": .string(archive)]
        if let name = reviewed.requestedProfileID { body["name"] = .string(try Self.profile(name)) }
        let value = try await mutateHTTP(.init(
            path: "/api/profiles/import", method: .post, body: body,
            maximumResponseBytes: 256 * 1_024
        ))
        guard value.object?["ok"]?.boolean == true,
              let rawID = value.object?["name"]?.string else {
            throw HermesProfileLifecycleError.outcomeUnknown
        }
        let importedID = try Self.profile(rawID)
        if let expected = reviewed.requestedProfileID, !Self.exact(expected, importedID) {
            throw HermesProfileLifecycleError.outcomeUnknown
        }
        let readback = try await catalog(selectedProfileID: importedID)
        let imported = try Self.exactProfile(importedID, in: readback)
        let change = HermesProfileLifecycleChange.imported(profileID: importedID)
        return .init(change: change, catalog: readback, profile: imported)
    }

    func describeAutomatically(
        profileID: String,
        overwrite: Bool = false
    ) async throws -> HermesProfileAutoDescriptionResult {
        let profileID = try Self.profile(profileID)
        _ = try await catalog(selectedProfileID: profileID)
        let value = try await mutateHTTP(.init(
            path: "/api/profiles/\(try Self.pathComponent(profileID))/describe-auto", method: .post,
            body: ["overwrite": .boolean(overwrite)], maximumResponseBytes: 64 * 1_024
        ))
        guard let row = value.object, let ok = row["ok"]?.boolean,
              let reason = try Self.optionalText(row["reason"], maximum: 4_096),
              let descriptionAuto = row["description_auto"]?.boolean,
              descriptionAuto == ok else {
            throw HermesProfileLifecycleError.invalidResponse
        }
        let returnedDescription = try Self.optionalText(row["description"], maximum: 8_192)
        let readback = try await catalog(selectedProfileID: profileID)
        let profile = try Self.exactProfile(profileID, in: readback)
        if ok {
            guard let returnedDescription,
                  Self.exact(profile.description, returnedDescription), profile.descriptionIsAutomatic else {
                throw HermesProfileLifecycleError.outcomeUnknown
            }
        }
        return .init(
            profileID: profileID, succeeded: ok, reason: reason,
            description: returnedDescription ?? profile.description, profile: profile
        )
    }

    func setupCommand(profileID: String) async throws -> HermesProfileSetupCommand {
        let profileID = try Self.profile(profileID)
        let value = try await requestHTTP(.init(
            path: "/api/profiles/\(try Self.pathComponent(profileID))/setup-command", method: .get,
            maximumResponseBytes: 16 * 1_024
        ))
        guard let command = try Self.optionalText(value.object?["command"], maximum: 2_048),
              !command.isEmpty else { throw HermesProfileLifecycleError.invalidResponse }
        return .init(profileID: profileID, command: command)
    }

    func rememberOnboardingFacts(
        _ facts: HermesOnboardingFacts,
        profileID: String
    ) async throws -> HermesOnboardingFactsReceipt {
        let profileID = try Self.profile(profileID)
        guard profileID == "default" else { throw HermesProfileLifecycleError.invalidRequest }
        let answers = try Self.onboardingAnswers(facts)
        let value: BighelpJSONValue
        do {
            value = try await requestRPC("profiles.remember_onboarding", params: [
                "profile": .string(profileID), "answers": .object(answers),
            ], mutation: true)
        } catch {
            try requireOwner()
            throw HermesProfileLifecycleError.outcomeUnknown
        }
        guard value.object?["saved"]?.boolean == true,
              Self.exact(value.object?["profile"]?.string, profileID),
              Self.exact(value.object?["target"]?.string, "user") else {
            throw HermesProfileLifecycleError.outcomeUnknown
        }
        return .init(saved: true, profileID: profileID, target: "user")
    }

    private func activeSnapshot() async throws -> HermesActiveProfileSnapshot {
        let value = try await requestHTTP(.init(
            path: "/api/profiles/active", method: .get, maximumResponseBytes: 16 * 1_024
        ))
        guard let active = value.object?["active"]?.string,
              let current = value.object?["current"]?.string else {
            throw HermesProfileLifecycleError.invalidResponse
        }
        return .init(activeProfileID: try Self.profile(active), currentProfileID: try Self.profile(current))
    }

    private func requestHTTP(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: requireOwner) {
            try await http.request(request)
        }
    }

    private func mutateHTTP(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        do { return try await requestHTTP(request) }
        catch {
            try requireOwner()
            throw HermesProfileLifecycleError.outcomeUnknown
        }
    }

    private func requestRPC(
        _ method: String,
        params: [String: BighelpJSONValue],
        mutation: Bool
    ) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: requireOwner,
            mapError: { mutation ? HermesProfileLifecycleError.outcomeUnknown : $0 }) {
            try await rpc.request(method, params: params)
        }
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard ownsScope else { throw HermesProfileLifecycleError.ownerChanged }
    }

    private static func item(_ value: BighelpJSONValue) throws -> HermesProfileLifecycleItem {
        guard let row = value.object, let rawID = row["name"]?.string,
              let isDefault = row["is_default"]?.boolean,
              let skillCount = row["skill_count"]?.integer, skillCount >= 0,
              let hasEnvironment = row["has_env"]?.boolean,
              let hasAlias = row["has_alias"]?.boolean,
              let gatewayRunning = row["gateway_running"]?.boolean,
              let automatic = row["description_auto"]?.boolean else {
            throw HermesProfileLifecycleError.invalidResponse
        }
        let id = try profile(rawID)
        let display = try optionalText(row["display_name"], maximum: 800)
        return .init(
            id: id,
            displayName: (display?.isEmpty == false ? display : nil) ?? id,
            description: try optionalText(row["description"], maximum: 8_192) ?? "",
            descriptionIsAutomatic: automatic, isDefaultProfile: isDefault,
            providerID: try optionalText(row["provider"], maximum: 128),
            modelID: try optionalText(row["model"], maximum: 512),
            skillCount: skillCount, hasEnvironment: hasEnvironment,
            hasAlias: hasAlias, gatewayRunning: gatewayRunning,
            distributionName: try optionalText(row["distribution_name"], maximum: 512),
            distributionVersion: try optionalText(row["distribution_version"], maximum: 128),
            distributionSource: try optionalText(row["distribution_source"], maximum: 2_048)
        )
    }

    private static func exactProfile(
        _ profileID: String,
        in catalog: HermesProfileLifecycleCatalog
    ) throws -> HermesProfileLifecycleItem {
        let matches = catalog.profiles.filter { exact($0.id, profileID) }
        guard matches.count == 1, let profile = matches.first else {
            throw HermesProfileLifecycleError.reviewChanged
        }
        return profile
    }

    private static func reviewToken(
        _ profile: HermesProfileLifecycleItem,
        active: HermesActiveProfileSnapshot
    ) throws -> Data {
        let value: BighelpJSONValue = .object([
            "id": .string(profile.id), "display_name": .string(profile.displayName),
            "description": .string(profile.description),
            "description_auto": .boolean(profile.descriptionIsAutomatic),
            "is_default": .boolean(profile.isDefaultProfile),
            "provider": profile.providerID.map(BighelpJSONValue.string) ?? .null,
            "model": profile.modelID.map(BighelpJSONValue.string) ?? .null,
            "skill_count": .integer(profile.skillCount),
            "has_env": .boolean(profile.hasEnvironment), "has_alias": .boolean(profile.hasAlias),
            "gateway_running": .boolean(profile.gatewayRunning),
            "distribution_name": profile.distributionName.map(BighelpJSONValue.string) ?? .null,
            "distribution_version": profile.distributionVersion.map(BighelpJSONValue.string) ?? .null,
            "distribution_source": profile.distributionSource.map(BighelpJSONValue.string) ?? .null,
            "active": .string(active.activeProfileID), "current": .string(active.currentProfileID),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(value)))
    }

    private static func onboardingAnswers(_ facts: HermesOnboardingFacts) throws -> [String: BighelpJSONValue] {
        func field(_ value: String, maximum: Int = 800) throws -> BighelpJSONValue {
            .string(try text(value.trimmingCharacters(in: .whitespacesAndNewlines), maximum: maximum))
        }
        func list(_ values: [String]) throws -> BighelpJSONValue {
            guard values.count <= 64 else { throw HermesProfileLifecycleError.invalidRequest }
            var seen = Set<Data>()
            let result = try values.compactMap { raw -> String? in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                let checked = try text(value, maximum: 256)
                guard seen.insert(Data(checked.utf8)).inserted else { return nil }
                return checked
            }
            return .array(result.map(BighelpJSONValue.string))
        }
        let result: [String: BighelpJSONValue] = [
            "name": try field(facts.preferredName), "context": try field(facts.context, maximum: 1_000),
            "focus": try list(facts.focusAreas), "connectors": try list(facts.tools),
            "theme": try field(facts.desktopTheme), "accent": try field(facts.desktopAccent),
            "layout": try field(facts.desktopLayout),
        ]
        let encoder = JSONEncoder()
        guard try encoder.encode(BighelpJSONValue.object(result)).count <= 2_000 else {
            throw HermesProfileLifecycleError.invalidRequest
        }
        return result
    }

    private static func profile(_ value: String) throws -> String {
        try WorkspaceAuthority.validateIdentifier(value, maximumBytes: 64)
        guard value != "all", value != ".", value != "..", !value.contains("/"),
              !value.contains("\\"), !value.contains(where: \.isWhitespace) else {
            throw HermesProfileLifecycleError.invalidRequest
        }
        return value
    }

    private static func displayName(_ value: String) throws -> String {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 800,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HermesProfileLifecycleError.invalidRequest
        }
        return value
    }

    private static func backendPath(_ value: String) throws -> String {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HermesProfileLifecycleError.invalidRequest
        }
        return value
    }

    private static func pathComponent(_ value: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty, !encoded.contains("/") else {
            throw HermesProfileLifecycleError.invalidRequest
        }
        return encoded
    }

    private static func text(_ value: String, maximum: Int) throws -> String {
        guard value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw HermesProfileLifecycleError.invalidResponse
        }
        return value
    }

    private static func optionalText(_ value: BighelpJSONValue?, maximum: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let string = value.string else { throw HermesProfileLifecycleError.invalidResponse }
        return try text(string, maximum: maximum)
    }

    private static func exact(_ lhs: String?, _ rhs: String) -> Bool {
        lhs?.utf8.elementsEqual(rhs.utf8) == true
    }
}
