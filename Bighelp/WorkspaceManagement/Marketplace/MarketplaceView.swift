import SwiftUI

/// One of the Marketplace's four ways in.
enum MarketplaceSection: String, CaseIterable, Identifiable, Sendable {
    case apps, skills, plugins, messaging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: String(localized: "Apps")
        case .skills: String(localized: "Skills")
        case .plugins: String(localized: "Plugins")
        case .messaging: String(localized: "Talk anywhere")
        }
    }

    var detail: String {
        switch self {
        case .apps: String(localized: "Sign in once and your agents can use them.")
        case .skills: String(localized: "Know-how your agent follows, step by step.")
        case .plugins: String(localized: "New tools for every agent on this computer.")
        case .messaging: String(localized: "Reach your agent in Telegram, Discord and more.")
        }
    }

    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2.fill"
        case .skills: "graduationcap.fill"
        case .plugins: "puzzlepiece.extension.fill"
        case .messaging: "bubble.left.and.text.bubble.right.fill"
        }
    }
}

/// What the Marketplace needs from the shell (`makeMarketplace(for:)`): its pages for one agent, and
/// the plugin catalog it features from. Made once per visit, so its plugin model lives as long as the page.
@MainActor
struct MarketplaceContext: Identifiable {
    let id = UUID()
    let hostName: String
    /// The agent whose skills, apps and messaging apps the pages show.
    let agentName: String
    /// This week's featured plugin and the most starred; nil without a computer to read them from.
    let plugins: PluginLifecycleManagementModel?
    let page: @MainActor (MarketplaceSection) -> AnyView
}

/// Settings › Marketplace, and a bot's own from its profile: this week's featured plugin, the four
/// ways in (Apps, Skills, Plugins, Talk anywhere), then the plugins with the most stars. For
/// everyone, not Nerd Mode: the pages behind it are the same ones Hermes tools opens.
@MainActor
struct MarketplaceView: View {
    let context: MarketplaceContext

    static let popularLimit = 5

    var body: some View {
        Form {
            if let plugins = context.plugins, let hero = plugins.storefront?.hero {
                Section {
                    NavigationLink {
                        PluginCatalogPageView(model: plugins, hostName: context.hostName, entry: hero)
                    } label: {
                        MarketplaceFeaturedRow(entry: hero, isFeatured: plugins.storefront?.heroIsFeatured == true)
                    }
                    .bighelpSettingsLink()
                    .accessibilityIdentifier("marketplace.featured")
                }
                .listRowBackground(theme.surface)
            }
            Section {
                ForEach(MarketplaceSection.allCases) { section in
                    NavigationLink {
                        context.page(section)
                    } label: {
                        sectionRow(section)
                            .bighelpSettingsLinkLabel()
                    }
                    .bighelpSettingsLink()
                    .accessibilityIdentifier("marketplace.\(section.rawValue)")
                    .driveTarget("marketplace.\(section.rawValue)")
                }
            } footer: {
                Text("Plugins change every agent on \(context.hostName). Skills and messaging apps are for \(context.agentName).")
            }
            .listRowBackground(theme.surface)
            if let plugins = context.plugins, let popular = plugins.storefront?.popular, !popular.isEmpty {
                Section {
                    ForEach(popular.prefix(Self.popularLimit)) { entry in
                        NavigationLink {
                            PluginCatalogPageView(model: plugins, hostName: context.hostName, entry: entry)
                        } label: {
                            HermesToolLabel(art: .artwork(entry.listedImageURL, entry.catalogCategory),
                                            name: entry.displayName, detail: Self.popularDetail(entry))
                        }
                        .bighelpSettingsLink()
                        .accessibilityIdentifier("marketplace.popular.\(entry.name)")
                    }
                } header: {
                    Text("Popular plugins")
                }
                .listRowBackground(theme.surface)
            }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .navigationTitle(String(localized: "Marketplace"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await context.plugins?.loadIfNeeded() }
        .accessibilityIdentifier("marketplace.screen")
    }

    private func sectionRow(_ section: MarketplaceSection) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            HermesToolIcon(art: .symbol(section.symbol, key: "marketplace.\(section.rawValue)"), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                    Text(section.title)
                        .font(.bighelp(.body, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    if let count = count(section) {
                        Text(count.formatted())
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Text(section.detail)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: BighelpTokens.space8)
            if BighelpPlatform.drawsOwnLinkChevron {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 60)
        .contentShape(.rect)
    }

    /// Plugins says how many the catalog lists, once it's read; the others don't load to count.
    private func count(_ section: MarketplaceSection) -> Int? {
        guard section == .plugins, let catalog = context.plugins?.snapshot?.catalog else { return nil }
        let listed = catalog.filter { $0.removedReason == nil }.count
        return listed > 0 ? listed : nil
    }

    /// "★ 4.1K · Memory".
    static func popularDetail(_ entry: PluginCatalogEntry) -> String {
        let stars = entry.marketplace.stars.map { "★ \($0.formatted(.number.notation(.compactName)))" }
        return [stars, entry.catalogCategory.title].compactMap { $0 }.joined(separator: " · ")
    }

    @BighelpThemeReader private var theme
}

/// The featured plugin as one row: its banner, "Featured this week" (or the app's own official
/// pick without the marketplace's), its name, one line and Get.
private struct MarketplaceFeaturedRow: View {
    let entry: PluginCatalogEntry
    let isFeatured: Bool

    @ScaledMetric(relativeTo: .body) private var art: CGFloat = 80

    var body: some View {
        HStack(alignment: .center, spacing: BighelpTokens.space12) {
            Color.clear
                .frame(width: art, height: art)
                .overlay {
                    CatalogArtwork(url: entry.listedImageURL, category: entry.catalogCategory, symbolSize: art * 0.4,
                                   cornerRadius: CatalogMetrics.artworkRadius)
                }
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(isFeatured ? "Featured this week" : "Official pick")
                    .font(.bighelp(.caption, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.secondaryText)
                Text(entry.displayName)
                    .font(.bighelp(.headline, weight: .heavy))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CatalogGetLabel(text: entry.isInstalled ? String(localized: "Open") : String(localized: "Get"),
                            prominent: !entry.isInstalled, filled: !entry.isInstalled)
        }
        .padding(.vertical, BighelpTokens.space8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// The Marketplace's Apps page: the apps agents can use, as Connections lists them.
@MainActor
struct MarketplaceAppsPage: View {
    let native: ConnectorAppsModel?
    let composio: ComposioAppsModel?

    var body: some View {
        Form {
            ConnectedAppsSection(native: native, composio: composio)
        }
        .bighelpFormSurface()
        .navigationTitle(String(localized: "Apps"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { composio?.account.reload() }
        .accessibilityIdentifier("marketplace.apps.page")
    }
}
