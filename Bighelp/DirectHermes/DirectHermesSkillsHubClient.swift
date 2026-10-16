import Foundation

/// Typed client for Hermes' public Skills Hub lifecycle. Hub installation is a
/// host-side download; this client never relabels it as an archive upload.
@MainActor
final class DirectHermesSkillsHubClient: SkillsHubManagementClient {
    let owner: WorkspaceOwner
    let profileID: String
    let actionStatusClient: (any HermesHostActionStatusClient)?

    private let http: any DirectHermesAuthenticatedHTTP
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private var knownSkills: [String: InstalledSkill] = [:]

    var isCurrentActionOwner: Bool { currentOwner() == owner }

    init(
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        profileID: String,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        actionStatusClient: (any HermesHostActionStatusClient)? = nil
    ) {
        self.http = http
        self.owner = owner
        self.profileID = profileID
        self.currentOwner = currentOwner
        self.actionStatusClient = actionStatusClient
    }

    func load() async throws -> SkillHubSnapshot {
        let profile = try checkedProfile()
        async let sourceValue = request(.sources(profile: profile))
        async let officialValue = request(.official(profile: profile))
        async let installedValue = requestValue(.installed(profile: profile))
        let sources = try await sourceValue
        let official = try await officialValue
        let installedPayload = try await installedValue
        try requireOwner()

        let installed = try decodeInstalled(sources["installed"])
        let activeSkills = try CapabilitiesPayload.rows(installedPayload, decodeInstalledSkill)
        for skill in activeSkills { knownSkills[skill.name] = skill }
        let activeNames = Set(activeSkills.map(\.name))
        let retainedDisabled = knownSkills.values.filter { !$0.isEnabled && !activeNames.contains($0.name) }
        let installedSkills = (activeSkills + retainedDisabled).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let sourceRows = try CapabilitiesPayload.rows(sources["sources"], decodeSource)
        let featured = try CapabilitiesPayload.rows(sources["featured"]) { try decodeItem($0, installed: installed) }
        let officialRows = try CapabilitiesPayload.rows(official["skills"]) { try decodeItem($0, installed: installed) }
        return SkillHubSnapshot(
            sources: sourceRows,
            featured: featured,
            official: officialRows,
            installedSkills: installedSkills,
            installedIdentifiers: installed,
            indexAvailable: try CapabilitiesPayload.boolean(sources["index_available"])
        )
    }

    func search(query: String, source: String = "all") async throws -> SkillHubSearchResult {
        let profile = try checkedProfile()
        let query = try query.trimmingCharacters(in: .whitespacesAndNewlines).validatedHubText(maximumBytes: 512)
        guard !query.isEmpty else { return SkillHubSearchResult(items: [], sourceCounts: [:], timedOutSources: []) }
        let source = try source.validatedHubText(maximumBytes: 80)
        let payload = try await request(.search(query: query, source: source.isEmpty ? "all" : source, profile: profile))
        let installed = try decodeInstalled(payload["installed"])
        let items = try CapabilitiesPayload.rows(payload["results"]) { try decodeItem($0, installed: installed) }
        let countsObject = try CapabilitiesPayload.object(payload["source_counts"])
        var counts: [String: Int] = [:]
        for (key, value) in countsObject {
            counts[try key.validatedHubText(maximumBytes: 80)] = try CapabilitiesPayload.integer(value)
        }
        return SkillHubSearchResult(
            items: items,
            sourceCounts: counts,
            timedOutSources: try CapabilitiesPayload.strings(payload["timed_out"])
        )
    }

    func preview(identifier: String) async throws -> SkillHubPreview {
        let identifier = try hubIdentifier(identifier)
        let payload = try await request(.preview(identifier: identifier, profile: checkedProfile()))
        let item = try decodeItem(.object(payload), installed: [])
        guard item.id == identifier else { throw CapabilitiesManagementError.invalidResponse }
        let markdown = try CapabilitiesPayload.text(
            payload["skill_md"], maximumBytes: CapabilitiesPayload.maximumDocumentBytes, required: false
        )
        let files = try CapabilitiesPayload.strings(payload["files"])
        return SkillHubPreview(item: item, skillMarkdown: markdown, files: files)
    }

