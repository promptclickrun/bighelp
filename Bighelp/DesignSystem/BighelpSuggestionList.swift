import SwiftUI

/// One row of a list over the message box: `/` commands and skills, `#` sessions and pull requests.
struct BighelpSuggestion: Identifiable, Equatable {
    enum Icon: Equatable {
        case symbol(String)
        /// A numbered dot in a session's color.
        case number(Int, Color)
    }

    /// What the tag says about the row's state.
    enum Tone: Equatable { case plain, working, needsYou, ready }

    let id: String
    var icon: Icon
    /// "/" or "#", drawn in the action color before the name.
    var sigil: String
    var name: String
    var detail: String?
    var tag: String?
    var tone: Tone = .plain
    /// Rows with a section show under its title, sections in the order they first appear.
    var section: String?
}

/// The list over the message box, after the approved mockup: one header line (a title or
/// filters, and the count), then rows with an icon, a name, one line and a tag. It takes
/// the room above the message box up to about eight rows, and shrinks to fit a short list.
/// The list's bottom edge sits on the message box, so its top edge never covers the top bar.
struct BighelpSuggestionList<Header: View>: View {
    let suggestions: [BighelpSuggestion]
    /// The accessibility identifier of the list; each row is `<identifier>.row.<id>`.
    let identifier: String
    var highlightedID: String?
    var emptyText = "No matches."
    let onPick: (BighelpSuggestion) -> Void
    /// Hold (or right-click) a row for this.
    var onDetails: ((BighelpSuggestion) -> Void)?
    @ViewBuilder var header: Header

    @State private var contentHeight: CGFloat = 0
    @State private var roomAbove: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.top, BighelpTokens.space8)
                .padding(.bottom, BighelpTokens.space4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        rows
                    }
                    .padding(.bottom, BighelpTokens.space4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .dismissesKeyboardOnScroll(false)
                .frame(height: listHeight)
                .onChange(of: highlightedID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
        }
        .foregroundStyle(theme.primaryText)
        .bighelpNavigationGlass(in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(theme.border, lineWidth: BighelpTokens.hairline) }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { roomAbove = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// Up to eight rows, inside the room between the top bar and the message box.
    private var listHeight: CGFloat {
        let row = BighelpTokens.scaled(Self.rowHeight)
        let room = max(roomAbove - Self.topClearance - BighelpTokens.scaled(44), row * 1.5)
        let cap = min(room, row * 8)
        return min(max(contentHeight, row), cap)
    }

    /// The status bar and the screen's own header stay clear of the list.
    private static var topClearance: CGFloat { BighelpPlatform.isMac ? 60 : 110 }
    private static var rowHeight: CGFloat { 56 }

    @ViewBuilder private var rows: some View {
        if suggestions.isEmpty {
            Text(emptyText)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space12)
        }
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
            if let title = section.title {
                Text(title.uppercased())
                    .font(.bighelp(.caption2).weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, BighelpTokens.space16)
                    .padding(.top, BighelpTokens.space8)
                    .padding(.bottom, BighelpTokens.space4)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(section.rows) { suggestion in
                row(suggestion)
            }
        }
    }

    private var sections: [(title: String?, rows: [BighelpSuggestion])] {
        var result: [(title: String?, rows: [BighelpSuggestion])] = []
        for suggestion in suggestions {
            if let index = result.firstIndex(where: { $0.title == suggestion.section }) {
                result[index].rows.append(suggestion)
            } else {
                result.append((suggestion.section, [suggestion]))
            }
        }
        return result
    }

    private func row(_ suggestion: BighelpSuggestion) -> some View {
        Button { onPick(suggestion) } label: {
            HStack(spacing: BighelpTokens.space12) {
                icon(suggestion.icon)
                    .frame(width: BighelpTokens.scaled(28))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(suggestion.sigil).foregroundStyle(theme.action))\(suggestion.name)")
                        .font(.bighelp(.body).weight(.semibold))
                        .lineLimit(1)
                    if let detail = suggestion.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let tag = suggestion.tag {
                    BighelpSuggestionTag(text: tag, tone: suggestion.tone)
                }
            }
            .padding(.leading, BighelpTokens.space16)
            .padding(.trailing, BighelpTokens.space12)
            .padding(.vertical, BighelpTokens.space8)
            .frame(minHeight: BighelpTokens.scaled(Self.rowHeight - 2))
            .background(suggestion.id == highlightedID ? theme.action.opacity(0.12) : .clear)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .contextMenu {
            if let onDetails {
                Button("Details", systemImage: "info.circle") { onDetails(suggestion) }
            }
        }
        .id(suggestion.id)
        .accessibilityLabel(suggestion.sigil + suggestion.name)
        .accessibilityValue([suggestion.detail, suggestion.tag].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("\(identifier).row.\(suggestion.id)")
    }

    @ViewBuilder private func icon(_ icon: BighelpSuggestion.Icon) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.bighelp(.body))
                .foregroundStyle(theme.primaryText)
        case .number(let number, let color):
            Text("\(number)")
                .font(.bighelp(.caption).weight(.bold))
                .foregroundStyle(color)
                .frame(width: BighelpTokens.scaled(24), height: BighelpTokens.scaled(24))
                .background(color.opacity(0.2), in: .circle)
        }
    }

    @BighelpThemeReader private var theme
}

/// The small capitals tag at the end of a suggestion row: SKILL, COMMAND, NEEDS YOU, OPEN…
struct BighelpSuggestionTag: View {
    let text: String
    var tone: BighelpSuggestion.Tone = .plain

    var body: some View {
        Text(text.uppercased())
            .font(.bighelp(.caption2).weight(.semibold))
            .tracking(0.9)
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(tone == .plain ? theme.border : color.opacity(0.5)) }
            .fixedSize()
    }

    private var color: Color {
        switch tone {
        case .plain: theme.secondaryText
        case .working: theme.action
        case .needsYou: theme.warning
        case .ready: theme.success
        }
    }

    @BighelpThemeReader private var theme
}

/// The usual header: a title on the left and the match count on the right.
struct BighelpSuggestionHeader: View {
    var systemImage: String?
    let title: String
    let count: Int?
    var isLoading = false

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            if let systemImage { Image(systemName: systemImage).font(.bighelp(.subheadline)) }
            Text(title).font(.bighelp(.subheadline).weight(.semibold))
            if isLoading { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            if let count {
                Text(count == 1 ? "1 match" : "\(count) matches")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .frame(minHeight: BighelpTokens.scaled(32))
    }

    @BighelpThemeReader private var theme
}
