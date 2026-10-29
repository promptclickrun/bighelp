import SwiftUI
import UIKit

// The pieces both storefronts (Skills Hub and Plugins) are made of: pages of sections in a
// ScrollView, shelves of whole cards that scroll sideways, and grids for "See all". Content tiles
// use the block palette (`BighelpBlockColor`); what acts (Get, Install, chips) takes `theme.action`.

enum CatalogMetrics {
    static let margin = BighelpTokens.space16
    static let cardSpacing = BighelpTokens.space12
    /// Between a shelf's cards: the page margin, so the card after the last whole one starts
    /// exactly at the screen's edge and none of it shows.
    static let shelfSpacing = margin
    static let sectionSpacing = BighelpTokens.space24
    static let artworkRadius: CGFloat = 14
    static let heroRadius: CGFloat = 22

}

/// How many whole cards a shelf shows across: at least `minimum`, more while each stays at least
/// `minimumWidth` wide. A shelf never shows part of a card at its edge.
struct CatalogShelfColumns: Sendable {
    let minimumWidth: CGFloat
    let minimum: Int

    /// Plugin cards: two on a phone.
    static let cards = CatalogShelfColumns(minimumWidth: 150, minimum: 2)
    /// Square skill tiles: three on a phone.
    static let tiles = CatalogShelfColumns(minimumWidth: 100, minimum: 3)
    /// Screenshots: one on a phone.
    static let screenshots = CatalogShelfColumns(minimumWidth: 260, minimum: 1)

    func count(in length: CGFloat) -> Int {
        let spacing = CatalogMetrics.shelfSpacing
        return max(minimum, Int((length + spacing) / (minimumWidth + spacing)))
    }

    /// One card's width when `count(in:)` cards and their gaps fill `length` exactly.
    func width(in length: CGFloat) -> CGFloat {
        let count = CGFloat(count(in: length))
        return (length - CatalogMetrics.shelfSpacing * (count - 1)) / count
    }
}

/// A plugin's banner picture, or its topic's tile until (or unless) the picture loads. Pictures
/// load through the link-preview store: public https hosts only, no cookies, size-bounded,
/// shrunk to card size and kept on disk for a week. A picture already in memory shows at once,
/// so scrolling back to a card doesn't flash its tile.
struct CatalogArtwork: View {
    let url: URL?
    let category: CatalogCategory
    var symbolSize: CGFloat = 30
    var cornerRadius: CGFloat = CatalogMetrics.artworkRadius

    @State private var picture: UIImage?
    @State private var shownURL: URL?

    init(url: URL?, category: CatalogCategory, symbolSize: CGFloat = 30,
         cornerRadius: CGFloat = CatalogMetrics.artworkRadius) {
        self.url = url
        self.category = category
        self.symbolSize = symbolSize
        self.cornerRadius = cornerRadius
        let cached = url.flatMap { LinkPreviewStore.shared.cachedPicture(for: $0) }
        _picture = State(initialValue: cached)
        _shownURL = State(initialValue: cached == nil ? nil : url)
    }

    var body: some View {
        CatalogCategoryTile(category: category, symbolSize: symbolSize, cornerRadius: cornerRadius)
            .overlay {
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: url) {
                guard url != shownURL || picture == nil else { return }
                picture = nil
                shownURL = url
                guard let url else { return }
                let store = LinkPreviewStore.shared
                guard case .preview = await store.load(url), !Task.isCancelled else { return }
                let image = await store.picture(for: url)
                guard !Task.isCancelled else { return }
                picture = image
            }
    }
}

/// A topic's tile: its pastel with its symbol in the block's ink.
struct CatalogCategoryTile: View {
    let category: CatalogCategory
    var symbolSize: CGFloat = 30
    var cornerRadius: CGFloat = CatalogMetrics.artworkRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(category.color.fill(dark: theme.isDarkPalette))
            .overlay {
                Image(systemName: category.symbol)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(category.color.ink)
            }
            .accessibilityHidden(true)
    }

    @BighelpThemeReader private var theme
}

/// A small label on a page or hero: a trust tier in capitals (inverted ink), or plain facts.
struct CatalogBadge: View {
    enum Style { case tier, fact, onArtwork }
    let text: String
    var style: Style = .fact

