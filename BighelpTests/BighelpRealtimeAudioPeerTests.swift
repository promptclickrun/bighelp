import Foundation
import Testing
@testable import Bighelp

// The peers share one process-wide audio owner, so tests that start one run in turn.
@Suite(.serialized)
@MainActor
struct BighelpRealtimeAudioPeerTests {
    @Test func routeRecoveryRestoresCaptureOnlyWithValidInputAndPreservesMute() {
        var state = BighelpAudioRecoveryState()
        state.routeLost()
        #expect(state.isInterrupted)
        let invalidRouteRestore = state.routeBecameAvailable(hasValidInputRoute: false)
        #expect(!invalidRouteRestore)
        #expect(state.isInterrupted)
        let validRouteRestore = state.routeBecameAvailable(hasValidInputRoute: true)
        #expect(validRouteRestore)
        #expect(!state.isInterrupted)
        #expect(state.shouldEnableCapture)

        state.setMuted(true)
        state.routeLost()
        let mutedRouteRestore = state.routeBecameAvailable(hasValidInputRoute: true)
        #expect(mutedRouteRestore)
        #expect(!state.isInterrupted)
        #expect(state.isMuted)
        #expect(!state.shouldEnableCapture)
    }

    @Test func routeLossWithAlreadyValidReplacementRestoresInOneCallback() {
        var state = BighelpAudioRecoveryState()
        state.routeLost()
        let restored = state.routeBecameAvailable(hasValidInputRoute: true)
        #expect(restored)
        #expect(!state.isInterrupted)
    }

    @Test func interruptionRecoveryRequiresSystemResumeAndValidInput() {
        var state = BighelpAudioRecoveryState()
        state.beginInterruption()
        let declinedResume = state.endInterruption(shouldResume: false, hasValidInputRoute: true)
        #expect(!declinedResume)
        #expect(state.isInterrupted)
        let routeAfterDeclinedResume = state.routeBecameAvailable(hasValidInputRoute: true)
        #expect(!routeAfterDeclinedResume)
        #expect(state.isInterrupted)
        let explicitResume = state.explicitResume(hasValidInputRoute: true)
        #expect(explicitResume)
        #expect(!state.isInterrupted)

        state.beginInterruption()
        let missingRouteResume = state.endInterruption(shouldResume: true, hasValidInputRoute: false)
        #expect(!missingRouteResume)
        #expect(state.isInterrupted)
        let resumedAfterRoute = state.endInterruption(shouldResume: true, hasValidInputRoute: true)
        #expect(resumedAfterRoute)
        #expect(!state.isInterrupted)
    }

    @Test func optionalAPIUsesItsOwnVoiceContract() {
        #expect(LiveVoiceProvider.codexSubscription.defaultVoice == "cove")
        #expect(LiveVoiceProvider.apiKey.defaultVoice == "marin")
        #expect(!LiveVoiceProvider.apiKey.voices.contains("cove"))
    }

