import Foundation

/// An agent on another computer couldn't join its group chat: which, and why.
struct BotModePeerLinkError: Error, Equatable {
    let candidate: HermesBotModePeerCandidate
    let problem: HermesBotModeRoomLink.Problem

    var message: String {
        let computer = candidate.hostName
        switch problem {
        case .noAddress:
            return "\(computer) has no address other computers can reach. Give its Hermes a room link address "
                + "(room_link_url), then try again."
        case .unavailable("unsupported"):
            return "\(computer)'s Hermes can't join group chats on other computers. Update Hermes there."
        case .unavailable("changed"):
            return "\(candidate.name)'s settings on \(computer) changed while the group was set up. Start the group again."
        case .unavailable:
            return "\(computer) can't join group chats on other computers right now."
        }
    }
}

extension BotModeRoomStore {
    /// Links each agent on another computer that this room still waits for:
    /// that computer issues a grant, and this one, the room's home, registers
    /// it. From then on Hermes calls the other computer directly.
    func linkPendingPeers(roomID: String) async {
        guard let room = room(id: roomID), !room.nativePendingPeerLinks.isEmpty else {
            nativePeerLinkProblems[roomID] = nil
            return
        }
        guard let peerHosts, let home = nativeClient as? any HermesBotModePeerRegistering,
              let state = room.nativeState, let homeInstallID = nativeCapabilities?.authorityGatewayID else {
            nativePeerLinkProblems[roomID] = "Agents on other computers join once this computer is connected."
            return
        }
        let boundary = nativeBoundaryGeneration
        for link in room.nativePendingPeerLinks {
            do {
                guard let member = state.members.first(where: { $0.memberID == link.memberID }) else {
                    throw WorkspaceClientError.invalidResponse
                }
                let invite: HermesBotModePeerInvite
                do {
                    invite = try await peerHosts.invite(
                        hostID: link.candidate.hostID, profile: member.profile, roomID: state.roomID,
                        homeInstallID: homeInstallID, authorityGatewayID: state.authorityGatewayID,
                        authorityEpoch: state.authorityEpoch, memberID: member.memberID
                    )
                } catch let problem as HermesBotModeRoomLink.Problem {
                    throw BotModePeerLinkError(candidate: link.candidate, problem: problem)
                }
                try requireNativeBoundary(boundary)
                // Hermes made the room with this agent's catalog; a different one
                // can't run there.
                guard invite.link.catalogDigest == member.target["capability_digest"]?.string,
                      invite.link.installationID == member.target["installation_id"]?.string else {
                    throw BotModePeerLinkError(candidate: link.candidate, problem: .unavailable("changed"))
                }
                try await home.groupsPeerRegister(roomID: state.roomID, memberID: member.memberID, invite: invite)
                try requireNativeBoundary(boundary)
                guard var latest = self.room(id: roomID) else { return }
                latest.setNativePendingPeerLinks(latest.nativePendingPeerLinks.filter { $0.memberID != link.memberID })
                try persist(room: latest)
            } catch is CancellationError {
                return
            } catch let error as BotModePeerLinkError {
                nativePeerLinkProblems[roomID] = error.message
                return
            } catch {
                guard boundary == nativeBoundaryGeneration else { return }
                nativePeerLinkProblems[roomID] = "\(link.candidate.name) on \(link.candidate.hostName) isn't linked yet. "
                    + "Both computers need to reach each other. This chat tries again when you open it."
                return
            }
        }
        nativePeerLinkProblems[roomID] = nil
    }
}
