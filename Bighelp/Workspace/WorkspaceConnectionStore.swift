import Foundation
import Observation
import SwiftUI

/// Projects the existing host registry into the neutral feature-client seam.
/// Authentication, browser presentation, selection and credentials remain owned
/// by BighelpHostRegistry and its DirectHermesWorkspaceStore.
@MainActor
@Observable
final class WorkspaceConnectionStore {
    let hosts: BighelpHostRegistry
    @ObservationIgnored var cloneClient: (any AgentProfileCloneClient)?
    @ObservationIgnored var openCanonicalSession: @MainActor (String, WorkspaceOwner) async throws -> String = { _, _ in
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
    @ObservationIgnored private var cachedWorkspace: DirectHermesWorkspaceClient?
    @ObservationIgnored private var cachedOwner: WorkspaceOwner?
    @ObservationIgnored private var invalidationObservers: [UUID: @MainActor (NativeWorkspaceInvalidationUpdate) -> Void] = [:]
    private(set) var capabilities: WorkspaceCapabilities = .disconnected
    private(set) var invalidationRevision: NativeWorkspaceInvalidationRevision = .disconnected

    init(hosts: BighelpHostRegistry) { self.hosts = hosts }

    var selectedDirectHost: BighelpConfiguredHost? { hosts.selectedHost }
    var isDirectSelected: Bool { hosts.selectedHostID != nil }

    var owner: WorkspaceOwner? {
        guard let selected = hosts.selectedHost, let store = hosts.selectedWorkspace,
              store.isConnected, let saved = store.savedConnection,
              DirectHermesIdentity.matches(saved.identity, selected.principalIdentity),
              let authority = saved.workspaceAuthority else { return nil }
        return WorkspaceOwner(authority: authority, authenticationGeneration: hosts.generation,
                              connectionGeneration: store.connectionGeneration)
    }

    var workspace: DirectHermesWorkspaceClient? {
        guard let owner, let client = hosts.selectedWorkspace?.nativeClient else { return nil }
        if cachedOwner == owner { return cachedWorkspace }
        let value = DirectHermesWorkspaceClient(
            rpc: client, http: client, owner: owner,
            capabilities: capabilities.owner == owner ? capabilities : .init(owner: owner),
            currentOwner: { [weak self] in self?.owner }
        )
        cachedOwner = owner
        cachedWorkspace = value
        return value
    }

    func retireCapabilities() {
        capabilities = .disconnected
        cachedOwner = nil
        cachedWorkspace = nil
        cloneClient = nil
        invalidationRevision = .disconnected
    }

    func installCapabilities(_ value: WorkspaceCapabilities) throws {
        guard let owner, value.owner == owner, let workspace else {
            throw WorkspaceClientError.ownerChanged
        }
        try workspace.installCapabilities(value)
        capabilities = value
    }

    /// Returns the exact currently selected event authority. The WebSocket
    /// callback already fences its private transport generation; this adds the
    /// account, selected host and public workspace owner coordinates consumed by
    /// native invalidation observers. It names no agent: which agent the
    /// connection last opened (a chat from a notification) never changes it.
    func nativeInvalidationSource(authority: WorkspaceAuthority) -> NativeWorkspaceEventSource? {
        guard let host = hosts.selectedHost,
              host.id == hosts.selectedHostID,
              let owner,
              owner.authority == authority,
              let selected = hosts.selectedWorkspace,
              selected.connectionGeneration == owner.connectionGeneration,
              selected.nativeClient != nil else { return nil }
        let servingProfile = workspace?.nativeContext?.servingProfileID
        return NativeWorkspaceEventSource(hostID: host.id, owner: owner, servingProfileID: servingProfile)
    }

    func addInvalidationObserver(
        id: UUID,
        observer: @escaping @MainActor (NativeWorkspaceInvalidationUpdate) -> Void
    ) {
        invalidationObservers[id] = observer
    }

    func removeInvalidationObserver(id: UUID) {
        invalidationObservers[id] = nil
    }

    func publishInvalidation(
        _ notice: NativeWorkspaceInvalidationNotice,
        source: NativeWorkspaceEventSource
    ) {
        guard nativeInvalidationSource(authority: source.owner.authority) == source else { return }
        var revision = invalidationRevision.source == source
            ? invalidationRevision
            : NativeWorkspaceInvalidationRevision(source: source)
        revision.advance(notice.topic)
        invalidationRevision = revision
        let update = NativeWorkspaceInvalidationUpdate(source: source, revision: revision, notice: notice)
        let observers = Array(invalidationObservers.values)
        for observer in observers { observer(update) }
    }
}

private struct WorkspaceConnectionsKey: EnvironmentKey {
    static let defaultValue: WorkspaceConnectionStore? = nil
}

extension EnvironmentValues {
    var workspaceConnections: WorkspaceConnectionStore? {
        get { self[WorkspaceConnectionsKey.self] }
        set { self[WorkspaceConnectionsKey.self] = newValue }
    }
}
