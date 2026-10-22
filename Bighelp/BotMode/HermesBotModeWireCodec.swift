import CryptoKit
import Foundation

enum HermesBotModeWireCodec {
    /// Hosted-room user payloads use Python's `str.strip()` before persistence.
    /// Keep the original retry payload intact; normalize only the expected receipt.
    static func canonicalUserText(_ value: String) -> String {
        func isHostWhitespace(_ scalar: Unicode.Scalar) -> Bool {
            scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
        }
        var scalars = value.unicodeScalars
        while let first = scalars.first, isHostWhitespace(first) { scalars.removeFirst() }
        while let last = scalars.last, isHostWhitespace(last) { scalars.removeLast() }
        return String(scalars)
    }

    static func mainThreadID(roomID: String) -> String {
        let legacy = "loopdy-\(roomID)"
        if identifier(legacy) { return legacy }
        return "loopdy-" + SHA256.hash(data: Data(roomID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil
    }

    static func label(_ value: String, maximum: Int = 200) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func capabilities(_ value: HermesBotModeCapabilities) throws {
        guard identifier(value.authorityGatewayID), (1...500).contains(value.maxLogLimit),
              value.methods.count <= 128, value.features.count <= 128,
              value.methods.allSatisfy({ label($0, maximum: 128) }),
              value.features.allSatisfy({ label($0, maximum: 128) }),
              value.seatableProfiles.map({ $0.count <= 512 && $0.allSatisfy { label($0, maximum: 128) } }) ?? true else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
    }

    static func member(_ value: HermesBotModeRoomMember) -> Bool {
        guard identifier(value.memberID), identifier(value.profile), identifier(value.handle),
              value.displayName.map({ label($0) }) ?? true else { return false }
        switch value.target["kind"]?.string {
        case "local":
            return Set(value.target.keys) == ["kind", "profile"]
                && value.target["profile"]?.string == value.profile
        case "peer":
            return Set(value.target.keys) == ["kind", "peer_id", "installation_id", "profile", "capability_digest"]
                && value.target["profile"]?.string == value.profile
                && value.target["peer_id"]?.string.map(identifier) == true
                && value.target["installation_id"]?.string.map(identifier) == true
                && value.target["capability_digest"]?.string.map({ label($0, maximum: 256) }) == true
        default:
            return false
        }
    }

    static func room(_ value: HermesBotModeRoomState) throws {
        guard identifier(value.roomID), label(value.name),
              identifier(value.authorityGatewayID), value.authorityEpoch > 0, value.revision > 0,
              (1...128).contains(value.members.count),
              Set(value.members.map(\.memberID)).count == value.members.count,
              value.members.allSatisfy(member),
              timestamp(value.createdAt), timestamp(value.updatedAt),
              value.updatedAt >= value.createdAt,
              value.latestSequence.map({ $0 >= 0 }) ?? true,
              value.disbandedAt.map(timestamp) ?? true else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
    }

    static func event(_ value: HermesBotModeEvent) throws {
        guard identifier(value.roomID), identifier(value.eventID), value.sequence > 0,
              value.kind.utf8.count <= 64,
              value.kind.range(of: #"^[a-z][a-z0-9_.-]*$"#, options: .regularExpression) != nil,
              timestamp(value.createdAt),
              Set(value.actor.keys).isSubset(of: ["kind", "id", "display_name", "profile", "connection_id"]),
              let actorID = value.actor["id"]?.string, identifier(actorID),
              let actorKind = value.actor["kind"]?.string,
              ["user", "member", "gateway", "system"].contains(actorKind),
              value.authorityEpoch.map({ $0 > 0 }) ?? true else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        for key in ["profile", "connection_id"] where value.actor[key] != nil {
            guard value.actor[key]?.string.map(identifier) == true else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
        }
        if value.actor["display_name"] != nil,
           value.actor["display_name"]?.string.map({ label($0) }) != true {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        let gatewayKinds: Set<String> = [
            "member.unavailable", "room.activity", "room.stop_requested", "turn.deferred",
            "turn.reassigned", "turn.cancelled", "turn.failed", "turn.settled", "turn.started",
        ]
        let systemKinds: Set<String> = [
            "authority.claimed", "authority.lost", "room.created", "room.disbanded",
            "room.members_changed", "room.renamed",
        ]
        guard !gatewayKinds.contains(value.kind) || actorKind == "gateway",
              !systemKinds.contains(value.kind) || actorKind == "system" else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        if value.kind == "message.user" || value.kind == "message.member" {
            guard let text = value.text, text.utf8.count <= 64 * 1024,
                  !text.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0) && !"\n\r\t".unicodeScalars.contains($0)
                  }),
                  value.kind == "message.user" ? actorKind == "user"
                    : actorKind == "member" && value.memberID == actorID else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
        }
    }

    private static func timestamp(_ value: Double) -> Bool {
        value.isFinite && (0...253_402_300_799).contains(value)
    }
}
