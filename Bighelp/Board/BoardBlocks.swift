import SwiftUI

// The "Color blocks" look of Feed, Ideas and Goals: content sits in rounded blocks of the block
// palette (`BighelpBlockColor`), less important items in a page-colored card with a hairline edge,
// and every control takes the color picked in Appearance (`theme.action`).

// MARK: - Rows

private struct BoardRowSideKey: EnvironmentKey {
    static let defaultValue: CGFloat = BighelpTokens.space20
}

extension EnvironmentValues {
    /// The page's side margin (`BoardScroll` keeps a 720-point column on iPad and the Mac).
    var boardRowSide: CGFloat {
        get { self[BoardRowSideKey.self] }
        set { self[BoardRowSideKey.self] = newValue }
    }
}

/// A board List row's insets: the page's side margin and the given gaps above and below.
/// Every top-level view in a `BoardScroll` takes one; card segments take none between them.
private struct BoardRow: ViewModifier {
    let top: CGFloat
    let bottom: CGFloat
    @Environment(\.boardRowSide) private var side

    func body(content: Content) -> some View {
        content.listRowInsets(EdgeInsets(top: top, leading: side, bottom: bottom, trailing: side))
    }
}

/// One List row of a bordered card. A card is drawn a row at a time so each row keeps its own
/// swipe and long-press menu: the first row has the top corners, the last the bottom ones, and
/// the rows between have only the sides.
private struct BoardCardSegment: ViewModifier {
    let isFirst: Bool
    let isLast: Bool
    let showsSeparator: Bool
    let separatorInset: CGFloat

    func body(content: Content) -> some View {
        let radius = BoardBlockMetrics.cardRadius
        let shape = UnevenRoundedRectangle(topLeadingRadius: isFirst ? radius : 0,
                                           bottomLeadingRadius: isLast ? radius : 0,
                                           bottomTrailingRadius: isLast ? radius : 0,
                                           topTrailingRadius: isFirst ? radius : 0,
                                           style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The open ends reach past the row and are clipped, so only the sides show there.
                // The stroke is twice the hairline because its outer half is clipped too.
                Color.clear
                    .overlay {
                        ZStack {
                            shape.fill(theme.canvas)
                            shape.stroke(theme.separator, lineWidth: BighelpTokens.hairline * 2)
                        }
                        .padding(.top, isFirst ? 0 : -2)
                        .padding(.bottom, isLast ? 0 : -2)
                    }
                    .clipped()
            }
            .overlay(alignment: .top) {
                if showsSeparator {
                    Rectangle()
                        .fill(theme.separator)
                        .frame(height: BighelpTokens.hairline)
                        .padding(.leading, separatorInset)
                        .accessibilityHidden(true)
                }
            }
            .boardRow(top: isFirst ? BighelpTokens.space8 : 0, bottom: isLast ? BighelpTokens.space8 : 0)
    }

    @BighelpThemeReader private var theme
}

/// A content block: a palette fill with its ink, rounded, with room inside.
private struct BoardBlockBackground: ViewModifier {
    let color: BighelpBlockColor
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BoardBlockMetrics.blockRadius, style: .continuous)
                .fill(color.fill(dark: theme.isDarkPalette)))
            .foregroundStyle(color.ink)
    }

    @BighelpThemeReader private var theme
}

enum BoardBlockMetrics {
    static let blockRadius: CGFloat = 28
    static let cardRadius: CGFloat = 26
    static let tileSpacing: CGFloat = BighelpTokens.space12
}

extension View {
    func boardRow(top: CGFloat = BighelpTokens.space8, bottom: CGFloat = BighelpTokens.space8) -> some View {
        modifier(BoardRow(top: top, bottom: bottom))
    }

    /// `separatorInset` lines the hairline up with the row's text, past its icon tile.
    func boardCardSegment(isFirst: Bool, isLast: Bool, showsSeparator: Bool? = nil,
                          separatorInset: CGFloat = 64) -> some View {
        modifier(BoardCardSegment(isFirst: isFirst, isLast: isLast, showsSeparator: showsSeparator ?? !isFirst,
                                  separatorInset: separatorInset))
    }

    func boardBlock(_ color: BighelpBlockColor, padding: CGFloat = 18) -> some View {
        modifier(BoardBlockBackground(color: color, padding: padding))
    }
}

extension BighelpBlockColor {
    /// A post's color: by where it came from, so a daily brief keeps its color day after day.
    static func feed(_ item: AgentBoardItem) -> BighelpBlockColor {
        pastel(for: item.source.isEmpty ? item.id : item.source)
    }

    /// An idea's color: by its section (the Ideas category), else by the idea.
    static func idea(_ item: AgentBoardItem) -> BighelpBlockColor {
        let section = item.section.trimmingCharacters(in: .whitespaces)
        return pastel(for: section.isEmpty ? item.id : section.lowercased())
    }

    static func goal(_ category: GoalCategory) -> BighelpBlockColor { pastel(for: category.rawValue) }
}

// MARK: - Tiles

/// Tiles two to a List row, the same height side by side. At accessibility text sizes they
/// stack one to a row, and then each row also swipes (a row with two tiles can't say which).
struct BoardTileRows<Tile: View>: View {
    let items: [AgentBoardItem]
    let columns: Int
    let store: AgentBoardStore
    @ViewBuilder let tile: (AgentBoardItem) -> Tile