    func scan(identifier: String) async throws -> SkillHubScan {
        let identifier = try hubIdentifier(identifier)
        let payload = try await request(.scan(identifier: identifier, profile: checkedProfile()))
        guard try CapabilitiesPayload.text(payload["identifier"], maximumBytes: 2_048) == identifier,
              let policy = SkillHubScan.Policy(rawValue: try CapabilitiesPayload.text(payload["policy"], maximumBytes: 16)) else {
            throw CapabilitiesManagementError.invalidResponse
        }
        let findings = try CapabilitiesPayload.array(payload["findings"]).map { value in
            let row = try CapabilitiesPayload.object(value)
            let line: Int?
            if row["line"] == nil || row["line"] == .null { line = nil }
            else { line = try CapabilitiesPayload.integer(row["line"], range: 0...10_000_000) }
            return SkillHubScanFinding(
                severity: try CapabilitiesPayload.text(row["severity"], maximumBytes: 32),
                category: try CapabilitiesPayload.text(row["category"], maximumBytes: 128),
                file: try CapabilitiesPayload.text(row["file"], maximumBytes: 4_096, required: false),
                line: line,
                detail: try CapabilitiesPayload.text(row["description"], maximumBytes: 8_192)
            )
        }
        let countsObject = try CapabilitiesPayload.object(payload["severity_counts"])
        var counts: [String: Int] = [:]
        for (key, value) in countsObject {
            counts[try key.validatedHubText(maximumBytes: 32)] = try CapabilitiesPayload.integer(value)
        }
        return SkillHubScan(
            identifier: identifier,
            name: try CapabilitiesPayload.text(payload["name"], maximumBytes: 256),
            source: try CapabilitiesPayload.text(payload["source"], maximumBytes: 2_048),
            trustLevel: try CapabilitiesPayload.text(payload["trust_level"], maximumBytes: 64),
            verdict: try CapabilitiesPayload.text(payload["verdict"], maximumBytes: 64),
            summary: try CapabilitiesPayload.text(payload["summary"], maximumBytes: 16_384),
            policy: policy,
            policyReason: try CapabilitiesPayload.text(payload["policy_reason"], maximumBytes: 16_384, required: false),
            findings: findings,
            severityCounts: counts
        )
    }

    func setEnabled(_ enabled: Bool, skillName: String) async throws -> InstalledSkill {
        let profile = try checkedProfile()
        let name = try CapabilitiesPayload.identifier(skillName, maximumBytes: 128)
        let activeBefore = try CapabilitiesPayload.rows(
            try await requestValue(.installed(profile: profile)), decodeInstalledSkill
        )
        guard let existing = activeBefore.first(where: { $0.name == name }) ?? knownSkills[name] else {
            throw CapabilitiesManagementError.invalidRequest
        }
        let payload = try await request(.toggle(name: name, enabled: enabled, profile: profile))
        guard payload["ok"]?.boolean == true, payload["name"]?.string == name,
              payload["enabled"]?.boolean == enabled else {
            throw CapabilitiesManagementError.invalidResponse
        }
        let readback = try await requestValue(.installed(profile: profile))
        if enabled {
            guard let skill = try CapabilitiesPayload.rows(readback, decodeInstalledSkill).first(where: { $0.name == name }),
                  skill.isEnabled else {
                throw CapabilitiesManagementError.readbackFailed
            }
            knownSkills[name] = skill
            return skill
        }
        // Hermes' GET /api/skills filters disabled rows. Absence after an
        // acknowledged disable is therefore the public readback contract.
        guard try !CapabilitiesPayload.listsName(name, in: readback) else {
            throw CapabilitiesManagementError.readbackFailed
        }
        let disabled = InstalledSkill(
            name: existing.name, summary: existing.summary, category: existing.category,
            isEnabled: false, provenance: existing.provenance, usageCount: existing.usageCount
        )
        knownSkills[name] = disabled
        return disabled
    }

    func install(identifier: String, preview: SkillHubPreview, scan: SkillHubScan) async throws -> CapabilityWriteResult {
        let identifier = try hubIdentifier(identifier)
        guard preview.item.id == identifier, scan.identifier == identifier, scan.policy != .block else {
            throw CapabilitiesManagementError.invalidRequest
        }
        let payload = try await request(.install(identifier: identifier, profile: checkedProfile()))
        return try actionResult(payload, fallbackAction: "skills-install", message: "Hermes is installing the reviewed skill.")
    }

