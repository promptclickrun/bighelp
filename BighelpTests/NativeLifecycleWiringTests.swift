import Foundation
import Testing
@testable import Bighelp

@MainActor
struct NativeLifecycleWiringTests {
    @Test func profileRemapRejectsAllRowsBeforeChangingAnyOwner() throws {
        var clean = SessionRecord(id: "clean", kind: .direct, agentIDs: ["old"], title: "Clean")
        clean.updatedAt = Date(timeIntervalSince1970: 2)
        var protected = SessionRecord(id: "protected", kind: .direct, agentIDs: ["old"], title: "Draft")
        protected.updatedAt = Date(timeIntervalSince1970: 1)
        protected.draft = "Keep this unsent draft"
        let store = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [clean, protected])
        #expect(store.records.first?.id == "clean")
        #expect(throws: NativeWorkspaceLifecycleError.self) {
            try store.remapProfileOwnership(from: "old", to: "new")
        }
        #expect(store.session(id: "clean")?.agentIDs == ["old"])
        #expect(store.session(id: "protected")?.agentIDs == ["old"])
        #expect(store.session(id: "protected")?.draft == "Keep this unsent draft")
    }

    @Test func verifiedRemapPreservesUnrelatedProfilesAndDurableIdentity() throws {
        let old = SessionRecord(id: "chat", kind: .direct, agentIDs: ["old"], title: "Chat", remoteStoredID: "durable")
        let other = SessionRecord(id: "other", kind: .direct, agentIDs: ["unrelated"], title: "Other")
        let store = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [old, other])
        try store.remapProfileOwnership(from: "old", to: "new")
        #expect(store.session(id: "chat")?.agentIDs == ["new"])
        #expect(store.session(id: "chat")?.remoteStoredID == "durable")
        #expect(store.session(id: "other")?.agentIDs == ["unrelated"])
    }
}
