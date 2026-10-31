import AVFoundation
import Foundation
#if os(visionOS)
@preconcurrency import LiveKitWebRTC // Names mapped in WebRTCVisionNames.swift.
#else
@preconcurrency import WebRTC
#endif

/// Pure lifecycle state for native capture recovery. The peer owns the actual
/// audio session and track; keeping these transitions separate makes route and
/// interruption behavior testable without constructing WebRTC resources.
struct BighelpAudioRecoveryState: Equatable, Sendable {
    private(set) var isMuted = false
    private(set) var isInterrupted = false
    private(set) var systemInterruptionEnded = true
    private(set) var systemResumeAllowed = true

    var shouldEnableCapture: Bool { !isMuted && !isInterrupted }

    mutating func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    mutating func beginInterruption() {
        isInterrupted = true
        systemInterruptionEnded = false
        systemResumeAllowed = false
    }

    mutating func endInterruption(shouldResume: Bool, hasValidInputRoute: Bool) -> Bool {
        systemInterruptionEnded = true
        systemResumeAllowed = shouldResume
        guard shouldResume, hasValidInputRoute, isInterrupted else { return false }
        isInterrupted = false
        return true
    }

    mutating func routeLost() {
        isInterrupted = true
    }

    mutating func routeBecameAvailable(hasValidInputRoute: Bool) -> Bool {
        guard systemInterruptionEnded, systemResumeAllowed, hasValidInputRoute,
              isInterrupted else { return false }
        isInterrupted = false
        return true
    }

    mutating func explicitResume(hasValidInputRoute: Bool) -> Bool {
        guard systemInterruptionEnded, hasValidInputRoute, isInterrupted else { return false }
        systemResumeAllowed = true
        isInterrupted = false
        return true
    }
}

/// The default route preference is reapplied when WebRTC starts or changes its
/// audio unit. A default speaker choice respects a user-selected external
/// route; an explicit speaker choice may override it.
enum BighelpSpeakerOutputPolicy: Equatable, Sendable {
    case none
    case defaultSpeaker
    case forceSpeaker
    case systemRoute
}

/// Native media only. Signalling, captions and jobs belong to the authenticated
/// bighelp control transport; this peer never creates an SCTP data channel.
@MainActor
final class BighelpRealtimeAudioPeer: NSObject {
    enum Failure: Error, LocalizedError, Sendable {
        case closed, busy, microphoneDenied, audioUnavailable, negotiation, timeout, invalidSDP

        var errorDescription: String? {
            switch self {
            case .closed: "The voice connection has closed."
            case .busy: "Another native voice connection is using audio."
            case .microphoneDenied: "Allow microphone access in Settings to start live voice."
            case .audioUnavailable: "Audio is unavailable. Check your audio route and try again."
            case .negotiation: "The native audio connection could not be negotiated."
            case .timeout: "The native audio connection timed out."
            case .invalidSDP: "The host returned an invalid audio connection."
            }
        }
    }

    enum ConnectionState: String, Sendable {
        case idle, connecting, connected, disconnected, failed, closed
    }

    /// Counts from the native RTP/audio statistics, never transcript heuristics.
    /// Received samples/energy are decoding evidence, not proof a person heard audio.
    struct MediaStatistics: Equatable, Sendable {
        /// The shape of one native WebRTC statistic. Values and identifiers are
        /// deliberately excluded so the diagnostic surface cannot expose SDP,
        /// candidate addresses, or audio payload metadata.
        struct RTCStatisticShape: Equatable, Sendable {
            var type: String
            var kind: String?
            var mediaType: String?
            var diagnosticValues: [String: String] = [:]

            var metadataDisplayValue: String {
                var parts = [type]
                if let kind { parts.append("kind=\(kind)") }
                if let mediaType { parts.append("mediaType=\(mediaType)") }
                return parts.joined(separator: " ")
            }

            var displayValue: String {
                var parts = [metadataDisplayValue]
                for key in ["packetsSent", "bytesSent", "totalAudioEnergy", "audioLevel", "totalSamplesDuration"] {
                    if let value = diagnosticValues[key] { parts.append("\(key)=\(value)") }
                }
                return parts.joined(separator: " ")
            }

