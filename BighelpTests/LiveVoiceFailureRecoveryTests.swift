import Foundation
import Observation
import Testing
@testable import Bighelp

@MainActor
struct LiveVoiceFailureRecoveryTests {
    private let owner = LiveVoiceOwner(hostID: "host", authorizationID: "owner", agentID: "default", sessionID: "voice")

    @Test func failedStartCanBeRetriedOnTheSameScreen() async throws {
        var offers = 0
        var voiceID = ""
        let client = LiveVoiceControlClient(owner: owner, operation: { operation, fields in
            switch operation {
            case "voice.live.status": return ["available": .boolean(true)]
            case "voice.live.offer":
                offers += 1
                voiceID = fields["voiceId"]?.string ?? ""
                // The first call fails on the host the way a plugin 503 does.
                if offers == 1 { throw WorkspaceClientError.outcomeUnknown }
                return ["voiceId": .string(voiceID), "sdp": .string(RecoveryPeer.sdp)]
            case "voice.live.close":
                try await Task.sleep(for: .milliseconds(300))  // Host cleanup takes a moment.
                return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            default: return ["voiceId": .string(voiceID), "closed": .boolean(true)]
            }
        }, isOwnerCurrent: { $0 == owner })
        var peers: [RecoveryPeer] = []
        let model = LiveVoiceModel(agentName: "Fixture", client: client, makePeer: {
            let peer = RecoveryPeer(); peers.append(peer); return peer
        })
        defer { model.end() }

        model.start()
        for _ in 0..<200 where model.phase != .failed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .failed)
        #expect(model.errorMessage == "Your computer couldn't start the Codex voice call. Try again, or take turns instead.")

        // The screen must hear that cleanup finished, or Start stays greyed out.
        #expect(!model.canStart)
        let startAvailabilityChanged = ObservationFlag()
        _ = withObservationTracking { model.canStart } onChange: { startAvailabilityChanged.set() }
        for _ in 0..<200 where !model.canStart { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.canStart)
        #expect(startAvailabilityChanged.value)

        model.start()
        for _ in 0..<200 where peers.last?.answerApplied != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(offers == 2)
        #expect(peers.last?.answerApplied == true)
        #expect(model.errorMessage == nil)
    }

    @Test func hostAnswersReadInPlainWords() {
        #expect(LiveVoiceModel.safeMessage(WorkspaceClientError.authenticationRequired)
            == "Sign in to your computer again, then try live voice.")
        #expect(LiveVoiceModel.safeMessage(WorkspaceClientError.rejected(code: "voice_already_active"))
            == "Another live voice call is still open with your computer. End it, then try again.")
        #expect(LiveVoiceModel.safeMessage(WorkspaceClientError.unavailable(.unsupportedOperation))
            == "Live voice isn't set up on your computer. Take turns instead.")
        #expect(LiveVoiceModel.safeMessage(WorkspaceClientError.transportUnavailable)
            == "Your computer couldn't start the Codex voice call. Try again, or take turns instead.")
        #expect(LiveVoiceModel.safeMessage(LiveVoiceControlError.unavailable)
            == LiveVoiceControlError.unavailable.localizedDescription)
        // The plugin's fixed provider reasons (loopdy-plugin #50).
        #expect(LiveVoiceModel.safeMessage(WorkspaceClientError.rejected(code: "voice_provider_rate_limited"))
            == "Codex is limiting voice calls right now. Wait a minute, then try again.")
        #expect(LiveVoiceModel.safeMessage(WorkspaceClientError.rejected(code: "voice_provider_authentication_failed"))
            == "Codex sign-in on your computer didn't work. Run `hermes auth add openai-codex` there, then try again.")
        // A multi-profile host that can't read the agent's own sign-in (#14).
        #expect(LiveVoiceModel.safeMessage(WorkspaceClientError.rejected(code: "voice_provider_credentials_unavailable"))
            == "bighelp couldn't read this bot's Codex sign-in on your computer. Update the bighelp plugin and restart Hermes, then try again.")
        #expect(LiveVoiceModel.safeMessage(WorkspaceClientError.rejected(code: "voice_provider_setup_timeout"))
            == "Codex took too long to start the call. Try again.")
        #expect(LiveVoiceModel.safeMessage(WorkspaceClientError.rejected(code: "voice_provider_failed"))
            == "Codex couldn't start the voice call. Try again, or take turns instead.")
    }
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

@MainActor
private final class RecoveryPeer: LiveVoiceAudioPeer {
    static let sdp = "v=0\r\na=fingerprint:sha-256 00:11\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
    var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)?
    var onAudioRoute: (@MainActor (String) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var answerApplied = false
    func makeOffer() async throws -> String { Self.sdp }
    func applyAnswer(_ sdp: String) async throws { answerApplied = true; onConnectionState?(.connected) }
    func setMuted(_ muted: Bool) {}
    func setPlaybackMuted(_ muted: Bool) {}
    func setSpeakerEnabled(_ enabled: Bool) throws {}
    func setDefaultSpeakerOutput() throws {}
    func resumeAudio() throws {}
    func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics { .init(audioDeviceRunning: false) }
    func close() {}
}
