import SwiftUI

/// ☰: bighelp's one menu (hosts, chats, and everywhere else). A sheet on
/// iPhone, a panel from the leading edge on iPad, a sidebar on Mac and Vision
/// Pro (see HomeMenuPresentation).
struct AgentHomeDrawer: View {
    let chats: [SessionSummary]
    let agent: (String) -> (name: String, imageURL: URL?)?
    let hosts: BighelpMenuHosts
    let destinations: BighelpMenuDestinations
    let onOpen: (SessionSummary) -> Void
    /// In the all-hosts view, recent chats come from every host.
    var fleetChats: (fleet: FleetStore, open: (FleetChat) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.homeMenuClose) private var panelClose

    var body: some View {
        NavigationStack {
            BighelpMenu(hosts: hosts, destinations: destinations, close: close, hasRecent: hasRecent) {
                AnyView(recentChats)
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            // A Mac sidebar has no title bar of its own.
            .toolbar(BighelpPlatform.isMac ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                // The Mac's sidebar stays; ☰ and View › Hide Sidebar put it away.
                if !BighelpPlatform.isMac {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: close)
                            .accessibilityIdentifier("menu.done")
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.drawer")
    }

    /// The panel isn't a presentation, so `dismiss` would do nothing there.
    private func close() {
        if let panelClose { panelClose() } else { dismiss() }
    }

    private var hasRecent: Bool {
        if let fleetChats { return !fleetChats.fleet.chats().isEmpty }
        return !chats.isEmpty
    }

    @ViewBuilder
    private var recentChats: some View {
        if let fleetChats {
            ForEach(fleetChats.fleet.chats().prefix(12)) { chat in
                Button {
                    close()
                    fleetChats.open(chat)
                } label: {
                    FleetChatRow(chat: chat, fleet: fleetChats.fleet, compact: true)
                }
                .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12), padding: BighelpTokens.space4)
                .accessibilityIdentifier("menu.fleet-chat.\(chat.title)")
            }
        } else {
            sessionChats
        }
    }

    private var sessionChats: some View {
        ForEach(chats) { chat in
            Button {
                close()
                onOpen(chat)
            } label: {
                BighelpMenuChatRow(chat: chat, agent: agent)
            }
            .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12), padding: BighelpTokens.space4)
            .accessibilityIdentifier("menu.chat.\(chat.id)")
        }
    }
}

extension EnvironmentValues {
    @Entry var homeMenuClose: (@MainActor () -> Void)?
}

/// Presents ☰ like a side menu on iPad: it slides in from the leading edge
/// over a dimmed screen, and a tap outside closes it. iPhone keeps the sheet.
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
            content.bighelpSheet(isPresented: $isPresented, onDismiss: onDismiss, content: menu)
        }
    }

    private func showSideMenu(_ sideMenu: BighelpSideMenu) {
        // Build inside a SwiftUI update, not the presentation callback, so
        // readiness keeps updating. contentID also replaces captured stores.
        let panel = BighelpDeferredSection { menu() }
            .environment(\.homeMenuClose, { if !BighelpPlatform.isMac { isPresented = false } })
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
                    .environment(\.homeMenuClose, { isPresented = false })
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
