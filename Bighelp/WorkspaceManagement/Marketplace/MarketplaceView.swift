import SwiftUI

/// One of the pages Apps & skills and a bot's Marketplace open.
enum MarketplaceSection: String, CaseIterable, Identifiable, Sendable {
    case skills, plugins, mcp, messaging, toolsets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skills: String(localized: "Skills")
        case .plugins: String(localized: "Plugins")
        case .mcp: String(localized: "MCP servers")
        case .messaging: String(localized: "Messaging apps")
        case .toolsets: String(localized: "Toolsets")
        }
    }

    var symbol: String {
        switch self {
        case .skills: "graduationcap.fill"
        case .plugins: "puzzlepiece.extension.fill"
        case .mcp: "server.rack"
        case .messaging: "bubble.left.and.text.bubble.right.fill"
        case .toolsets: "wrench.and.screwdriver.fill"
        }
    }
}

/// What the Marketplace needs from the shell (`makeMarketplace(for:)`): its pages for one bot, and
/// the plugin catalog it features from. Made once per visit, so its plugin model lives as long as the page.
@MainActor
struct MarketplaceContext: Identifiable {
    let id = UUID()
    let hostName: String
    /// The bot whose skills and messaging apps the pages show.
    let agentName: String
    /// This week's featured plugin and the plugin count; nil without a computer to read them from.
    let plugins: PluginLifecycleManagementModel?
    let page: @MainActor (MarketplaceSection) -> AnyView
}

/// A bot's own Marketplace, from its profile: the same groups Settings › Apps & skills lists after
/// the apps. The bot's apps are in its Connections, so they show once.
@MainActor
struct MarketplaceView: View {
    let context: MarketplaceContext

    var body: some View {
        Form {
            MarketplaceSections(context: context, part: .skillsAndPlugins)
            MarketplaceSections(context: context, part: .talkAnywhere)
            MarketplaceSections(context: context, part: .advanced)
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .navigationTitle(String(localized: "Marketplace"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await context.plugins?.loadIfNeeded() }
        .accessibilityIdentifier("marketplace.screen")
    }
}

/// One group of the Marketplace's pages. Apps & skills puts the logins between Talk anywhere and
/// Advanced, so each group is its own section. The page that shows them loads `context.plugins`.
@MainActor
struct MarketplaceSections: View {
    enum Part { case skillsAndPlugins, talkAnywhere, advanced }

    let context: MarketplaceContext
    let part: Part
    @AppStorage("loopdy.settings.nerd-mode") private var nerdMode = false

    var body: some View {
        switch part {
        case .skillsAndPlugins:
            Section {
                link(.skills)
                link(.plugins, value: pluginCount.map { $0.formatted() })
                if let plugins = context.plugins, let hero = plugins.storefront?.hero {
                    NavigationLink {
                        PluginCatalogPageView(model: plugins, hostName: context.hostName, entry: hero)
                    } label: {
                        AppsHubRow(title: plugins.storefront?.heroIsFeatured == true
                                       ? String(localized: "Featured this week") : String(localized: "Official pick"),
                                   value: hero.displayName, symbol: "star.fill")
                            .bighelpSettingsLinkLabel()
                    }
                    .bighelpSettingsLink()
                    .accessibilityIdentifier("marketplace.featured")
                    .driveTarget("marketplace.featured")
                }
            } header: {
                Text("Skills and plugins")
            } footer: {
                Text("Plugins change every bot on \(context.hostName). Skills are set per bot.")
            }
            .listRowBackground(theme.surface)
        case .talkAnywhere:
            Section {
                link(.messaging)
            } header: {
                Text("Talk anywhere")
            }
            .listRowBackground(theme.surface)
        case .advanced:
            if nerdMode {
                Section {
                    link(.mcp)
                    link(.toolsets)
                } header: {
                    Text("Advanced")
                }
                .listRowBackground(theme.surface)
            }
        }
    }

    private func link(_ section: MarketplaceSection, value: String? = nil) -> some View {
        NavigationLink {
            context.page(section)
        } label: {
            AppsHubRow(title: section.title, value: value, symbol: section.symbol)
                .bighelpSettingsLinkLabel()
        }
        .bighelpSettingsLink()
        .accessibilityIdentifier("marketplace.\(section.rawValue)")
        .driveTarget("marketplace.\(section.rawValue)")
    }

    /// How many plugins the computer has, once they're read.
    private var pluginCount: Int? {
        guard let installed = context.plugins?.snapshot?.installed, !installed.isEmpty else { return nil }
        return installed.count
    }

    @BighelpThemeReader private var theme
}