    var body: some View {
        Text(style == .tier ? text.uppercased() : text)
            .font(.bighelp(.caption, weight: style == .tier ? .heavy : .semibold))
            .tracking(style == .tier ? 0.5 : 0)
            .padding(.horizontal, BighelpTokens.space8)
            .padding(.vertical, BighelpTokens.space4)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: BighelpTokens.radius8, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var foreground: Color {
        switch style {
        case .tier: theme.canvas
        case .fact: theme.secondaryText
        case .onArtwork: .white
        }
    }

    private var background: Color {
        switch style {
        case .tier: theme.primaryText
        case .fact: theme.surface
        case .onArtwork: .black.opacity(0.5)
        }
    }

    @BighelpThemeReader private var theme
}

/// "Get" or "Open" on a card. The whole card is the button; this only says what it does.
/// `filled` is the hero's: the action color, at least a touch target tall.
struct CatalogGetLabel: View {
    let text: String
    var prominent = true
    var filled = false

    var body: some View {
        Text(text)
            .font(.bighelp(filled ? .body : .subheadline, weight: .heavy))
            .foregroundStyle(filled ? theme.actionForeground : prominent ? theme.action : theme.primaryText)
            .padding(.horizontal, filled ? BighelpTokens.space20 : BighelpTokens.space16)
            .padding(.vertical, 6)
            .frame(minHeight: filled ? BighelpTokens.hitTarget : nil)
            .background(filled ? theme.action : theme.surface, in: Capsule())
            .fixedSize()
    }

    @BighelpThemeReader private var theme
}

/// A section's title with its count, and See all when there's more to see.
struct CatalogSectionHeader<Destination: View>: View {
    let title: String
    var count: Int?
    var seeAllIdentifier: String?
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space12) {
            HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                Text(title)
                    .font(.bighelp(.title3, weight: .heavy))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let count {
                    Text(count.formatted())
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if Destination.self != EmptyView.self {
                NavigationLink(destination: destination) {
                    Text("See all")
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.action)
                        .fixedSize()
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier(seeAllIdentifier ?? "catalog.seeAll")
                .accessibilityLabel(Text("See all, \(title)"))
            }
        }
        .padding(.horizontal, CatalogMetrics.margin)
    }

    @BighelpThemeReader private var theme
}

extension CatalogSectionHeader where Destination == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count, seeAllIdentifier: nil) { EmptyView() }
    }
}

/// A row of whole cards that scrolls sideways. Whole cards fill the width inside the page
/// margins, and a swipe stops on a card, so no card is ever cut at the edge; See all shows the rest.
/// The cards in a row are as tall as the tallest, so a card's last line (Get) lines up.
struct CatalogShelf<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let columns: CatalogShelfColumns
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        ScrollView(.horizontal) {
            // Not lazy: a shelf holds at most a dozen cards, and every card must be measured
            // to make the row as tall as the tallest.
            HStack(alignment: .top, spacing: CatalogMetrics.shelfSpacing) {
                ForEach(items) { item in
                    card(item)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .containerRelativeFrame(.horizontal) { length, _ in columns.width(in: length) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, CatalogMetrics.margin, for: .scrollContent)
        .scrollIndicators(.hidden)
    }
}

/// "See all" and search results: the same cards, two across on a phone and more on wider screens.
struct CatalogGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var minimumWidth: CGFloat = 150
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: CatalogMetrics.cardSpacing,
                                     alignment: .top)],
                  alignment: .leading, spacing: BighelpTokens.space20) {
            ForEach(items) { card($0) }
        }
        .padding(.horizontal, CatalogMetrics.margin)
    }
}

/// A plugin as a card: banner (or topic tile) at 2:1, its name, one line, and Get or Open.
/// Only official and verified plugins load their banner here: a community plugin's picture is
/// on its author's server, so it loads only on the plugin's own page, once the person opens it.
struct PluginCatalogCard: View {
    let entry: PluginCatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Color.clear
                .aspectRatio(2, contentMode: .fit)
                .overlay { CatalogArtwork(url: entry.listedImageURL, category: entry.catalogCategory) }
            Text(entry.displayName)
                .font(.bighelp(.subheadline, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
            // In a shelf the card is as tall as the row's tallest, and Get sits at the bottom.
            Spacer(minLength: 0)
            CatalogGetLabel(text: entry.isInstalled ? String(localized: "Open") : String(localized: "Get"),
                            prominent: !entry.isInstalled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}

/// A skill as a square tile in its topic's color (or its hub's), with its name and topic.
struct SkillCatalogTile: View {
    let item: SkillHubItem
    let sourceLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    CatalogCategoryTile(category: CatalogCategory(id: item.tileKey), symbolSize: 34,
                                        cornerRadius: CatalogMetrics.heroRadius)
                }
                .overlay(alignment: .topTrailing) {
                    if item.isInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(theme.actionForeground, theme.action)
                            .padding(BighelpTokens.space8)
                            .accessibilityHidden(true)
                    }
                }
            Text(item.name)
                .font(.bighelp(.subheadline, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.catalogCategory?.title ?? sourceLabel)
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([item.name, item.catalogCategory?.title ?? sourceLabel,
                                  item.isInstalled ? String(localized: "Installed") : nil]
            .compactMap { $0 }.joined(separator: ", ")))
    }

