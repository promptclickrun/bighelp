import Foundation
import Observation

struct NativeSessionResumeProgressIndicator: Equatable, Sendable {
    let requestID: UUID
    let message: String
}

/// View-local presentation for one exact resumed runtime session. It never
/// enters the transcript or persistence path; only the matching terminal event
/// may clear an admitted loading flight.
@MainActor
@Observable
final class NativeSessionResumeProgressPresentation {
    private struct Binding: Equatable {
        let source: NativeWorkspaceEventSource
        let runtimeSessionID: String
        let clientID: ObjectIdentifier
        let connectionGeneration: UUID
    }

    private(set) var indicator: NativeSessionResumeProgressIndicator?
    private(set) var isMounted = false
    @ObservationIgnored private var binding: Binding?
    @ObservationIgnored private var retired = false

    var visibleIndicator: NativeSessionResumeProgressIndicator? {
        isMounted ? indicator : nil
    }

    func bind(
        source: NativeWorkspaceEventSource,
        runtimeSessionID: String,
        client: DirectHermesConversationClient
    ) {
        guard !retired else { return }
        let next = Binding(
            source: source,
            runtimeSessionID: runtimeSessionID,
            clientID: ObjectIdentifier(client),
            connectionGeneration: client.sessionActionsConnectionGeneration
        )
        if binding != next { indicator = nil }
        binding = next
    }

    func mount() {
        guard !retired else { return }
        isMounted = true
    }

    func unmount() {
        isMounted = false
    }

    func receive(
        _ progress: NativeWorkspaceResumeProgress,
        source: NativeWorkspaceEventSource,
        client: DirectHermesConversationClient
    ) {
        guard !retired, let binding,
              binding.source == source,
              binding.clientID == ObjectIdentifier(client),
              binding.connectionGeneration == client.sessionActionsConnectionGeneration,
              Data(binding.runtimeSessionID.utf8) == Data(progress.runtimeSessionID.utf8),
              progress.profileID.map({ Data(client.profile.utf8) == Data($0.utf8) }) ?? true,
              Data(client.runtimeID.utf8) == Data(progress.runtimeSessionID.utf8)
        else { return }

        switch progress.state {
        case .loading:
            guard indicator == nil else { return }
            indicator = NativeSessionResumeProgressIndicator(
                requestID: progress.requestID,
                message: "Restoring session history…"
            )
        case .complete, .failed:
            guard indicator?.requestID == progress.requestID else { return }
            indicator = nil
        }
    }

    func cancel(source: NativeWorkspaceEventSource, client: DirectHermesConversationClient) {
        guard let binding,
              binding.source == source,
              binding.clientID == ObjectIdentifier(client),
              binding.connectionGeneration == client.sessionActionsConnectionGeneration else { return }
        indicator = nil
        self.binding = nil
    }

    func retire() {
        guard !retired else { return }
        retired = true
        indicator = nil
        binding = nil
        isMounted = false
    }
}

/// Retains only live loading flights and weak presentation bindings. A flight
/// can arrive before its chat model is prepared; binding later replays only that
/// exact owner/profile/runtime/request loading state. No catalog refresh or
/// blocking presentation is driven from this coordinator.
@MainActor
final class NativeSessionResumeProgressCoordinator {
    private struct Route: Hashable {
        let source: NativeWorkspaceEventSource
        let runtimeSessionID: String
    }

    private struct Flight {
        let progress: NativeWorkspaceResumeProgress
    }

    @MainActor
    private final class ModelBinding {
        weak var model: ChatModel?
        weak var client: DirectHermesConversationClient?
        let route: Route
        let connectionGeneration: UUID

        init(
            model: ChatModel,
            client: DirectHermesConversationClient,
            route: Route
        ) {
            self.model = model
            self.client = client
            self.route = route
            connectionGeneration = client.sessionActionsConnectionGeneration
        }
    }

    private var flights: [Route: Flight] = [:]
    private var bindings: [Route: ModelBinding] = [:]

    func bind(
        model: ChatModel,
        client: DirectHermesConversationClient,
        coordinate: WorkspaceSessionCoordinate,
        source: NativeWorkspaceEventSource
    ) {
        guard coordinate.owner == source.owner,
              coordinate.sessionID == model.conversationID,
              model.nativeConversationClient === client,
              client.nativeWorkspaceAuthority == source.owner.authority,
              let runtimeSessionID = coordinate.runtimeSessionID,
              // The chat's own agent, whichever agent the connection last opened.
              Data(coordinate.profileID.utf8) == Data(client.profile.utf8),
              Data(client.runtimeID.utf8) == Data(runtimeSessionID.utf8)
        else { return }

        bindings = bindings.filter { _, binding in
            guard let boundModel = binding.model, binding.client != nil else { return false }
            return boundModel !== model
        }
        let route = Route(source: source, runtimeSessionID: runtimeSessionID)
        bindings[route] = ModelBinding(model: model, client: client, route: route)
        model.nativeSessionResumeProgress.bind(
            source: source,
            runtimeSessionID: runtimeSessionID,
            client: client
        )
        if let flight = flights[route] {
            deliver(flight.progress, route: route)
        }
    }

    func receive(_ progress: NativeWorkspaceResumeProgress, source: NativeWorkspaceEventSource) {
        guard source.owner.authority.kind == .direct else { return }
        let route = Route(source: source, runtimeSessionID: progress.runtimeSessionID)
        switch progress.state {
        case .loading:
            guard flights[route] == nil, flights.count < 256 else { return }
            flights[route] = Flight(progress: progress)
            deliver(progress, route: route)
        case .complete, .failed:
            guard let flight = flights[route],
                  flight.progress.requestID == progress.requestID else { return }
            deliver(progress, route: route)
            flights[route] = nil
        }
    }

    func suspend() {
        for binding in bindings.values {
            guard let model = binding.model, let client = binding.client else { continue }
            model.nativeSessionResumeProgress.cancel(source: binding.route.source, client: client)
        }
        flights.removeAll(keepingCapacity: false)
        bindings.removeAll(keepingCapacity: false)
    }

    private func deliver(_ progress: NativeWorkspaceResumeProgress, route: Route) {
        guard let binding = bindings[route],
              let model = binding.model,
              let client = binding.client,
              model.nativeConversationClient === client,
              client.sessionActionsConnectionGeneration == binding.connectionGeneration,
              progress.profileID.map({ Data(client.profile.utf8) == Data($0.utf8) }) ?? true,
              Data(client.runtimeID.utf8) == Data(route.runtimeSessionID.utf8) else {
            bindings[route] = nil
            return
        }
        model.nativeSessionResumeProgress.receive(progress, source: route.source, client: client)
    }
}
