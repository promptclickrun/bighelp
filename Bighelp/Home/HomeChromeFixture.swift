#if DEBUG
import SwiftUI

/// The home's chrome on made-up data, alone: every header variant, the bar and the sidebar.
/// For screenshots and review before the shell uses them (suggested launch argument `-test-home-chrome`).
struct HomeChromeFixture: View {
    enum Part: String, CaseIterable, Identifiable {
        case headers, bar, sidebar
        var id: String { rawValue }
    }

    @State private var part = Part.headers
    @State private var view = HomeConversationsView.bots
    @State private var tab = HomeTab.conversations
    @State private var search = ""
    @State private var computerID = "home"
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $part) {
                ForEach(Part.allCases) { part in Text(verbatim: part.rawValue.capitalized).tag(part) }
            } label: {
                Text(verbatim: "Part")
            }
            .pickerStyle(.segmented)
            .padding(BighelpTokens.space16)
            .accessibilityIdentifier("home.fixture.part")
            switch part {
            case .headers: headers
            case .bar: bar
            case .sidebar: HomeSidebar(context: sidebarContext)
            }
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
    }

    // MARK: Headers

    private var headers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space24) {
                sample("First tab") {
                    HomeHeaderBar(context: header(
                        viewSwitch: HomeViewSwitch(current: view, select: { view = $0 }),
                        search: .button(label: "Search", action: {}),
                        newItems: SimpleBotsNewItem.allCases))
                }
                sample("First tab, search field") {
                    HomeHeaderBar(context: header(
                        viewSwitch: HomeViewSwitch(current: view, select: { view = $0 }),
                        search: .field($search, prompt: "Search chats"),
                        newItems: [.groupChat]))
                }
                sample("Today") {
                    HomeHeaderBar(context: header(title: "Today", trailing: AnyView(editChip)))
                }
                sample("Work, two computers") {
                    HomeHeaderBar(context: header(title: "Work", search: .button(label: "Search", action: {}),
                                                  computer: computer))
                }
                sample("With the sidebar button") {
                    HomeHeaderBar(context: header(title: "Today", onToggleSidebar: {}))
                }
            }
            .padding(.bottom, BighelpTokens.space24)
        }
    }

    private func header(title: String? = nil, viewSwitch: HomeViewSwitch? = nil, search: HomeHeaderSearch? = nil,
                        newItems: [SimpleBotsNewItem] = [], trailing: AnyView? = nil,
                        computer: HomeHeaderComputer? = nil,
                        onToggleSidebar: (() -> Void)? = nil) -> HomeHeaderContext {
        HomeHeaderContext(personName: "Sam Rivera", personImageURL: nil, onOpenSettings: {}, title: title,
                          viewSwitch: viewSwitch, search: search, newItems: newItems, trailing: trailing,
                          computer: computer, onToggleSidebar: onToggleSidebar)
    }

    private var computer: HomeHeaderComputer {
        let hosts = [("home", "Home Mac"), ("studio", "Studio Mac")].map {
            BighelpMenuHosts.Host(id: $0.0, name: $0.1, isSelected: $0.0 == computerID)
        }
        return HomeHeaderComputer(name: hosts.first(where: \.isSelected)?.name ?? "", hosts: hosts,
                                  select: { computerID = $0 })
    }

    private var editChip: some View {
        Button {} label: {
            Text(verbatim: "Edit")
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space16)
                .frame(height: BighelpTokens.hitTarget)
                .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
        }
        .buttonStyle(.plain)
    }

    private func sample<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text(verbatim: name)
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, BighelpTokens.space16)
            content()
        }
    }

    // MARK: Bar

    private var bar: some View {
        VStack {
            Spacer()
            Text(verbatim: "Selected: \(tab.rawValue)")
                .font(.bighelp(.body))
                .foregroundStyle(theme.secondaryText)
            Spacer()
            HomeTabBar(selection: $tab, items: HomeTabItem.standard(view: view, todayHasNew: true), onNewChat: {})
        }
    }

    // MARK: Sidebar

    private var sidebarContext: HomeSidebarContext {
        let chats: [(String, String, String, Bool)] = [
            ("trip", "Lisbon trip", "Mina", true),
            ("budget", "Family budget", "Group chat", false),
            ("garden", "Garden plan", "Jordan", false),
        ]
        let recent = chats.enumerated().map { index, chat in
            HomeSidebarChat(id: chat.0, title: chat.1, subtitle: chat.2,
                            face: AnyView(AvatarView(stableID: chat.0, displayName: chat.2, size: 30)),
                            isUnread: chat.3, updatedAt: Date(timeIntervalSinceNow: -Double(index + 1) * 900),
                            open: {})
        }
        return HomeSidebarContext(
            items: HomeTabItem.standard(view: view, todayHasNew: true), selection: tab, onSelect: { tab = $0 },
            recent: recent, onSeeAll: {},
            more: [HomeSidebarLink(id: "shared", title: "Shared with Bighelp", symbol: "tray.and.arrow.down",
                                   detail: "2", showsDot: true, action: {})],
            onNewChat: {}, onOpenSettings: {})
    }
}
#endif