            var hasDiagnosticValues: Bool { !diagnosticValues.isEmpty }
        }

        var bytesSent: UInt64 = 0
        var bytesReceived: UInt64 = 0
        var packetsSent: UInt64 = 0
        var packetsReceived: UInt64 = 0
        var samplesReceived: UInt64 = 0
        var concealedSamples: UInt64 = 0
        var inputAudioLevel: Double = 0
        var outputAudioLevel: Double = 0
        var receivedAudioEnergy: Double = 0
        var emittedSamples: UInt64 = 0
        var audioDeviceRunning = false
        /// Populated only in DEBUG builds for the native media disclosure.
        var peerConnectionState = "unknown"
        var iceConnectionState = "unknown"
        var localSenderTrackEnabled: Bool?
        var inputRoutePresent = false
        var rtcStatisticShapes: [RTCStatisticShape] = []

        var hasOutboundMedia: Bool { packetsSent > 0 && bytesSent > 0 }
        var hasInboundMedia: Bool { packetsReceived > 0 && bytesReceived > 0 }
    }

    var onConnectionState: (@MainActor (ConnectionState) -> Void)?
    var onAudioRoute: (@MainActor (String) -> Void)?
    var onInterruption: (@MainActor (Bool) -> Void)?
    var isMuted: Bool { recoveryState.isMuted }
    var isInterrupted: Bool { recoveryState.isInterrupted }
    private(set) var connectionState: ConnectionState = .idle
    private(set) var audioDeviceRunning = false

    private let captureEnabled: Bool
    private let sessionCoordinator: VoiceAudioSessionCoordinator
    private static let initializedSSL = RTCInitializeSSL()
    private let resources = LiveVoicePeerResources()
    private var started = false
    private var closed = false
    private var recoveryState = BighelpAudioRecoveryState()
    private var speakerOutputPolicy: BighelpSpeakerOutputPolicy = .none
    private var pending: [UUID: (Failure) -> Void] = [:]

    /// Inert: no permission prompt, audio unit, factory or network on construction.
    /// `false` builds a receive-only audio offer without microphone access.
    init(captureEnabled: Bool = true, sessionCoordinator: VoiceAudioSessionCoordinator = .shared) {
        self.captureEnabled = captureEnabled
        self.sessionCoordinator = sessionCoordinator
        super.init()
    }

