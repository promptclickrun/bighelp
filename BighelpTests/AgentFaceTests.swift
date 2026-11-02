import Foundation
import Testing
@testable import Bighelp

/// Every surface draws an agent's face in one order, a working face acts its work out, and a pet
/// companion is its agent's own avatar.
@MainActor
struct AgentFaceTests {
    private func profile(_ id: String, look: AgentAvatarLook?) -> AgentProfile {
        AgentProfile(id: id, name: "Agent \(id)", role: "", summary: "", instructions: "", isDefault: false, look: look)
    }

    @Test func hermesLooksComeFromTheComputersProfiles() {
        let store = AgentLookStore()
        let face = AgentAvatarLook(style: .face, shape: "blobatar:seed")
        let shape = AgentAvatarLook(style: .shape, shape: "hexagon", color: "#336699")
        store.publish(scope: "computer:a", profiles: [profile("one", look: face), profile("two", look: shape),
                                                       profile("three", look: .photo), profile("four", look: nil)])
        store.publish(scope: "computer:b", profiles: [profile("one", look: shape)])
        #expect(store.looks[CompanionStore.agentKey(agentScope: "computer:a", agentID: "one")]?.look == face)
        #expect(store.looks[CompanionStore.agentKey(agentScope: "computer:a", agentID: "two")]?.look == shape)
        #expect(store.looks[CompanionStore.agentKey(agentScope: "computer:a", agentID: "three")] == nil,
                "A photo draws as its picture")
        #expect(store.looks[CompanionStore.agentKey(agentScope: "computer:a", agentID: "four")] == nil)
        // A later read replaces that computer's looks only.
        store.publish(scope: "computer:a", profiles: [profile("one", look: .photo)])
        #expect(store.looks[CompanionStore.agentKey(agentScope: "computer:a", agentID: "one")] == nil)
        #expect(store.looks[CompanionStore.agentKey(agentScope: "computer:b", agentID: "one")]?.look == shape)
    }

    @Test func otherGatewaysRetainHermesLooksWithoutReplacingTheLiveGateway() throws {
        let store = AgentLookStore()
        let live = UUID(), other = UUID()
        let look = AgentAvatarLook(style: .shape, shape: "hexagon", color: "#336699")
        let liveScope = CompanionSurfaceScope.computer(live.uuidString)
        store.publish(scope: liveScope, profiles: [profile("bot", look: look)])
        let remote = FleetAgent(hostID: other, profileID: "bot", name: "Remote", role: "", isPinned: false,
                                isDefault: false, look: look)
        let snapshot = FleetSnapshot(agents: [remote], refreshedAt: .now)
        let restored = try JSONDecoder().decode(FleetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored.agents.first?.look == look)
        store.publish(fleet: [other: restored, live: FleetSnapshot(refreshedAt: .now)], excluding: liveScope)
        #expect(store.looks[CompanionStore.agentKey(agentScope: CompanionSurfaceScope.computer(other.uuidString),
                                                  agentID: "bot")]?.look == look)
        #expect(store.looks[CompanionStore.agentKey(agentScope: liveScope, agentID: "bot")]?.look == look)
    }

    @Test func faceOrderIsCharacterThenHermesThenMarkThenPicture() {
        let scope = "computer:face-order-\(UUID().uuidString)"
        let companions = CompanionStore(defaults: UserDefaults(suiteName: "agent-face-\(UUID().uuidString)")!)
        let key = CompanionStore.agentKey(agentScope: scope, agentID: "bot")
        let marks = SimpleBotMarkStore.shared
        defer {
            marks.set(nil, scope: scope, agentID: "bot")
            AgentLookStore.shared.publish(scope: scope, profiles: [])
        }
        #expect(AgentFace.resolve(agentID: "bot", scope: scope, companions: companions) == .picture)
        #expect(!AgentFace.picture.moves, "A photo never moves by itself")

        let mark = SimpleBotMark(shape: .star, color: .teal)
        marks.set(mark, scope: scope, agentID: "bot")
        #expect(AgentFace.resolve(agentID: "bot", scope: scope, companions: companions) == .mark(mark))

        let look = AgentAvatarLook(style: .face, shape: "blobatar")
        AgentLookStore.shared.publish(scope: scope, profiles: [profile("bot", look: look)])
        #expect(AgentFace.resolve(agentID: "bot", scope: scope, companions: companions) == .hermes(look, name: "Agent bot"),
                "The computer's Hermes face wins over a mark kept on this device")

        let character = CompanionAppearance(character: .fox)
        companions.setOverride(character, for: key)
        #expect(AgentFace.resolve(agentID: "bot", scope: scope, companions: companions) == .character(character))
        #expect(AgentFace.resolve(agentID: "bot", scope: "", companions: companions) == .picture,
                "No computer chosen: nothing kept on this device shows")
    }

    /// Real work only: idle plays the rest, and every kind of work plays a move of its own.
    @Test(arguments: AgentActivityKind.allCases)
    func everyWorkHasAMoveForEachFamily(_ activity: AgentActivityKind) {
        if activity == .idle {
            #expect(activity.moodID == nil)
            #expect(activity.hermesPlayState == .idle)
            return
        }
        let mood = activity.moodID
        #expect(mood.map(BuddyPose.moods.contains) == true, "Characters and marks act it out")
        #expect(activity.hermesPlayState.animates, "Hermes faces play a designer state for it")
        #expect(activity.hermesPlayState != .idle)
    }

    /// A pet's reactions reach Hermes faces as the designer's own states.
    @Test(arguments: CompanionReaction.allCases)
    func petReactionsMapToHermesStates(_ reaction: CompanionReaction) {
        let mood = CompanionAvatar.mood(reaction: reaction, activityMood: nil, ambientMotion: .none, idleMood: nil)
        let state = AvatarPlayState(mood: mood)
        #expect(state.animates)
        #expect(reaction == .idle ? state == .idle : state != .idle)
    }

    @Test func workingBadgesShowOnlyWhereTheFaceCantActItOut() {
        #expect(!SimpleBotFace.showsBadge(for: .working(tool: "web_search"), faceMoves: true))
        #expect(SimpleBotFace.showsBadge(for: .working(tool: "web_search"), faceMoves: false))
        #expect(SimpleBotFace.showsBadge(for: .waiting, faceMoves: true), "Needs you always shows its hand")
        #expect(!SimpleBotFace.showsBadge(for: .idle, faceMoves: false))
    }

    @Test func petsPlayTheirSheetsMoves() {
        #expect(PetdexMove(reaction: .idle) == .idle)
        #expect(PetdexMove(reaction: .thinking) == .review)
        #expect(PetdexMove(reaction: .question) == .waiting)
        #expect(PetdexMove(reaction: .failed) == .failed)
    }
}
