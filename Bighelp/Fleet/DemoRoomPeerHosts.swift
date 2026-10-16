import CryptoKit
import Foundation

#if DEBUG
/// Demo: the demo's other computers offer room links, so a group chat with
/// agents on them can be made without real hosts.
@MainActor
final class DemoRoomPeerHosts: HermesBotModePeerHosts {
    private let hostNames: [String]
    private weak var fleet: FleetStore?

    init(hostNames: [String] = FleetFixtureReader().hosts.map(\.name), fleet: FleetStore? = nil) {
        self.hostNames = hostNames
        self.fleet = fleet
    }

    func roomLink(hostID: String, profile: String) async throws -> HermesBotModeRoomLink {
        let installation = "demo-install-\(hostID.prefix(8).lowercased())"
        let digest = SHA256.hash(data: Data("\(installation):\(profile)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return try HermesBotModeRoomLink.parse(catalog: [
            "installation_id": .string(installation), "catalog_digest": .string(digest),
            "endpoint": .object(["available": .boolean(true), "url": .string("https://demo-peer.example.invalid"),
                                 "transport_security": .string("tls")]),
        ], profile: profile)
    }

    func invite(hostID: String, profile: String, roomID: String, homeInstallID: String,
                authorityGatewayID: String, authorityEpoch: Int, memberID: String) async throws -> HermesBotModePeerInvite {
        HermesBotModePeerInvite(grant: "demo-grant", link: try await roomLink(hostID: hostID, profile: profile))
    }

    func hostName(peerID: String) -> String? {
        hostNames.first { HermesBotModePeerMembers.slug($0) == peerID }
    }

    func agent(peerID: String, profile: String) -> HermesBotModePeerAgent? {
        fleet?.peerAgent(peerID: peerID, profile: profile)
    }

    func refreshAgents() {
        fleet?.refresh()
    }

    /// The demo's other computers can't be reached.
    func connect(peerID: String) async throws -> any HermesBotModePeerConnection {
        throw WorkspaceClientError.unavailable(.unsupportedHost)
    }
}
#endif
