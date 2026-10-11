import Foundation
import Testing
@testable import Bighelp

@MainActor
struct PinnedModelTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "PinnedModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    private func provider(_ id: String, models: [String]) -> BighelpLinkModelProvider {
        .init(id: id, name: id, isCurrent: false, isCustom: false, models: models)
    }

    @Test func pinsPersistAndUnpinWithoutAffectingRecents() {
        withDefaults { defaults in
            let store = RecentModelHistoryStore(defaults: defaults)
            store.record(providerID: "a", modelID: "recent")
            #expect(store.togglePin(providerID: "a", modelID: "favorite"))
            let restored = RecentModelHistoryStore(defaults: defaults)
            #expect(restored.isPinned(providerID: "a", modelID: "favorite"))
            let catalog = [provider("a", models: ["current", "recent", "favorite"])]
            #expect(restored.choices(providers: catalog, currentProviderID: "a", currentModelID: "current").first?.modelID == "favorite")
            #expect(!restored.togglePin(providerID: "a", modelID: "favorite"))
            #expect(!RecentModelHistoryStore(defaults: defaults).isPinned(providerID: "a", modelID: "favorite"))
            #expect(restored.choices(providers: catalog, currentProviderID: "a", currentModelID: "current").map(\.modelID).contains("recent"))
        }
    }

    @Test func recentFilterListsOnlyPickedModelsNewestFirst() {
        withDefaults { defaults in
            let store = RecentModelHistoryStore(defaults: defaults)
            store.record(providerID: "a", modelID: "older")
            store.record(providerID: "a", modelID: "gone")
            store.record(providerID: "b", modelID: "newest")
            let catalog = [provider("a", models: ["first", "older"]), provider("b", models: ["newest"])]
            let recent = store.recentChoices(providers: catalog, currentProviderID: "a", currentModelID: "first")
            #expect(recent.map(\.modelID) == ["newest", "older"])
        }
    }

    @Test func pinsStayWithinLiveScopeAndNilDoesNotWrite() {
        withDefaults { defaults in
            var scope: String? = "device-a:host-a"
            let store = RecentModelHistoryStore(defaults: defaults, scopeID: { scope })
            #expect(store.togglePin(providerID: "p", modelID: "m"))
            scope = "device-b:host-a"
            #expect(!store.isPinned(providerID: "p", modelID: "m"))
            scope = nil
            let prior = defaults.data(forKey: "loopdy.models.pinned")
            #expect(!store.togglePin(providerID: "p", modelID: "other"))
            #expect(defaults.data(forKey: "loopdy.models.pinned") == prior)
            scope = "device-a:host-a"
            #expect(store.isPinned(providerID: "p", modelID: "m"))
        }
    }

    @Test func exactProviderModelIdentityAndUnavailablePinsSurvive() {
        withDefaults { defaults in
            let store = RecentModelHistoryStore(defaults: defaults)
            store.togglePin(providerID: "a:b", modelID: "c")
            store.togglePin(providerID: "a", modelID: "b:c")
            let both = [provider("a:b", models: ["c"]), provider("a", models: ["b:c"])]
            #expect(store.pinnedChoices(providers: both, currentProviderID: nil, currentModelID: nil).count == 2)
            #expect(store.pinnedChoices(providers: [], currentProviderID: nil, currentModelID: nil).isEmpty)
            #expect(store.isPinned(providerID: "a:b", modelID: "c"))
            #expect(store.pinnedChoices(providers: both, currentProviderID: nil, currentModelID: nil).count == 2)
        }
    }

    @Test func reachingPinCapacityDoesNotDeleteSavedFavorites() {
        withDefaults { defaults in
            let store = RecentModelHistoryStore(defaults: defaults)
            for n in 0..<12 { #expect(store.togglePin(providerID: "p", modelID: "m\(n)")) }
            #expect(!store.togglePin(providerID: "p", modelID: "thirteenth"))
            for n in 0..<12 { #expect(store.isPinned(providerID: "p", modelID: "m\(n)")) }
            #expect(!store.isPinned(providerID: "p", modelID: "thirteenth"))
        }
    }
}
