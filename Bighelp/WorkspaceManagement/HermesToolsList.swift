import SwiftUI

// The pieces Nerd Mode's Hermes tools pages share (MCP servers, toolsets, plugins, skills, webhooks,
// messaging, memory, hooks). They draw the same app list as Native App Connections
// (`ConnectorAppsView`): a search row and chips, sections by state, rows with a tile, a name, one
// line and a switch, a status word or Get.

/// What a row's tile shows, best first: a real logo, a provider's mark, a plugin's banner, else a
/// tile for its topic. Nothing here guesses a brand.
enum HermesToolArt: Equatable {
    /// An https logo (`ConnectorLogo`).
    case logo(URL)
    /// An AI provider's own mark. Make it with `brand(id:name:fallback:)`.
    case provider(id: String, name: String)
    /// A plugin's listed banner over its topic's tile (`CatalogArtwork`).
    case artwork(URL?, CatalogCategory)
    /// A catalog topic's tile (`CatalogCategoryTile`).
    case topic(CatalogCategory)
    /// A symbol on a pastel picked by `key`, for things the host gives no topic (servers, hooks, people).
    case symbol(String, key: String)

    /// The provider's mark when the app knows its brand, else `fallback`.
    static func brand(id: String, name: String, fallback: HermesToolArt) -> HermesToolArt {
        if case .custom = AIProviderBrandRegistry.resolve(id: id, name: name) { return fallback }
        return .provider(id: id, name: name)
    }
}

/// A row's or a page's tile at `size` points.
struct HermesToolIcon: View {
    let art: HermesToolArt
    var size: CGFloat = 40

    var body: some View {
        tile
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var radius: CGFloat { size * 0.22 }
    private var symbolSize: CGFloat { size * 0.42 }

    @ViewBuilder
    private var tile: some View {
        switch art {
        case .logo(let url):
            ConnectorLogo(url: url, name: "", size: size)
        case .provider(let id, let name):
            providerTile(id: id, name: name)
        case .artwork(let url, let category):
            CatalogArtwork(url: url, category: category, symbolSize: symbolSize, cornerRadius: radius)
        case .topic(let category):
            CatalogCategoryTile(category: category, symbolSize: symbolSize, cornerRadius: radius)
        case .symbol(let name, let key):
            symbolTile(name, color: BighelpBlockColor.pastel(for: key))
        }
    }

    private func providerTile(id: String, name: String) -> some View {
        AIProviderMarkView(providerID: id, providerName: name, context: .chatQuickChoice, size: size * 0.62)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(theme.isDarkPalette ? Color(white: 0.16) : .white))
    }

    private func symbolTile(_ name: String, color: BighelpBlockColor) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color.fill(dark: theme.isDarkPalette))
            .overlay {
                Image(systemName: name)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(color.ink)
            }
    }

    @BighelpThemeReader private var theme
}

