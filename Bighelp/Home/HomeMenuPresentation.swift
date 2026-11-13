import SwiftUI



/// Presents the sidebar on iPad: it slides in from the leading edge over a dimmed screen, and a tap
/// outside closes it. iPhone has no sidebar: its bar holds the places.
/// The panel is a see-through full-screen cover so it sits above the title bar.
struct HomeMenuPresentation<Menu: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    /// A new host/runtime supplies new stores and actions, not just new values.
    var contentID: ObjectIdentifier? = nil
    @ViewBuilder let menu: () -> Menu

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bighelpSideMenu) private var sideMenu
    @State private var isCoverPresented = false
    @State private var isPanelVisible = false

    static var panelWidth: CGFloat { 380 }

    func body(content: Content) -> some View {
        if let sideMenu {
            // Vision Pro and Mac: a column beside the app, which narrows to make
            // room. The Mac's stays open while you pick chats and pages.
            content.onChange(of: isPresented, initial: true) { _, presented in
                if presented { showSideMenu(sideMenu) } else { sideMenu.hide() }
            }
            .onChange(of: contentID) {
                if isPresented { showSideMenu(sideMenu) }
            }
        } else if horizontalSizeClass == .regular {
            content
                .bighelpFullScreenCover(isPresented: $isCoverPresented, onDismiss: onDismiss) {
                    panel.presentationBackground(.clear)
                }
                .onChange(of: isPresented, initial: true) { _, presented in
                    presented ? open() : close()
                }
        } else {
            // Compact width has no sidebar. One left open (an iPad window made narrow) closes.
            content.onChange(of: isPresented, initial: true) { _, presented in
                if presented { isPresented = false }
            }
        }
    }

    private func showSideMenu(_ sideMenu: BighelpSideMenu) {
        // Build inside a SwiftUI update, not the presentation callback, so
        // readiness keeps updating. contentID also replaces captured stores.
        let panel = BighelpDeferredSection { menu() }
        sideMenu.show(AnyView(panel)) {
            isPresented = false
            onDismiss()
        }
    }

    private var slide: Animation? { reduceMotion ? nil : .snappy(duration: 0.28) }

    private func open() {
        guard !isCoverPresented else { return }
        // The cover itself appears instantly; the panel does the sliding.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { isCoverPresented = true }
    }

    private func close() {
        guard isCoverPresented else { return }
        withAnimation(slide) {
            isPanelVisible = false
        } completion: {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { isCoverPresented = false }
        }
    }

    private var panel: some View {
        ZStack(alignment: .leading) {
            if isPanelVisible {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { isPresented = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                menu()
                    .frame(width: Self.panelWidth)
                    .frame(maxHeight: .infinity)
                    .clipShape(.rect(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                     bottomTrailingRadius: 28, topTrailingRadius: 28))
                    .shadow(color: .black.opacity(0.18), radius: 24, x: 6)
                    .ignoresSafeArea(.container, edges: .vertical)
                    .accessibilityAction(.escape) { isPresented = false }
                    .transition(.move(edge: .leading))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear { withAnimation(slide) { isPanelVisible = true } }
    }
}