    /// Call only from explicit Start intent. ICE must finish within eight seconds;
    /// no partial offer is sent because this protocol has no trickle-ICE endpoint.
    func makeOffer() async throws -> String {
        guard !closed else { throw Failure.closed }
        guard !started else { throw Failure.busy }
        started = true
        do {
            if captureEnabled {
                let permitted = await AVAudioApplication.requestRecordPermission()
                try Task.checkCancellation()
                guard !closed else { throw Failure.closed }
                guard permitted else { throw Failure.microphoneDenied }
            }
            try resources.acquireAudio(captureEnabled: captureEnabled, coordinator: sessionCoordinator)
            let audioSession = RTCAudioSession.sharedInstance()
            audioSession.add(self)
            resources.audioDelegate = self
            guard Self.initializedSSL else { throw Failure.negotiation }
            let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
            resources.factory = factory
            let configuration = RTCConfiguration()
            configuration.sdpSemantics = .unifiedPlan
            configuration.continualGatheringPolicy = .gatherOnce
            configuration.bundlePolicy = .maxBundle
            configuration.rtcpMuxPolicy = .require
            // No third-party STUN service or credentials. The remote ICE-lite
            // candidate set supplies the server path; qualify NAT coverage live.
            configuration.iceServers = []
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let connection = factory.peerConnection(
                with: configuration, constraints: constraints, delegate: self
            ) else { throw Failure.negotiation }
            resources.connection = connection
            let transceiver = RTCRtpTransceiverInit()
            if captureEnabled {
                let source = factory.audioSource(with: constraints)
                let track = factory.audioTrack(with: source, trackId: "loopdy-live-audio")
                track.isEnabled = captureEnabled && !isMuted && !isInterrupted
                resources.track = track
                transceiver.direction = .sendRecv
                guard connection.addTransceiver(with: track, init: transceiver) != nil else {
                    throw Failure.negotiation
                }
            } else {
                transceiver.direction = .recvOnly
                guard connection.addTransceiver(of: .audio, init: transceiver) != nil else {
                    throw Failure.negotiation
                }
            }
            publish(.connecting)
            let offer: String = try await callback { finish in
                connection.offer(for: constraints) { description, error in
                    guard error == nil, let description else {
                        finish(.failure(.negotiation)); return
                    }
                    finish(.success(description.sdp))
                }
            }
            let _: Bool = try await callback { finish in
                connection.setLocalDescription(RTCSessionDescription(type: .offer, sdp: offer)) { error in
                    finish(error == nil ? .success(true) : .failure(.negotiation))
                }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while connection.iceGatheringState != .complete {
                try Task.checkCancellation()
                guard !closed else { throw Failure.closed }
                guard ContinuousClock.now < deadline else { throw Failure.timeout }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            guard !closed, let sdp = connection.localDescription?.sdp else { throw Failure.closed }
            try Self.validateAudioSDP(sdp)
            return sdp
        } catch {
            close()
            throw error
        }
    }

    func applyAnswer(_ sdp: String) async throws {
        guard !closed, let connection = resources.connection,
              connection.signalingState == .haveLocalOffer else { throw Failure.closed }
        try Self.validateAudioSDP(sdp)
        let _: Bool = try await callback { finish in
            connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                finish(error == nil ? .success(true) : .failure(.negotiation))
            }
        }
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        // The native receiver plays its audio track. Never decode/play sideband
        // output_audio.delta a second time.
    }

    func setMuted(_ muted: Bool) {
        recoveryState.setMuted(muted)
        applyCaptureState()
    }

    func setPlaybackMuted(_ muted: Bool) {
        resources.connection?.receivers.forEach { receiver in
            receiver.track?.isEnabled = !muted
        }
    }

    func setSpeakerEnabled(_ enabled: Bool) throws {
        guard !closed, resources.hasAudioLease else { throw Failure.closed }
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do { try session.overrideOutputAudioPort(enabled ? .speaker : .none) }
        catch { throw Failure.audioUnavailable }
        speakerOutputPolicy = enabled ? .forceSpeaker : .systemRoute
        publishRoute()
    }

    /// Prefer the built-in speaker for a fresh call while respecting an audio
    /// route the user already selected, such as Bluetooth or headphones.
    func setDefaultSpeakerOutput() throws {
        guard !closed, resources.hasAudioLease else { throw Failure.closed }
        speakerOutputPolicy = .defaultSpeaker
        try reapplySpeakerOutputIfNeeded()
    }

    private func reapplySpeakerOutputIfNeeded() throws {
        let outputs = RTCAudioSession.sharedInstance().currentRoute.outputs
        let hasExternalRoute = outputs.contains {
            !($0.portType == .builtInReceiver || $0.portType == .builtInSpeaker)
        }
        let currentBuiltInSpeaker = outputs.contains { $0.portType == .builtInSpeaker }
        guard Self.shouldApplySpeakerOutput(policy: speakerOutputPolicy,
                                             hasExternalRoute: hasExternalRoute,
                                             currentBuiltInSpeaker: currentBuiltInSpeaker) else {
            publishRoute()
            return
        }
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do { try session.overrideOutputAudioPort(.speaker) }
        catch { throw Failure.audioUnavailable }
        publishRoute()
    }

    static func shouldApplySpeakerOutput(policy: BighelpSpeakerOutputPolicy,
                                         hasExternalRoute: Bool,
                                         currentBuiltInSpeaker: Bool) -> Bool {
        guard !currentBuiltInSpeaker else { return false }
        return switch policy {
        case .defaultSpeaker: !hasExternalRoute
        case .forceSpeaker: true
        case .none, .systemRoute: false
        }
    }

    /// Explicitly resumes microphone capture after a system pause or route loss.
    func resumeAudio() throws {
        guard !closed, resources.hasAudioLease, captureEnabled else { throw Failure.closed }
        guard recoveryState.explicitResume(hasValidInputRoute: hasValidInputRoute()) else {
            throw Failure.audioUnavailable
        }
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        applyCaptureState()
        onInterruption?(false)
    }

    func statistics() async throws -> MediaStatistics {
        guard !closed, let connection = resources.connection else { throw Failure.closed }
        var result: MediaStatistics = try await callback(timeout: .seconds(3)) { finish in
            connection.statistics { report in
                var result = MediaStatistics()
                for statistic in report.statistics.values {
                    let values = statistic.values
                    let kind = (values["kind"] as? String) ?? (values["mediaType"] as? String)
                    #if DEBUG
                    var diagnosticValues: [String: String] = [:]
                    if ["outbound-rtp", "media-source", "remote-inbound-rtp"].contains(statistic.type) {
                        for key in ["packetsSent", "bytesSent", "totalAudioEnergy", "audioLevel", "totalSamplesDuration"] {
                            guard let number = values[key] as? NSNumber else { continue }
                            if key == "packetsSent" || key == "bytesSent" {
                                diagnosticValues[key] = String(number.uint64Value)
                            } else if number.doubleValue.isFinite {
                                diagnosticValues[key] = String(number.doubleValue)
                            }
                        }
                    }
                    result.rtcStatisticShapes.append(.init(
                        type: statistic.type,
                        kind: values["kind"] as? String,
                        mediaType: values["mediaType"] as? String,
                        diagnosticValues: diagnosticValues
                    ))
                    #endif
                    guard kind == "audio" || statistic.type == "media-playout" else { continue }
                    func count(_ key: String) -> UInt64 { (values[key] as? NSNumber)?.uint64Value ?? 0 }
                    func number(_ key: String) -> Double {
                        let value = (values[key] as? NSNumber)?.doubleValue ?? 0
                        return value.isFinite ? max(0, value) : 0
                    }
                    switch statistic.type {
                    case "outbound-rtp":
                        result.bytesSent &+= count("bytesSent")
                        result.packetsSent &+= count("packetsSent")
                    case "inbound-rtp":
                        result.bytesReceived &+= count("bytesReceived")
                        result.packetsReceived &+= count("packetsReceived")
                        result.samplesReceived &+= count("totalSamplesReceived")
                        result.concealedSamples &+= count("concealedSamples")
                        result.receivedAudioEnergy += number("totalAudioEnergy")
                        result.outputAudioLevel = max(result.outputAudioLevel, min(1, number("audioLevel")))
                    case "media-source":
                        result.inputAudioLevel = max(result.inputAudioLevel, min(1, number("audioLevel")))
                    case "media-playout": result.emittedSamples &+= count("totalSamplesCount")
                    default: break
                    }
                }
                finish(.success(result))
            }
        }
        result.audioDeviceRunning = audioDeviceRunning
        #if DEBUG
        result.peerConnectionState = Self.peerConnectionStateName(connection.connectionState)
        result.iceConnectionState = Self.iceConnectionStateName(connection.iceConnectionState)
        result.localSenderTrackEnabled = resources.track?.isEnabled
        result.inputRoutePresent = !RTCAudioSession.sharedInstance().currentRoute.inputs.isEmpty
        #endif
        return result
    }

    func close() {
        guard !closed else { return }
        closed = true
        let waiters = Array(pending.values)
        pending.removeAll()
        waiters.forEach { $0(.closed) }
        resources.close()
        audioDeviceRunning = false
        publish(.closed)
        onConnectionState = nil
        onAudioRoute = nil
        onInterruption = nil
    }

    private func callback<Value: Sendable>(
        timeout: Duration = .seconds(8),
        _ begin: (@escaping @Sendable (Result<Value, Failure>) -> Void) -> Void
    ) async throws -> Value {
        let id = UUID()
        let timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.pending.removeValue(forKey: id)?(.timeout)
        }
        defer { timer.cancel(); pending.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !closed else { throw Failure.closed }
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = { continuation.resume(throwing: $0) }
                begin { [weak self] result in
                    Task { @MainActor in
                        guard self?.pending.removeValue(forKey: id) != nil else { return }
                        continuation.resume(with: result.mapError { $0 as any Error })
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.pending.removeValue(forKey: id)?(.closed)
            }
        }
    }

    nonisolated static func validateAudioSDP(_ sdp: String) throws {
        guard !sdp.isEmpty, sdp.utf8.count <= 262_144, !sdp.contains("\0") else { throw Failure.invalidSDP }
        let lines = sdp.components(separatedBy: .newlines)
        guard lines.count <= 4_096, lines.allSatisfy({ $0.utf8.count <= 4_096 }),
              lines.contains("v=0"), lines.contains(where: { $0.hasPrefix("a=fingerprint:") }) else {
            throw Failure.invalidSDP
        }
        let media = lines.filter { $0.hasPrefix("m=") }
        guard media.count == 1, media[0].hasPrefix("m=audio ") else { throw Failure.invalidSDP }
        let fields = media[0].split(separator: " ")
        guard fields.count >= 4, fields[1] != "0" else { throw Failure.invalidSDP }
    }

    private func publish(_ state: ConnectionState) {
        connectionState = state
        onConnectionState?(state)
    }

    private func publishRoute() {
        let outputs = RTCAudioSession.sharedInstance().currentRoute.outputs
        // Route types only: do not expose a person's named Bluetooth device.
        let names = outputs.map { output in
            switch output.portType {
            case .builtInSpeaker: "Speaker"
            case .builtInReceiver: "Receiver"
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: "Bluetooth"
            case .headphones, .headsetMic: "Headphones"
            default: "External audio"
            }
        }
        onAudioRoute?(names.isEmpty ? "No audio route" : names.joined(separator: ", "))
    }

    private func hasValidInputRoute() -> Bool {
        !captureEnabled || !RTCAudioSession.sharedInstance().currentRoute.inputs.isEmpty
    }

    private func applyCaptureState() {
        resources.track?.isEnabled = captureEnabled && !isMuted && !isInterrupted && !closed
    }

    private static func peerConnectionStateName(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: "new"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .closed: "closed"
        @unknown default: "unknown"
        }
    }

