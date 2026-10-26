import Foundation
import Observation

extension BighelpAppComposition {
    func makeNativeWorkspaceSelection(connections: WorkspaceConnectionStore,
                                      peerHosts: (any HermesBotModePeerHosts)? = nil) -> NativeWorkspaceSelectionStore {
        NativeWorkspaceSelectionStore(
            connections: connections, settings: settings, userIdentity: userIdentity,
            directory: DirectHermesApplicationFactory.workspaceStorageRoot, peerHosts: peerHosts
        )
    }
}

@MainActor
@Observable
final class NativeWorkspaceSelectionStore {
    struct SynchronizationKey: Hashable {
        let hostID: UUID?
        let owner: WorkspaceOwner?
    }

    private(set) var errorMessage: String?
    private var runtime: NativeWorkspaceRuntime?
    private var hostID: UUID?
    private weak var retirementWorkspace: DirectHermesWorkspaceStore?
    private var synchronizedOwner: WorkspaceOwner?
    private var synchronizationFlight: (
        id: UUID,
        key: SynchronizationKey,
        task: Task<Void, Never>
    )?
    private let connections: WorkspaceConnectionStore
    private let settings: SettingsStore
    private let userIdentity: UserIdentityStore
    private let directory: URL
    private let peerHosts: (any HermesBotModePeerHosts)?
    private let protectedData: any BighelpProtectedDataAvailabilityProviding

    var current: NativeWorkspaceRuntime? {
        guard hostID == connections.hosts.selectedHostID, connections.isDirectSelected else { return nil }
        return runtime
    }

    var synchronizationKey: SynchronizationKey {
        SynchronizationKey(hostID: connections.hosts.selectedHostID, owner: connections.owner)
    }

    init(connections: WorkspaceConnectionStore, settings: SettingsStore,
         userIdentity: UserIdentityStore, directory: URL, peerHosts: (any HermesBotModePeerHosts)? = nil,
         protectedData: any BighelpProtectedDataAvailabilityProviding = BighelpSystemProtectedDataAvailability()) {
        self.connections = connections
        self.settings = settings
        self.userIdentity = userIdentity
        self.directory = directory
        self.peerHosts = peerHosts
        self.protectedData = protectedData
    }

    func synchronize() async {
        let requestedKey = synchronizationKey
        while true {
            if let flight = synchronizationFlight {
                if flight.key == requestedKey {
                    await flight.task.value
                    return
                }
                // Retired network work can ignore cancellation until its
                // request times out. Its exact-owner guards prevent publishing
                // into the replacement, so do not put foreground readiness
                // behind that old request's completion.
                synchronizationFlight = nil
                flight.task.cancel()
                continue
            }
            guard synchronizationKey == requestedKey else { return }

            let flightID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.synchronizeNow(for: requestedKey)
            }
            synchronizationFlight = (flightID, requestedKey, task)
            await task.value
            if synchronizationFlight?.id == flightID { synchronizationFlight = nil }
            return
        }
    }

    private func synchronizeNow(for requestedKey: SynchronizationKey) async {
        guard !Task.isCancelled, synchronizationKey == requestedKey else { return }
        let selectedID = connections.hosts.selectedHostID
        if selectedID != hostID {
            retirementWorkspace?.onBeforeConnectionRetired = nil
            retirementWorkspace = nil
            runtime?.retire(nextHostID: selectedID)
            runtime = nil
            hostID = selectedID
            synchronizedOwner = nil
            errorMessage = nil
            connections.retireCapabilities()
        }
        guard selectedID != nil else { return }
        guard let owner = connections.owner else {
            if synchronizedOwner != nil { runtime?.suspend() }
            synchronizedOwner = nil
            return
        }
        if let synchronizedOwner, synchronizedOwner != owner {
            runtime?.suspend()
        }
        synchronizedOwner = owner
        if runtime?.authority != owner.authority {
            runtime?.retire()
            runtime = nil
            do {
                runtime = try NativeWorkspaceRuntime(
                    connections: connections, authority: owner.authority,
                    settings: settings, userIdentity: userIdentity, directory: directory, peerHosts: peerHosts,
                    protectedData: protectedData
                )
                errorMessage = nil
            } catch BighelpLocalPersistenceError.protectedDataUnavailable {
                // Woken while the phone is locked (Background App Refresh, a Shortcut, the Watch): the
                // saved files open once it's unlocked. Unlocking, coming back and Reconnect try again
                // (`reopenIfClosed`).
                errorMessage = nil
                return
            } catch {
                errorMessage = "Saved native workspace data could not be opened. It has not been replaced or adopted by another account."
                return
            }
        }
        if let workspace = connections.hosts.selectedWorkspace, retirementWorkspace !== workspace {
            retirementWorkspace?.onBeforeConnectionRetired = nil
            retirementWorkspace = workspace
            workspace.onBeforeConnectionRetired = { [weak self] in
                self?.runtime?.suspend()
            }
        }
        await runtime?.refresh()
        guard synchronizationKey == requestedKey else { return }
    }

    func receive(host: BighelpConfiguredHost, event: DirectHermesEvent) {
        guard host.id == hostID, host.id == connections.hosts.selectedHostID else { return }
        current?.receive(event)
    }

    /// Opens the workspace if it isn't open, for the same connection. Its usual trigger is a new owner,
    /// but a wake while the phone was locked leaves its connection up: nothing new comes when the
    /// person unlocks and returns, so foreground entry, unlocking and Reconnect call this (#628).
    func reopenIfClosed() async {
        guard current == nil else { return }
        await synchronize()
    }

    /// Parent BighelpApp calls this on foreground entry even when the selected
    /// host/owner synchronization key did not change while the app was away.
    func refreshCurrentRuntimeForForeground() async {
        guard current != nil else { return await reopenIfClosed() }
        let key = synchronizationKey
        guard let owner = connections.owner,
              let runtime = current,
              runtime.authority == owner.authority else { return }
        if runtime.isSuspended || !runtime.isReady {
            // Actual background suspension revokes optional clients as well as
            // the retained adapters, requiring exact-owner bootstrap recovery.
            await runtime.refresh()
        } else {
            // An inactive overlay did not revoke the socket. Keep the canonical
            // non-destructive policy when an optional read fails on foreground.
            if let activeID = runtime.appState.activeConversationID {
                try? await runtime.features.forceRefreshSession(id: activeID)
            }
            guard synchronizationKey == key, !runtime.isSuspended else { return }
            await runtime.refreshActiveSessions()
        }
        guard synchronizationKey == key else { return }
    }

    func suspend() { current?.suspend() }
}

extension DirectHermesApplicationFactory {
    static var workspaceStorageRoot: URL {
        let root = URL.applicationSupportDirectory.appending(path: "LoopdyNativeWorkspaces", directoryHint: .isDirectory)
        #if DEBUG && targetEnvironment(simulator)
        if let runID = ProcessInfo.processInfo.environment["BIGHELP_UI_TEST_RUN_ID"], UUID(uuidString: runID) != nil {
            return root.appending(path: "test-" + runID, directoryHint: .isDirectory)
        }
        #endif
        return root
    }
}