    @BighelpThemeReader private var theme
}

/// A filter chip: whole at every text size, laid out with `BighelpFlowLayout` so a row wraps.
struct CatalogChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.bighelp(.subheadline, weight: isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, BighelpTokens.space8)
                .frame(minHeight: BighelpTokens.hitTarget)
                .background(isSelected ? theme.action : theme.surface, in: Capsule())
                .contentShape(Capsule())
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @BighelpThemeReader private var theme
}

/// The page's state in a plain sentence: waiting, unavailable on this host, an error with Retry,
/// or what Hermes confirmed. The ScrollView pages' counterpart of `CapabilitiesStatusSections`.
struct CatalogStatusBanner: View {
    let support: CapabilitiesHostSupport
    let isBusy: Bool
    let errorMessage: String?
    let successMessage: String?
    let retry: () -> Void

    var body: some View {
        // Nothing at all when there's nothing to say, so the page keeps one gap there, not two.
        if isBusy || errorMessage != nil || successMessage != nil || support.isUnavailable { banner }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if isBusy {
                Label("Waiting for Hermes…", systemImage: "hourglass")
                    .foregroundStyle(theme.secondaryText)
            }
            if case .unavailable(let message) = support {
                Label(message, systemImage: "questionmark.circle")
                    .foregroundStyle(theme.secondaryText)
            }
            if let errorMessage {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                    Button("Retry", action: retry)
                        .font(.bighelp(.body, weight: .semibold))
                        .foregroundStyle(theme.action)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .bighelpPlainButtonStyle()
                        .disabled(isBusy)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("capabilities.error")
            }
            if let successMessage {
                Label(successMessage, systemImage: "checkmark.circle")
                    .accessibilityIdentifier("capabilities.confirmed")
            }
        }
        .font(.bighelp(.subheadline))
        .foregroundStyle(theme.primaryText)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CatalogMetrics.margin)
    }

    @BighelpThemeReader private var theme
}

private extension CapabilitiesHostSupport {
    var isUnavailable: Bool {
        if case .unavailable = self { true } else { false }
    }
}

/// A rounded card of label/value rows (a plugin's "What it adds"); put `CatalogFactDivider`
/// between the rows.
struct CatalogFactCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @BighelpThemeReader private var theme
}

struct CatalogFactDivider: View {
    var body: some View {
        Rectangle().fill(theme.separator).frame(height: BighelpTokens.hairline).accessibilityHidden(true)
    }

    @BighelpThemeReader private var theme
}

/// One row of a fact card: a bold label, its value, and optional detail under them.
struct CatalogFactRow: View {
    let title: String
    let value: String
    var detail: String?
    /// Code-like detail (tool names, keys, a commit) in monospace.
    var monospaced = false
    var monospacedValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            if value.isEmpty {
                titleText
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        titleText
                        Spacer(minLength: BighelpTokens.space12)
                        valueText
                    }
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        titleText
                        valueText
                    }
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.bighelp(.footnote, design: monospaced ? .monospaced : nil))
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, CatalogMetrics.margin)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title).font(.bighelp(.subheadline, weight: .bold)).foregroundStyle(theme.primaryText)
    }

    private var valueText: some View {
        Text(value)
            .font(.bighelp(.subheadline, design: monospacedValue ? .monospaced : nil))
            .foregroundStyle(theme.secondaryText)
            .textSelection(.enabled)
    }

    @BighelpThemeReader private var theme
}

/// The page's one big action: Install, Add.
struct CatalogPrimaryButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.bighelp(.body, weight: .heavy))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(isEnabled ? theme.actionForeground : theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BighelpTokens.space12)
                .frame(minHeight: BighelpTokens.scaled(52))
                .background(isEnabled ? theme.action : theme.surface, in: Capsule())
                .contentShape(Capsule())
        }
        .bighelpPlainButtonStyle(.capsule)
        .disabled(!isEnabled)
    }

    @BighelpThemeReader private var theme
}

extension View {
    /// A storefront page: sections in a ScrollView on the page color.
    func catalogPage() -> some View {
        modifier(CatalogPageModifier())
    }
}

private struct CatalogPageModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .dismissesKeyboardOnScroll(true)
            .background(theme.canvas.ignoresSafeArea())
            .foregroundStyle(theme.primaryText)
            .tint(theme.action)
    }

    @BighelpThemeReader private var theme
}
