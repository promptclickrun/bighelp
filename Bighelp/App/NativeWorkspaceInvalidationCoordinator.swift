import Foundation

/// The exact host/socket/profile authority that delivered a native gateway event.
/// `profileID` is the selected RPC profile; `servingProfileID` separately names
/// the process-level HTTP profile when the native context advertises one.
/// One connection's feed of host changes: the computer, its sign-in and socket (`owner`) and the profile
/// its dashboard serves. Not the agent a screen shows: every agent's changes come through one connection,
/// and each screen keeps the ones for its own agent (a change can name its agent with `profile`).
struct NativeWorkspaceEventSource: Hashable, Sendable {
    let hostID: UUID
    let owner: WorkspaceOwner
    let servingProfileID: String?
}

enum NativeWorkspaceInvalidationTopic: Hashable, Sendable {
    case sessions
    case scheduledTasks
    case platforms
    case pairing
    case setup
    case resumeProgress
}

struct NativeWorkspaceSetupSnapshot: Equatable, Sendable {
    let providerConfigured: Bool
    let inferenceProvider: String
    let freeTier: Bool
    let hasIdentity: Bool
    let otherProviders: Bool
    let error: String
    let finishedAt: Double
}

struct NativeWorkspaceResumeProgress: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case loading
        case complete(messageCount: Int)
        case failed(message: String)
    }

    /// A client-local token created only by the matching `loading` event. A
    /// terminal event without that exact live runtime-session flight is dropped.
    let requestID: UUID
    let runtimeSessionID: String
    /// The agent the change names; nil when it names none (the runtime session already belongs to one).
    let profileID: String?
    let state: State
}

enum NativeWorkspaceInvalidationNotice: Equatable, Sendable {
    case sessionsChanged
    case scheduledTasksChanged
    case platformsChanged
    case pairingChanged
    case setupReady(NativeWorkspaceSetupSnapshot)
    case resumeProgress(NativeWorkspaceResumeProgress)

    var topic: NativeWorkspaceInvalidationTopic {
        switch self {
        case .sessionsChanged: .sessions
        case .scheduledTasksChanged: .scheduledTasks
        case .platformsChanged: .platforms
        case .pairingChanged: .pairing
        case .setupReady: .setup
        case .resumeProgress: .resumeProgress
        }
    }
}

struct NativeWorkspaceInvalidationRevision: Equatable, Sendable {
    let source: NativeWorkspaceEventSource?
    private(set) var sessions: UInt64 = 0
    private(set) var scheduledTasks: UInt64 = 0
    private(set) var platforms: UInt64 = 0
    private(set) var pairing: UInt64 = 0
    private(set) var setup: UInt64 = 0
    private(set) var resumeProgress: UInt64 = 0

    static let disconnected = NativeWorkspaceInvalidationRevision(source: nil)
    var owner: WorkspaceOwner? { source?.owner }

    func value(for topic: NativeWorkspaceInvalidationTopic) -> UInt64 {
        switch topic {
        case .sessions: sessions
        case .scheduledTasks: scheduledTasks
        case .platforms: platforms
        case .pairing: pairing
        case .setup: setup
        case .resumeProgress: resumeProgress
        }
    }

    mutating func advance(_ topic: NativeWorkspaceInvalidationTopic) {
        switch topic {
        case .sessions: sessions &+= 1
        case .scheduledTasks: scheduledTasks &+= 1
        case .platforms: platforms &+= 1
        case .pairing: pairing &+= 1
        case .setup: setup &+= 1
        case .resumeProgress: resumeProgress &+= 1
        }
    }
}

struct NativeWorkspaceInvalidationUpdate: Equatable, Sendable {
    let source: NativeWorkspaceEventSource
    let revision: NativeWorkspaceInvalidationRevision
    let notice: NativeWorkspaceInvalidationNotice
}

/// Decodes only the stock gateway's exact invalidation payloads. Host/account/
/// socket ownership is established separately by `NativeWorkspaceEventSource`.
enum NativeWorkspaceInvalidationDecoder {
    enum Decoded: Equatable, Sendable {
        case sessionsChanged
        case scheduledTasksChanged
        case platformsChanged
        case pairingChanged
        case setupReady(NativeWorkspaceSetupSnapshot)
        case resumeProgress(runtimeSessionID: String, profileID: String?, state: ResumeState)
    }

    enum ResumeState: Equatable, Sendable {
        case loading
        case complete(messageCount: Int)
        case failed(message: String)
    }

    static func handles(_ type: String) -> Bool {
        [
            "sessions.changed", "cron.changed", "platforms.changed", "pairing.changed",
            "setup.ready", "session.resume_progress",
        ].contains(type)
    }

