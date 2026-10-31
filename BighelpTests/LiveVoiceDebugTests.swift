import Foundation
import Testing
@testable import Bighelp

/// Settings › Voice › Debug: the call screen shows only what its switches ask for, and only in Nerd Mode;
/// Restart sound reaches only a Gemini Live call in progress, and never keeps one alive.
@MainActor
struct LiveVoiceDebugTests {
    @Test func theReportIsHiddenByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "LiveVoiceDebugTests.\(UUID().uuidString)"))
        // A fresh install, with Nerd Mode turned on: the switches have never been set.
        let parts = LiveVoiceDebug.parts(nerdMode: true,
                                         showsReport: defaults.bool(forKey: LiveVoiceDebug.showsReportKey),
                                         showsCopy: defaults.bool(forKey: LiveVoiceDebug.showsCopyKey))
        #expect(parts == LiveVoiceDebug.Parts())
        #expect(!parts.any)
        #expect(LiveVoiceDebug.parts(nerdMode: false) == LiveVoiceDebug.Parts())
        for key in [LiveVoiceDebug.showsReportKey, LiveVoiceDebug.showsCopyKey] {
            #expect(key.hasPrefix("bighelp.voice.debug."))
        }
    }

    @Test func eachSwitchShowsOnlyItsOwnPart() {
        #expect(LiveVoiceDebug.parts(nerdMode: true, showsReport: true) == .init(report: true, copy: false))
        #expect(LiveVoiceDebug.parts(nerdMode: true, showsCopy: true) == .init(report: false, copy: true))
        #expect(LiveVoiceDebug.parts(nerdMode: true, showsReport: true, showsCopy: true)
                == .init(report: true, copy: true))
    }

    @Test func turningNerdModeOffHidesBothParts() {
        #expect(LiveVoiceDebug.parts(nerdMode: false, showsReport: true, showsCopy: true) == LiveVoiceDebug.Parts())
    }

    @Test func restartSoundDoesNothingWithNoCall() {
        let current = LiveVoiceCurrentCall()
        let peer = DebugPeer()
        let model = Self.model(peer: peer)
        model.currentCall = current
        // Made but never started: no call is in progress.
        #expect(current.call == nil)
        #expect(!current.canRestartSound)
        #expect(!current.restartSound())
        #expect(peer.restarts == 0)
    }

    @Test func restartSoundReachesTheCallInProgressUntilItEnds() async throws {
        let current = LiveVoiceCurrentCall()
        let peer = DebugPeer()
        let model = Self.model(peer: peer)
        model.currentCall = current
        model.start()
        defer { model.end() }
        #expect(current.call === model)
        for _ in 0..<100 where !peer.answered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(current.canRestartSound)
        #expect(current.restartSound())
        #expect(peer.restarts == 1)

        model.end()
        #expect(current.call == nil)
        #expect(!current.canRestartSound)
        #expect(!current.restartSound())
        #expect(peer.restarts == 1)
    }

    /// GPT-Live's sound plays through WebRTC, which has no player of the app's own to restart.
    @Test func aCallWithoutASoundReportCantRestartSound() async throws {
        let current = LiveVoiceCurrentCall()
        let peer = DebugPeer()
        let model = Self.model(peer: peer.plain)
        model.currentCall = current
        model.start()
        defer { model.end() }
        for _ in 0..<100 where !peer.answered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(current.call === model)
        #expect(!current.canRestartSound)
        #expect(!current.restartSound())
    }

    @Test func anOlderCallEndingLeavesTheNewerOne() {
        let current = LiveVoiceCurrentCall()
        let older = Self.model(peer: DebugPeer())
        let newer = Self.model(peer: DebugPeer())
        current.began(older)
        current.began(newer)
        current.ended(older)
        #expect(current.call === newer)
    }

    @Test func theCurrentCallNeverKeepsACallAlive() {
        let current = LiveVoiceCurrentCall()
        weak var released: LiveVoiceModel?
        do {
            let model = Self.model(peer: DebugPeer())
            current.began(model)
            released = model
        }
        #expect(released == nil)
        #expect(current.call == nil)
        #expect(!current.restartSound())
    }

    private static func model(peer: any LiveVoiceAudioPeer) -> LiveVoiceModel {
        let owner = LiveVoiceOwner(hostID: "host", authorizationID: "owner", agentID: "default", sessionID: "voice")
        let client = LiveVoiceControlClient(owner: owner, operation: { operation, fields in
            let id = fields["voiceId"]?.string ?? ""
            switch operation {
            case "voice.live.status": return ["available": .boolean(true)]
            case "voice.live.offer": return ["voiceId": .string(id), "sdp": .string(DebugPeer.sdp)]
            default: return ["voiceId": .string(id), "closed": .boolean(true)]
            }
        }, isOwnerCurrent: { $0 == owner })
        return LiveVoiceModel(agentName: "Fixture", client: client, makePeer: { peer })
    }
}

/// A Gemini-like peer that keeps a sound report and counts restarts; `plain` is the same peer without one.
@MainActor
private final class DebugPeer: LiveVoiceAudioPeer, LiveVoiceAudioReporting {
    static let sdp = "v=0\r\na=fingerprint:sha-256 00:11\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
    var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)?
    var onAudioRoute: (@MainActor (String) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var answered = false
    var restarts = 0
    lazy var plain: any LiveVoiceAudioPeer = PlainPeer(owner: self)

    func makeOffer() async throws -> String { Self.sdp }
    func applyAnswer(_ sdp: String) async throws { answered = true; onConnectionState?(.connected) }
    func setMuted(_ muted: Bool) {}
    func setPlaybackMuted(_ muted: Bool) {}
    func setSpeakerEnabled(_ enabled: Bool) throws {}
    func setDefaultSpeakerOutput() throws {}
    func resumeAudio() throws {}
    func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics { .init(audioDeviceRunning: true) }
    func close() {}
    func audioReport() -> String { "Call audio, 0 s" }
    func restartPlayback() { restarts += 1 }

    /// Forwards everything but the report, like GPT-Live's WebRTC peer.
    @MainActor
    private final class PlainPeer: LiveVoiceAudioPeer {
        unowned let owner: DebugPeer
        init(owner: DebugPeer) { self.owner = owner }
        var onConnectionState: (@MainActor (BighelpRealtimeAudioPeer.ConnectionState) -> Void)? {
            get { owner.onConnectionState }
            set { owner.onConnectionState = newValue }
        }
        var onAudioRoute: (@MainActor (String) -> Void)?
        var onInterruption: (@MainActor (Bool) -> Void)?
        func makeOffer() async throws -> String { try await owner.makeOffer() }
        func applyAnswer(_ sdp: String) async throws { try await owner.applyAnswer(sdp) }
        func setMuted(_ muted: Bool) {}
        func setPlaybackMuted(_ muted: Bool) {}
        func setSpeakerEnabled(_ enabled: Bool) throws {}
        func setDefaultSpeakerOutput() throws {}
        func resumeAudio() throws {}
        func statistics() async throws -> BighelpRealtimeAudioPeer.MediaStatistics { try await owner.statistics() }
        func close() {}
    }
}
