import Foundation

/// Voices for agents on other computers in a Team Call: each speaks with its
/// own computer's Hermes voice. The first piece connects to that computer and
/// keeps the connection until the call ends.
@MainActor
final class TeamCallPeerVoices {
    private let peers: any HermesBotModePeerHosts
    private var connections: [String: Task<any HermesBotModePeerConnection, any Error>] = [:]
    private var outputs: [String: DirectHermesVoiceSpeechOutput] = [:]
    private var isReleased = false

    init(peers: any HermesBotModePeerHosts) {
        self.peers = peers
    }

    static func key(peerID: String, profileID: String) -> String { "\(peerID)/\(profileID)" }

    /// A voice for a `peerID/profile` key; nil for this computer's own profiles.
    func voice(for key: String) -> (any TeamCallVoice)? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return Voice(owner: self, peerID: parts[0], profileID: parts[1])
    }

    /// Lets every computer's connection go.
    func releaseAll() {
        isReleased = true
        let held = connections.values
        connections = [:]
        outputs = [:]
        for task in held {
            Task { @MainActor in (try? await task.value)?.release() }
        }
    }

    fileprivate func output(peerID: String, profileID: String) async throws -> DirectHermesVoiceSpeechOutput {
        guard !isReleased else { throw CancellationError() }
        let key = Self.key(peerID: peerID, profileID: profileID)
        if let output = outputs[key] { return output }
        let task = connections[peerID] ?? Task { @MainActor [peers] in try await peers.connect(peerID: peerID) }
        connections[peerID] = task
        let connection: any HermesBotModePeerConnection
        do { connection = try await task.value } catch {
            // Try again on the next piece instead of keeping the failure.
            if connections[peerID] == task { connections[peerID] = nil }
            throw error
        }
        guard !isReleased else {
            connection.release()
            throw CancellationError()
        }
        let output = DirectHermesVoiceSpeechOutput(workspace: connection.workspace, owner: connection.owner,
                                                   profileID: profileID, currentOwner: connection.currentOwner)
        outputs[key] = output
        return output
    }

    private final class Voice: TeamCallVoice {
        weak var owner: TeamCallPeerVoices?
        let peerID: String
        let profileID: String

        init(owner: TeamCallPeerVoices, peerID: String, profileID: String) {
            self.owner = owner
            self.peerID = peerID
            self.profileID = profileID
        }

        func synthesize(_ text: String) async throws -> TeamCallAudio {
            guard let owner else { throw CancellationError() }
            return try await owner.output(peerID: peerID, profileID: profileID).synthesize(text)
        }
    }
}
