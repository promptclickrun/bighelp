import SwiftUI

extension ChatModel {
    /// What the agent in this chat is doing right now, from the live stream:
    /// the running tool decides (code, web, images…), then streaming text,
    /// then plain thinking.
    var liveActivityKind: AgentActivityKind {
        guard isSending else { return .idle }
        let running = activityLedger.allEvents.last { event in
            event.lifecycle == .running && (event.kind == .tool || event.kind == .subagent)
        }
        if let running {
            if running.kind == .subagent { return .delegating }
            return AgentActivityKind(toolName: running.toolName ?? running.title)
        }
        if case .message(let item)? = transcriptEntries.last,
           item.role == .assistant, item.metadata.delivery == "Streaming" {
            return .replying
        }
        return .thinking
    }

    /// The step the agent itself is on, in plain words ("Checking your
    /// calendars…"), for voice mode's status line. A helper's own steps stay
    /// inside its folder; its delegation reads "Asking another agent…".
    var liveStepPhrase: String? {
        guard isSending else { return nil }
        return activityLedger.allEvents.last { event in
            event.lifecycle == .running
                && (event.kind == .subagent || (event.kind == .tool && event.subagentID == nil))
        }?.toolPhrase.live
    }
}

/// The agent's face across the app. A designed pet plays a move for each kind
/// of work, a petdex pet plays its own sheet's move, and a photo avatar gets a
/// matching motion. A small badge names the work (code, web, images…) so the
/// difference reads at a glance.
struct AgentLiveAvatar: View {
    let agentID: String
    let displayName: String
    let imageURL: URL?
    var activity: AgentActivityKind = .idle
    var size: CGFloat = 88
    var showsBadge = true
    /// Off on the island's stage, where the pet walks around bare.
    var showsBackdrop = true
    /// How the face rests with no work (voice mode shows listening).
    var restingState: AgentLiveState = .idle

    @Environment(\.companionStore) private var companionStore
    @Environment(\.agentActivityInIsland) private var activityInIsland
    @Environment(\.companionAgentScope) private var companionAgentScope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            face
                .frame(width: size, height: size)
            // With a Dynamic Island, the island names the work instead.
            if activity != .idle, showsBadge, !activityInIsland {
                badge
                    .offset(x: size * 0.04, y: size * 0.02)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: activity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayName)
        .accessibilityValue(activity.label)
    }

    private var look: CompanionAppearance? {
        guard let companionStore, !companionAgentScope.isEmpty else { return nil }
        return companionStore.override(for: CompanionStore.agentKey(agentScope: companionAgentScope, agentID: agentID))
    }

    private var petFrames: [CGImage]? {
        guard !companionAgentScope.isEmpty else { return nil }
        let move = activity == .idle && restingState == .listening ? .waiting : PetdexMove(activity: activity)
        return PetAvatarStore.shared.frames(
            for: CompanionStore.agentKey(agentScope: companionAgentScope, agentID: agentID), move: move)
    }

    @ViewBuilder
    private var face: some View {
        if let look {
            Circle()
                .fill(backdrop(look).opacity(showsBackdrop ? 0.18 : 0))
                .overlay(Circle().strokeBorder(backdrop(look).opacity(showsBackdrop ? 0.25 : 0), lineWidth: 1))
                .overlay {
                    CompanionAvatar(
                        appearance: look,
                        reaction: companionReaction,
                        isAnimating: true,
                        activityMood: activity.moodID
                    )
                    .frame(width: size * 0.82, height: size * 0.82)
                }
        } else if let petFrames {
            // Pets are drawn with dark outlines, so the disc stays light in dark mode.
            Circle()
                .fill(theme.action.opacity(showsBackdrop ? (colorScheme == .dark ? 0.45 : 0.12) : 0))
                .overlay(Circle().strokeBorder(theme.action.opacity(showsBackdrop ? 0.2 : 0), lineWidth: 1))
                .overlay {
                    PetdexAnimatedAvatar(frames: petFrames)
                        .frame(width: size * 0.86, height: size * 0.86)
                }
        } else {
            AvatarView(stableID: agentID, displayName: displayName, imageURL: imageURL,
                       size: size, state: liveState)
                .modifier(ActivityMotion(activity: activity, enabled: !reduceMotion))
        }
    }

    private var companionReaction: CompanionReaction {
        switch activity {
        case .done: .celebrate
        case .failed: .failed
        case .waiting: .attention
        default: .idle
        }
    }

    private var liveState: AgentLiveState {
        switch activity {
        case .idle: restingState
        case .replying, .messaging: .speaking
        case .done, .publishing: .happy
        case .waiting: .nudge
        default: .thinking
        }
    }

    private var badge: some View {
        Image(systemName: activity.systemImage)
            .font(.system(size: max(11, size * 0.15), weight: .bold))
            .foregroundStyle(theme.actionForeground)
            .frame(width: max(22, size * 0.3), height: max(22, size * 0.3))
            .background(Circle().fill(activity == .failed ? theme.danger : theme.action))
            .overlay(Circle().strokeBorder(theme.canvas, lineWidth: 2.5))
            .symbolEffect(.pulse, options: .repeating, isActive: activity.isWorking && !reduceMotion)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    private func backdrop(_ look: CompanionAppearance) -> Color {
        let hex = look.matchesTheme
            ? CompanionAppearance.validatedColorHex(theme.actionHex) ?? CompanionAppearance.fallbackColorHex
            : look.colorHex
        return Color(hex: String(hex.dropFirst()))
    }

    @BighelpThemeReader private var theme
}

