import Foundation
import Testing
@testable import Bighelp

@MainActor
struct UserIdentityStoreTests {
    @Test func identityPersistsAcrossStoreRecreation() {
        let defaults = isolatedDefaults()
        let store = UserIdentityStore(defaults: defaults)

        store.identity = UserIdentity(name: "Maya", avatarFileName: "maya.png")

        let restored = UserIdentityStore(defaults: defaults)
        #expect(restored.identity.name == "Maya")
        #expect(restored.identity.avatarFileName == "maya.png")
    }

    @Test func nameOnlyLocalSavePersistsWithoutAnAccount() {
        let defaults = isolatedDefaults()
        let store = UserIdentityStore(defaults: defaults)
        store.saveDisplayName("  Maya  ")
        #expect(store.identity.name == "Maya")
        #expect(UserIdentityStore(defaults: defaults).identity.name == "Maya")
    }

    /// Your name reaches agents, so saving an empty name removes it on purpose
    /// ("Remove name" in Settings).
    @Test func savingABlankNameRemovesItWithoutAnAccount() {
        let store = UserIdentityStore(defaults: isolatedDefaults())
        store.identity.name = "Maya"
        store.saveDisplayName(" \n ")
        #expect(store.identity.name.isEmpty)
        #expect(store.identity.displayName == "You")
    }

    @Test func stableIdentityUsesTheLocalUserID() {
        #expect(UserIdentity.stableID == "local-user")
    }

    @Test func legacyIdentityWithoutAccountFieldsMigratesWithoutResettingTheProfile() throws {
        let defaults = isolatedDefaults()
        defaults.set(
            Data("""
            {"name":"Maya","avatarFileName":"maya.png"}
            """.utf8),
            forKey: "loopdy.demo.userIdentity"
        )

        let store = UserIdentityStore(defaults: defaults)

        #expect(store.identity.name == "Maya")
        #expect(store.identity.avatarFileName == "maya.png")
    }
}