    private struct Row: Identifiable {
        let items: [AgentBoardItem]
        var id: String { items.map(\.id).joined(separator: "|") }
    }

    var body: some View {
        let size = max(1, columns)
        let rows = stride(from: 0, to: items.count, by: size).map { start in
            Row(items: Array(items[start..<min(start + size, items.count)]))
        }
        ForEach(rows) { row in
            if size == 1, let item = row.items.first {
                tile(item)
                    .boardRow(top: BoardBlockMetrics.tileSpacing / 2, bottom: BoardBlockMetrics.tileSpacing / 2)
                    .boardItemSwipe(item, store: store)
            } else {
                HStack(alignment: .top, spacing: BoardBlockMetrics.tileSpacing) {
                    ForEach(row.items) { item in
                        tile(item).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if row.items.count < size {
                        Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .boardRow(top: BoardBlockMetrics.tileSpacing / 2, bottom: BoardBlockMetrics.tileSpacing / 2)
            }
        }
    }
}

/// A row's small colored square: the item's emoji, or a symbol, on a pastel.
struct BoardIconTile: View {
    let icon: String
    let fallback: String
    let color: BighelpBlockColor
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(color.fill(dark: theme.isDarkPalette))
            if icon.isEmpty {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(color.ink)
            } else {
                Text(icon).font(.system(size: size * 0.52))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @BighelpThemeReader private var theme
}

/// A section's small heading over a card or a run of tiles.
struct BoardSectionCaption: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.bighelp(.title3, weight: .bold))
            .foregroundStyle(theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, BighelpTokens.space8)
            .accessibilityAddTraits(.isHeader)
    }

    @BighelpThemeReader private var theme
}

/// ⋯ on a tile, for the Mac. A tile's actions open on touch and hold (its `Menu`), which the
/// Mac doesn't have, and a right-click menu can't be used in a row of tiles.
struct BoardTileMoreMenu: View {
    let item: AgentBoardItem
    let context: AgentBoardContext
    let ink: Color
    @Binding var asksWhy: Bool

    var body: some View {
        Menu {
            BoardItemMenu.info(item, context: context)
            BoardItemMenu.items(item, context: context, asksWhy: $asksWhy, includesShare: true)
        } label: {
            Image(systemName: "ellipsis")
                .font(.bighelp(.body, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .accessibilityLabel("More for \(item.title)")
    }
}

// MARK: - Pills and chips

/// A button's pill: the color picked in Appearance, never a block color.
struct BoardActionPillLabel: View {
    let title: String
    var systemImage: String?
    var isBusy = false

    var body: some View {
        Group {
            if isBusy {
                BighelpNoodleView(motion: .loader, size: 20, tint: theme.actionForeground)
            } else if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.bighelp(.subheadline, weight: .semibold))
        .foregroundStyle(theme.actionForeground)
        .lineLimit(1)
        .padding(.horizontal, BighelpTokens.space16)
        .frame(minHeight: BighelpTokens.hitTarget)
        .background(Capsule().fill(theme.action))
        .contentShape(.capsule)
    }

    @BighelpThemeReader private var theme
}

/// A label (not a control) drawn as an outlined pill in the block's ink: "Today", a category.
struct BoardOutlinePill: View {
    let title: String
    var systemImage: String?
    let ink: Color

    var body: some View {
        HStack(spacing: BighelpTokens.space4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(title).lineLimit(1)
        }
        .font(.bighelp(.caption, weight: .semibold))
        .foregroundStyle(ink)
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.vertical, 5)
        .overlay(Capsule().strokeBorder(ink.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A filter chip. The selected one takes the color picked in Appearance.
struct BoardFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                .lineLimit(1)
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minHeight: BighelpTokens.hitTarget)
                .background(Capsule().fill(isSelected ? theme.action : theme.surface))
                .contentShape(.capsule)
        }
        // Only the chip takes the tap in a List row.
        .bighelpPlainButtonStyle()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @BighelpThemeReader private var theme
}

// MARK: - Files on a tile

/// A Feed tile's files: up to two picture thumbnails, then a count of the rest. A tap opens
/// the post.
struct BoardTileFiles: View {
    let item: AgentBoardItem
    let files: [AgentBoardItem.File]
    let store: AgentBoardStore
    let ink: Color
    let onOpen: () -> Void

    var body: some View {
        let summary = BoardFileSummary(files: files)
        let shown = Array(summary.pictures.prefix(2))
        let morePictures = summary.pictures.count - shown.count + summary.morePictures
        Button(action: onOpen) {
            HStack(spacing: 6) {
                ForEach(shown) { file in
                    BoardFileThumbnail(item: item, file: file, store: store)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if morePictures > 0 {
                    Text("+\(morePictures)")
                        .font(.bighelp(.footnote, weight: .semibold))
                        .foregroundStyle(ink)
                }
                if !summary.others.isEmpty {
                    Label(summary.others.count == 1 ? "1 file" : "\(summary.others.count) files",
                          systemImage: summary.chipSymbol)
                        .font(.bighelp(.footnote, weight: .semibold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint("Opens the post")
        .accessibilityIdentifier("board.feed.files.\(item.id)")
    }
}
