import Observation
import SwiftUI

/// Vision Pro and Mac: ☰ opens as a column beside the app instead of covering
/// it. The chat or list stays visible, only narrower. On the Mac it's the
/// window's sidebar: it stays open while you pick chats and pages.
@MainActor
@Observable
final class BighelpSideMenu {
    private(set) var content: AnyView?
    @ObservationIgnored private var onClose: (@MainActor () -> Void)?
    /// The Mac title bar's sidebar button asks; the shell opens or closes it.
    private(set) var toggleRequests = 0
    /// Whether there's a sidebar to show (none during onboarding or host setup).
    var canToggle = false

    var isOpen: Bool { content != nil }

    func requestToggle() {
        guard canToggle else { return }
        toggleRequests += 1
    }

    func show(_ view: AnyView, onClose: @escaping @MainActor () -> Void) {
        content = view
        self.onClose = onClose
    }

    func hide() {
        guard content != nil else { return }
        content = nil
        let close = onClose
        onClose = nil
        close?()
    }
}

extension EnvironmentValues {
    @Entry var bighelpSideMenu: BighelpSideMenu? = nil
}

/// Lays the open menu beside the window's content on Vision Pro and Mac;
/// elsewhere it changes nothing.
struct BighelpSideMenuHost: ViewModifier {
    let menu: BighelpSideMenu
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if targetEnvironment(macCatalyst)
    /// The width you dragged the divider to; 0 keeps the default.
    @AppStorage("bighelp.mac.sidebar-width") private var savedWidth = 0.0
    @State private var draggedWidth: CGFloat?
    @State private var windowWidth: CGFloat = 0
    #endif

    /// The Mac's sidebar widens with bigger text so rows don't wrap.
    static var width: CGFloat {
        #if targetEnvironment(macCatalyst)
        min(max(330 * BighelpInterfaceSize.shared.textSize.macFactor / BighelpTextSize.standard.macFactor, 300), 420)
        #else
        340
        #endif
    }

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        HStack(spacing: 0) {
            if let panel = menu.content {
                panel
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    // Keep the column solid while the chat changes width.
                    .transition(.move(edge: .leading))
                MacSidebarDivider(width: sidebarWidth, clamp: clamped, draggedWidth: $draggedWidth) { width in
                    savedWidth = width.map { Double($0) } ?? 0
                }
                .zIndex(1)
            }
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        // A short non-springing transition avoids a bounce during relayout.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: menu.isOpen)
        .environment(\.bighelpSideMenu, menu)
        #elseif os(visionOS)
        HStack(spacing: 0) {
            if let panel = menu.content {
                panel
                    .frame(width: Self.width)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            content
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: menu.isOpen)
        .environment(\.bighelpSideMenu, menu)
        #else
        content
        #endif
    }
}

#if targetEnvironment(macCatalyst)
extension BighelpSideMenuHost {
    static let minimumWidth: CGFloat = 240
    /// The page beside it always keeps room for a readable chat.
    static let minimumPageWidth: CGFloat = 380

    private var sidebarWidth: CGFloat {
        clamped(draggedWidth ?? (savedWidth > 0 ? CGFloat(savedWidth) : Self.width))
    }

    private func clamped(_ width: CGFloat) -> CGFloat {
        let widest = windowWidth > 0 ? max(Self.minimumWidth, min(640, windowWidth - Self.minimumPageWidth)) : 640
        return min(max(width, Self.minimumWidth), widest).rounded()
    }
}

/// The line between the Mac's sidebar and the page. Drag it to make the
/// sidebar narrower or wider (remembered); double-click it for the default.
private struct MacSidebarDivider: View {
    let width: CGFloat
    let clamp: (CGFloat) -> CGFloat
    @Binding var draggedWidth: CGFloat?
    /// The width to keep, or nil for the default.
    let save: (CGFloat?) -> Void
    @State private var isHovering = false
    @State private var startWidth: CGFloat?
    @BighelpThemeReader private var theme

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(theme.action.opacity(isHovering || startWidth != nil ? 0.55 : 0))
                    .frame(width: 3)
                    .allowsHitTesting(false)
            }
            .overlay {
                // A wider grip than the line itself, reaching a few points into each side.
                Color.white.opacity(0.001)
                    .frame(width: 9)
                    .contentShape(.rect)
                    .onHover { inside in
                        isHovering = inside
                        MacResizeCursor.shows(inside || startWidth != nil)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                draggedWidth = clamp(start + value.translation.width)
                            }
                            .onEnded { _ in
                                if let draggedWidth { save(draggedWidth) }
                                draggedWidth = nil
                                startWidth = nil
                                MacResizeCursor.shows(isHovering)
                            }
                    )
                    .onTapGesture(count: 2) { save(nil) }
            }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: save(clamp(width + 40))
                case .decrement: save(clamp(width - 40))
                @unknown default: break
                }
            }
            .bighelpHelp("Drag to resize the sidebar. Double-click for the usual width.")
    }
}

/// AppKit's left-right resize pointer. Mac Catalyst has no public way to ask
/// for it, so it's looked up by name, and nothing happens if it's missing.
@MainActor
private enum MacResizeCursor {
    private static var isShown = false

    static func shows(_ show: Bool) {
        guard show != isShown, let cursor = cursor() else { return }
        isShown = show
        _ = cursor.perform(NSSelectorFromString(show ? "push" : "pop"))
    }

    private static func cursor() -> NSObject? {
        guard let type = NSClassFromString("NSCursor") as AnyObject? else { return nil }
        for name in ["columnResizeCursor", "resizeLeftRightCursor"] {
            let selector = NSSelectorFromString(name)
            if type.responds(to: selector), let cursor = type.perform(selector)?.takeUnretainedValue() as? NSObject {
                return cursor
            }
        }
        return nil
    }
}
#endif

/// The Mac opens its sidebar the way you left it (open the first time), once
/// there's a host: during first-run onboarding and host setup it has nothing to offer.
struct MacSidebarMemory: ViewModifier {
    @Binding var isOpen: Bool
    let canShow: Bool
    @AppStorage("bighelp.mac.sidebar-open") private var savedOpen = true
    @Environment(\.bighelpSideMenu) private var sideMenu

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .onAppear {
                sideMenu?.canToggle = canShow
                if canShow, savedOpen, !isOpen { isOpen = true }
            }
            .onChange(of: canShow) { _, canShow in
                sideMenu?.canToggle = canShow
                if canShow { if savedOpen { isOpen = true } } else { isOpen = false }
            }
            // The title bar's sidebar button, on every screen.
            .onChange(of: sideMenu?.toggleRequests ?? 0) { if canShow { isOpen.toggle() } }
            // Closing it for onboarding isn't your choice, so it isn't remembered.
            .onChange(of: isOpen) { _, open in if canShow { savedOpen = open } }
        #else
        content
        #endif
    }
}
