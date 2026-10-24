#if os(iOS) && !targetEnvironment(macCatalyst)
import CarPlay
import Testing
import UIKit
@testable import Bighelp

/// The car's screens, built as the car gets them: CarPlay refuses a voice picture over 150 points
/// and every state needs End and Agents.
@MainActor
struct CarPlayTemplateTests {
    private let agent = CarPlayAgent(id: "atlas", name: "Atlas", isDefault: false)

    @Test func theVoiceScreenShowsTheAgentsFaceInEveryState() {
        let face = CarPlayFaces.face(for: agent, imageURL: nil, size: CarPlayFaces.voiceSize)
        #expect(face.size.width > 0)
        let states = CarPlayVoiceStates.all(face: face, name: agent.name, end: {}, agents: {})
        #expect(states.map(\.identifier) == ["connecting", "listening", "working", "speaking"])
        for state in states {
            let image = state.image
            #expect(image != nil)
            #expect((image?.size.width ?? 999) <= CarPlayFaces.voiceSize, "\(state.identifier) is 150 points at most")
            #expect((image?.size.height ?? 999) <= CarPlayFaces.voiceSize)
            if #available(iOS 26.4, *) {
                #expect(state.actionButtons.map(\.title) == ["End", "Agents"])
            }
        }
        #expect(states[2].titleVariants?.first == "Atlas is working…")
    }

    @Test func theHomesHeaderCarriesTheFaceStatusAndSteps() {
        guard #available(iOS 26.4, *) else { return }
        let content = CarPlayHeaderContent(agentID: "atlas", name: "Atlas", status: "Searching the web…",
                                           earlierSteps: ["Reading your trip notes…"], isTalking: true)
        let face = CarPlayFaces.face(for: agent, imageURL: nil, size: 96)
        let header = CPListTemplateDetailsHeader(
            thumbnail: CPThumbnailImage(image: face), title: content.name, subtitle: content.status,
            bodyVariants: [NSAttributedString(string: content.earlierSteps.joined(separator: "\n"))], actionButtons: [])
        let home = CPListTemplate(title: "bighelp", listHeader: header, sections: [], assistantCellConfiguration: nil)
        #expect(home.listHeader?.title == "Atlas")
        #expect(home.listHeader?.subtitle == "Searching the web…")
    }

    @Test func theHomeAlwaysOffersTalkAndEndWhileTalking() {
        let idle = CarPlayHeaderContent(agentID: "atlas", name: "Atlas", status: "Tap Talk to start",
                                        earlierSteps: [], isTalking: false)
        #expect(idle.actions.map(\.title) == ["Talk"])
        var talking = idle
        talking.isTalking = true
        // Talk goes back to the voice screen if the car closed it.
        #expect(talking.actions.map(\.title) == ["Talk", "End"])
    }

    @Test func talkGoesBackToTheConversationThatsOnAndStartsOneOtherwise() {
        // Nothing runs before the first start, so the car's first Talk starts a conversation.
        #expect(CarPlayVoiceSession().phase == .paused)
        for phase in [CarPlayVoiceSession.Phase.paused, .problem("Couldn't connect")] {
            #expect(CarPlayTalkAction.for(phase: phase, currentAgentID: "atlas", requestedID: nil) == .startCall)
            #expect(CarPlayTalkAction.for(phase: phase, currentAgentID: "atlas", requestedID: "atlas") == .startCall)
        }
        for phase in [CarPlayVoiceSession.Phase.connecting, .listening, .working, .speaking] {
            // Talk, or tapping the agent in the conversation, shows it again instead of restarting it.
            #expect(CarPlayTalkAction.for(phase: phase, currentAgentID: "atlas", requestedID: nil) == .showCall)
            #expect(CarPlayTalkAction.for(phase: phase, currentAgentID: "atlas", requestedID: "atlas") == .showCall)
            // Another agent starts a conversation with it.
            #expect(CarPlayTalkAction.for(phase: phase, currentAgentID: "atlas", requestedID: "finance") == .startCall)
        }
    }
}
#endif
