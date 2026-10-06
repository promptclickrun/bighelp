import Foundation
import Testing
@testable import Bighelp

/// One connection, one agent: what a passing check (a tapped alert) selects doesn't stay behind.
@MainActor
struct ConnectionContractTests {
    @Test func aTappedAlertsAgentDoesNotStaySelected() async throws {
        let store = DirectHermesWorkspaceStore(vault: MemoryVault(nil))
        store.selectedProfile = "default"

        let seen = await store.visiting(profile: "alfie") { store.selectedProfile }
        #expect(seen == "alfie")
        #expect(store.selectedProfile == "default", "Gateway restarts and alert setup act for the app's agent again")

        await #expect(throws: DirectHermesError.self) {
            try await store.visiting(profile: "alfie") { throw DirectHermesError.invalidResponse }
        }
        #expect(store.selectedProfile == "default", "A failed check puts it back too")
    }

    /// Every screen and service asks the same question: up, and signed in to this host's computer?
    @Test func oneCheckSaysWhetherAConnectionIsThisComputers() throws {
        let endpoint = try DirectHermesEndpoint(address: "https://host.example")
        func signIn(_ user: String) -> DirectHermesSavedConnection {
            DirectHermesSavedConnection(endpoint: endpoint, authentication: .bearer(
                accessToken: UUID().uuidString, refreshToken: nil, expiresAt: nil), provider: "basic", userID: user)
        }
        let mine = signIn("sam"), someoneElse = signIn("alex")
        let host = BighelpConfiguredHost(id: UUID(), accountScope: "scope", accountID: "account", endpoint: endpoint,
                                         principalIdentity: mine.identity, name: "Studio")
        #expect(host.owns(mine))
        #expect(!host.owns(someoneElse))

        let store = DirectHermesWorkspaceStore(vault: MemoryVault(mine))
        #expect(throws: DirectHermesError.notConnected) {
            try store.verifiedConnection(for: host, generation: UUID())
        }
    }
}
