import SwiftUI

/// The first tab's Bots | Chats switch: which view of the conversations shows. It changes this run only;
/// Settings › Chat › Opens on picks the one the app opens on.
struct HomeViewSwitch {
    let current: HomeConversationsView
    let select: @MainActor (HomeConversationsView) -> Void
}

/// Search in the header: a round button that opens a search page, or a field on the row under the buttons.
enum HomeHeaderSearch {
    case button(label: LocalizedStringKey, identifier: String = "home.search", action: () -> Void)
    case field(Binding<String>, prompt: String, identifier: String = "home.search")
}

/// The computer that Today and Work show, and the others to switch to. Only drawn with two or more.
struct HomeHeaderComputer {
    let name: String
    let hosts: [BighelpMenuHosts.Host]
    let select: (String) -> Void

    var isShown: Bool { hosts.count >= 2 }
}

/// What a home root's header draws. Each root hides the navigation bar and draws this on top.
@MainActor
struct HomeHeaderContext {
    let personName: String
    let personImageURL: URL?
    let onOpenSettings: () -> Void
    /// Today and Work.
    var title: String? = nil
    /// The first tab only. Wins over `title`.
    var viewSwitch: HomeViewSwitch? = nil
    var search: HomeHeaderSearch? = nil
    /// The + menu, in this order; empty leaves + out.
    var newItems: [SimpleBotsNewItem] = []
    var onNew: (SimpleBotsNewItem) -> Void = { _ in }
    /// Today's Edit, for example. Sits before +.
    var trailing: AnyView? = nil
    /// Today and Work with two or more computers.
    var computer: HomeHeaderComputer? = nil
    /// iPad at regular width, Mac and Vision Pro: opens or closes the sidebar.
    var onToggleSidebar: (() -> Void)? = nil

    /// What sits beside the person's circle.
    enum Center: Equatable {
        case viewSwitch(HomeConversationsView)
        case title(String)
        case empty
    }

    var center: Center {
        if let viewSwitch { return .viewSwitch(viewSwitch.current) }
        if let title, !title.isEmpty { return .title(title) }
        return .empty
    }

    /// The computer menu, only when there's another computer to pick.
    var shownComputer: HomeHeaderComputer? {
        computer.flatMap { $0.isShown ? $0 : nil }
    }
}

