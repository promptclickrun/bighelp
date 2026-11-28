import Foundation
import SwiftUI
import Testing
import UIKit
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

    @Test func backgroundScenePhaseKeepsLiveCallRunningAndDisappearEndsIt() async throws {
        let owner = LiveVoiceOwner(hostID: "host", authorizationID: "owner", agentID: "default", sessionID: "voice")
        let peer = ReadinessPeer()
        var voiceID = ""
        var closeCount = 0
        let client = LiveVoiceControlClient(owner: owner, operation: { operation, fields in
            switch operation {
            case "voice.live.status": return ["available": .boolean(true)]
            case "voice.live.offer":
                voiceID = fields["voiceId"]?.string ?? ""
                return ["voiceId": .string(voiceID), "sdp": .string(ReadinessPeer.sdp)]
            case "voice.live.close":
                closeCount += 1
                return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            default: return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            }
        }, isOwnerCurrent: { $0 == owner })
        var holdCount = 0
        let model = LiveVoiceModel(agentName: "Fixture", client: client, makePeer: { peer }, holdHostConnection: {
            holdCount += 1
            return { holdCount -= 1 }
        })
        defer { model.end() }

        let host = LiveVoiceSceneHostState()
        let controller = UIHostingController(rootView: LiveVoiceSceneHost(state: host, model: model))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        for _ in 0..<200 where !peer.answerApplied { try await Task.sleep(for: .milliseconds(10)) }
        peer.running = true
        model.receive(["voiceId": .string(voiceID), "event": .object(["kind": .string("started")])], owner: owner)
        for _ in 0..<200 where model.phase != .live { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .live)
        #expect(holdCount == 1)

        // Locking the phone / backgrounding the app must keep the live call open and audio running.
        host.scenePhase = .inactive
        try await Task.sleep(for: .milliseconds(50))
        host.scenePhase = .background
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .live)
        #expect(model.isCallOpen)
        #expect(!peer.closed)
        #expect(closeCount == 0)
        #expect(holdCount == 1)

        // Coming back to the foreground leaves the same call running.
        host.scenePhase = .active
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.phase == .live)
        #expect(!peer.closed)

        // Dismissing the view (onDisappear) ends the call cleanly and releases the host hold.
        host.isPresented = false
        for _ in 0..<200 where model.phase != .ended { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .ended)
        #expect(peer.closed)
        #expect(holdCount == 0)
        for _ in 0..<200 where closeCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(closeCount == 1)
    }

    @Test func interruptionEndedWithoutResumeEndsOpenCallAndReleasesHostHold() async throws {
        let owner = LiveVoiceOwner(hostID: "host", authorizationID: "owner", agentID: "default", sessionID: "voice")
        let peer = ReadinessPeer()
        var voiceID = ""
        var closeCount = 0
        let client = LiveVoiceControlClient(owner: owner, operation: { operation, fields in
            switch operation {
            case "voice.live.status": return ["available": .boolean(true)]
            case "voice.live.offer":
                voiceID = fields["voiceId"]?.string ?? ""
                return ["voiceId": .string(voiceID), "sdp": .string(ReadinessPeer.sdp)]
            case "voice.live.close":
                closeCount += 1
                return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            default: return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            }
        }, isOwnerCurrent: { $0 == owner })
        var holdCount = 0
        let model = LiveVoiceModel(agentName: "Fixture", client: client, makePeer: { peer }, holdHostConnection: {
            holdCount += 1
            return { holdCount -= 1 }
        })
        defer { model.end() }

        model.start()
        for _ in 0..<100 where !peer.answerApplied { try await Task.sleep(for: .milliseconds(10)) }
        peer.running = true
        model.receive(["voiceId": .string(voiceID), "event": .object(["kind": .string("started")])], owner: owner)
        for _ in 0..<200 where model.phase != .live { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .live)
        #expect(holdCount == 1)

        // Incoming phone call / Siri takes audio -> paused.
        peer.onInterruption?(true)
        #expect(model.phase == .interrupted)
        #expect(model.isCallOpen)
        #expect(!peer.closed)

        // Interruption ends with shouldResume == false -> call ends cleanly rather than hanging.
        peer.onInterruptionEndedWithoutResume?()
        #expect(model.phase == .ended)
        #expect(!model.isCallOpen)
        #expect(peer.closed)
        #expect(holdCount == 0)
        for _ in 0..<200 where closeCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(closeCount == 1)
    }

    @Test func hostConnectionDropWhileOpenEndsCallWithoutZombieSession() async throws {
        let owner = LiveVoiceOwner(hostID: "host", authorizationID: "owner", agentID: "default", sessionID: "voice")
        let peer = ReadinessPeer()
        var voiceID = ""
        var ownerIsCurrent = true
        let client = LiveVoiceControlClient(owner: owner, operation: { operation, fields in
            switch operation {
            case "voice.live.status": return ["available": .boolean(true)]
            case "voice.live.offer":
                voiceID = fields["voiceId"]?.string ?? ""
                return ["voiceId": .string(voiceID), "sdp": .string(ReadinessPeer.sdp)]
            default: return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            }
        }, isOwnerCurrent: { $0 == owner && ownerIsCurrent })
        var holdCount = 0
        let model = LiveVoiceModel(agentName: "Fixture", client: client, makePeer: { peer }, holdHostConnection: {
            holdCount += 1
            return { holdCount -= 1 }
        })
        defer { model.end() }

        model.start()
        for _ in 0..<100 where !peer.answerApplied { try await Task.sleep(for: .milliseconds(10)) }
        peer.running = true
        model.receive(["voiceId": .string(voiceID), "event": .object(["kind": .string("started")])], owner: owner)
        for _ in 0..<200 where model.phase != .live { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .live)
        #expect(holdCount == 1)

        // Simulate host socket disconnect while the phone is locked: owner is no longer current.
        ownerIsCurrent = false
        for _ in 0..<300 where model.phase != .ended { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .ended)
        #expect(!model.isCallOpen)
        #expect(peer.closed)
        #expect(holdCount == 0)
    }

    @Test func resumedInterruptionRestoresExplicitMuteState() async throws {
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
        for _ in 0..<100 where !peer.answerApplied { try await Task.sleep(for: .milliseconds(10)) }
        peer.running = true
        model.receive(["voiceId": .string(voiceID), "event": .object(["kind": .string("started")])], owner: owner)
        for _ in 0..<200 where model.phase != .live { try await Task.sleep(for: .milliseconds(10)) }

        model.setMuted(true)
        #expect(peer.muteChanges == [true])

        peer.onInterruption?(true)
        #expect(model.phase == .interrupted)
        peer.onInterruption?(false)
        #expect(model.phase == .live)
        #expect(model.isMuted)
        #expect(peer.muteChanges == [true, true])
    }
}