    static func decode(_ event: DirectHermesEvent, source: NativeWorkspaceEventSource) -> Decoded? {
        guard envelopeMatches(event, source: source) else { return nil }
        switch event.type {
        case "sessions.changed":
            guard isGlobal(event), event.payload.isEmpty else { return nil }
            return .sessionsChanged
        case "cron.changed":
            guard isGlobal(event), event.payload.isEmpty else { return nil }
            return .scheduledTasksChanged
        case "platforms.changed":
            guard isGlobal(event), event.payload.isEmpty else { return nil }
            return .platformsChanged
        case "pairing.changed":
            guard isGlobal(event), event.payload.isEmpty else { return nil }
            return .pairingChanged
        case "setup.ready":
            guard isGlobal(event), let snapshot = setupSnapshot(event.payload) else { return nil }
            return .setupReady(snapshot)
        case "session.resume_progress":
            guard let runtimeID = event.sessionID, validIdentifier(runtimeID, maximumBytes: 1_024),
                  let state = resumeState(event.payload) else { return nil }
            return .resumeProgress(runtimeSessionID: runtimeID, profileID: profile(of: event), state: state)
        default:
            return nil
        }
    }

    private static func envelopeMatches(_ event: DirectHermesEvent, source: NativeWorkspaceEventSource) -> Bool {
        let allowedKeys: Set<String> = ["type", "session_id", "payload", "seq", "profile"]
        guard event.parameters.isEmpty || (
            Set(event.parameters.keys).isSubset(of: allowedKeys)
                && event.parameters["type"]?.string == event.type
        ) else { return false }
        if !event.parameters.isEmpty {
            guard event.parameters["session_id"]?.string == event.sessionID,
                  event.parameters["payload"]?.object == event.payload else { return false }
            if let sequence = event.sequence {
                guard event.parameters["seq"]?.integer == sequence else { return false }
            } else {
                guard event.parameters["seq"] == nil else { return false }
            }
        }
        // A change may name its agent; any agent's change belongs to this connection.
        if let profileValue = event.parameters["profile"] {
            guard let profile = profileValue.string, validIdentifier(profile, maximumBytes: 128) else { return false }
        }
        return true
    }

    /// The agent a change names, if it names one.
    static func profile(of event: DirectHermesEvent) -> String? {
        event.parameters["profile"]?.string
    }

    private static func isGlobal(_ event: DirectHermesEvent) -> Bool {
        event.sessionID == ""
    }

    private static func setupSnapshot(_ payload: [String: BighelpJSONValue]) -> NativeWorkspaceSetupSnapshot? {
        let keys: Set<String> = [
            "provider_configured", "inference_provider", "free_tier", "has_identity",
            "other_providers", "error", "finished_at",
        ]
        guard Set(payload.keys) == keys,
              let providerConfigured = payload["provider_configured"]?.boolean,
              let inferenceProvider = payload["inference_provider"]?.string,
              validText(inferenceProvider, maximumBytes: 256),
              let freeTier = payload["free_tier"]?.boolean,
              let hasIdentity = payload["has_identity"]?.boolean,
              let otherProviders = payload["other_providers"]?.boolean,
              let error = payload["error"]?.string,
              validText(error, maximumBytes: 4_096),
              let finishedAt = payload["finished_at"]?.number,
              finishedAt.isFinite, finishedAt > 0 else { return nil }
        return .init(
            providerConfigured: providerConfigured, inferenceProvider: inferenceProvider,
            freeTier: freeTier, hasIdentity: hasIdentity, otherProviders: otherProviders,
            error: error, finishedAt: finishedAt
        )
    }

    private static func resumeState(_ payload: [String: BighelpJSONValue]) -> ResumeState? {
        guard payload["phase"]?.string == "history", let status = payload["status"]?.string else { return nil }
        switch status {
        case "loading":
            guard Set(payload.keys) == ["phase", "status"] else { return nil }
            return .loading
        case "complete":
            guard Set(payload.keys) == ["phase", "status", "message_count"],
                  let count = payload["message_count"]?.integer,
                  (0...10_000_000).contains(count) else { return nil }
            return .complete(messageCount: count)
        case "failed":
            guard Set(payload.keys) == ["phase", "status", "message"],
                  let message = payload["message"]?.string,
                  !message.isEmpty, validText(message, maximumBytes: 4_096) else { return nil }
            return .failed(message: message)
        default:
            return nil
        }
    }

    private static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    private static func validText(_ value: String, maximumBytes: Int) -> Bool {
        value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains { $0.value == 0 || $0.value == 0x7f }
    }
}

/// Coalesces burst invalidations onto the retained stores' existing refresh
/// flights. Events received during a refresh become one trailing authoritative
/// pass, so no change is lost and no parallel catalog pipeline is introduced.
@MainActor
final class NativeWorkspaceInvalidationCoordinator {
    private enum Refresh: Hashable {
        case sessions
        case scheduledTasks
    }

    private struct ResumeFlight {
        let requestID: UUID
        let source: NativeWorkspaceEventSource
    }

