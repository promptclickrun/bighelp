// Live Activities are iPhone and iPad only; Vision Pro gets the Home widgets.
#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

struct BighelpSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LoopdySessionActivityAttributes.self) { context in
            // The app's own page and bubble colors (Settings › Colors), like the Home widgets.
            let snapshot = BighelpWidgetSnapshot.load()
            BighelpLiveActivityCard(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale,
                snapshot: snapshot
            )
            .activityBackgroundTint(BighelpActivityColors.canvas(snapshot: snapshot))
            .activitySystemActionForegroundColor(BighelpActivityColors.accent(snapshot: snapshot))
            .widgetURL(context.state.sessions == nil ? context.attributes.deepLink : BighelpWidgetSnapshot.sessionsURL)
        } dynamicIsland: { context in
            if context.state.sessions != nil { return sharedIsland(context) }
            let presentation = BighelpActivityPresentation(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            )
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BighelpActivityAvatar(agentID: context.attributes.agentID,
                                         name: presentation.agentName, diameter: 44)
                        .overlay(alignment: .bottomTrailing) { islandBadge(presentation, size: 18) }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(presentation.agentName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(presentation.status)
                            .font(.headline)
                            .foregroundStyle(presentation.pose.tint)
                            .contentTransition(.opacity)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(presentation.accessibilityLabel)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: presentation.symbolName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(presentation.pose.tint)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let detail = presentation.detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .accessibilityHidden(true)
                        }
                        if !context.isStale {
                            BighelpActivitySteps(phase: context.state.phase, color: presentation.pose.tint,
                                                 track: .white.opacity(0.18))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                BighelpActivityAvatar(agentID: context.attributes.agentID,
                                     name: presentation.agentName, diameter: 24)
                    .accessibilityHidden(false)
                    .accessibilityLabel(presentation.agentName)
            } compactTrailing: {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(presentation.pose.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityLabel(presentation.status)
            } minimal: {
                BighelpActivityAvatar(agentID: context.attributes.agentID,
                                     name: presentation.agentName, diameter: 22)
                    .overlay(alignment: .bottomTrailing) { islandBadge(presentation, size: 11) }
                    .accessibilityLabel(presentation.accessibilityLabel)
            }
            .keylineTint(Color(widgetHex: BighelpWidgetSnapshot.Palette.emberDark.accentHex))
            .widgetURL(context.attributes.deepLink)
        }
    }

    private func sharedIsland(_ context: ActivityViewContext<LoopdySessionActivityAttributes>) -> DynamicIsland {
        let rows = context.state.sessions ?? []
        let attention = !context.isStale && rows.contains { $0.phase == .waiting }
        let count = context.state.activeCount ?? rows.filter { !$0.phase.isTerminal }.count
        let symbol = context.isStale ? "pause.circle" : attention ? "questionmark.circle.fill" : count == 0 ? "checkmark.circle" : "circle.dashed"
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Text("bighelp").font(.system(.caption, design: .rounded, weight: .bold))
            }
            DynamicIslandExpandedRegion(.trailing) {
                Text(context.isStale ? "Paused" : attention ? "Needs you" : "\(count) active")
                    .font(.caption.weight(.semibold)).foregroundStyle(attention ? .orange : .secondary)
            }
            DynamicIslandExpandedRegion(.bottom) {
                BighelpActivityRowsView(state: context.state, isStale: context.isStale, maximumRows: 3, showsHeader: false)
                    .padding(.vertical, 4)
            }
        } compactLeading: {
            Image(systemName: "bubble.left.and.bubble.right.fill").accessibilityLabel("bighelp")
        } compactTrailing: {
            Image(systemName: symbol).foregroundStyle(attention ? .orange : .secondary)
                .accessibilityLabel(context.isStale ? "Updates paused" : "\(count) active chats")
        } minimal: {
            Image(systemName: symbol).foregroundStyle(attention ? .orange : .secondary)
        }
        .widgetURL(rows.first.map { BighelpWidgetSnapshot.chatURL($0.id) } ?? BighelpWidgetSnapshot.sessionsURL)
    }

    /// The kind of work on the avatar's corner: code, globe, paintbrush…
    private func islandBadge(_ presentation: BighelpActivityPresentation, size: CGFloat) -> some View {
        Image(systemName: presentation.symbolName)
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Circle().fill(presentation.pose.tint))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}
#endif