/// A tile, a name and one line about the item, as a list row shows them.
struct HermesToolLabel: View {
    let art: HermesToolArt
    let name: String
    var detail: String = ""
    var detailColor: Color?

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            HermesToolIcon(art: art)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.bighelp(.body))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(detailColor ?? theme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// One item in a list: its label, which opens its page when `open` is set, and its own trailing
/// control (a switch, a status word or Get), which keeps its taps.
struct HermesToolRow<Trailing: View>: View {
    let art: HermesToolArt
    let name: String
    var detail: String = ""
    var detailColor: Color?
    var open: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            if let open {
                Button(action: open) {
                    label
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .bighelpPlainButtonStyle()
                .accessibilityHint("Opens its page")
            } else {
                label
                Spacer(minLength: 0)
            }
            trailing()
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .accessibilityElement(children: .contain)
    }

    private var label: some View {
        HermesToolLabel(art: art, name: name, detail: detail, detailColor: detailColor)
    }
}

/// The top of an item's page: a bigger tile, its name and one line.
struct HermesToolHeader: View {
    let art: HermesToolArt
    let name: String
    var summary: String = ""

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            HermesToolIcon(art: art, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.bighelp(.title3).weight(.semibold))
                if !summary.isEmpty {
                    Text(summary)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// Which row's switch is changing, and to what. A page keeps one in its `@State` while the model
/// works, so that row shows the new value and the others wait.
struct HermesToolChange: Equatable {
    let id: String
    let isOn: Bool

    /// The value `id`'s switch shows while this change runs, or nil for every other row.
    func pending(for id: String) -> Bool? { self.id == id ? isOn : nil }
}

/// An on/off switch, at a row's end or (with `showsTitle`) as a page's own "Turned on" row. While
/// its own change runs it shows the new value, dimmed and off; while another runs (`isLocked`) it's off.
struct HermesToolSwitch: View {
    let title: String
    let isOn: Bool
    var pending: Bool?
    var isLocked = false
    var showsTitle = false
    let identifier: String
    let change: (Bool) -> Void

    var body: some View {
        Group {
            if showsTitle {
                toggle
            } else {
                toggle.labelsHidden()
            }
        }
        .disabled(pending != nil || isLocked)
        .opacity(pending == nil ? 1 : 0.5)
        .accessibilityIdentifier(identifier)
    }

    private var toggle: some View {
        Toggle(title, isOn: Binding(get: { pending ?? isOn }, set: { change($0) }))
    }
}

/// A short state word at a row's end: Needs setup, Update available, Connected.
struct HermesToolStatus: View {
    enum Tone { case quiet, positive, warning }
    let text: String
    var tone: Tone = .quiet

    var body: some View {
        Text(text)
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private var color: Color {
        switch tone {
        case .quiet: theme.secondaryText
        case .positive: theme.success
        case .warning: theme.warning
        }
    }

    @BighelpThemeReader private var theme
}

/// Get or Add at the end of a catalog row, like Connect in Native App Connections.
struct HermesToolGetButton: View {
    var title = String(localized: "Get")
    let accessibilityLabel: String
    let identifier: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.bighelp(.subheadline).weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(theme.action)
            .disabled(isDisabled)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(identifier)
    }

    @BighelpThemeReader private var theme
}

/// The chips under a list's search row. Each page offers the ones its data has.
enum HermesToolFilter: Hashable, Identifiable {
    case all, on, off, needsSetup, updates, connected, notSetUp
    case topic(CatalogCategory)

    var id: String {
        switch self {
        case .all: "all"
        case .on: "on"
        case .off: "off"
        case .needsSetup: "needs-setup"
        case .updates: "updates"
        case .connected: "connected"
        case .notSetUp: "not-set-up"
        case .topic(let category): "topic.\(category.id)"
        }
    }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        case .needsSetup: String(localized: "Needs setup")
        case .updates: String(localized: "Update available")
        case .connected: String(localized: "Connected")
        case .notSetUp: String(localized: "Not set up")
        case .topic(let category): category.title
        }
    }

    /// Whether an item with these facts shows under this chip. Connected and Not set up read `isOn`.
    func admits(isOn: Bool, needsSetup: Bool = false, hasUpdate: Bool = false,
                topic: CatalogCategory? = nil) -> Bool {
        switch self {
        case .all: true
        case .on, .connected: isOn
        case .off, .notSetUp: !isOn
        case .needsSetup: needsSetup
        case .updates: hasUpdate
        case .topic(let category): topic == category
        }
    }

    /// Topic chips for `values`, by name, each topic once.
    static func topics(_ values: [String]) -> [HermesToolFilter] {
        let categories = Set(values.map { CatalogCategory($0) })
        return categories.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { .topic($0) }
    }
}

/// The chips themselves, modeled on Native App Connections' categories. Tapping the chosen chip
/// again goes back to All. Chips keep their whole name at every text size and scroll sideways.
struct HermesToolFilterChips: View {
    let filters: [HermesToolFilter]
    @Binding var selection: HermesToolFilter
    /// The row's identifier; each chip adds `.<filter id>`.
    let identifier: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme

    var body: some View {
        // The chips wrap onto more lines rather than run off the edge, at every text size.
        BighelpFlowLayout(spacing: BighelpTokens.space8) {
            ForEach(filters) { chip($0) }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
        .accessibilityIdentifier(identifier)
    }

    private func chip(_ filter: HermesToolFilter) -> some View {
        let isOn = selection == filter
        return Button {
            withAnimation(reduceMotion ? nil : .snappy) { selection = isOn ? .all : filter }
        } label: {
            Text(filter.title)
                .fixedSize(horizontal: false, vertical: true)
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(isOn ? theme.actionForeground : theme.primaryText)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: chipHeight)
                .background(isOn ? theme.action : theme.surface, in: .capsule)
                .overlay { Capsule().strokeBorder(isOn ? .clear : theme.border) }
                .contentShape(.capsule)
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).\(filter.id)")
    }

    private var chipHeight: CGFloat {
        #if os(visionOS)
        BighelpTokens.hitTarget
        #else
        BighelpTokens.scaled(36)
        #endif
    }
}

/// A list's first section: the search row, then its chips.
struct HermesToolSearchSection: View {
    @Binding var search: String
    let prompt: String
    let searchIdentifier: String
    let filters: [HermesToolFilter]
    @Binding var filter: HermesToolFilter
    let filtersIdentifier: String

    var body: some View {
        Section {
            BighelpSearchField(text: $search, prompt: prompt, accessibilityLabel: prompt,
                               accessibilityIdentifier: searchIdentifier)
                .bighelpListSearchRow()
            if filters.count > 1 {
                HermesToolFilterChips(filters: filters, selection: $filter, identifier: filtersIdentifier)
                    .templateChipsRow()
            }
        }
    }
}

/// Small text helpers the lists share.
enum HermesTools {
    /// A section's title with how many it holds: "On · 3".
    static func heading(_ title: String, _ count: Int) -> String {
        "\(title) · \(count.formatted())"
    }

    /// A host value made readable: `needs_setup` becomes "Needs setup".
    static func readable(_ value: String) -> String {
        let words = value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Joins the parts that aren't empty with " · ".
    static func line(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A symbol for a Hermes toolset by its name; unknown ones use their catalog topic's.
    static func toolsetSymbol(_ name: String) -> String {
        toolsetSymbols[name.lowercased()] ?? CatalogCategory(id: name).symbol
    }

    private static let toolsetSymbols: [String: String] = [
        "web": "globe", "browser": "safari", "terminal": "terminal", "file": "doc",
        "vision": "eye", "image_gen": "photo", "tts": "waveform", "memory": "brain.head.profile",
        "code_execution": "chevron.left.forwardslash.chevron.right", "delegation": "person.2",
        "cronjob": "clock", "skills": "sparkles", "todo": "checklist", "session_search": "magnifyingglass",
        "clarify": "questionmark.bubble", "moa": "person.3", "homeassistant": "house",
        "messaging": "bubble.left.and.bubble.right", "rl": "chart.xyaxis.line",
    ]
}
