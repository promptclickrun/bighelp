import SwiftUI
import WidgetKit

/// The app's colors for widgets: the bubble color and the Cream/Paper or
/// Graphite/Black page picked in Settings › Colors. Tinted and Lock Screen
/// widgets fall back to the system's own styles.
struct BighelpWidgetColors: Sendable {
    let canvas: Color
    let primary: Color
    let secondary: Color
    let accent: Color
    let accentForeground: Color
    let isFullColor: Bool

    static let fallback = BighelpWidgetColors(palette: .emberLight, isFullColor: true)

    /// Glass widgets: the system's vibrant ink, with the after-dark bubble color for accents.
    static func glass(snapshot: BighelpWidgetSnapshot) -> BighelpWidgetColors {
        let palette = snapshot.darkPalette ?? .emberDark
        return BighelpWidgetColors(canvas: .clear, primary: .primary, secondary: .secondary,
                                   accent: Color(widgetHex: palette.accentHex),
                                   accentForeground: Color(widgetHex: palette.accentForegroundHex), isFullColor: true)
    }

    private init(canvas: Color, primary: Color, secondary: Color, accent: Color, accentForeground: Color,
                 isFullColor: Bool) {
        self.canvas = canvas
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
        self.accentForeground = accentForeground
        self.isFullColor = isFullColor
    }

    init(snapshot: BighelpWidgetSnapshot, scheme: ColorScheme, isFullColor: Bool) {
        let palette = scheme == .dark
            ? snapshot.darkPalette ?? .emberDark
            : snapshot.lightPalette ?? .emberLight
        self.init(palette: palette, isFullColor: isFullColor)
    }

    private init(palette: BighelpWidgetSnapshot.Palette, isFullColor: Bool) {
        self.isFullColor = isFullColor
        if isFullColor {
            canvas = Color(widgetHex: palette.canvasHex)
            primary = Color(widgetHex: palette.primaryTextHex)
            secondary = Color(widgetHex: palette.secondaryTextHex)
            accent = Color(widgetHex: palette.accentHex)
            accentForeground = Color(widgetHex: palette.accentForegroundHex)
        } else {
            canvas = .clear
            primary = .primary
            secondary = .secondary
            accent = .primary
            accentForeground = .black
        }
    }
}

extension BighelpWidgetSnapshot.Palette {
    static let emberLight = Self(canvasHex: "FFF9F5", surfaceHex: "FFFFFF", primaryTextHex: "1C1A19",
                                 secondaryTextHex: "6F6762", accentHex: "7B52E0", accentForegroundHex: "FFFFFF")
    static let emberDark = Self(canvasHex: "1C1C1F", surfaceHex: "27272B", primaryTextHex: "F4F4F6",
                                secondaryTextHex: "A3A3AA", accentHex: "C9B6FF", accentForegroundHex: "1C1A19")
}

private struct BighelpWidgetColorsKey: EnvironmentKey {
    static let defaultValue = BighelpWidgetColors.fallback
}

extension EnvironmentValues {
    var bighelpWidgetColors: BighelpWidgetColors {
        get { self[BighelpWidgetColorsKey.self] }
        set { self[BighelpWidgetColorsKey.self] = newValue }
    }
}

