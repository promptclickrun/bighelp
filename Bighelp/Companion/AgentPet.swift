import SwiftUI

/// The agent a pet companion belongs to: its pet is its own avatar.
struct AgentPetIdentity: Equatable, Sendable {
    let agentID: String
    let name: String
    let imageURL: URL?
}

/// An agent's pet companion: its own face (`AgentFace`), acting out what the chat, voice or
/// home is doing. A kit character reacts as it always has; a petdex pet plays the matching move;
/// a Hermes face or shape plays the designer's state nearest it; a mark acts out the mood; a
/// picture stays still. Reduce Motion and the app in the background hold every one still.
struct AgentPet: View {
    let identity: AgentPetIdentity
    let reaction: CompanionReaction
    var isAnimating = true
    var audioLevel: Double = 0
    var isInteracting = false
    var ambientMotion: CompanionAmbientMotion = .none
    var activityMood: String? = nil

    @Environment(\.companionStore) private var companions
    @Environment(\.companionAgentScope) private var scope

    var body: some View {
        let face = AgentFace.resolve(agentID: identity.agentID, scope: scope, companions: companions)
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            content(face, side: side)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(identity.name) companion")
        .accessibilityValue(reaction.accessibilityDescription)
    }

    @ViewBuilder
    private func content(_ face: AgentFace, side: CGFloat) -> some View {
        switch face {
        case .character(let appearance):
            CompanionAvatar(appearance: appearance, reaction: reaction, isAnimating: isAnimating,
                            audioLevel: audioLevel, isInteracting: isInteracting, ambientMotion: ambientMotion,
                            activityMood: activityMood)
        case .pet(let key):
            if let frames = PetAvatarStore.shared.frames(for: key, move: PetdexMove(reaction: reaction)) {
                PetdexAnimatedAvatar(frames: frames)
            } else {
                picture(side: side)
            }
        case .hermes(let look, let name):
            HermesLookPlayer(look: look, name: name, state: isAnimating ? AvatarPlayState(mood: mood) : .still)
        case .mark(let mark):
            SimpleBotMarkView(mark: mark, size: side * 0.86, blinks: isAnimating, state: liveState,
                              mood: isAnimating ? mood : nil)
        case .picture:
            picture(side: side)
        }
    }

    private var mood: String {
        CompanionAvatar.mood(reaction: reaction, activityMood: activityMood, ambientMotion: ambientMotion, idleMood: nil)
    }

    private func picture(side: CGFloat) -> some View {
        AvatarView(stableID: identity.agentID, displayName: identity.name, imageURL: identity.imageURL,
                   size: side * 0.86, state: liveState)
    }

    private var liveState: AgentLiveState {
        switch reaction {
        case .idle: .idle
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        case .celebrate: .happy
        case .question, .attention, .failed: .nudge
        }
    }
}

extension PetdexMove {
    /// A pet's move for a companion reaction, in Hermes's priority (`derive_pet_state`).
    init(reaction: CompanionReaction) {
        switch reaction {
        case .idle: self = .idle
        case .listening, .question, .attention: self = .waiting
        case .thinking: self = .review
        case .speaking: self = .run
        case .celebrate: self = .jump
        case .failed: self = .failed
        }
    }
}