    @Test func speakerPolicyAvoidsDuplicateOverrideAndRespectsExternalRoute() {
        #expect(BighelpRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .defaultSpeaker, hasExternalRoute: false, currentBuiltInSpeaker: false))
        #expect(!BighelpRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .defaultSpeaker, hasExternalRoute: false, currentBuiltInSpeaker: true))
        #expect(!BighelpRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .defaultSpeaker, hasExternalRoute: true, currentBuiltInSpeaker: false))
        #expect(BighelpRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .forceSpeaker, hasExternalRoute: true, currentBuiltInSpeaker: false))
        #expect(!BighelpRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .forceSpeaker, hasExternalRoute: true, currentBuiltInSpeaker: true))
        #expect(!BighelpRealtimeAudioPeer.shouldApplySpeakerOutput(
            policy: .systemRoute, hasExternalRoute: false, currentBuiltInSpeaker: false))
    }

    @Test func nativeOfferIsAudioOnlyWithoutAProviderDataChannel() async throws {
        let peer = BighelpRealtimeAudioPeer(captureEnabled: false)
        defer { peer.close() }
        let offer = try await peer.makeOffer()
        #expect(offer.contains("m=audio "))
        #expect(!offer.contains("m=video "))
        #expect(!offer.contains("m=application "))
        #expect(offer.contains("a=fingerprint:"))
        #expect(offer.contains("a=ice-ufrag:"))
        if let endpoint = ProcessInfo.processInfo.environment["BIGHELP_SUBSCRIPTION_PROBE"],
           let url = URL(string: endpoint) {
            #expect(url.host == "127.0.0.1")
            var request = URLRequest(url: url.appending(path: "offer"))
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["sdp": offer])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 55
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                Issue.record("Subscription call refused: \(result?["error"] as? String ?? "unknown")")
                return
            }
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let answer = try #require(object["sdp"] as? String)
            try await peer.applyAnswer(answer)
            if ProcessInfo.processInfo.environment["BIGHELP_EXPECT_AUDIO"] == "1" {
                var speak = URLRequest(url: url.appending(path: "speak"))
                speak.httpMethod = "POST"; speak.httpBody = Data("{}".utf8)
                _ = try await URLSession.shared.data(for: speak)
                var received = false
                for _ in 0..<15 {
                    try await Task.sleep(for: .seconds(1))
                    let stats = try await peer.statistics()
                    if stats.hasInboundMedia { received = true; break }
                }
                #expect(received, "Actual subscription audio must reach the native peer")
            } else {
                try await Task.sleep(for: .seconds(3))
            }
            var close = URLRequest(url: url.appending(path: "close"))
            close.httpMethod = "POST"
            close.httpBody = Data("{}".utf8)
            _ = try await URLSession.shared.data(for: close)
        }
    }

    /// The call's WebRTC audio session is not the coordinator's, so anything the coordinator
    /// configured or deactivated meanwhile would land on the live call.
    @Test func whileTheCallOwnsAudioNothingElseCanTakeTheSharedSession() async throws {
        let session = CountingAudioSession()
        let coordinator = VoiceAudioSessionCoordinator(session: session)
        let peer = BighelpRealtimeAudioPeer(captureEnabled: false, sessionCoordinator: coordinator)
        defer { peer.close() }
        _ = try await peer.makeOffer()

        #expect(throws: (any Error).self) { _ = try coordinator.acquire(for: .conversation) }
        #expect(throws: (any Error).self) { _ = try coordinator.acquire(for: .playback) }
        #expect(coordinator.claimCount == 0)
        #expect(session.calls.isEmpty, "The shared session was touched under the live call: \(session.calls)")

        peer.close()
        let after = try coordinator.acquire(for: .conversation)
        #expect(session.calls == ["configure", "activate"], "Others work again once the call has ended")
        after.release()
    }

    /// The hold music takes a claim and lets go of it on every wait. Letting go with no other claim
    /// used to deactivate the session, under the call.
    @Test func holdMusicReleasingDuringTheCallNeverDeactivatesTheSession() async throws {
        let session = CountingAudioSession()
        let coordinator = VoiceAudioSessionCoordinator(session: session)
        let peer = BighelpRealtimeAudioPeer(captureEnabled: false, sessionCoordinator: coordinator)
        defer { peer.close() }
        _ = try await peer.makeOffer()

        let music = AVAudioPlayerHoldMusic(sessionCoordinator: coordinator)
        music.start()
        #expect(!music.isPlaying, "Hold music must stay silent when it can't have the audio")
        music.stop()
        try await Task.sleep(for: .milliseconds(200))

        #expect(coordinator.claimCount == 0, "No claim is left pinned")
        #expect(session.calls.isEmpty, "The session saw \(session.calls)")
    }

    /// A call can't start over someone else's claim; it never tears that one down.
    @Test func theCallRefusesToStartWhileAClaimHoldsTheSession() async throws {
        let session = CountingAudioSession()
        let coordinator = VoiceAudioSessionCoordinator(session: session)
        let claim = try coordinator.acquire(for: .conversation)
        let peer = BighelpRealtimeAudioPeer(captureEnabled: false, sessionCoordinator: coordinator)
        defer { peer.close() }

        await #expect(throws: BighelpRealtimeAudioPeer.Failure.self) { _ = try await peer.makeOffer() }
        #expect(session.calls == ["configure", "activate"])
        claim.release()
        #expect(session.calls == ["configure", "activate", "deactivate"])
    }
}

private final class CountingAudioSession: VoiceAudioSessionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var calls: [String] { lock.withLock { recorded } }
    func configure(for use: VoiceAudioUse) throws { lock.withLock { recorded.append("configure") } }
    func setActive(_ active: Bool) throws { lock.withLock { recorded.append(active ? "activate" : "deactivate") } }
}
