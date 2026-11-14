import Foundation
import Testing
@testable import Bighelp

@MainActor
struct LiveVoiceReadinessTests {
    @Test func connectedIsNotShownUntilTheMicrophoneIsRunning() async throws {
        let owner = LiveVoiceOwner(hostID: "host", authorizationID: "owner", agentID: "default", sessionID: "voice")
        let peer = ReadinessPeer()
        var voiceID = ""
        let client = LiveVoiceControlClient(owner: owner, operation: { operation, fields in
            switch operation {
            case "voice.live.status": return ["available": .boolean(true)]
            case "voice.live.offer":
                voiceID = fields["voiceId"]?.string ?? ""
                return ["voiceId": .string(voiceID), "sdp": .string(ReadinessPeer.sdp)]
            case "voice.live.jobs": return ["voiceId": .string(voiceID), "jobs": .array([])]
            default: return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            }
        }, isOwnerCurrent: { $0 == owner })
        let model = LiveVoiceModel(agentName: "Fixture", client: client, makePeer: { peer })
        defer { model.end() }
        model.start()
        for _ in 0..<100 where !peer.answerApplied { try await Task.sleep(for: .milliseconds(10)) }
        #expect(peer.answerApplied)
        model.receive(["voiceId": .string(voiceID), "event": .object(["kind": .string("started")])], owner: owner)
        #expect(model.phase == .connecting)
        peer.running = true
        for _ in 0..<50 where model.phase != .live { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .live)
        model.setSpeakerMuted(true)
        #expect(model.isSpeakerMuted)
        #expect(!model.isMuted)
        #expect(peer.playbackMuteChanges == [true])
        model.receive(["voiceId": .string(voiceID), "event": .object([
            "kind": .string("provider_error"), "fatal": .boolean(false)
        ])], owner: owner)
        #expect(model.phase == .live)
        #expect(!peer.closed)
    }

    @Test func resumedInterruptionReturnsToReadinessOnlyWhilePeerIsConnected() async throws {
        let owner = LiveVoiceOwner(hostID: "host", authorizationID: "owner", agentID: "default", sessionID: "voice")
        let peer = ReadinessPeer()
        var voiceID = ""
        let client = LiveVoiceControlClient(owner: owner, operation: { operation, fields in
            switch operation {
            case "voice.live.status": return ["available": .boolean(true)]
            case "voice.live.offer":
                voiceID = fields["voiceId"]?.string ?? ""
                return ["voiceId": .string(voiceID), "sdp": .string(ReadinessPeer.sdp)]
            case "voice.live.jobs": return ["voiceId": .string(voiceID), "jobs": .array([])]
            default: return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            }
        }, isOwnerCurrent: { $0 == owner })
        let model = LiveVoiceModel(agentName: "Fixture", client: client, makePeer: { peer })
        defer { model.end() }
        model.start()
        for _ in 0..<100 where !peer.answerApplied { try await Task.sleep(for: .milliseconds(10)) }
        peer.running = true
        model.receive(["voiceId": .string(voiceID), "event": .object(["kind": .string("started")])], owner: owner)
        for _ in 0..<200 where model.phase != .live { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .live)

        peer.onInterruption?(true)
        #expect(model.phase == .interrupted)
        peer.onInterruption?(false)
        for _ in 0..<100 where model.phase != .live { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .live)

        peer.onInterruption?(true)
        peer.onConnectionState?(.disconnected)
        #expect(model.phase == .connecting)
        peer.onInterruption?(false)
        #expect(model.phase == .connecting)
    }

    @Test func liveVoiceDefaultsToSpeakerOutput() async throws {
        let owner = LiveVoiceOwner(hostID: "host", authorizationID: "owner", agentID: "default", sessionID: "voice")
        let peer = ReadinessPeer()
        var voiceID = ""
        let client = LiveVoiceControlClient(owner: owner, operation: { operation, fields in
            switch operation {
            case "voice.live.status": return ["available": .boolean(true)]
            case "voice.live.offer":
                voiceID = fields["voiceId"]?.string ?? ""
                return ["voiceId": .string(voiceID), "sdp": .string(ReadinessPeer.sdp)]
            case "voice.live.jobs": return ["voiceId": .string(voiceID), "jobs": .array([])]
            default: return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            }
        }, isOwnerCurrent: { $0 == owner })
        let model = LiveVoiceModel(agentName: "Fixture", client: client, makePeer: { peer })
        defer { model.end() }

        model.start()
        for _ in 0..<100 where !peer.answerApplied { try await Task.sleep(for: .milliseconds(10)) }

        #expect(peer.answerApplied)
        #expect(model.speakerEnabled)
        #expect(peer.speakerChanges == [true])
    }

    @Test func liveVoiceShowsOnlyVerifiedDelegationStatus() async throws {
        let owner = LiveVoiceOwner(hostID: "host", authorizationID: "owner", agentID: "default", sessionID: "voice")
        let peer = ReadinessPeer()
        var voiceID = ""
        let client = LiveVoiceControlClient(owner: owner, operation: { operation, fields in
            switch operation {
            case "voice.live.status": return ["available": .boolean(true)]
            case "voice.live.offer":
                voiceID = fields["voiceId"]?.string ?? ""
                return ["voiceId": .string(voiceID), "sdp": .string(ReadinessPeer.sdp)]
            default: return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            }
        }, isOwnerCurrent: { $0 == owner })
        let model = LiveVoiceModel(agentName: "Fixture", client: client, makePeer: { peer })
        defer { model.end() }

        model.start()
        for _ in 0..<100 where voiceID.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!voiceID.isEmpty)

        model.receive(["voiceId": .string(voiceID), "event": .object([
            "kind": .string("delegation_status"), "state": .string("working"),
            "delegationId": .string("delegation-verified")
        ])], owner: owner)
        #expect(model.workStatus == .working)

        model.receive(["voiceId": .string(voiceID), "event": .object([
            "kind": .string("delegation_status"), "state": .string("result_sent"),
            "delegationId": .string("not-admitted")
        ])], owner: owner)
        #expect(model.workStatus == .working)

        model.receive(["voiceId": .string(voiceID), "event": .object([
            "kind": .string("delegation_status"), "state": .string("result_sent"),
            "delegationId": .string("delegation-verified")
        ])], owner: owner)
        #expect(model.workStatus == .resultSent)
    }
}

@MainActor
private final class ReadinessPeer: LiveVoiceAudioPeer {
    static let sdp = "v=0\r\na=fingerprint:sha-256 00:11\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
    var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)?
    var onAudioRoute: (@MainActor (String) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var answerApplied = false
    var running = false
    var closed = false
    var speakerChanges: [Bool] = []
    var playbackMuteChanges: [Bool] = []
    func makeOffer() async throws -> String { Self.sdp }
    func applyAnswer(_ sdp: String) async throws { answerApplied = true; onConnectionState?(.connected) }
    func setMuted(_ muted: Bool) {}
    func setPlaybackMuted(_ muted: Bool) { playbackMuteChanges.append(muted) }
    func setSpeakerEnabled(_ enabled: Bool) throws { speakerChanges.append(enabled) }
    func setDefaultSpeakerOutput() throws { speakerChanges.append(true) }
    func resumeAudio() throws {}
    func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics {
        .init(audioDeviceRunning: running)
    }
    func close() { closed = true }
}
