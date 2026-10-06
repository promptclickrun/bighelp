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
}
