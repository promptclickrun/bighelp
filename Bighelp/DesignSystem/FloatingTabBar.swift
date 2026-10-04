import SwiftUI

// Still consumed by SpectrumAction outside primary navigation.
enum FloatingTabBarActionSurface: Equatable, Sendable {
    case neutralGlass
}

enum FloatingTabBarActionForeground: Equatable, Sendable {
    case themeAccent
}

struct FloatingTabBarActionPresentation: Equatable, Sendable {
    let surface: FloatingTabBarActionSurface
    let foreground: FloatingTabBarActionForeground
    let usesGradient: Bool
    let showsBorder: Bool
    let usesGlow: Bool
}

enum FloatingTabBarBackgroundSurface: Equatable, Sendable {
    case regularLiquidGlass
    case regularMaterial
    case thickMaterial
    case opaque
}

struct FloatingTabBar: View {
    static let newChatVisibleLabel = "New chat"
    static let newChatAccessibilityLabel = "New chat"
    static let selectionShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    static func newChatPresentation(for _: BighelpThemeID) -> FloatingTabBarActionPresentation {
        FloatingTabBarActionPresentation(surface: .neutralGlass, foreground: .themeAccent,
                                        usesGradient: false, showsBorder: false, usesGlow: false)
    }

    static func backgroundSurface(
        supportsLiquidGlass: Bool,
        reduceTransparency: Bool,
        increasedContrast: Bool
    ) -> FloatingTabBarBackgroundSurface {
        if reduceTransparency { return .opaque }
        if supportsLiquidGlass { return .regularLiquidGlass }
        return increasedContrast ? .thickMaterial : .regularMaterial
    }

    /// The shell reserves navigation space only at the root, never over a pushed chat or keyboard.
    static func isRootBarVisible(for path: [AppRoute]) -> Bool {
        path.isEmpty
    }

    /// Settings › Appearance › Bottom menu: start as one button that opens the full bar.
    static let startsCollapsedKey = "bighelp.tabbar.starts-collapsed"

    @Binding var selection: AppTab
    let onNewChat: (() -> Void)?
    /// Points the bar drops into the home indicator's area.
    let homeIndicatorSink: CGFloat
    /// Feed, Ideas or Goals with something the person hasn't seen: a small dot.
    let unread: Set<AppTab>

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var tabChanges = 0
    /// Observed so the bar follows the setting; read through `bool(forKey:)` because a launch
    /// argument's "NO" is a string that AppStorage would ignore.
    @AppStorage(FloatingTabBar.startsCollapsedKey) private var storedStartsCollapsed = true
    private var startsCollapsed: Bool {
        _ = storedStartsCollapsed
        let defaults = UserDefaults.standard
        return defaults.object(forKey: Self.startsCollapsedKey) == nil || defaults.bool(forKey: Self.startsCollapsedKey)
    }
    @State private var isExpanded = false
    @State private var collapseTask: Task<Void, Never>?
    @Namespace private var barSpace
    /// The glyphs keep a 3-pt margin on their 24-pt grid, so 26 draws them about 20pt.
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 26
    @ScaledMetric(relativeTo: .caption2) private var captionHeight: CGFloat = 28

    init(selection: Binding<AppTab>, onNewChat: (() -> Void)? = nil, homeIndicatorSink: CGFloat = 0,
         unread: Set<AppTab> = []) {
        self._selection = selection
        self.onNewChat = onNewChat
        self.homeIndicatorSink = homeIndicatorSink
        self.unread = unread
    }

    /// Like the system tab bar, the bar sits low, just above the home
    /// indicator, instead of a full safe-area inset above it. Clamped so a
    /// keyboard's inset never pushes it off screen.
    static func homeIndicatorSink(forBottomInset inset: CGFloat) -> CGFloat {
        min(max(0, inset - 14), 20)
    }