    private static func iceConnectionStateName(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .count: "unknown"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .closed: "closed"
        @unknown default: "unknown"
        }
    }
}

extension BighelpRealtimeAudioPeer: RTCPeerConnectionDelegate, RTCAudioSessionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.close()
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let state: ConnectionState
        switch newState {
        case .new: state = .idle
        case .connecting: state = .connecting
        case .connected: state = .connected
        case .disconnected: state = .disconnected
        case .failed: state = .failed
        case .closed: state = .closed
        @unknown default: state = .failed
        }
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.publish(state)
        }
    }
    nonisolated func audioSessionDidBeginInterruption(_ session: RTCAudioSession) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.recoveryState.beginInterruption()
            self.applyCaptureState()
            RTCAudioSession.sharedInstance().isAudioEnabled = false
            self.onInterruption?(true)
        }
    }
    nonisolated func audioSessionDidEndInterruption(_ session: RTCAudioSession, shouldResumeSession: Bool) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            let resumed = self.recoveryState.endInterruption(
                shouldResume: shouldResumeSession, hasValidInputRoute: self.hasValidInputRoute())
            guard resumed else { return }
            RTCAudioSession.sharedInstance().isAudioEnabled = true
            self.applyCaptureState()
            try? self.reapplySpeakerOutputIfNeeded()
            self.onInterruption?(false)
        }
    }
    nonisolated func audioSessionDidChangeRoute(
        _ session: RTCAudioSession, reason: AVAudioSession.RouteChangeReason,
        previousRoute: AVAudioSessionRouteDescription
    ) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.publishRoute()
            if reason == .oldDeviceUnavailable {
                self.recoveryState.routeLost()
                self.applyCaptureState()
                RTCAudioSession.sharedInstance().isAudioEnabled = false
                if !self.recoveryState.routeBecameAvailable(hasValidInputRoute: self.hasValidInputRoute()) {
                    self.onInterruption?(true)
                } else {
                    RTCAudioSession.sharedInstance().isAudioEnabled = true
                    self.applyCaptureState()
                    try? self.reapplySpeakerOutputIfNeeded()
                    self.onInterruption?(false)
                }
            } else if self.recoveryState.routeBecameAvailable(
                hasValidInputRoute: self.hasValidInputRoute()) {
                RTCAudioSession.sharedInstance().isAudioEnabled = true
                self.applyCaptureState()
                try? self.reapplySpeakerOutputIfNeeded()
                self.onInterruption?(false)
            }
            try? self.reapplySpeakerOutputIfNeeded()
        }
    }
    nonisolated func audioSessionMediaServerTerminated(_ session: RTCAudioSession) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.publish(.failed)
            self.close()
        }
    }
    nonisolated func audioSessionMediaServerReset(_ session: RTCAudioSession) {
        audioSessionMediaServerTerminated(session)
    }
    nonisolated func audioSession(_ session: RTCAudioSession, audioUnitStartFailedWithError error: any Error) {
        audioSessionMediaServerTerminated(session)
    }
    nonisolated func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            self.audioDeviceRunning = true
            try? self.reapplySpeakerOutputIfNeeded()
            self.publishRoute()
        }
    }
    nonisolated func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) {
        Task { @MainActor [weak self] in self?.audioDeviceRunning = false }
    }
}

