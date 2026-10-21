import CryptoKit
import Foundation

struct DirectHermesCanonicalAgentSession: Equatable, Sendable {
    let id: String
    let resolvedID: String?
}

struct DirectHermesAgentProfileRow: Equatable, Sendable {
    let id: String
    let name: String
    let role: String
    let summary: String
    let isDefault: Bool
    let hasAvatar: Bool
    let namespace: [String: BighelpJSONValue]
    let namespaceRevision: Int?
    let canonicalSession: DirectHermesCanonicalAgentSession?
}

struct DirectHermesAgentProfileSnapshot: Equatable, Sendable {
    let row: DirectHermesAgentProfileRow
    let profile: AgentProfile
}

@MainActor
final class DirectHermesAgentProfileService {
    static let maximumProfiles = 128
    let workspace: any WorkspaceOperationPerforming
    let owner: WorkspaceOwner
    let currentOwner: @MainActor () -> WorkspaceOwner?
    private var isValid = true

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?) {
        self.workspace = workspace
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func invalidate() { isValid = false }

    func requireOwner() throws {
        try Task.checkCancellation()
        guard isValid, currentOwner() == owner, workspace.owner == owner else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    func request(
        _ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue],
        capability: WorkspaceCapability, profileID: String? = nil
    ) async throws -> [String: BighelpJSONValue] {
        try requireCapability(capability, profileID: profileID)
        let response = try await workspace.perform(operation, payload: payload, owner: owner)
        try requireOwner()
        return response
    }

    static let pluginSharingFeature = "native-agent-plugin-links-v1"

    /// Hermes copies the source agent's plugins into a clone, and two copies of one plugin package stop every
    /// later plugin install on the computer, the bighelp plugin's updates included. The plugin swaps exact copies
    /// for links to the default agent's. In the background: comparing the copies can take seconds, and making the
    /// agent never waits for it. With an older plugin, or on any failure, the plugin's own pass links them when the
    /// app next connects, and the new agent is fine either way.
    func sharePlugins(profileID: String) {
        let payload: [String: BighelpJSONValue] = ["agentId": .string(profileID)]
        let workspace = workspace, owner = owner
        Task {
            do {
                _ = try await workspace.perform(.agentPluginsShare, payload: payload, owner: owner)
            } catch WorkspaceClientError.conflict {
                // The plugin's context changed (412): the next call loads it again. Once.
                _ = try? await workspace.perform(.agentPluginsShare, payload: payload, owner: owner)
            } catch {}
        }
    }

    func requireCapability(_ capability: WorkspaceCapability, profileID: String? = nil) throws {
        try requireOwner()
        let availability = workspace.capabilities.availability(for: capability, owner: owner, profileID: profileID)
        guard availability.isAvailable else {
            if case .unavailable(let reason) = availability { throw WorkspaceClientError.unavailable(reason) }
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    func rows() async throws -> [DirectHermesAgentProfileRow] {
        let payload = try await request(.profilesList, ["include_sessions": .boolean(false)], capability: .profilesRead)
        guard let values = payload["profiles"]?.array else { throw WorkspaceClientError.invalidResponse }
        guard values.count <= Self.maximumProfiles else { throw WorkspaceClientError.capacityExceeded }
        let rows = try values.map(Self.decodeRow)
        guard Set(rows.map(\.id)).count == rows.count else { throw WorkspaceClientError.invalidResponse }
        return rows
    }

    func snapshot(id: String) async throws -> DirectHermesAgentProfileSnapshot {
        guard let row = try await rows().first(where: { $0.id == id }) else {
            throw WorkspaceClientError.rejected(code: "profile_unavailable")
        }
        return try await snapshot(row: row)
    }

    func snapshot(row: DirectHermesAgentProfileRow) async throws -> DirectHermesAgentProfileSnapshot {
        async let soul = readSoul(profileID: row.id)
        let avatar = row.hasAvatar ? try await readAvatar(profileID: row.id) : nil
        return DirectHermesAgentProfileSnapshot(
            row: row,
            profile: AgentProfile(
                id: row.id, name: row.name, role: row.role, summary: row.summary,
                instructions: try await soul, avatar: avatar, isDefault: row.isDefault,
                look: AgentAvatarLook(namespace: row.namespace),
                placement: AgentListPlacement(namespace: row.namespace)
            )
        )
    }

    func readSoul(profileID: String) async throws -> String {
        let payload = try await request(
            .profilesSoulGet, ["profile": .string(profileID)], capability: .profilesRead, profileID: profileID
        )
        guard let content = payload["content"]?.string, let exists = payload["exists"]?.boolean,
              exists || content.isEmpty else { throw WorkspaceClientError.invalidResponse }
        return try Self.text(content, maximumBytes: 256_000)
    }

    func writeSoul(_ content: String, profileID: String) async throws {
        _ = try Self.text(content, maximumBytes: 256_000)
        let result = try await request(.profilesSoulSet, [
            "profile": .string(profileID), "content": .string(content)
        ], capability: .profilesEdit, profileID: profileID)
        guard result["ok"]?.boolean == true else { throw WorkspaceClientError.rejected(code: nil) }
        let readback = try await request(.profilesSoulGet, ["profile": .string(profileID)],
                                        capability: .profilesRead, profileID: profileID)
        guard readback["exists"]?.boolean == true, readback["content"]?.string == content else {
            throw WorkspaceClientError.conflict
        }
    }

    func readAvatar(profileID: String) async throws -> AgentAvatar? {
        let response = try await request(.profilesGetAsset, [
            "name": .string(profileID), "asset": .string("avatar")
        ], capability: .profilesRead, profileID: profileID)
        guard let found = response["found"]?.boolean else { throw WorkspaceClientError.invalidResponse }
        guard found else { return nil }
        guard let mime = response["mime"]?.string, let size = response["size"]?.integer,
              let dataURL = response["data"]?.string else { throw WorkspaceClientError.invalidResponse }
        let data = try Self.avatarData(mime: mime, size: size, dataURL: dataURL)
        return AgentAvatar(mimeType: mime, byteCount: size,
                           sha256: BighelpLinkBase64URL.encode(Data(SHA256.hash(data: data))), dataURL: dataURL)
    }

    func writeAvatar(_ avatar: AgentAvatar?, profileID: String) async throws {
        var payload: [String: BighelpJSONValue] = ["name": .string(profileID), "asset": .string("avatar")]
        if let avatar {
            let data = try Self.avatarData(mime: avatar.mimeType, size: avatar.byteCount, dataURL: avatar.dataURL)
            guard avatar.sha256 == BighelpLinkBase64URL.encode(Data(SHA256.hash(data: data))) else {
                throw WorkspaceClientError.invalidRequest
            }
            payload["data"] = .string(avatar.dataURL)
        } else {
            payload["clear"] = .boolean(true)
        }
        let response = try await request(.profilesSetAsset, payload, capability: .profilesEdit, profileID: profileID)
        guard response["ok"]?.boolean == true, response["asset"]?.string == "avatar",
              response["size"]?.integer == (avatar?.byteCount ?? 0) else {
            throw WorkspaceClientError.invalidResponse
        }
        guard try await readAvatar(profileID: profileID) == avatar else { throw WorkspaceClientError.conflict }
    }

    static func decodeRow(_ value: BighelpJSONValue) throws -> DirectHermesAgentProfileRow {
        guard let row = value.object, let rawID = row["name"]?.string,
              let isDefault = row["is_default"]?.boolean, let hasAvatar = row["has_avatar"]?.boolean else {
            throw WorkspaceClientError.invalidResponse
        }
        let id = try profileIdentifier(rawID)
        let metadata = try object(row["ui_meta"])
        let namespace = try object(metadata["hermes-bots"])
        let encoded = try JSONEncoder().encode(BighelpJSONValue.object(namespace))
        guard encoded.count <= 65_536 else { throw WorkspaceClientError.capacityExceeded }
        let revisions = try object(row["ui_meta_revisions"])
        let revision: Int?
        if row["ui_meta_revisions"] == nil || row["ui_meta_revisions"] == .null {
            revision = nil
        } else if let value = revisions["hermes-bots"] {
            guard let number = value.integer, number >= 0 else { throw WorkspaceClientError.invalidResponse }
            revision = number
        } else {
            revision = 0
        }
        let title = try optionalText(namespace["title"], maximumBytes: 800)
        let displayName = try optionalText(row["display_name"], maximumBytes: 800)
        let role = try optionalText(row["description"], maximumBytes: 4_096) ?? ""
        let summary = try optionalText(namespace["description"], maximumBytes: 4_096) ?? role
        var canonical: DirectHermesCanonicalAgentSession?
        if let value = row["canonical_session"], value != .null {
            guard let fields = value.object, let rawSessionID = fields["id"]?.string else {
                throw WorkspaceClientError.invalidResponse
            }
            try WorkspaceAuthority.validateIdentifier(rawSessionID, maximumBytes: 512)
            let resolved = try optionalText(fields["resolved_id"], maximumBytes: 512)
            if let resolved { try WorkspaceAuthority.validateIdentifier(resolved, maximumBytes: 512) }
            canonical = DirectHermesCanonicalAgentSession(id: rawSessionID, resolvedID: resolved)
        }
        let name = [title, displayName].compactMap { $0 }.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? id
        return DirectHermesAgentProfileRow(
            id: id, name: name,
            role: role, summary: summary, isDefault: isDefault, hasAvatar: hasAvatar,
            namespace: namespace, namespaceRevision: revision, canonicalSession: canonical
        )
    }

    static func object(_ value: BighelpJSONValue?) throws -> [String: BighelpJSONValue] {
        guard let value, value != .null else { return [:] }
        guard let object = value.object else { throw WorkspaceClientError.invalidResponse }
        return object
    }

    static func optionalText(_ value: BighelpJSONValue?, maximumBytes: Int) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let string = value.string else { throw WorkspaceClientError.invalidResponse }
        return try text(string, maximumBytes: maximumBytes)
    }

    static func text(_ value: String, maximumBytes: Int) throws -> String {
        guard value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t")).contains($0)
              }) else { throw WorkspaceClientError.capacityExceeded }
        return value
    }

    static func profileIdentifier(_ value: String) throws -> String {
        try WorkspaceAuthority.validateIdentifier(value, maximumBytes: 64)
        guard value != ".", value != "..", !value.contains("/"), !value.contains("\\"),
              !value.contains(where: \.isWhitespace) else { throw WorkspaceClientError.invalidRequest }
        return value
    }

    static func validatedDraft(_ draft: AgentDraft) throws -> AgentDraft {
        var result = draft
        result.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.role = draft.role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, !(draft.removesAvatar && draft.avatar != nil) else {
            throw WorkspaceClientError.invalidRequest
        }
        _ = try text(result.name, maximumBytes: 800)
        _ = try text(result.role, maximumBytes: 4_096)
        _ = try text(result.summary, maximumBytes: 4_096)
        _ = try text(result.instructions, maximumBytes: 256_000)
        if let avatar = result.avatar {
            let data = try avatarData(mime: avatar.mimeType, size: avatar.byteCount, dataURL: avatar.dataURL)
            guard avatar.sha256 == BighelpLinkBase64URL.encode(Data(SHA256.hash(data: data))) else {
                throw WorkspaceClientError.invalidRequest
            }
        }
        if let fileName = result.avatarFileName {
            guard fileName.utf8.count <= 255,
                  AvatarFileURL.resolve(fileName: fileName, in: URL(fileURLWithPath: "/")) != nil else {
                throw WorkspaceClientError.invalidRequest
            }
        }
        if let source = result.cloneSourceProfileID {
            result.cloneSourceProfileID = try profileIdentifier(source)
        }
        return result
    }

    private static func avatarData(mime: String, size: Int, dataURL: String) throws -> Data {
        guard (1...2_000_000).contains(size), dataURL.utf8.count <= 2_800_000,
              ["image/png", "image/jpeg", "image/webp"].contains(mime),
              dataURL.hasPrefix("data:\(mime);base64,"),
              let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              data.count == size else { throw WorkspaceClientError.invalidResponse }
        let validMagic: Bool
        switch mime {
        case "image/png": validMagic = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case "image/jpeg": validMagic = data.starts(with: [255, 216, 255])
        default:
            validMagic = data.count >= 12 && data.prefix(4) == Data("RIFF".utf8)
                && data.dropFirst(8).prefix(4) == Data("WEBP".utf8)
        }
        guard validMagic else { throw WorkspaceClientError.invalidResponse }
        return data
    }
}