extension Color {
    /// "RRGGBB" or "#RRGGBB"; anything else draws gray.
    init(widgetHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// Every widget's frame: the app's page color with a soft glow of the bubble
/// color, text in the app's colors, and the colors in the environment. On
/// Vision Pro the widget is glass in the room, so text stays the system's own
/// vibrant ink and only the glow keeps the bubble color.
struct BighelpWidgetScaffold<Content: View>: View {
    let snapshot: BighelpWidgetSnapshot
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.widgetFamily) private var family

    var body: some View {
        #if os(visionOS)
        let colors = BighelpWidgetColors.glass(snapshot: snapshot)
        #else
        let colors = BighelpWidgetColors(snapshot: snapshot, scheme: scheme, isFullColor: mode == .fullColor)
        #endif
        content
            .environment(\.bighelpWidgetColors, colors)
            .foregroundStyle(colors.primary)
            .tint(colors.accent)
            .containerBackground(for: .widget) {
                #if os(visionOS)
                RadialGradient(colors: [colors.accent.opacity(0.18), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 260)
                #else
                if colors.isFullColor, !family.isAccessory {
                    ZStack {
                        colors.canvas
                        RadialGradient(colors: [colors.accent.opacity(scheme == .dark ? 0.22 : 0.14), .clear],
                                       center: .topLeading, startRadius: 0, endRadius: 220)
                    }
                } else {
                    Color.clear
                }
                #endif
            }
    }
}

extension WidgetFamily {
    var isAccessory: Bool {
        #if os(visionOS)
        false
        #else
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: false
        }
        #endif
    }
}

extension WidgetConfiguration {
    /// Vision Pro: frosted glass, on a wall or set into a surface.
    func bighelpWidgetPlacement() -> some WidgetConfiguration {
        #if os(visionOS)
        widgetTexture(.glass).supportedMountingStyles([.elevated, .recessed])
        #else
        self
        #endif
    }
}

/// The agent's real picture (or its initial), ringed in the bubble color with
/// a badge for the work while it runs.
struct BighelpWidgetAvatar: View {
    let agentID: String?
    let name: String
    let diameter: CGFloat
    var pose: BighelpActivityPose? = nil
    /// A pinned agent's own picture (`BighelpPinnedAvatarStore`), for agents
    /// that may be on another computer, where `agentID` could name someone else.
    var avatarKey: String? = nil

    @Environment(\.bighelpWidgetColors) private var colors
    @Environment(\.bighelpPinnedAvatarDirectory) private var pinnedAvatars

    var body: some View {
        face
            .frame(width: diameter, height: diameter)
            .padding(pose == nil ? 0 : ringGap)
            .overlay {
                if pose != nil {
                    Circle()
                        .strokeBorder(AngularGradient(colors: [colors.accent, colors.accent.opacity(0.15), colors.accent],
                                                      center: .center),
                                      lineWidth: max(2, diameter * 0.05))
                        .widgetAccentable()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let pose {
                    Image(systemName: pose.symbolName)
                        .font(.system(size: max(9, diameter * 0.2), weight: .bold))
                        .foregroundStyle(colors.accentForeground)
                        .frame(width: max(18, diameter * 0.36), height: max(18, diameter * 0.36))
                        .background(Circle().fill(colors.accent))
                        .overlay(Circle().strokeBorder(colors.canvas, lineWidth: colors.isFullColor ? 2 : 0))
                        .widgetAccentable()
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
    }

    private var ringGap: CGFloat { max(3, diameter * 0.07) }

    private var picture: UIImage? {
        if let avatarKey { return BighelpPinnedAvatarStore.image(key: avatarKey, in: pinnedAvatars) }
        return agentID.flatMap { BighelpActivityAvatarStore.image(agentID: $0) }
    }

    @ViewBuilder
    private var face: some View {
        if let image = picture {
            Image(uiImage: image)
                .resizable()
                .bighelpWidgetFullColor()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            Text(String(name.first ?? "b").uppercased())
                .font(.system(size: diameter * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(colors.accentForeground)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(colors.accent.gradient))
                .widgetAccentable()
        }
    }
}

extension Image {
    /// Photos keep their colors on a tinted Home Screen (iOS 18 and later).
    @ViewBuilder
    func bighelpWidgetFullColor() -> some View {
        if #available(iOS 18.0, *) {
            widgetAccentedRenderingMode(.fullColor)
        } else {
            self
        }
    }
}

/// A small uppercase section title.
struct BighelpWidgetSectionTitle: View {
    let title: String
    var symbol: String? = nil
    @Environment(\.bighelpWidgetColors) private var colors

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).foregroundStyle(colors.accent).widgetAccentable() }
            Text(title.uppercased()).tracking(0.6).foregroundStyle(colors.secondary)
        }
        .font(.system(size: 10, weight: .bold))
        .lineLimit(1)
    }
}

extension BighelpWidgetSnapshot {
    /// The default agent's running chat, if any, else any running chat.
    var agentRunningSession: Session? {
        let running = runningSessions.sorted { $0.updatedAt > $1.updatedAt }
        return running.first { $0.agentID != nil && $0.agentID == defaultAgentID } ?? running.first
    }

    /// What the default agent is doing, nil while idle.
    var agentPose: BighelpActivityPose? {
        guard let session = agentRunningSession else { return nil }
        return session.activity.flatMap(BighelpActivityPose.init(rawValue:)) ?? .thinking
    }

    var agentDisplayName: String { defaultAgentName ?? "Your agent" }
}