    var body: some View {
        // New chat floats centered above the tabs, so the tab row keeps the
        // same width on every screen.
        VStack(spacing: BighelpTokens.space8) {
            if let onNewChat {
                RootComposeButton { onNewChat() }
                    .accessibilityShowsLargeContentViewer {
                        Label(Self.newChatVisibleLabel, systemImage: "square.and.pencil")
                    }
            }
            if startsCollapsed && !isExpanded {
                collapsedButton
            } else {
                // Five icons in one row, like a dock; names stay in VoiceOver and
                // the large content viewer.
                navigationRow(constrainsWidth: true) {
                    ForEach(AppTab.allCases) { tab in
                        destination(tab, showsCaption: false)
                    }
                }
                .padding(6)
                .bighelpNavigationGlass(in: Capsule())
                .matchedGeometryEffect(id: "bar", in: barSpace)
                .transition(.opacity)
            }
        }
        .sensoryFeedback(.selection, trigger: tabChanges)
        .onDisappear { collapseTask?.cancel() }
        .frame(maxWidth: BighelpTokens.scaled(620))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Primary navigation")
        .accessibilityIdentifier("primary-navigation")
        .padding(.horizontal, 12)
        .padding(.vertical, isVerticallyCompact ? 4 : 8)
        .frame(maxWidth: .infinity)
        .padding(.bottom, -homeIndicatorSink)
    }

    private var isVerticallyCompact: Bool { verticalSizeClass == .compact }

