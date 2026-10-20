import SwiftUI

// The pieces every template picker shares (agent templates, New Bot's Templates, Feed, Ideas and
// Goals blueprints): the topic chips under the search row, a topic's heading, the sort menu and
// what shows when nothing matches.

/// All, My Templates, then each topic that has templates. Tapping the chosen topic again goes back
/// to All.
struct TemplateTopicChips: View {
    let filters: [TemplateTopicFilter]
    @Binding var selection: TemplateTopicFilter
    /// "agent.templates" names the chips "agent.templates.category.coding" and so on.
    let identifier: String
    /// Lines the first chip up with what's above it; the chips scroll past it to the edge.
    var inset = BighelpTokens.space16
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(filters, id: \.self) { chip($0) }
            }
            .padding(.horizontal, inset)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .modifier(TemplateChipsEdgeFade(width: inset))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Topics")
        .accessibilityIdentifier("\(identifier).categories")
    }

    private func chip(_ filter: TemplateTopicFilter) -> some View {
        let isOn = selection == filter
        return Button {
            withAnimation(.snappy) { selection = isOn ? .all : filter }
        } label: {
            HStack(spacing: 6) {
                if let symbol = Self.systemImage(filter) {
                    Image(systemName: symbol)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                Text(Self.title(filter)).lineLimit(1)
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(isOn ? theme.actionForeground : theme.primaryText)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: Self.height)
            .background(isOn ? theme.action : theme.surface, in: .capsule)
            .overlay { Capsule().strokeBorder(isOn ? .clear : theme.border) }
            .contentShape(.capsule)
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).category.\(Self.key(filter))")
    }

    /// Eyes need the full target on Vision Pro; elsewhere a chip stays small beside the others.
    private static var height: CGFloat {
        #if os(visionOS)
        BighelpTokens.hitTarget
        #else
        BighelpTokens.scaled(36)
        #endif
    }

    static func title(_ filter: TemplateTopicFilter) -> String {
        switch filter {
        case .all: "All"
        case .mine: "My Templates"
        case .topic(let topic): topic.title
        }
    }

    static func systemImage(_ filter: TemplateTopicFilter) -> String? {
        switch filter {
        case .all: nil
        case .mine: "person.fill"
        case .topic(let topic): topic.systemImage
        }
    }

    static func key(_ filter: TemplateTopicFilter) -> String {
        switch filter {
        case .all: "all"
        case .mine: "mine"
        case .topic(let topic): topic.id
        }
    }
}

/// In a list the row clips the chips' strip at its sides: they fade out there instead of being cut.
private struct TemplateChipsEdgeFade: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        if width > 0 {
            content.mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                }
            }
        } else {
            content
        }
    }
}

/// A section's heading in a template list: the topic's icon, its name and how many it holds.
struct TemplateSectionHeader: View {
    let title: String
    var systemImage: String?
    let count: Int
    let identifier: String
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(theme.action)
            }
            Text(title)
                .textCase(.uppercase)
                .font(.bighelp(.caption).weight(.bold))
                .tracking(1)
                .foregroundStyle(theme.secondaryText)
            Text(verbatim: "\(count)")
                .font(.bighelp(.caption).weight(.medium))
                .foregroundStyle(theme.tertiaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(identifier)
    }
}

/// The picker's order and, while the catalog holds community templates, bighelp only.
struct TemplateSortMenu: View {
    @Binding var order: TemplateOrder
    @Binding var officialOnly: Bool
    let offersOfficialOnly: Bool
    let identifier: String

    var body: some View {
        Menu {
            Picker("Order", selection: $order) {
                ForEach(TemplateOrder.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("\(identifier).order")
            if offersOfficialOnly {
                Toggle(isOn: $officialOnly) {
                    Label("bighelp only", systemImage: "checkmark.seal")
                }
                .accessibilityIdentifier("\(identifier).official")
            }
        } label: {
            // The toolbar draws the glass around it; Newest and Most used name themselves in the list.
            Image(systemName: "arrow.up.arrow.down")
                .bighelpToolbarIcon()
        }
        .bighelpIconLabel("Sort")
        .accessibilityValue(order.title)
        .accessibilityIdentifier(identifier)
    }
}

/// Nothing matches: says so, and offers to look in every topic when a chip narrowed it.
struct TemplateEmptyView: View {
    let state: TemplateEmptyState
    let identifier: String
    let onShowAll: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: BighelpTokens.space8) {
            Image(systemName: "magnifyingglass")
                .font(.bighelp(.title2))
                .foregroundStyle(theme.tertiaryText)
                .accessibilityHidden(true)
            Text(state.title)
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
            Text(state.detail)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if state.offersAll {
                Button("Search all", action: onShowAll)
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .bighelpPlainButtonStyle()
                    .accessibilityIdentifier("\(identifier).all")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BighelpTokens.space24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

extension View {
    /// The topic chips' row under the search row: edge to edge, so the chips scroll off the sides.
    func templateChipsRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: BighelpTokens.space8, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
