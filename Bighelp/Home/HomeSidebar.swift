import SwiftUI

/// A recent chat in the sidebar, as the shell reads it from the chat lists.
struct HomeSidebarChat: Identifiable {
    let id: String
    let title: String
    /// Who it's with (a bot, or the group's name).
    let subtitle: String
    /// The bot's face, or the group's.
    let face: AnyView
    var isUnread = false
    var updatedAt: Date?
    let open: () -> Void
}

/// A row in the sidebar's More group (Shared with bighelp, for example).
struct HomeSidebarLink: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var detail: String?
    var showsDot = false
    let action: () -> Void
}

/// What the sidebar shows: the three places, recent chats, then More.
@MainActor
struct HomeSidebarContext {
    let items: [HomeTabItem]
    /// The place showing; nil while a chat is open over it.
    let selection: HomeTab?
    let onSelect: (HomeTab) -> Void
    var recent: [HomeSidebarChat] = []
    /// All chats; nil leaves See all out.
    var onSeeAll: (() -> Void)? = nil
    var more: [HomeSidebarLink] = []
    let onNewChat: () -> Void
    let onOpenSettings: () -> Void
    /// Runs before every choice: closes the iPad's slide-in panel; nothing for a sidebar that stays.
    var close: () -> Void = {}
}

/// The sidebar on iPad (slide-in), Mac and Vision Pro (`BighelpSideMenu` hosts it): the home's three
/// places, recent chats and More. iPhone has no sidebar; its bar holds the places.
struct HomeSidebar: View {
    let context: HomeSidebarContext

    @BighelpThemeReader private var theme

    var body: some View {
        List {
            placesSection
            recentSection
            if !context.more.isEmpty { moreSection }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .tint(theme.action)
        .accessibilityIdentifier("home.sidebar")
    }

    // MARK: Places

    private var placesSection: some View {
        Section {
            ForEach(context.items) { item in
                let isSelected = context.selection == item.id
                row(item.title, symbol: item.symbol(selected: isSelected),
                    id: "home.sidebar.place.\(item.id.rawValue)",
                    trailing: item.showsDot(selected: isSelected) ? .new : .none,
                    isSelected: isSelected) { context.onSelect(item.id) }
            }
            row(String(localized: "Settings"), symbol: "gearshape", id: "home.sidebar.settings",
                action: context.onOpenSettings)
        } header: {
            HStack {
                Spacer(minLength: 0)
                newChatButton
            }
            .padding(.bottom, BighelpTokens.space4)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var newChatButton: some View {
        Button { choose(context.onNewChat) } label: {
            Image(systemName: "square.and.pencil")
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(theme.actionForeground)
                .frame(width: BighelpTokens.scaled(40), height: BighelpTokens.scaled(40))
                .background(theme.action, in: Circle())
                .contentShape(Circle())
        }
        .bighelpPlainButtonStyle(.circle)
        .textCase(nil)
        .bighelpHelp(FloatingTabBar.newChatAccessibilityLabel, shortcut: "⌘N")
        .accessibilityLabel(FloatingTabBar.newChatAccessibilityLabel)
        .accessibilityIdentifier("home.sidebar.new-chat")
    }

    // MARK: Recent

    private var recentSection: some View {
        Section {
            if context.recent.isEmpty {
                Text("Your chats show up here.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            } else {
                ForEach(context.recent) { chat in
                    Button { choose(chat.open) } label: {
                        HomeSidebarChatLabel(chat: chat)
                            .padding(.horizontal, BighelpMenuRowLayout.labelInset)
                    }
                    .bighelpPlainButtonStyle(BighelpMenuRowLayout.outline,
                                             padding: BighelpMenuRowLayout.highlightPadding)
                    .listRowInsets(BighelpMenuRowLayout.insets)
                    .bighelpMenuRowSeparator()
                    .accessibilityIdentifier("home.sidebar.chat.\(chat.id)")
                }
            }
        } header: {
            HStack {
                Text("Recent chats")
                Spacer()
                if let onSeeAll = context.onSeeAll {
                    Button("See all") { choose(onSeeAll) }
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .textCase(nil)
                        #if targetEnvironment(macCatalyst)
                        .bighelpPlainButtonStyle(padding: BighelpTokens.space4)
                        #endif
                        .accessibilityLabel("See all chats")
                        .accessibilityIdentifier("home.sidebar.see-all")
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: More

    private var moreSection: some View {
        Section("More") {
            ForEach(context.more) { link in
                row(link.title, detail: link.detail, symbol: link.symbol, id: "home.sidebar.more.\(link.id)",
                    trailing: link.showsDot ? .new : .none, action: link.action)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: Rows

    private func row(_ title: String, detail: String? = nil, symbol: String, id: String,
                     trailing: BighelpMenuRowLabel.Trailing = .none, isSelected: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button { choose(action) } label: {
            BighelpMenuRowLabel(title: title, detail: detail, symbol: symbol, trailing: trailing)
                .padding(.horizontal, BighelpMenuRowLayout.labelInset)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
                            .fill(theme.surface)
                            .padding(-BighelpMenuRowLayout.highlightPadding)
                            .accessibilityHidden(true)
                    }
                }
        }
        .bighelpPlainButtonStyle(BighelpMenuRowLayout.outline, padding: BighelpMenuRowLayout.highlightPadding)
        .listRowInsets(BighelpMenuRowLayout.insets)
        .bighelpMenuRowSeparator()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private func choose(_ action: () -> Void) {
        context.close()
        action()
    }
}

/// A recent chat's row: its face, title and who it's with, unread, and when it last moved. The same
/// look as the old menu's `BighelpMenuChatRow`, from values the shell hands over, so chats on any
/// computer draw alike.
private struct HomeSidebarChatLabel: View {
    let chat: HomeSidebarChat

    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            chat.face
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title.isEmpty ? String(localized: "New chat") : chat.title)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(chat.subtitle)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: BighelpTokens.space8)
            if chat.isUnread {
                Circle().fill(theme.action).frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            }
            if let updatedAt = chat.updatedAt {
                Text(updatedAt, format: .relative(presentation: .named, unitsStyle: .narrow))
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