    /// One round button in the middle; a tap grows it into the full bar. Ideas' sparkle, not ☰,
    /// so it isn't mistaken for the menu at the top.
    private var collapsedButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: BighelpTokens.transitionDuration)) { isExpanded = true }
        } label: {
            AppTabIcon(tab: .ideas, selected: false)
                .frame(width: BighelpTokens.scaled(26), height: BighelpTokens.scaled(26))
                .foregroundStyle(theme.action)
                .frame(width: BighelpTokens.scaled(56), height: BighelpTokens.scaled(56))
                .contentShape(Circle())
        }
        .buttonStyle(.bighelpTilePress)
        .bighelpNavigationGlass(in: Circle(), isInteractive: true)
        .matchedGeometryEffect(id: "bar", in: barSpace)
        .transition(.opacity)
        .accessibilityLabel("Show Feed, Ideas, Goals and more")
        .accessibilityIdentifier("primary-navigation.expand")
    }

    /// After a pick, a collapsed-by-default bar folds back once the new screen is up.
    private func collapseSoon() {
        guard startsCollapsed else { return }
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: BighelpTokens.transitionDuration)) { isExpanded = false }
        }
    }

    private func navigationRow<Content: View>(
        constrainsWidth: Bool = false, @ViewBuilder content: () -> Content
    ) -> some View {
        let layout = NavigationRowLayout(constrainsWidth: constrainsWidth)
        return layout { content() }
    }


    private func destination(_ tab: AppTab, showsCaption: Bool = true) -> some View {
        let isSelected = selection == tab
        return Button {
            BighelpKeyboard.dismiss()
            if selection != tab { tabChanges += 1 }
            withAnimation(reduceMotion ? nil : .snappy(duration: BighelpTokens.transitionDuration)) {
                selection = tab
            }
            collapseSoon()
        } label: {
            itemLabel(tab, selected: isSelected, showsCaption: showsCaption)
                .overlay(alignment: .topTrailing) {
                    if unread.contains(tab), !isSelected {
                        Circle()
                            .fill(theme.action)
                            .frame(width: 8, height: 8)
                            .padding(.top, isVerticallyCompact ? 4 : 8)
                            .padding(.trailing, 10)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.bighelpTilePress)
        .bighelpHover(in: Self.selectionShape)
        .bighelpHelp(tab.title, shortcut: tab.macShortcut)
        .accessibilityLabel(tab.title)
        .accessibilityValue(unread.contains(tab) && !isSelected ? "New" : "")
        .accessibilityShowsLargeContentViewer {
            if let glyph = tab.glyph {
                Label { Text(tab.title) } icon: { Image(uiImage: glyph.image(selected: isSelected)) }
            } else {
                Label(tab.title, systemImage: tab.systemImage(selected: isSelected))
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }

    // Destinations share the existing neutral surface and equal touch targets.
    private func itemLabel(_ tab: AppTab, selected: Bool, showsCaption: Bool) -> some View {
        let identifier = tab.accessibilityIdentifier
        return VStack(spacing: 4) {
            AppTabIcon(tab: tab, selected: selected)
                .frame(width: BighelpTokens.scaled(min(iconSize, 32)), height: BighelpTokens.scaled(min(iconSize, 32)))
                .accessibilityIdentifier(identifier + ".icon")
            if showsCaption {
                Text(tab.title)
                    .font(.bighelp(.caption2).weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(height: captionHeight)
                    .accessibilityIdentifier(identifier + ".label")
            }
        }
        // The theme's ink, not `.secondary`: on glass that turns symbols vibrant
        // but leaves the drawn glyphs a faint grey.
        .foregroundStyle(selected ? (increasedContrast ? Color.primary : theme.action) : theme.secondaryText)
        .padding(.horizontal, 4)
        .padding(.vertical, isVerticallyCompact ? 4 : 10)
        .frame(minWidth: BighelpTokens.hitTarget, maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
        .background {
            if selected {
                Self.selectionShape
                    .fill(increasedContrast ? Color.primary.opacity(0.18) : theme.action.opacity(0.14))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.86).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
    }

    private var increasedContrast: Bool { colorSchemeContrast == .increased }

    @BighelpThemeReader private var theme
}

/// The labelled row reports its ideal width; the icon fallback respects its proposal.
/// Every destination gets the same measured width and height.
struct NavigationRowLayout: Layout {
    var constrainsWidth = false

    static func fittingSize(
        proposedWidth: CGFloat?, itemSizes: [CGSize], constrainsWidth: Bool = false
    ) -> CGSize {
        let requiredWidth = (itemSizes.map(\.width).max() ?? 44) * CGFloat(itemSizes.count)
        let availableWidth = proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? requiredWidth
        let width = constrainsWidth
            ? max(44 * CGFloat(itemSizes.count), availableWidth)
            : max(availableWidth, requiredWidth)
        return CGSize(width: width,
                      height: itemSizes.map(\.height).max() ?? 44)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = Self.fittingSize(
            proposedWidth: proposal.width,
            itemSizes: subviews.map { $0.sizeThatFits(.unspecified) },
            constrainsWidth: constrainsWidth
        )
        guard constrainsWidth, !subviews.isEmpty else { return ideal }
        let cellProposal = ProposedViewSize(width: ideal.width / CGFloat(subviews.count), height: nil)
        return Self.fittingSize(
            proposedWidth: ideal.width,
            itemSizes: subviews.map { $0.sizeThatFits(cellProposal) },
            constrainsWidth: true
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

extension View {
    /// Neutral native navigation glass with an optional interactive response.
    /// No custom tint, glow or shadow; all consumers share its fallbacks.
    func bighelpNavigationGlass<S: InsettableShape>(in shape: S, isInteractive: Bool = false) -> some View {
        modifier(BighelpNavigationGlass(shape: shape, isInteractive: isInteractive))
    }
}

private struct BighelpNavigationGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let isInteractive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content.modifier(NavigationSurface(
            shape: shape,
            isInteractive: isInteractive,
            surface: FloatingTabBar.backgroundSurface(
                supportsLiquidGlass: supportsLiquidGlass,
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased
            ),
            increasedContrast: colorSchemeContrast == .increased
        ))
    }

    private var supportsLiquidGlass: Bool {
        #if compiler(>=6.2) && !os(visionOS) // visionOS has no glassEffect.
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

private struct NavigationSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let isInteractive: Bool
    let surface: FloatingTabBarBackgroundSurface
    let increasedContrast: Bool

    func body(content: Content) -> some View {
        surfaced(content)
            .modifier(InteractiveGlassHover(shape: shape, isInteractive: isInteractive))
            .overlay {
                if increasedContrast {
                    shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        switch surface {
        case .opaque:
            content.background(Color(uiColor: .systemBackground), in: shape)
        case .regularMaterial:
            content.background(.regularMaterial, in: shape)
        case .thickMaterial:
            content.background(.thickMaterial, in: shape)
        case .regularLiquidGlass:
            #if compiler(>=6.2) && !os(visionOS) // visionOS has no glassEffect.
            if #available(iOS 26.0, *) {
                content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
            #else
            content.background(.regularMaterial, in: shape)
            #endif
        }
    }
}

/// Mac: glass that's a button lights up under the pointer.
private struct InteractiveGlassHover<S: Shape>: ViewModifier {
    let shape: S
    let isInteractive: Bool

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        if isInteractive { content.bighelpHover(in: shape) } else { content }
        #else
        content
        #endif
    }
}

#if os(visionOS)
/// Vision Pro's tabs: a vertical glass strip beside the window, where visionOS
/// puts its own tab bars. Each target is 60pt and lights up where you look,
/// well away from the window's move and close controls under it.
struct VisionTabOrnament: View {
    @Binding var selection: AppTab
    var unread: Set<AppTab> = []
    var onNewChat: (() -> Void)?

    var body: some View {
        VStack(spacing: BighelpTokens.space8) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = selection == tab
                Button {
                    selection = tab
                } label: {
                    AppTabIcon(tab: tab, selected: isSelected)
                        .frame(width: 32, height: 32)
                        .frame(width: 60, height: 60)
                        .background {
                            if isSelected { Circle().fill(.white.opacity(0.22)) }
                        }
                        .overlay(alignment: .topTrailing) {
                            if unread.contains(tab), !isSelected {
                                Circle().fill(Color.accentColor).frame(width: 10, height: 10).padding(8)
                            }
                        }
                }
                .buttonStyle(.plain)
                .buttonBorderShape(.circle)
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.highlight)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityValue(unread.contains(tab) && !isSelected ? "New" : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier(tab.accessibilityIdentifier)
            }
            if let onNewChat {
                Divider().frame(width: 36)
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.bighelp(.title2).weight(.semibold))
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.plain)
                .buttonBorderShape(.circle)
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.highlight)
                .help(FloatingTabBar.newChatVisibleLabel)
                .accessibilityLabel(FloatingTabBar.newChatAccessibilityLabel)
                .accessibilityIdentifier("root.new-chat")
            }
        }
        .padding(BighelpTokens.space12)
        .glassBackgroundEffect(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Primary navigation")
        .accessibilityIdentifier("primary-navigation")
    }
}
#endif

/// A bottom-bar tab's icon, filling its frame: bighelp's glyph for Chat, Feed,
/// Ideas and Goals, outlined until selected; Apps keeps its symbol.
struct AppTabIcon: View {
    let tab: AppTab
    let selected: Bool

    var body: some View {
        if let glyph = tab.glyph {
            BighelpTabGlyphShape(glyph: glyph, selected: selected)
        } else {
            // A symbol fills its frame; the glyphs keep a 3-pt margin on their 24-pt grid.
            Image(systemName: tab.systemImage(selected: selected))
                .resizable()
                .scaledToFit()
                .fontWeight(.medium) // Close to the glyphs' 1.7-pt line.
                .scaleEffect(0.78)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

extension AppTab {
    var glyph: BighelpTabGlyph? {
        switch self {
        case .sessions: .chat
        case .feed: .feed
        case .ideas: .ideas
        case .goals: .goals
        default: nil
        }
    }
}

private extension AppTab {
    var title: String {
        switch self {
        case .home: "Activity"
        case .agents: "Agents"
        case .sessions: "Chat"
        case .inbox: "Inbox"
        case .profile: "Settings"
        case .scheduledTasks: "Tasks"
        case .workspace: "Workspace"
        case .feed: "Feed"
        case .ideas: "Ideas"
        case .goals: "Goals"
        case .apps: "Apps"
        }
    }

    func systemImage(selected: Bool) -> String {
        switch (self, selected) {
        case (.home, true): "waveform.path"
        case (.home, false): "waveform.path"
        case (.agents, true): "person.2.fill"
        case (.agents, false): "person.2"
        case (.sessions, true): "bubble.left.fill"
        case (.sessions, false): "bubble.left"
        case (.inbox, true): "tray.full.fill"
        case (.inbox, false): "tray"
        case (.profile, true): "gearshape.fill"
        case (.profile, false): "gearshape"
        case (.scheduledTasks, _): "calendar.badge.clock"
        case (.workspace, true): "square.grid.2x2.fill"
        case (.workspace, false): "square.grid.2x2"
        case (.feed, true): "newspaper.fill"
        case (.feed, false): "newspaper"
        case (.ideas, true): "lightbulb.fill"
        case (.ideas, false): "lightbulb"
        case (.goals, true): "checkmark.square.fill"
        case (.goals, false): "checkmark.square"
        case (.apps, true): "square.on.circle.fill"
        case (.apps, false): "square.on.circle"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .home: "tab.home"
        case .agents: "tab.agents"
        case .sessions: "tab.sessions"
        case .inbox: "tab.inbox"
        case .profile: "tab.profile"
        case .scheduledTasks: "tab.scheduled-tasks"
        case .workspace: "tab.workspace"
        case .feed: "tab.feed"
        case .ideas: "tab.ideas"
        case .goals: "tab.goals"
        case .apps: "tab.apps"
        }
    }
}
