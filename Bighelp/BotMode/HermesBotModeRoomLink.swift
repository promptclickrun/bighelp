import Foundation

/// One agent's RoomLink offer, from `groups.capabilities {profile}` on the
/// computer it lives on. A room whose home is another computer includes the
/// agent with it; Hermes then links the two computers directly ("Desktop is a
/// viewer, not a relay"), and the app only carries the setup between them.
struct HermesBotModeRoomLink: Equatable, Sendable {
    /// Why a computer can't take part in a room on another computer.
    enum Problem: Error, Equatable {
        /// Its Hermes can't link rooms (`room_link.reason`), or is too old to.
        case unavailable(String)
        /// It has no address other computers can reach (`endpoint.reason`;
        /// `not_configured` until its `room_link_url` is set).
        case noAddress(String)
    }

    /// The catalog exactly as Hermes sent it: `groups.peer.register` takes it back unchanged.
    let catalog: [String: BighelpJSONValue]
    let profile: String
    let installationID: String
    let catalogDigest: String
    let endpointURL: String

    static func parse(roomLink: [String: BighelpJSONValue], profile: String) throws -> Self {
        guard roomLink["enabled"]?.boolean == true else {
            throw Problem.unavailable(roomLink["reason"]?.string.flatMap(reason) ?? "unavailable")
        }
        guard let catalog = roomLink["catalog"]?.object else { throw BighelpLinkWorkspaceClientError.invalidResponse }
        return try parse(catalog: catalog, profile: profile)
    }

    static func parse(catalog: [String: BighelpJSONValue], profile: String) throws -> Self {
        guard let installationID = catalog["installation_id"]?.string,
              HermesBotModeWireCodec.identifier(installationID),
              let digest = catalog["catalog_digest"]?.string,
              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              catalog["execution_policy"]?.object?["target_profile"]?.string.map({ $0 == profile }) ?? true,
              let size = try? JSONEncoder().encode(BighelpJSONValue.object(catalog)).count, size <= 32_768 else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        guard let endpoint = catalog["endpoint"]?.object, let available = endpoint["available"]?.boolean else {
            throw Problem.noAddress("not_configured")
        }
        guard available else {
            throw Problem.noAddress(endpoint["reason"]?.string.flatMap(reason) ?? "not_configured")
        }
        guard let url = endpoint["url"]?.string, isLinkAddress(url) else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        return Self(catalog: catalog, profile: profile, installationID: installationID,
                    catalogDigest: digest, endpointURL: url)
    }

    /// https anywhere, plain http only to this machine, as Hermes requires
    /// (`validate_room_link_url`).
    static func isLinkAddress(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048, let url = URL(string: value),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "::1"
        default: return false
        }
    }

    private static func reason(_ value: String) -> String? {
        HermesBotModeWireCodec.identifier(value) ? value : nil
    }
}

/// A grant one computer issues for one agent in one room homed elsewhere. It
/// is a credential: held in memory only until the home registers it.
struct HermesBotModePeerInvite: Sendable, CustomStringConvertible {
    let grant: String
    let link: HermesBotModeRoomLink

    var description: String { "HermesBotModePeerInvite(\(link.installationID), grant redacted)" }
}

/// An agent on another saved computer, picked for a new group chat.
struct HermesBotModePeerCandidate: Codable, Equatable, Sendable {
    /// The saved computer (its `BighelpHostRegistry` host ID).
    let hostID: String
    let hostName: String
    let profileID: String
    let name: String
}

/// An agent on another computer that its room still has to link.
struct HermesBotModePeerLink: Codable, Equatable, Sendable {
    let memberID: String
    let candidate: HermesBotModePeerCandidate
}