/// Motion for photo avatars: each kind of work moves differently.
private struct ActivityMotion: ViewModifier {
    let activity: AgentActivityKind
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, activity.isWorking {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                content
                    .scaleEffect(scale(t))
                    .rotationEffect(.degrees(rotation(t)))
                    .offset(x: offsetX(t), y: offsetY(t))
            }
        } else {
            content
        }
    }

    private func scale(_ t: Double) -> Double {
        switch activity {
        case .thinking: 1 + 0.03 * sin(t * 2.2)
        case .images, .publishing: 1 + 0.05 * sin(t * 5)
        default: 1
        }
    }

    private func rotation(_ t: Double) -> Double {
        switch activity {
        case .web, .seeing: 6 * sin(t * 1.6)
        case .images: 4 * sin(t * 3.1)
        default: 0
        }
    }

    private func offsetX(_ t: Double) -> Double {
        switch activity {
        case .coding, .files, .tools: 1.5 * sin(t * 22)
        default: 0
        }
    }

    private func offsetY(_ t: Double) -> Double {
        switch activity {
        case .replying, .messaging, .delegating: -4 * abs(sin(t * 3.2))
        case .memory: 2 * sin(t * 1.4)
        default: 0
        }
    }
}

/// Avatar with the agent's name pill below it, used at the top of the chat,
/// Feed, Ideas, Goals and Apps. The avatar opens the agent's profile; the name
/// pill switches agents.
struct AgentHeroHeader: View {
    let agentID: String
    let displayName: String
    let imageURL: URL?
    var activity: AgentActivityKind = .idle
    var avatarSize: CGFloat = 84
    /// Replaces the activity line, e.g. "Updating…" while a chat reloads.
    var status: String? = nil
    /// Hidden by choice (Settings › Chat layout): the chip shows only while
    /// there's a status, and holding the avatar offers Switch agent.
    var showsName = true
    let onAvatarTap: () -> Void
    let onNameTap: () -> Void
    @Environment(\.agentActivityInIsland) private var activityInIsland

    var body: some View {
        VStack(spacing: 2) {
            Button(action: onAvatarTap) {
                AgentLiveAvatar(agentID: agentID, displayName: displayName, imageURL: imageURL,
                                activity: activity, size: avatarSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayName) profile")
            .accessibilityValue(activity.label)
            .accessibilityHint("Opens activity, approvals, schedules and identity.")
            .accessibilityIdentifier("agent.hero.avatar")
            .contextMenu {
                if !showsName {
                    Button("Open profile", systemImage: "person.crop.circle", action: onAvatarTap)
                    Button("Switch agent", systemImage: "arrow.left.arrow.right", action: onNameTap)
                }
            }
            .accessibilityActions {
                if !showsName { Button("Switch agent", action: onNameTap) }
            }
            if showsName || statusLine != nil {
            Button(action: onNameTap) {
                VStack(spacing: 1) {
                    if showsName {
                        Text(displayName)
                            .font(.bighelp(.subheadline).weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                    }
                    if let line = statusLine {
                        Text(line)
                            .font(.bighelp(.caption2).weight(.medium))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, 6)
                .frame(minHeight: 34)
                .contentShape(.capsule)
                .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayName)
            .accessibilityValue(statusLine ?? "")
            .accessibilityHint("Switch agents or open a group chat.")
            .accessibilityIdentifier("agent.hero.name")
            .transition(.opacity)
            }
        }
        .animation(.snappy, value: activity)
        .animation(.snappy, value: status)
        .animation(.snappy, value: avatarSize)
    }

    private var statusLine: String? {
        if let status { return status }
        return activity != .idle && !activityInIsland ? activity.label : nil
    }

    @BighelpThemeReader private var theme
}
