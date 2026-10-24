#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import Foundation
import SwiftUI
import UIKit

/// Keeps its original "Loopdy" name: push-started Live Activities name this type,
/// and BuzzKit sends the type name to the push service.
struct LoopdySessionActivityAttributes: Codable, Hashable, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case thinking
            case waiting
            case usingTool = "using_tool"
            case delegating
            case responding
            case completed
            case failed

            var isTerminal: Bool {
                self == .completed || self == .failed
            }
        }

        let phase: Phase
        let currentAction: String
        let progress: Int
        let completedSteps: Int
        let activeSubagentCount: Int
        let latestTool: String?
        let timestamp: Int
        var sessions: [BighelpActivitySession]? = nil
        var activeCount: Int? = nil
        var activeRows: [String]? = nil

        static func initial(agentName: String, timestamp: Int) -> ContentState {
            let name = BighelpActivityText.personName(agentName) ?? "Your agent"
            return ContentState(
                phase: .thinking,
                currentAction: "\(name) is getting started",
                progress: 0,
                completedSteps: 0,
                activeSubagentCount: 0,
                latestTool: nil,
                timestamp: max(1, timestamp)
            )
        }
    }

    let sessionID: String
    let sessionTitle: String
    let agentID: String
    let agentName: String

    var deepLink: URL {
        URL(string: "loopdy://chat/\(sessionID)")!
    }

    static func make(
        sessionID: String,
        sessionTitle: String,
        agentID: String,
        agentName: String
    ) -> LoopdySessionActivityAttributes? {
        guard
            let sessionID = BighelpActivityText.coordinate(sessionID, maximum: 128),
            let agentID = BighelpActivityText.coordinate(agentID, maximum: 96),
            let agentName = BighelpActivityText.personName(agentName)
        else { return nil }
        // Retain the required v1 key without copying private chat titles.
        let title = "Active session"
        return LoopdySessionActivityAttributes(
            sessionID: sessionID,
            sessionTitle: title,
            agentID: agentID,
            agentName: agentName
        )
    }
}

enum BighelpActivityText {
    static func coordinate(_ value: String, maximum: Int) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            value == normalized,
            !normalized.isEmpty,
            normalized.count <= maximum,
            normalized.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            })
        else { return nil }
        return normalized
    }

    static func display(_ value: String, maximum: Int) -> String? {
        let normalized = value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard
            !normalized.isEmpty,
            normalized.count <= maximum,
            !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return normalized
    }

    static func personName(_ value: String) -> String? {
        display(value, maximum: 50)
    }
}

/// Fixed vocabulary only; old remote/restored v1 free text is never rendered.
enum BighelpActivityStatus {
    static let responseReady = "Response ready"
    static let reviewingDelegatedWork = "Reviewing delegated work"
    static let agentsWorking = "Agents are still working"
    static let finished = "Finished"
    static let couldNotFinish = "Could not finish"
    static let stopped = "Stopped"
}

struct BighelpActivityPresentation: Equatable {
    let agentName: String
    let status: String
    let detail: String?
    let symbolName: String
    /// The kind of work, for the island's icon and accent.
    let pose: BighelpActivityPose

    init(attributes: LoopdySessionActivityAttributes, state: LoopdySessionActivityAttributes.ContentState, isStale: Bool) {
        agentName = BighelpActivityText.personName(attributes.agentName) ?? "Your agent"
        pose = isStale && !state.phase.isTerminal ? .idle : BighelpActivityPose(phase: state.phase, tool: state.latestTool)
        if isStale && !state.phase.isTerminal {
            status = "Updates paused"
            detail = "Open bighelp for current status"
            symbolName = "pause.circle"
            return
        }
        let children = min(max(state.activeSubagentCount, 0), 99)
        switch state.phase {
        case .thinking:
            status = state.currentAction == BighelpActivityStatus.reviewingDelegatedWork
                ? BighelpActivityStatus.reviewingDelegatedWork : "Thinking"
            symbolName = "sparkles"
        case .waiting:
            status = "Needs your attention"
            symbolName = "questionmark.bubble"
        case .usingTool:
            status = pose == .tools ? "Working" : pose.label
            symbolName = pose.symbolName
        case .delegating:
            status = state.currentAction == BighelpActivityStatus.responseReady
                ? BighelpActivityStatus.responseReady : "Working with other agents"
            symbolName = "person.2"
        case .responding:
            status = "Writing the response"
            symbolName = "text.bubble"
        case .completed:
            status = state.currentAction == BighelpActivityStatus.stopped
                ? BighelpActivityStatus.stopped : BighelpActivityStatus.finished
            symbolName = state.currentAction == BighelpActivityStatus.stopped ? "stop.circle" : "checkmark.circle"
        case .failed:
            status = BighelpActivityStatus.couldNotFinish
            symbolName = "exclamationmark.circle"
        }
        if children > 0 {
            detail = children == 1 ? "1 agent still working" : "\(children) agents still working"
        } else if state.phase == .waiting {
            detail = "Open bighelp to continue"
        } else {
            detail = nil
        }
    }

    var accessibilityLabel: String {
        [agentName, status, detail].compactMap { $0 }.joined(separator: ". ")
    }
}

/// The app's colors for the Live Activity: the Cream or Graphite page picked in
/// Settings › Colors with its bubble color, like the Home widgets.
struct BighelpActivityColors: Sendable {
    let canvas: Color
    let primary: Color
    let secondary: Color
    let accent: Color
    let track: Color