    func uninstall(name: String) async throws -> CapabilityWriteResult {
        let name = try CapabilitiesPayload.identifier(name, maximumBytes: 128)
        let payload = try await request(.uninstall(name: name, profile: checkedProfile()))
        return try actionResult(payload, fallbackAction: "skills-uninstall", message: "Hermes is uninstalling the selected skill.")
    }

    func updateInstalled() async throws -> CapabilityWriteResult {
        let payload = try await request(.update(profile: checkedProfile()))
        return try actionResult(payload, fallbackAction: "skills-update", message: "Hermes is checking installed Hub skills for updates.")
    }

    private enum Route {
        case sources(profile: String)
        case official(profile: String)
        case installed(profile: String)
        case toggle(name: String, enabled: Bool, profile: String)
        case search(query: String, source: String, profile: String)
        case preview(identifier: String, profile: String)
        case scan(identifier: String, profile: String)
        case install(identifier: String, profile: String)
        case uninstall(name: String, profile: String)
        case update(profile: String)

        var isCapabilityProbe: Bool {
            switch self {
            case .sources, .official: true
            default: false
            }
        }

        var request: DirectHermesHTTPRequest {
            switch self {
            case .sources(let profile):
                return DirectHermesHTTPRequest(path: "/api/skills/hub/sources", method: .get, query: [.init(name: "profile", value: profile)])
            case .official(let profile):
                return DirectHermesHTTPRequest(path: "/api/skills/hub/official", method: .get, query: [.init(name: "profile", value: profile)])
            case .installed(let profile):
                return DirectHermesHTTPRequest(path: "/api/skills", method: .get, query: [.init(name: "profile", value: profile)])
            case .toggle(let name, let enabled, let profile):
                return DirectHermesHTTPRequest(path: "/api/skills/toggle", method: .put, body: [
                    "name": .string(name), "enabled": .boolean(enabled), "profile": .string(profile),
                ])
            case .search(let query, let source, let profile):
                return DirectHermesHTTPRequest(path: "/api/skills/hub/search", method: .get, query: [
                    .init(name: "q", value: query), .init(name: "source", value: source),
                    .init(name: "limit", value: "50"), .init(name: "profile", value: profile),
                ])
            case .preview(let identifier, let profile):
                return DirectHermesHTTPRequest(path: "/api/skills/hub/preview", method: .get, query: [
                    .init(name: "identifier", value: identifier), .init(name: "profile", value: profile),
                ], maximumResponseBytes: 1_048_576)
            case .scan(let identifier, let profile):
                return DirectHermesHTTPRequest(path: "/api/skills/hub/scan", method: .get, query: [
                    .init(name: "identifier", value: identifier), .init(name: "profile", value: profile),
                ], maximumResponseBytes: 1_048_576)
            case .install(let identifier, let profile):
                return DirectHermesHTTPRequest(path: "/api/skills/hub/install", method: .post, body: [
                    "identifier": .string(identifier), "profile": .string(profile),
                ])
            case .uninstall(let name, let profile):
                return DirectHermesHTTPRequest(path: "/api/skills/hub/uninstall", method: .post, body: [
                    "name": .string(name), "profile": .string(profile),
                ])
            case .update(let profile):
                return DirectHermesHTTPRequest(path: "/api/skills/hub/update", method: .post, body: ["profile": .string(profile)])
            }
        }
    }

    private func request(_ route: Route) async throws -> [String: BighelpJSONValue] {
        try CapabilitiesPayload.object(try await requestValue(route))
    }

    private func requestValue(_ route: Route) async throws -> BighelpJSONValue {
        try requireOwner()
        do {
            let value = try await http.request(route.request)
            try requireOwner()
            return value
        } catch DirectHermesError.unsupportedAuthentication where route.isCapabilityProbe {
            throw CapabilitiesManagementError.unsupportedHost("This Hermes host does not expose the Skills Hub management routes.")
        } catch DirectHermesError.unsupportedAuthentication {
            throw CapabilitiesManagementError.invalidResponse
        }
    }

    private func checkedProfile() throws -> String {
        try requireOwner()
        return try CapabilitiesPayload.profile(profileID)
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard currentOwner() == owner else { throw CapabilitiesManagementError.staleOwner }
    }

