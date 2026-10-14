import Foundation

/// An agent's screen on its host (Hermes Bot Screen, `display.*`): a Linux desktop
/// the agent's browser and computer tools use, which a person can watch and take over.
/// Live on a connected Hermes host; demo mode draws one in the app.
@MainActor
protocol BotScreenService: AnyObject {
    /// Throws `WorkspaceClientError.unavailable(.unsupportedOperation)` when the host's
    /// Hermes has no screens at all (older than 0.22): then there's no Screen tab.
    func status(agentID: String) async throws -> BotScreenStatus
    func start(agentID: String) async throws -> BotScreenStatus
    func stop(agentID: String) async throws -> BotScreenStatus
    func thumbnail(agentID: String) async throws -> BotScreenThumbnail
    /// A ticket for the screen's socket. Passing the viewer ID this connection got before
    /// keeps a person's control across a reconnect; Hermes gives a fresh one otherwise.
    func observe(agentID: String, viewerID: String?) async throws -> BotScreenObservation
    func takeControl(agentID: String, viewerID: String) async throws -> BotScreenLease
    func handBack(agentID: String, viewerID: String) async throws -> BotScreenLease
    func openStream(_ observation: BotScreenObservation) async throws -> any RFBTransport
    /// `display.lease` and `display.status` from this host while the caller listens.
    func events() -> AsyncStream<BotScreenEvent>
}

/// Hermes' `display.*` on the connected host. Each call uses the connection as it is
/// now: a reconnect after the app comes back is the same computer and sign-in, so the
/// screen carries on; another computer or sign-in ends it.
@MainActor
final class LiveBotScreenService: BotScreenService {
    struct Connection {
        let owner: WorkspaceOwner
        let workspace: any WorkspaceOperationPerforming
        let streams: DirectHermesBotScreenStreams
    }

    private let signIn: WorkspaceSignIn
    private let hostID: UUID
    private let connection: @MainActor () -> Connection?

    init(signIn: WorkspaceSignIn, hostID: UUID, connection: @escaping @MainActor () -> Connection?) {
        self.signIn = signIn
        self.hostID = hostID
        self.connection = connection
    }

    func status(agentID: String) async throws -> BotScreenStatus {
        BotScreenStatus(try await perform(.displayStatus, agentID: agentID))
    }

    func start(agentID: String) async throws -> BotScreenStatus {
        BotScreenStatus(try await perform(.displayStart, agentID: agentID))
    }

    func stop(agentID: String) async throws -> BotScreenStatus {
        BotScreenStatus(try await perform(.displayStop, agentID: agentID))
    }

    func thumbnail(agentID: String) async throws -> BotScreenThumbnail {
        await BotScreenThumbnail.decode(try await perform(.displayThumbnail, agentID: agentID))
    }

    func observe(agentID: String, viewerID: String?) async throws -> BotScreenObservation {
        let result = try await perform(.displayObserve, agentID: agentID,
                                       extra: viewerID.map { ["viewer_id": .string($0)] } ?? [:])
        guard let observation = BotScreenObservation(result) else { throw WorkspaceClientError.invalidResponse }
        return observation
    }

    func takeControl(agentID: String, viewerID: String) async throws -> BotScreenLease {
        try lease(await perform(.displayLeaseAcquire, agentID: agentID, extra: ["viewer_id": .string(viewerID)]))
    }

    func handBack(agentID: String, viewerID: String) async throws -> BotScreenLease {
        try lease(await perform(.displayLeaseRelease, agentID: agentID, extra: ["viewer_id": .string(viewerID)]))
    }

    func openStream(_ observation: BotScreenObservation) async throws -> any RFBTransport {
        guard let current = connection(), current.owner.signIn == signIn else { throw WorkspaceClientError.ownerChanged }
        return try current.streams.open(observation)
    }

    func events() -> AsyncStream<BotScreenEvent> { BotScreenEventHub.shared.events(hostID: hostID) }

    private func lease(_ result: [String: BighelpJSONValue]) throws -> BotScreenLease {
        guard let lease = BotScreenLease(result["lease"]) else { throw WorkspaceClientError.invalidResponse }
        return lease
    }

    private func perform(_ operation: WorkspaceOperation, agentID: String,
                         extra: [String: BighelpJSONValue] = [:]) async throws -> [String: BighelpJSONValue] {
        guard let current = connection(), current.owner.signIn == signIn else { throw WorkspaceClientError.ownerChanged }
        var payload = extra
        payload["profile"] = .string(agentID)
        return try await current.workspace.perform(operation, payload: payload, owner: current.owner)
    }
}

/// `display.*` events from every host's connection, handed to the screens listening
/// for that host. Fed from the app's one native event path (`BighelpApp`).
@MainActor
final class BotScreenEventHub {
    static let shared = BotScreenEventHub()

    private var listeners: [UUID: (hostID: UUID, continuation: AsyncStream<BotScreenEvent>.Continuation)] = [:]

    func receive(hostID: UUID, event: DirectHermesEvent) {
        guard !listeners.isEmpty, event.type.hasPrefix("display."), let parsed = BotScreenEvent(event) else { return }
        for listener in listeners.values where listener.hostID == hostID { listener.continuation.yield(parsed) }
    }

    func events(hostID: UUID) -> AsyncStream<BotScreenEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: BotScreenEvent.self, bufferingPolicy: .bufferingNewest(32))
        listeners[id] = (hostID, continuation)
        continuation.onTermination = { _ in
            Task { @MainActor in BotScreenEventHub.shared.listeners[id] = nil }
        }
        return stream
    }
}

/// A plain sentence for a failed screen action. Hermes' own words are for Nerd Mode.
enum BotScreenMessage {
    static func sentence(for error: any Error, doing action: String) -> String {
        switch error {
        case WorkspaceClientError.unavailable(.unsupportedOperation):
            "This computer's Hermes doesn't have screens yet. Update Hermes to use them."
        case WorkspaceClientError.ownerChanged, WorkspaceClientError.transportUnavailable,
             WorkspaceClientError.unavailable(.notConnected):
            "Couldn't reach your computer. Check that it's connected, then try again."
        default:
            "Couldn't \(action). Try again."
        }
    }
}