@MainActor
@Observable
private final class LiveVoiceSceneHostState {
    var scenePhase: ScenePhase = .active
    var isPresented = true
}

private struct LiveVoiceSceneHost: View {
    let state: LiveVoiceSceneHostState
    let model: LiveVoiceModel

    var body: some View {
        Group {
            if state.isPresented {
                LiveVoiceView(model: model)
            } else {
                Color.clear
            }
        }
        .environment(\.scenePhase, state.scenePhase)
    }
}

@MainActor
private final class ReadinessPeer: LiveVoiceAudioPeer {
    static let sdp = "v=0\r\na=fingerprint:sha-256 00:11\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
    var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)?
    var onAudioRoute: (@MainActor (String) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var onInterruptionEndedWithoutResume: (@MainActor () -> Void)?
    var answerApplied = false
    var running = false
    var closed = false
    var muteChanges: [Bool] = []
    var speakerChanges: [Bool] = []
    var playbackMuteChanges: [Bool] = []
    func makeOffer() async throws -> String { Self.sdp }
    func applyAnswer(_ sdp: String) async throws { answerApplied = true; onConnectionState?(.connected) }
    func setMuted(_ muted: Bool) { muteChanges.append(muted) }
    func setPlaybackMuted(_ muted: Bool) { playbackMuteChanges.append(muted) }
    func setSpeakerEnabled(_ enabled: Bool) throws { speakerChanges.append(enabled) }
    func setDefaultSpeakerOutput() throws { speakerChanges.append(true) }
    func resumeAudio() throws {}
    func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics {
        .init(audioDeviceRunning: running)
    }
    func close() { closed = true }
}