    private let currentSource: @MainActor () -> NativeWorkspaceEventSource?
    private let refreshSessions: @MainActor (NativeWorkspaceEventSource) async -> Void
    private let refreshScheduledTasks: @MainActor (NativeWorkspaceEventSource) async -> Void
    private let publish: @MainActor (NativeWorkspaceEventSource, NativeWorkspaceInvalidationNotice) -> Void
    private var source: NativeWorkspaceEventSource?
    private var generation = UUID()
    private var pendingRefreshes = Set<Refresh>()
    private var drainTask: Task<Void, Never>?
    private var resumeFlights: [Data: ResumeFlight] = [:]

    init(
        currentSource: @escaping @MainActor () -> NativeWorkspaceEventSource?,
        refreshSessions: @escaping @MainActor (NativeWorkspaceEventSource) async -> Void,
        refreshScheduledTasks: @escaping @MainActor (NativeWorkspaceEventSource) async -> Void,
        publish: @escaping @MainActor (NativeWorkspaceEventSource, NativeWorkspaceInvalidationNotice) -> Void
    ) {
        self.currentSource = currentSource
        self.refreshSessions = refreshSessions
        self.refreshScheduledTasks = refreshScheduledTasks
        self.publish = publish
    }

    @discardableResult
    func receive(_ event: DirectHermesEvent, source incoming: NativeWorkspaceEventSource) -> Bool {
        guard currentSource() == incoming,
              let decoded = NativeWorkspaceInvalidationDecoder.decode(event, source: incoming) else { return false }
        activate(incoming)
        switch decoded {
        case .sessionsChanged:
            publish(incoming, .sessionsChanged)
            enqueue(.sessions, source: incoming)
        case .scheduledTasksChanged:
            publish(incoming, .scheduledTasksChanged)
            enqueue(.scheduledTasks, source: incoming)
        case .platformsChanged:
            publish(incoming, .platformsChanged)
        case .pairingChanged:
            publish(incoming, .pairingChanged)
        case .setupReady(let snapshot):
            publish(incoming, .setupReady(snapshot))
        case .resumeProgress(let runtimeID, let profileID, let state):
            receiveResumeProgress(runtimeID: runtimeID, profileID: profileID, state: state, source: incoming)
        }
        return true
    }

    func suspend() {
        generation = UUID()
        drainTask?.cancel()
        drainTask = nil
        pendingRefreshes.removeAll(keepingCapacity: false)
        resumeFlights.removeAll(keepingCapacity: false)
        source = nil
    }

    private func activate(_ incoming: NativeWorkspaceEventSource) {
        guard source != incoming else { return }
        suspend()
        source = incoming
    }

    private func enqueue(_ refresh: Refresh, source incoming: NativeWorkspaceEventSource) {
        pendingRefreshes.insert(refresh)
        guard drainTask == nil else { return }
        let token = generation
        drainTask = Task { @MainActor [weak self] in
            await Task.yield()
            await self?.drain(source: incoming, token: token)
        }
    }

    private func drain(source incoming: NativeWorkspaceEventSource, token: UUID) async {
        defer {
            if generation == token { drainTask = nil }
        }
        while generation == token, source == incoming, currentSource() == incoming, !Task.isCancelled {
            let batch = pendingRefreshes
            pendingRefreshes.removeAll(keepingCapacity: true)
            guard !batch.isEmpty else { return }
            if batch.contains(.sessions) {
                await refreshSessions(incoming)
            }
            guard generation == token, source == incoming, currentSource() == incoming, !Task.isCancelled else { return }
            if batch.contains(.scheduledTasks) {
                await refreshScheduledTasks(incoming)
            }
        }
    }

    private func receiveResumeProgress(
        runtimeID: String,
        profileID: String?,
        state: NativeWorkspaceInvalidationDecoder.ResumeState,
        source incoming: NativeWorkspaceEventSource
    ) {
        let key = Data(runtimeID.utf8)
        switch state {
        case .loading:
            // A runtime id identifies one live resumed session. Replayed or
            // duplicated loading frames must not mint a second request token
            // that a terminal frame could accidentally complete.
            guard resumeFlights[key] == nil else { return }
            let flight = ResumeFlight(requestID: UUID(), source: incoming)
            resumeFlights[key] = flight
            publish(incoming, .resumeProgress(.init(
                requestID: flight.requestID, runtimeSessionID: runtimeID,
                profileID: profileID, state: .loading
            )))
        case .complete(let messageCount):
            guard let flight = resumeFlights.removeValue(forKey: key), flight.source == incoming else { return }
            publish(incoming, .resumeProgress(.init(
                requestID: flight.requestID, runtimeSessionID: runtimeID,
                profileID: profileID, state: .complete(messageCount: messageCount)
            )))
        case .failed(let message):
            guard let flight = resumeFlights.removeValue(forKey: key), flight.source == incoming else { return }
            publish(incoming, .resumeProgress(.init(
                requestID: flight.requestID, runtimeSessionID: runtimeID,
                profileID: profileID, state: .failed(message: message)
            )))
        }
    }
}