    private func hubIdentifier(_ value: String) throws -> String {
        try value.validatedHubText(maximumBytes: 2_048, required: true)
    }

    private func decodeSource(_ value: BighelpJSONValue) throws -> SkillHubSource {
        let row = try CapabilitiesPayload.object(value)
        let available = row["available"]?.boolean
        return SkillHubSource(
            id: try CapabilitiesPayload.text(row["id"], maximumBytes: 80),
            label: try CapabilitiesPayload.text(row["label"], maximumBytes: 160),
            isAvailable: available,
            isSearchable: row["searchable"]?.boolean ?? true,
            isRateLimited: row["rate_limited"]?.boolean ?? false
        )
    }

    private func decodeInstalled(_ value: BighelpJSONValue?) throws -> Set<String> {
        guard let value else { throw CapabilitiesManagementError.invalidResponse }
        if let object = value.object {
            return Set(try object.keys.map { try $0.validatedHubText(maximumBytes: 2_048) })
        }
        if let array = value.array {
            return Set(try array.map { try CapabilitiesPayload.text($0, maximumBytes: 2_048) })
        }
        throw CapabilitiesManagementError.invalidResponse
    }

    private func decodeInstalledSkill(_ value: BighelpJSONValue) throws -> InstalledSkill {
        let row = try CapabilitiesPayload.object(value)
        let usage = row["usage"]?.integer ?? 0
        guard (0...10_000_000).contains(usage) else { throw CapabilitiesManagementError.invalidResponse }
        return InstalledSkill(
            name: try CapabilitiesPayload.text(row["name"], maximumBytes: 128),
            summary: try CapabilitiesPayload.summary(row["description"]),
            // Hermes sends `null` for a skill outside any category folder.
            category: try CapabilitiesPayload.optionalText(row["category"], maximumBytes: 256) ?? "",
            isEnabled: try CapabilitiesPayload.boolean(row["enabled"]),
            provenance: try CapabilitiesPayload.text(row["provenance"], maximumBytes: 32),
            usageCount: usage
        )
    }

    private func decodeItem(_ value: BighelpJSONValue, installed: Set<String>) throws -> SkillHubItem {
        let row = try CapabilitiesPayload.object(value)
        let identifier = try CapabilitiesPayload.text(row["identifier"], maximumBytes: 2_048)
        let installedFlag = row["installed"]?.boolean ?? installed.contains(identifier)
        return SkillHubItem(
            id: identifier,
            name: try CapabilitiesPayload.text(row["name"], maximumBytes: 256),
            summary: try CapabilitiesPayload.summary(row["description"]),
            source: try CapabilitiesPayload.text(row["source"], maximumBytes: 2_048, required: false),
            trustLevel: try CapabilitiesPayload.text(row["trust_level"], maximumBytes: 64),
            repository: try CapabilitiesPayload.optionalText(row["repo"], maximumBytes: 2_048),
            tags: try CapabilitiesPayload.strings(row["tags"]),
            category: try CapabilitiesPayload.optionalText(row["category"], maximumBytes: 128),
            isInstalled: installedFlag
        )
    }

    private func actionResult(_ payload: [String: BighelpJSONValue], fallbackAction: String, message: String) throws -> CapabilityWriteResult {
        guard payload["ok"]?.boolean == true else { throw CapabilitiesManagementError.invalidResponse }
        let action = try CapabilitiesPayload.optionalText(payload["action"], maximumBytes: 160)
            ?? CapabilitiesPayload.optionalText(payload["name"], maximumBytes: 160)
            ?? fallbackAction
        let processID = try payload["pid"].flatMap { value in
            value == .null ? nil : try CapabilitiesPayload.integer(value, range: 1...Int.max)
        }
        let actionID = try CapabilitiesPayload.optionalText(payload["action_id"], maximumBytes: 128)
        return .pending(
            receipt: .init(actionName: action, processID: processID, actionID: actionID),
            message: message
        )
    }
}

private extension String {
    func validatedHubText(maximumBytes: Int, required: Bool = false) throws -> String {
        guard (!required || !isEmpty), utf8.count <= maximumBytes,
              !unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t")).contains($0)
              }) else { throw CapabilitiesManagementError.invalidRequest }
        return self
    }
}