/// Reaches other saved computers for group chats with their agents, each with
/// its own saved sign-in. The app layer provides it.
@MainActor
protocol HermesBotModePeerHosts: AnyObject {
    func roomLink(hostID: String, profile: String) async throws -> HermesBotModeRoomLink
    func invite(hostID: String, profile: String, roomID: String, homeInstallID: String,
                authorityGatewayID: String, authorityEpoch: Int, memberID: String) async throws -> HermesBotModePeerInvite
    /// The saved computer a room member's `peer_id` names, for its label.
    func hostName(peerID: String) -> String?
    /// That computer's agent as this device last read it: its current name
    /// and its own picture.
    func agent(peerID: String, profile: String) -> HermesBotModePeerAgent?
    /// Reads the other computers again if they haven't been lately, so their
    /// agents' names and pictures are there.
    func refreshAgents()
    /// Opens the computer a member's `peer_id` names and keeps its connection
    /// until `release`: for a group chat on screen or a Team Call.
    func connect(peerID: String) async throws -> any HermesBotModePeerConnection
}

/// Another computer's connection, held open for as long as it's needed.
@MainActor
protocol HermesBotModePeerConnection: AnyObject, Sendable {
    var workspace: any WorkspaceOperationPerforming { get }
    var owner: WorkspaceOwner { get }
    var currentOwner: @MainActor () -> WorkspaceOwner? { get }
    /// The bighelp plugin's features there (`native-room-peer-typing-v1`).
    var pluginFeatures: Set<String> { get }
    func release()
}

/// An agent on another computer, as the all-computers view last read it.
struct HermesBotModePeerAgent: Equatable, Sendable {
    let name: String
    let imageURL: URL?
}

/// The home computer's side of RoomLink setup.
@MainActor
protocol HermesBotModePeerRegistering: AnyObject {
    func groupsPeerRegister(roomID: String, memberID: String, invite: HermesBotModePeerInvite) async throws
}

enum HermesBotModePeerMembers {
    /// A computer's name as a Hermes identifier: its `peer_id`, and the tail of
    /// its agents' device-qualified handles (`@default-vera`, as in Hermes Desktop).
    static func slug(_ name: String) -> String {
        let words = name.lowercased().unicodeScalars.map { scalar -> Character in
            ("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)) ? Character(scalar) : "-"
        }
        let joined = String(words).split(separator: "-").joined(separator: "-")
        let bounded = String(joined.prefix(40))
        return HermesBotModeWireCodec.identifier(bounded) ? bounded : "computer"
    }

    /// Member IDs and handles for agents on other computers, unique beside the
    /// home's own members (Hermes refuses repeats, ignoring case).
    static func members(
        for peers: [(candidate: HermesBotModePeerCandidate, link: HermesBotModeRoomLink)],
        taken: [HermesBotModeRoomMember]
    ) -> [(member: HermesBotModeRoomMember, link: HermesBotModePeerLink)] {
        var ids = Set(taken.map { $0.memberID.lowercased() })
        var handles = Set(taken.map { $0.handle.lowercased() }).union(["all", "everyone"])
        func unique(_ base: String, in used: inout Set<String>) -> String {
            var value = String(base.prefix(120))
            var suffix = 2
            while used.contains(value.lowercased()) {
                value = "\(base.prefix(116))-\(suffix)"
                suffix += 1
            }
            used.insert(value.lowercased())
            return value
        }
        return peers.map { peer in
            let device = slug(peer.candidate.hostName)
            let handleBase = NativeBotModeHandles.preferred(profileID: peer.candidate.profileID, name: peer.candidate.name)
            let memberID = unique("\(peer.candidate.profileID)-\(device)", in: &ids)
            let member = HermesBotModeRoomMember(
                memberID: memberID, profile: peer.candidate.profileID,
                handle: unique("\(handleBase)-\(device)", in: &handles),
                displayName: peer.candidate.name,
                target: [
                    "kind": .string("peer"), "peer_id": .string(device),
                    "installation_id": .string(peer.link.installationID),
                    "profile": .string(peer.candidate.profileID),
                    "capability_digest": .string(peer.link.catalogDigest),
                ]
            )
            return (member, HermesBotModePeerLink(memberID: memberID, candidate: peer.candidate))
        }
    }
}
