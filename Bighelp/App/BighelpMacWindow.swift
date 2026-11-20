import Observation
import SwiftUI

/// The Mac window (Mac Catalyst, "Optimize for Mac"): no title text over the
/// app's own header, a sidebar button in the title bar on every screen, a size
/// floor, a roomy first size, and icon menus that look like the buttons beside
/// them instead of Mac pull-down buttons.
struct BighelpMacWindowStyle: ViewModifier {
    let sideMenu: BighelpSideMenu

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .menuStyle(BighelpMacMenuStyle())
            .menuIndicator(.hidden)
            .background(MacWindowConfigurator(sideMenu: sideMenu).allowsHitTesting(false).accessibilityHidden(true))
        #else
        content
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// A menu draws exactly its label, as on iPhone and iPad; the Mac's pull-down
/// style would put a bezel inside the app's own round buttons. Its whole label
/// (at least 28 points each way) opens it and lights up under the pointer.
private struct BighelpMacMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration).menuStyle(.button).buttonStyle(MenuLabelStyle())
            .bighelpHover(in: Capsule())
    }

    /// Draws the label as `.plain` does, at least 28 points each way: the Mac
    /// opens a menu from its label's frame, so a bare "…" glyph was a sliver.
    /// A menu hands its label only to a `ButtonStyle` (a primitive style gets
    /// just its title).
    private struct MenuLabelStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(minWidth: BighelpPointer.minimumTarget, minHeight: BighelpPointer.minimumTarget)
                .contentShape(.rect)
                .opacity(configuration.isPressed ? 0.6 : 1)
        }
    }
}

private struct MacWindowConfigurator: UIViewRepresentable {
    let sideMenu: BighelpSideMenu

    func makeUIView(context: Context) -> WindowConfiguringView { WindowConfiguringView(sideMenu: sideMenu) }
    func updateUIView(_ view: WindowConfiguringView, context: Context) {}

    final class WindowConfiguringView: UIView {
        private static let sizedKey = "bighelp.mac.window-first-size"
        private let titlebarItems: MacTitlebarItems

        init(sideMenu: BighelpSideMenu) {
            titlebarItems = MacTitlebarItems(sideMenu: sideMenu)
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            guard let scene = window?.windowScene else { return }
            scene.titlebar?.titleVisibility = .hidden
            if scene.titlebar?.toolbar == nil {
                scene.titlebar?.toolbar = titlebarItems.toolbar
                scene.titlebar?.toolbarStyle = .unifiedCompact
            }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 480, height: 600)
            // macOS remembers the window's frame after this; only the very first
            // launch opens at a comfortable size instead of the 1024×768 default.
            guard !UserDefaults.standard.bool(forKey: Self.sizedKey) else { return }
            // A request made while the window is still being set up is dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak scene] in
                guard let scene else { return }
                let screen = scene.screen.bounds
                let size = CGSize(width: min(1280, screen.width * 0.9), height: min(900, screen.height * 0.88))
                let frame = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                   width: size.width, height: size.height)
                scene.requestGeometryUpdate(.Mac(systemFrame: frame))
                UserDefaults.standard.set(true, forKey: Self.sizedKey)
            }
        }
    }
}

/// The title bar's sidebar button, right after the window controls as in Mail
/// and Finder, so the sidebar opens and closes from every screen (⌃⌘S too).
/// It's greyed out while there's no sidebar (first-run setup).
@MainActor
private final class MacTitlebarItems: NSObject, NSToolbarDelegate {
    private static let sidebar = NSToolbarItem.Identifier("bighelp.sidebar")
    let toolbar = NSToolbar(identifier: "bighelp.window")
    private let sideMenu: BighelpSideMenu
    private weak var sidebarItem: NSToolbarItem?
    // The title bar honours a bar button's target and action, not a primaryAction.
    private lazy var sidebarButton = UIBarButtonItem(
        image: UIImage(systemName: "sidebar.leading"), style: .plain, target: self, action: #selector(toggleSidebar))

    init(sideMenu: BighelpSideMenu) {
        self.sideMenu = sideMenu
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        followAvailability()
    }

    @objc private func toggleSidebar() {
        sideMenu.requestToggle()
    }

    private func followAvailability() {
        withObservationTracking {
            // The bar button and the title bar item each keep their own state.
            let isAvailable = HomeSidebarControlPolicy.showsNativeTitlebarControl(
                sidebarAvailable: sideMenu.canToggle, isMac: true, sidebarOpen: sideMenu.isOpen
            )
            sidebarButton.isEnabled = isAvailable
            sidebarItem?.isEnabled = isAvailable
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAvailability() }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.sidebar] }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.sidebar] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.sidebar else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier, barButtonItem: sidebarButton)
        item.label = "Sidebar"
        item.toolTip = "Show or hide the sidebar (⌃⌘S)"
        item.isEnabled = HomeSidebarControlPolicy.showsNativeTitlebarControl(
            sidebarAvailable: sideMenu.canToggle, isMac: true, sidebarOpen: sideMenu.isOpen
        )
        sidebarItem = item
        return item
    }
}
#endif
