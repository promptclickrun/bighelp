import Foundation
import Testing
@testable import Bighelp

@MainActor
struct CompanionStoreTests {
    @Test func sizeAndAdventurePersistWithoutReplacingCharacterOverrides() throws {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        store.setOverride(.init(character: .dragon), for: "my-host:my-agent")
        store.sizeScale = 1.35
        store.isAdventurous = true
        store.isEnabled = false
        let restored = CompanionStore(defaults: defaults)
        #expect(restored.sizeScale == 1.35)
        #expect(restored.isAdventurous)
        #expect(!restored.isEnabled)
        #expect(restored.agentOverrides == store.agentOverrides)
    }

    @Test func schemaOneWithoutNewKeysKeepsExistingPetChoices() throws {
        let defaults = isolatedDefaults()
        let bytes = Data(##"{"schemaVersion":1,"isEnabled":true,"defaultAppearance":{"character":"clip","colorHex":"#123456","matchesTheme":false},"agentOverrides":{"host:agent":{"character":"fox","colorHex":"#123456","matchesTheme":false}}}"##.utf8)
        defaults.set(bytes, forKey: "loopdy.companion.preferences")
        let restored = CompanionStore(defaults: defaults)
        #expect(restored.isEnabled)
        #expect(restored.override(for: "host:agent")?.character == .fox, "Agents' characters stay their avatars")
        #expect(restored.sizeScale == 1)
        #expect(!restored.isAdventurous)
    }

    /// Each pet is its agent's avatar now, but an older build reads these preferences only with
    /// the app default it had: it still gets one, so going back keeps the switch, size and characters.
    @Test func savedPreferencesStillReadInOlderBuilds() throws {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        store.isEnabled = true
        store.setOverride(.init(character: .owl), for: "host:agent")
        let data = try #require(defaults.data(forKey: "loopdy.companion.preferences"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let legacy = try #require(object["defaultAppearance"] as? [String: Any])
        #expect(legacy["character"] as? String != nil && legacy["colorHex"] as? String != nil)
        #expect(object["isEnabled"] as? Bool == true)
    }

    @Test func companionScaleRejectsNonfiniteAndOutOfRangeValues() {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        for value in [Double.nan, .infinity, -.infinity, -3, 500] {
            store.sizeScale = value
            #expect(store.sizeScale.isFinite)
            #expect((0.6...1.5).contains(store.sizeScale))
            #expect(CompanionStore(defaults: defaults).sizeScale == store.sizeScale)
        }
    }

    @Test func petsAreOptInAndAllSuppliedChoicesExist() {
        let store = CompanionStore(defaults: isolatedDefaults())
        #expect(!store.isEnabled)
        #expect(Set(CompanionCharacter.allCases.map(\.rawValue)) == Set([
            "lobster", "messenger", "zeus", "octopus", "robot", "dragon", "owl", "cat", "fox", "dog",
            "orb", "cube", "wedge", "hex", "drop", "capsule", "cloud", "ghost", "bloom", "gem",
        ]))
    }

    @Test func anAgentsCharacterIsExactlyItsOwn() {
        let store = CompanionStore(defaults: isolatedDefaults())
        let override = CompanionAppearance(character: .robot, colorHex: "#33AADD", matchesTheme: false)
        store.setOverride(override, for: "host-a:agent-a")
        #expect(store.override(for: "host-a:agent-a") == override)
        #expect(store.override(for: "host-b:agent-a") == nil)
        #expect(store.override(for: "host-a:agent-b") == nil)
        store.setOverride(nil, for: "host-a:agent-a")
        #expect(store.override(for: "host-a:agent-a") == nil)
    }

    @Test func disablingRetainsChoicesAcrossReopen() {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        let override = CompanionAppearance(character: .octopus, colorHex: "#3366AA", matchesTheme: true)
        store.isEnabled = true
        store.setOverride(override, for: "host:agent")
        store.isEnabled = false
        let restored = CompanionStore(defaults: defaults)
        #expect(!restored.isEnabled)
        #expect(restored.override(for: "host:agent") == override)
        restored.isEnabled = true
        #expect(restored.override(for: "host:agent") == override)
    }

    @Test func everyAcceptedOverrideSurvivesTheStorageByteLimit() {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        for index in 0..<256 {
            store.setOverride(.init(character: .robot, colorHex: "#ABCDEF", matchesTheme: false),
                              for: String(repeating: "a", count: 480) + "-\(index)")
        }
        let restored = CompanionStore(defaults: defaults)
        #expect(restored.agentOverrides == store.agentOverrides)
    }

    @Test func scopedAgentKeysCannotCollideAtSeparators() {
        #expect(CompanionStore.agentKey(agentScope: "a:b", agentID: "c")
                != CompanionStore.agentKey(agentScope: "a", agentID: "b:c"))
    }

}
