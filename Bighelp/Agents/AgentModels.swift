import Foundation

struct AgentAvatar: Codable, Equatable, Sendable {
    let mimeType: String
    let byteCount: Int
    let sha256: String
    let dataURL: String
}

struct AgentProfile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var role: String
    var summary: String
    var instructions: String
    var avatarFileName: String?
    var avatar: AgentAvatar? = nil
    var isDefault: Bool
    /// The look Hermes Desktop draws for this agent, when the host keeps one.
    var look: AgentAvatarLook? = nil
    /// Its section and whether it's hidden in the all-hosts list.
    var placement: AgentListPlacement? = nil
}

/// Where an agent sits in the all-hosts list: its section, or hidden. Saved
/// on the agent's own host in `ui_meta["hermes-bots"]` under the keys Hermes
/// Desktop uses (`sectionId`, `sectionName`, `hidden`), so both show the same
/// folders. Hiding only changes the list: the agent keeps working everywhere.
struct AgentListPlacement: Codable, Equatable, Sendable {
    var sectionID: String?
    /// Carried beside the ID so a device that never saw the section can rebuild it.
    var sectionName: String?
    var isHidden = false

    init(sectionID: String? = nil, sectionName: String? = nil, isHidden: Bool = false) {
        self.sectionID = sectionID
        self.sectionName = sectionName
        self.isHidden = isHidden
    }

    static let maximumNameLength = 80

    /// Read leniently: a missing or odd value counts as unset.
    init(namespace: [String: BighelpJSONValue]) {
        let id = namespace["sectionId"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        sectionID = id.flatMap { !$0.isEmpty && $0.utf8.count <= 128 ? $0 : nil }
        sectionName = sectionID == nil ? nil : namespace["sectionName"]?.string.flatMap(Self.cleanName)
        isHidden = namespace["hidden"]?.boolean ?? false
    }

    /// Trimmed, without control characters, bounded; nil when nothing's left.
    static func cleanName(_ name: String) -> String? {
        let scalars = name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(scalars).prefix(maximumNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// The namespace with this placement written in and every other key kept.
    /// Hermes merges `ui_meta` per top-level key, so the whole namespace goes back.
    func applied(to namespace: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] {
        var result = namespace
        if sectionID != nil || namespace["sectionId"] != nil {
            result["sectionId"] = sectionID.map(BighelpJSONValue.string) ?? .null
            result["sectionName"] = sectionName.map(BighelpJSONValue.string) ?? .null
        }
        if isHidden || namespace["hidden"] != nil { result["hidden"] = .boolean(isHidden) }
        return result
    }
}

/// Saves where an agent sits in the all-hosts list on its own host.
@MainActor
protocol AgentListPlacementWriting {
    func setPlacement(_ placement: AgentListPlacement, profileID: String) async throws
}

extension AgentProfile {
    static let bighelpLinkDefault = AgentProfile(
        id: "default",
        name: "Bighelp",
        role: "Default bot",
        summary: "Your default Hermes bot.",
        instructions: "",
        avatarFileName: nil,
        isDefault: true
    )
}

struct AgentDraft: Codable, Equatable, Sendable {
    var name: String
    var role: String
    var summary: String
    var instructions: String
    var avatarFileName: String?
    var avatar: AgentAvatar? = nil
    var removesAvatar = false
    var isDefault: Bool
    /// The Hermes Desktop look to record with a new avatar picture.
    var look: AgentAvatarLook? = nil
    /// Creation-only options forwarded to stock Hermes on the selected host.
    var cloneSourceProfileID: String? = nil
    var skipBundledSkills = false
}

extension AgentDraft {
    private enum CodingKeys: String, CodingKey {
        case name, role, summary, instructions, avatarFileName, avatar, removesAvatar, isDefault
        case cloneSourceProfileID, skipBundledSkills
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        role = try values.decode(String.self, forKey: .role)
        summary = try values.decode(String.self, forKey: .summary)
        instructions = try values.decode(String.self, forKey: .instructions)
        avatarFileName = try values.decodeIfPresent(String.self, forKey: .avatarFileName)
        avatar = try values.decodeIfPresent(AgentAvatar.self, forKey: .avatar)
        removesAvatar = try values.decodeIfPresent(Bool.self, forKey: .removesAvatar) ?? false
        isDefault = try values.decode(Bool.self, forKey: .isDefault)
        cloneSourceProfileID = try values.decodeIfPresent(String.self, forKey: .cloneSourceProfileID)
        skipBundledSkills = try values.decodeIfPresent(Bool.self, forKey: .skipBundledSkills) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(role, forKey: .role)
        try values.encode(summary, forKey: .summary)
        try values.encode(instructions, forKey: .instructions)
        try values.encodeIfPresent(avatarFileName, forKey: .avatarFileName)
        try values.encodeIfPresent(avatar, forKey: .avatar)
        try values.encode(removesAvatar, forKey: .removesAvatar)
        try values.encode(isDefault, forKey: .isDefault)
        try values.encodeIfPresent(cloneSourceProfileID, forKey: .cloneSourceProfileID)
        try values.encode(skipBundledSkills, forKey: .skipBundledSkills)
    }
}

struct AgentDirectoryPartialMutationError: Error, Equatable, Sendable {
    enum Field: String, CaseIterable, Sendable {
        case name, role, summary, instructions, avatar
    }

    let committedProfile: AgentProfile
    let unappliedFields: Set<Field>
    let isOutcomeUncertain: Bool

    init(
        committedProfile: AgentProfile,
        unappliedFields: Set<Field> = [.avatar],
        isOutcomeUncertain: Bool = false
    ) {
        self.committedProfile = committedProfile
        self.unappliedFields = unappliedFields
        self.isOutcomeUncertain = isOutcomeUncertain
    }
}

@MainActor
protocol AgentDirectoryClient {
    func list() async throws -> [AgentProfile]
    func create(_ draft: AgentDraft) async throws -> AgentProfile
    func update(id: String, draft: AgentDraft) async throws -> AgentProfile
    func resetForAccountBoundary()
    /// The host's petdex gallery (Hermes `pet.gallery`), for the studio's Pets.
    func petGallery() async throws -> [PetdexPet]
    /// A pet's first frame as a small PNG (Hermes `pet.thumb`).
    func petThumbnail(_ pet: PetdexPet) async throws -> Data
    /// A pet's full animation sheet, for its moves.
    func petSheet(_ pet: PetdexPet) async throws -> Data
}

/// An agent list that removes an agent itself: the demo's. A real computer deletes an agent
/// through Hermes' profile lifecycle (`NativeWorkspaceLifecycleCoordinator.deleteAgent`).
@MainActor
protocol AgentDirectoryDeleting {
    func delete(profileID: String) async throws
}

extension AgentDirectoryClient {
    func resetForAccountBoundary() {}
    func petGallery() async throws -> [PetdexPet] { throw PetdexError.unsupported }
    func petThumbnail(_ pet: PetdexPet) async throws -> Data { throw PetdexError.unsupported }
    /// Hermes lends only a first frame, so sheets come from petdex itself.
    func petSheet(_ pet: PetdexPet) async throws -> Data { try await PetdexPublicCatalog.shared.sheet(pet) }
}