    init(palette: BighelpWidgetSnapshot.Palette, isDark: Bool) {
        canvas = Color(widgetHex: palette.canvasHex)
        primary = Color(widgetHex: palette.primaryTextHex)
        secondary = Color(widgetHex: palette.secondaryTextHex)
        accent = Color(widgetHex: palette.accentHex)
        track = Color(widgetHex: palette.primaryTextHex).opacity(isDark ? 0.16 : 0.1)
    }

    init(snapshot: BighelpWidgetSnapshot = .empty, scheme: ColorScheme) {
        let isDark = scheme == .dark
        let palette = isDark ? snapshot.darkPalette ?? .emberDark : snapshot.lightPalette ?? .emberLight
        self.init(palette: palette, isDark: isDark)
    }

    /// The card's page color for `activityBackgroundTint`, which takes one color for both looks.
    static func canvas(snapshot: BighelpWidgetSnapshot) -> Color {
        let light = UIColor(Color(widgetHex: (snapshot.lightPalette ?? .emberLight).canvasHex))
        let dark = UIColor(Color(widgetHex: (snapshot.darkPalette ?? .emberDark).canvasHex))
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// The bubble color for system parts of the card, in both looks.
    static func accent(snapshot: BighelpWidgetSnapshot) -> Color {
        let light = UIColor(Color(widgetHex: (snapshot.lightPalette ?? .emberLight).accentHex))
        let dark = UIColor(Color(widgetHex: (snapshot.darkPalette ?? .emberDark).accentHex))
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// Where the work stands: the bubble color while it's going, amber when it
    /// needs you, green when it's done, red when it couldn't finish.
    func stateColor(_ phase: LoopdySessionActivityAttributes.ContentState.Phase, isStale: Bool) -> Color {
        if isStale && !phase.isTerminal { return secondary }
        return switch phase {
        case .waiting: Color(uiColor: .systemOrange)
        case .completed: Color(uiColor: .systemGreen)
        case .failed: Color(uiColor: .systemRed)
        default: accent
        }
    }
}

/// The four steps of a turn, from the phase Hermes reports (never a guessed
/// percentage): thinking, working, replying, done.
struct BighelpActivitySteps: View {
    let phase: LoopdySessionActivityAttributes.ContentState.Phase
    let color: Color
    let track: Color

    static func reached(_ phase: LoopdySessionActivityAttributes.ContentState.Phase) -> Int {
        switch phase {
        case .thinking: 1
        case .usingTool, .delegating, .waiting: 2
        case .responding: 3
        case .completed, .failed: 4
        }
    }

    var body: some View {
        let reached = Self.reached(phase)
        HStack(spacing: 4) {
            ForEach(1...4, id: \.self) { step in
                Capsule()
                    .fill(step <= reached ? color : track)
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The actual Lock Screen content, also available to an app/test ImageRenderer.
/// No ActivityViewContext, network, WidgetKit process or preview-only mock is needed.
struct BighelpLiveActivityCard: View {
    let attributes: LoopdySessionActivityAttributes
    let state: LoopdySessionActivityAttributes.ContentState
    var isStale = false
    var snapshot: BighelpWidgetSnapshot = .empty
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var avatarDiameter: CGFloat = 46

    private var presentation: BighelpActivityPresentation {
        BighelpActivityPresentation(attributes: attributes, state: state, isStale: isStale)
    }

    var body: some View {
        if state.sessions != nil {
            BighelpActivityRowsView(state: state, isStale: isStale, snapshot: snapshot)
                .foregroundStyle(BighelpActivityColors(snapshot: snapshot, scheme: scheme).primary)
                .padding(12)
                .background(BighelpActivityColors(snapshot: snapshot, scheme: scheme).canvas)
        } else {
            legacyCard
        }
    }

    private var legacyCard: some View {
        let colors = BighelpActivityColors(snapshot: snapshot, scheme: scheme)
        let stateColor = colors.stateColor(state.phase, isStale: isStale)
        return HStack(alignment: .center, spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                avatar(colors: colors, stateColor: stateColor)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(presentation.agentName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("bighelp")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(colors.accent)
                        .accessibilityHidden(true)
                }
                Text(presentation.status)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(colors.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if let detail = presentation.detail, !dynamicTypeSize.isAccessibilitySize || isStale {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !isStale {
                    BighelpActivitySteps(phase: state.phase, color: stateColor, track: colors.track)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            ZStack {
                colors.canvas
                RadialGradient(colors: [colors.accent.opacity(scheme == .dark ? 0.24 : 0.16), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 240)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint("Opens the conversation in bighelp")
    }

    /// The agent's picture in a ring of where the work stands, with what it's
    /// doing (code, the web, a question…) on its corner.
    private func avatar(colors: BighelpActivityColors, stateColor: Color) -> some View {
        BighelpActivityAvatar(agentID: attributes.agentID, name: presentation.agentName, diameter: avatarDiameter)
            .padding(3)
            .overlay(Circle().strokeBorder(stateColor, lineWidth: 2.5))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: presentation.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    // Dark mode's bubble color is a light lavender: a dark glyph reads on it.
                    .foregroundStyle(scheme == .dark ? colors.canvas : .white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(stateColor))
                    .overlay(Circle().strokeBorder(colors.canvas, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
    }
}

struct BighelpActivityAgentMark: View {
    let name: String
    let diameter: CGFloat

    var body: some View {
        Text(String(name.first ?? "L").uppercased())
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .background(.primary.opacity(0.08), in: Circle())
            .accessibilityHidden(true)
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
// Vision Pro has no Live Activities; the same work state still drives the app there.
extension LoopdySessionActivityAttributes: ActivityAttributes {}
#endif
