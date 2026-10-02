import Network
import Observation
import SwiftUI

/// The selected host connection as a chat sees it.
enum WorkspaceConnectionState: Equatable, Sendable {
    case connected, reconnecting, disconnected
}

enum WorkspaceReconnectPolicy {
    /// The transport already retries for a few seconds. After that, keep trying
    /// with backoff while the app is open instead of giving up silently.
    static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]
    /// Attempts made before the chat offers a manual Retry.
    static let quietAttempts = 3

    static func delay(afterAttempt attempt: Int) -> Duration {
        delays[min(max(attempt, 0), delays.count - 1)]
    }
}

/// Restores a dropped host connection while the app is open, and tells the
/// connection pill what is happening so a disabled Send button is never a mystery.
///
/// It observes the store directly instead of relying on view updates: a view
/// under a pushed chat does not refresh its tasks until it is visible again.
@MainActor
@Observable
final class WorkspaceConnectionKeeper {
    private(set) var state: WorkspaceConnectionState = .connected
    /// False while the phone has no network at all ("No internet", not "Disconnected").
    private(set) var hasNetwork = true
    /// Whether the selected computer has connected since the app started (or
    /// since it was picked): "Reconnecting" once it has, "Connecting" before.
    /// The island and the chat both read it, so they say the same thing.
    private(set) var hasConnected = false

    /// The keeper of the computer in use, for screens the chat's environment
    /// doesn't reach (Hosts), so they say what the island and the chat say.
    static weak var current: WorkspaceConnectionKeeper?

    @ObservationIgnored private var storeProvider: () -> DirectHermesWorkspaceStore? = { nil }
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var isPathSatisfied = true
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var tracking = 0
    @ObservationIgnored private weak var connectedStore: DirectHermesWorkspaceStore?
    @ObservationIgnored private var isHeldForTesting = false
    @ObservationIgnored private nonisolated(unsafe) let monitor = NWPathMonitor()

    init() {
        #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
        holdForTesting(ProcessInfo.processInfo.arguments)
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "app.loopdy.network-path"))
    }

    deinit { monitor.cancel() }

    /// Follows whichever host store is selected; safe to call repeatedly.
    func bind(_ provider: @escaping () -> DirectHermesWorkspaceStore?) {
        storeProvider = provider
        Self.current = self
        evaluate()
    }

    /// Whether this keeper looks after `store`, so its state describes it.
    func isFollowing(_ store: DirectHermesWorkspaceStore?) -> Bool {
        store != nil && storeProvider() === store
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        attempt = 0
        evaluate()
    }

    /// Try now and restart the backoff (opening a saved chat while disconnected).
    func retry() {
        attempt = 0
        loop?.cancel()
        loop = nil
        evaluate(tryNow: true)
    }

    private func pathChanged(satisfied: Bool) {
        guard !isHeldForTesting else { return }
        let recovered = satisfied && !isPathSatisfied
        isPathSatisfied = satisfied
        if hasNetwork != satisfied { hasNetwork = satisfied }
        if recovered { attempt = 0; loop?.cancel(); loop = nil }
        evaluate(tryNow: recovered)
    }

    /// Recomputes the state and re-arms observation of the store's connection.
    private func evaluate(tryNow: Bool = false) {
        guard !isHeldForTesting else { return }
        tracking &+= 1
        let current = tracking
        let store = withObservationTracking {
            let store = storeProvider()
            _ = store.map { ($0.isConnected, $0.isConnecting, $0.hasSavedConnection) }
            return store
        } onChange: { [weak self] in
            // Only the latest registration re-arms, so observations never pile up.
            Task { @MainActor [weak self] in
                guard let self, self.tracking == current else { return }
                self.evaluate()
            }
        }
        if let store, store.isConnected { connectedStore = store }
        let connectedBefore = store != nil && store === connectedStore
        if hasConnected != connectedBefore { hasConnected = connectedBefore }
        guard let store, store.hasSavedConnection, !store.isConnected else {
            loop?.cancel(); loop = nil; attempt = 0
            publish(.connected)
            return
        }
        guard isActive, isPathSatisfied else {
            loop?.cancel(); loop = nil
            publish(isActive ? .disconnected : .reconnecting)
            return
        }
        publish(store.isConnecting || attempt < WorkspaceReconnectPolicy.quietAttempts ? .reconnecting : .disconnected)
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            await self?.reconnectWithBackoff(store, immediately: tryNow)
        }
    }

    private func reconnectWithBackoff(_ store: DirectHermesWorkspaceStore, immediately: Bool) async {
        var waitFirst = !immediately
        while !Task.isCancelled {
            if waitFirst {
                do { try await Task.sleep(for: WorkspaceReconnectPolicy.delay(afterAttempt: attempt)) } catch { return }
                attempt += 1
            }
            waitFirst = true
            guard !Task.isCancelled, isActive, isPathSatisfied, storeProvider() === store,
                  store.hasSavedConnection, !store.isConnected else { break }
            if !store.isConnecting { await store.reconnect() }
            if store.isConnected { break }
            publish(attempt < WorkspaceReconnectPolicy.quietAttempts ? .reconnecting : .disconnected)
        }
        if !Task.isCancelled { loop = nil; evaluate() }
    }

    private func publish(_ value: WorkspaceConnectionState) {
        if state != value { state = value }
    }

    #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
    /// "-test-connection-keeper connecting|reconnecting|disconnected|no-internet":
    /// holds one state, so demo chats show the banner (and the island follows)
    /// for screenshots.
    private func holdForTesting(_ arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-test-connection-keeper"),
              arguments.indices.contains(index + 1) else { return }
        let held: [String: (state: WorkspaceConnectionState, connectedBefore: Bool, network: Bool)] = [
            "connecting": (.reconnecting, false, true), "reconnecting": (.reconnecting, true, true),
            "disconnected": (.disconnected, true, true), "no-internet": (.disconnected, true, false),
        ]
        guard let hold = held[arguments[index + 1]] else { return }
        isHeldForTesting = true
        state = hold.state
        hasConnected = hold.connectedBefore
        hasNetwork = hold.network
    }
    #endif
}
