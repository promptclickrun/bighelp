import SwiftUI

enum CompanionReaction: String, Codable, CaseIterable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
    case question
    case celebrate
    case attention
    case failed

    var accessibilityDescription: String {
        switch self {
        case .idle: "idle"
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        case .question: "asking a question"
        case .celebrate: "celebrating"
        case .attention: "needs attention"
        case .failed: "showing a failure"
        }
    }

    fileprivate var characterMood: String {
        switch self {
        case .idle: "idle"
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "bounce"
        case .question: "curious"
        case .celebrate: "excited"
        case .attention: "alert"
        case .failed: "sad"
        }
    }
}

/// Composer-owned ambient motion. It never replaces a semantic reaction; it
/// only selects authored idle choreography while the chat itself is idle.
enum CompanionAmbientMotion: Equatable, Sendable {
    case none
    case bounce
    case dance
}

struct CompanionAvatar: View {
    let appearance: CompanionAppearance
    let reaction: CompanionReaction
    let isAnimating: Bool
    var audioLevel: Double = 0
    var isInteracting: Bool = false
    var ambientMotion: CompanionAmbientMotion = .none
    /// An engine mood for what the agent is doing right now (coding, browsing,
    /// making images…). It replaces the idle move while set.
    var activityMood: String? = nil
    /// The kit's backdrop disc. Off: avatars are transparent like Hermes's faces and shapes.
    var showsBackground = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var isInViewport = true
    /// Redraws once a missing catalog pack lands.
    @State private var packArrived = 0

    var body: some View {
        Group {
            let _ = packArrived
            if let (kit, art) = appearance.kitArt, let colors = appearance.avatarKitColors(themeHex: themeHex) {
                AvatarKitView(
                    kit: kit,
                    art: art,
                    headwear: appearance.catalogAvatar == nil ? appearance.character : nil,
                    colors: colors,
                    look: BuddyLook(topper: appearance.topper ?? .none, pattern: appearance.pattern ?? .none),
                    face: appearance.avatarKitFace,
                    mood: mood,
                    isAnimating: effectiveAnimation,
                    showsBackground: showsBackground,
                    showsQuestion: reaction == .question
                )
            }
        }
        .id(appearance.catalogAvatar?.id ?? appearance.character.rawValue)
        // A catalog character picked on this phone keeps its pack; fetch it if it's gone.
        .task(id: appearance.catalogAvatar) {
            guard let reference = appearance.catalogAvatar, appearance.kitArt == nil else { return }
            if await AvatarCatalogStore.shared.pack(for: reference) != nil { packArrived += 1 }
        }
        .modifier(CompanionViewportObserver(isInViewport: $isInViewport))
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(appearance.displayName) companion")
        .accessibilityValue(accessibilityDescription)
    }

    /// Semantic reactions win; otherwise the agent's activity, then the
    /// composer's ambient motion, then the chosen idle move.
    private var mood: String? {
        guard reaction == .idle else { return reaction == .question ? "curious" : reaction.characterMood }
        if let activityMood { return activityMood }
        switch ambientMotion {
        case .none: return appearance.vibe?.moodID ?? reaction.characterMood
        case .bounce: return "bounce"
        case .dance: return "dance"
        }
    }

    /// Keeps each character's authored eye color unless it would disappear
    /// into the chosen body color; then uses ink or snow, whichever reads.
    static func readableEyeColor(authored: String, body: String) -> String {
        let bodyLuminance = CompanionColor.luminance(body)
        let authoredLuminance = CompanionColor.luminance(authored)
        let lighter = max(bodyLuminance, authoredLuminance) + 0.05
        let darker = min(bodyLuminance, authoredLuminance) + 0.05
        if lighter / darker >= 3 { return authored }
        return bodyLuminance > 0.3 ? "#16181B" : "#F5F6F4"
    }

    private var accessibilityDescription: String {
        guard reaction == .idle else { return reaction.accessibilityDescription }
        switch ambientMotion {
        case .none: return reaction.accessibilityDescription
        case .bounce: return "bouncing"
        case .dance: return "dancing"
        }
    }

    @BighelpThemeReader private var theme

    private var themeHex: String {
        CompanionAppearance.validatedColorHex(theme.actionHex) ?? CompanionAppearance.fallbackColorHex
    }

    private var effectiveAnimation: Bool {
        isAnimating && isVisible && isInViewport && !reduceMotion
            && !CompanionAcceptanceFixture.reducedMotion && scenePhase == .active
    }
}
