import Foundation

/// A connection that is up and signed in to the computer its host was saved for. Screens and services
/// ask for one each time they act (`DirectHermesWorkspaceStore.verifiedConnection(for:generation:)`)
/// and don't keep it: a reconnect or another sign-in replaces it.
struct VerifiedHostConnection {
    let client: DirectHermesClient
    let saved: DirectHermesSavedConnection
    let owner: WorkspaceOwner
}

extension BighelpConfiguredHost {
    /// The one check that a sign-in is for this host: the same computer, as the same person.
    func owns(_ connection: DirectHermesSavedConnection) -> Bool {
        DirectHermesIdentity.matches(connection.identity, principalIdentity)
    }
}

extension DirectHermesWorkspaceStore {
    /// Throws `notConnected` while the connection is down and `identityChanged` when it is signed in to
    /// another computer than `host`. `generation` is the host list's sign-in generation.
    func verifiedConnection(for host: BighelpConfiguredHost, generation: UUID) throws -> VerifiedHostConnection {
        guard isConnected, let client = nativeClient, let saved = savedConnection else { throw DirectHermesError.notConnected }
        guard host.owns(saved) else { throw DirectHermesError.identityChanged }
        guard let authority = saved.workspaceAuthority else { throw DirectHermesError.notConnected }
        return VerifiedHostConnection(client: client, saved: saved, owner: WorkspaceOwner(
            authority: authority, authenticationGeneration: generation, connectionGeneration: connectionGeneration))
    }
}