/// The header every home root draws: the person's circle (Settings), the switch or the title, then
/// search, the computer, the root's own control and +. When the switch or the title doesn't fit beside
/// the buttons (large text), it moves to a row of its own instead of being cut.
struct HomeHeaderBar: View {
    let context: HomeHeaderContext

    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: BighelpTokens.space12) {
            ViewThatFits(in: .horizontal) {
                oneRow
                twoRows
            }
            if case .field(let text, let prompt, let identifier) = context.search {
                BighelpSearchField(text: text, prompt: prompt, accessibilityLabel: prompt,
                                   accessibilityIdentifier: identifier)
            }
        }
        // The slop each glass button would carry, so the placement puts the glass where the top bar does.
        .padding(HeaderButtonMetrics.slop)
        .bighelpHeaderButtonsPlacement()
        .padding(.bottom, BighelpTokens.space8)
        .background { SimpleBotsHeaderFade() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.header")
    }

    // MARK: Layouts

    /// The switch centered between the two button groups, or the title after the circle.
    @ViewBuilder
    private var oneRow: some View {
        switch context.center {
        case .viewSwitch:
            HomeHeaderRowLayout(spacing: BighelpTokens.space8) {
                leadingButtons
                centerView(wraps: false)
                trailingButtons
            }
        case .title:
            HStack(spacing: BighelpTokens.space8) {
                leadingButtons
                centerView(wraps: false)
                Spacer(minLength: BighelpTokens.space8)
                trailingButtons
            }
        case .empty:
            HStack(spacing: BighelpTokens.space8) {
                leadingButtons
                Spacer(minLength: BighelpTokens.space8)
                trailingButtons
            }
        }
    }

    /// Large text: the buttons on top, the switch or the title whole under them.
    private var twoRows: some View {
        VStack(alignment: context.viewSwitch == nil ? .leading : .center, spacing: BighelpTokens.space8) {
            HStack(spacing: BighelpTokens.space8) {
                leadingButtons
                Spacer(minLength: BighelpTokens.space8)
                trailingButtons
            }
            if context.center != .empty {
                centerView(wraps: true)
            }
        }
    }

    @ViewBuilder
    private func centerView(wraps: Bool) -> some View {
        if let viewSwitch = context.viewSwitch {
            HomeViewSwitchPill(viewSwitch: viewSwitch)
        } else if let title = context.title, !title.isEmpty {
            Text(title)
                .font(.bighelp(.title2, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: true)
                .padding(.leading, wraps ? 0 : BighelpTokens.space4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.title")
        }
    }

    // MARK: Buttons

    private var leadingButtons: some View {
        HStack(spacing: BighelpTokens.space8) {
            if let onToggleSidebar = context.onToggleSidebar {
                SimpleBotsCircleButton(systemImage: "sidebar.leading", label: "Sidebar",
                                       identifier: "home.sidebar-toggle", action: onToggleSidebar)
            }
            SimpleBotsPersonButton(name: context.personName, imageURL: context.personImageURL,
                                   action: context.onOpenSettings)
        }
        .fixedSize()
    }

    private var trailingButtons: some View {
        HStack(spacing: BighelpTokens.space8) {
            if let computer = context.shownComputer {
                HomeHeaderComputerMenu(computer: computer)
            }
            if case .button(let label, let identifier, let action) = context.search {
                SimpleBotsCircleButton(systemImage: "magnifyingglass", label: label, identifier: identifier,
                                       action: action)
            }
            if let trailing = context.trailing {
                trailing
            }
            if !context.newItems.isEmpty {
                newMenu
            }
        }
        .fixedSize()
    }

    /// + : New bot, New group chat, New section, each only where it can work (the caller decides).
    private var newMenu: some View {
        Menu {
            ForEach(context.newItems) { item in
                Button(item.title, systemImage: item.systemImage) { context.onNew(item) }
                    .accessibilityIdentifier("home.new.\(item.rawValue)")
            }
        } label: {
            Image(systemName: "plus")
                .font(.bighelp(.title3, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.circle)
                .bighelpNavigationGlass(in: Circle(), isInteractive: true)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityLabel("Add")
        .accessibilityIdentifier("home.new")
    }
}

/// Bots | Chats, as tall as the header's glass buttons. The view showing sits in a lighter capsule.
struct HomeViewSwitchPill: View {
    let viewSwitch: HomeViewSwitch

    @BighelpThemeReader private var theme

    private static let inset: CGFloat = 3

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeConversationsView.allCases, id: \.self) { view in
                segment(view)
            }
        }
        .padding(Self.inset)
        .bighelpNavigationGlass(in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
        .accessibilityIdentifier("home.switch")
    }

    private func segment(_ view: HomeConversationsView) -> some View {
        let isOn = view == viewSwitch.current
        return Button {
            if !isOn { viewSwitch.select(view) }
        } label: {
            Text(view.title)
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(isOn ? theme.primaryText : theme.primaryText.opacity(0.75))
                .lineLimit(1)
                .padding(.horizontal, BighelpTokens.scaled(13))
                .frame(minHeight: HeaderButtonMetrics.glass - Self.inset * 2)
                .background {
                    if isOn {
                        Capsule()
                            .fill(selectedFill)
                            .shadow(color: .black.opacity(theme.isDarkPalette ? 0 : 0.12), radius: 2, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("home.switch.\(view.rawValue)")
    }

    /// Dark: nearly black, sunk into the glass. Light: a white page on the gray track.
    private var selectedFill: Color {
        theme.isDarkPalette ? Color.black.opacity(0.6) : theme.canvas
    }
}

/// The computer in use, as a capsule; the others one tap away.
private struct HomeHeaderComputerMenu: View {
    let computer: HomeHeaderComputer

    @BighelpThemeReader private var theme

    var body: some View {
        Menu {
            ForEach(computer.hosts) { host in
                Button { computer.select(host.id) } label: {
                    if host.isSelected { Label(host.name, systemImage: "checkmark") } else { Text(host.name) }
                }
                .accessibilityIdentifier("home.computer.\(host.id)")
            }
        } label: {
            HStack(spacing: BighelpTokens.space4) {
                Text(computer.name)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.bighelp(.caption2, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.bighelp(.subheadline, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(maxWidth: BighelpTokens.scaled(160))
            .frame(height: BighelpTokens.hitTarget)
            .contentShape(Capsule())
            .bighelpNavigationGlass(in: Capsule(), isInteractive: true)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityLabel("Computer")
        .accessibilityValue(computer.name)
        .accessibilityIdentifier("home.computer")
    }
}

/// One header row: the leading group at the start, the trailing group at the end, and the middle
/// view centered on the row. Its ideal width keeps the middle clear of both groups, so a
/// `ViewThatFits` falls back to two rows instead of letting them overlap.
struct HomeHeaderRowLayout: Layout {
    var spacing: CGFloat

    /// The narrowest row that keeps the middle centered and clear of both sides.
    static func requiredWidth(leading: CGFloat, middle: CGFloat, trailing: CGFloat, spacing: CGFloat) -> CGFloat {
        2 * max(leading, trailing) + middle + 2 * spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard sizes.count == 3 else {
            return CGSize(width: sizes.map(\.width).reduce(0, +), height: sizes.map(\.height).max() ?? 0)
        }
        let required = Self.requiredWidth(leading: sizes[0].width, middle: sizes[1].width,
                                          trailing: sizes[2].width, spacing: spacing)
        let width = proposal.width.flatMap { $0.isFinite ? max($0, required) : nil } ?? required
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }
}