/// Accessed by the main-actor peer, then exclusively by its final release.
/// A non-actor resource box guarantees native teardown even if the screen owner
/// is released without calling close. WebRTC's configuration lock protects audio.
private final class LiveVoicePeerResources: @unchecked Sendable {
    private final class AudioOwnership: @unchecked Sendable {
        let lock = NSLock()
        var owner: UUID?
    }
    private static let ownership = AudioOwnership()
    private let id = UUID()
    var factory: RTCPeerConnectionFactory?
    var connection: RTCPeerConnection?
    var track: RTCAudioTrack?
    weak var audioDelegate: (any RTCAudioSessionDelegate)?
    private(set) var hasAudioLease = false
    private var sessionLease: VoiceAudioSessionLiveCallLease?
    private var activated = false
    private var previousManual = false
    private var previousEnabled = false

    func acquireAudio(captureEnabled: Bool, coordinator: VoiceAudioSessionCoordinator) throws {
        Self.ownership.lock.lock()
        defer { Self.ownership.lock.unlock() }
        guard Self.ownership.owner == nil,
              let lease = try? coordinator.holdForLiveCall() else {
            throw BighelpRealtimeAudioPeer.Failure.busy
        }
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        previousManual = audio.useManualAudio
        previousEnabled = audio.isAudioEnabled
        audio.useManualAudio = true
        audio.isAudioEnabled = false
        do {
            if captureEnabled {
                // Speakerphone tuning (see SystemVoiceAudioSession): voice-chat
                // mode played the agent at earpiece-call volume on the speaker.
                // Echo cancellation is WebRTC's own and stays on.
                try audio.setCategory(.playAndRecord, mode: SystemVoiceAudioSession.liveCallMode,
                                      options: SystemVoiceAudioSession.liveCallOptions)
                try audio.setActive(true)
                activated = true
            }
        } catch {
            audio.isAudioEnabled = previousEnabled
            audio.useManualAudio = previousManual
            lease.release()
            throw BighelpRealtimeAudioPeer.Failure.audioUnavailable
        }
        Self.ownership.owner = id
        // Until the call ends, the app's other audio (hold music, samples) is refused rather than
        // configuring or deactivating the session under it.
        sessionLease = lease
        hasAudioLease = true
        audio.isAudioEnabled = captureEnabled
    }

    func close() {
        track?.isEnabled = false
        connection?.delegate = nil
        connection?.close()
        connection = nil
        track = nil
        factory = nil
        guard hasAudioLease else { return }
        hasAudioLease = false
        let audio = RTCAudioSession.sharedInstance()
        if let audioDelegate { audio.remove(audioDelegate) }
        audioDelegate = nil
        Self.ownership.lock.lock()
        defer { Self.ownership.lock.unlock() }
        guard Self.ownership.owner == id else { return }
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        audio.isAudioEnabled = false
        if activated { try? audio.setActive(false) }
        activated = false
        audio.isAudioEnabled = previousEnabled
        audio.useManualAudio = previousManual
        sessionLease?.release()
        sessionLease = nil
        Self.ownership.owner = nil
    }

    deinit { close() }
}
