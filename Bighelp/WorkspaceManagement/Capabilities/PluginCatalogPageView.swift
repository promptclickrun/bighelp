import SwiftUI

/// A catalog plugin's page: banner, tier and topic, name and maintainer, one Install button, then
/// what installing it brings (the tools and hooks it declares, the keys it needs, the pinned
/// commit) before its description and screenshots. Install installs exactly that commit.
@MainActor
struct PluginCatalogPageView: View {
    @Bindable var model: PluginLifecycleManagementModel
    let hostName: String
    let entry: PluginCatalogEntry

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var confirmsInstall = false

    /// The latest copy from the host, so Install's result shows here.
    private var current: PluginCatalogEntry {
        model.snapshot?.catalog.first { $0.name == entry.name } ?? entry
    }

    var body: some View {
        let entry = current
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                Color.clear
                    .frame(height: sizeClass == .regular ? 280 : 200)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        CatalogArtwork(url: entry.imageURL, category: entry.catalogCategory, symbolSize: 64,
                                       cornerRadius: CatalogMetrics.heroRadius)
                    }
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    BighelpFlowLayout(spacing: 6) {
                        CatalogBadge(text: entry.tier, style: .tier)
                        CatalogBadge(text: entry.catalogCategory.title)
                        if let version = entry.version { CatalogBadge(text: "v\(version)") }
                        if entry.updateAvailable { CatalogBadge(text: String(localized: "Update available")) }
                    }
                    .accessibilityElement(children: .combine)
                    Text(entry.displayName)
                        .font(.bighelp(.largeTitle, weight: .heavy))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !entry.maintainer.isEmpty {
                        Text("by \(entry.maintainer)")
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                action(entry)
                CatalogStatusBanner(support: model.support, isBusy: model.isBusy,
                                    errorMessage: model.errorMessage, successMessage: model.successMessage,
                                    retry: { Task { await model.load() } })
                    .padding(.horizontal, -CatalogMetrics.margin)
                trust(entry)
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, CatalogMetrics.margin)
            .padding(.top, BighelpTokens.space8)

            if !entry.screenshotURLs.isEmpty {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    CatalogShelf(items: entry.screenshotURLs.map(Screenshot.init),
                                 columns: .screenshots) { shot in
                        Color.clear
                            .aspectRatio(16.0 / 10.0, contentMode: .fit)
                            .overlay { CatalogArtwork(url: shot.url, category: entry.catalogCategory) }
                    }
                    Text("Screenshots from the plugin")
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, CatalogMetrics.margin)
                }
                .padding(.top, BighelpTokens.space16)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Screenshots from the plugin"))
            }

            details(entry)
                .padding(.horizontal, CatalogMetrics.margin)
                .padding(.vertical, BighelpTokens.space24)
        }
        .catalogPage()
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.clearMessages() }
        // The last look before anything changes: what it adds, from where, at which commit.
        .confirmationDialog(Text("Install \(entry.displayName)?"), isPresented: $confirmsInstall,
                            titleVisibility: .visible) {
            Button("Install and turn on") { Task { await model.install(entry) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.installMessage(entry, hostName: hostName))
        }
        .accessibilityIdentifier("plugin.page")
    }

    @ViewBuilder
    private func action(_ entry: PluginCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if entry.isInstalled {
                if model.snapshot?.installed.contains(where: { $0.name == entry.name }) == true {
                    NavigationLink {
                        InstalledPluginDetailView(model: model, pluginName: entry.name)
                    } label: {
                        Text("Open")
                            .font(.bighelp(.body, weight: .heavy))
                            .foregroundStyle(theme.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: BighelpTokens.scaled(52))
                            .background(theme.surface, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .bighelpPlainButtonStyle(.capsule)
                    .accessibilityIdentifier("plugin.open")
                } else {
                    Label("Installed", systemImage: "checkmark.circle")
                        .font(.bighelp(.body, weight: .semibold))
                }
            } else {
                CatalogPrimaryButton(title: model.isBusy ? String(localized: "Installing…")
                                                         : String(localized: "Install on \(hostName)"),
                                     isEnabled: !model.isBusy) {
                    confirmsInstall = true
                }
                .accessibilityIdentifier("plugin.install")
                Text("Plugins change every agent on this computer. Hermes runs its own security review, and bighelp never forces an install.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func trust(_ entry: PluginCatalogEntry) -> some View {
        let capabilities = entry.capabilities
        let keys = capabilities.requiredEnvironment
        return CatalogFactCard {
            CatalogFactRow(title: String(localized: "What it adds"), value: Self.additions(capabilities),
                           detail: (capabilities.tools + capabilities.hooks + capabilities.middleware)
                               .prefix(50).joined(separator: ", "),
                           monospaced: true)
            CatalogFactDivider()
            CatalogFactRow(title: String(localized: "Needs a key"),
                           value: keys.isEmpty ? String(localized: "No") : String(localized: "You add it after"),
                           detail: keys.prefix(50).joined(separator: ", "), monospaced: true)
            CatalogFactDivider()
            CatalogFactRow(title: String(localized: "Pinned version"), value: String(entry.commitSHA.prefix(7)),
                           detail: entry.commitSHA, monospaced: true, monospacedValue: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin.trust")
    }

    @ViewBuilder
    private func details(_ entry: PluginCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text("Details")
                .font(.bighelp(.title3, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
            CatalogFactCard {
                CatalogFactRow(title: String(localized: "Source"), value: "", detail: entry.repository)
                if !entry.platforms.isEmpty {
                    CatalogFactDivider()
                    CatalogFactRow(title: String(localized: "Platforms"),
                                   value: entry.platforms.joined(separator: ", "))
                }
                if !entry.requiredHermesVersion.isEmpty {
                    CatalogFactDivider()
                    CatalogFactRow(title: String(localized: "Needs Hermes"), value: entry.requiredHermesVersion)
                }
                if !entry.knownIssues.isEmpty {
                    CatalogFactDivider()
                    CatalogFactRow(title: String(localized: "Known issues"), value: "",
                                   detail: entry.knownIssues.map { "• \($0)" }.joined(separator: "\n"))
                }
            }
            if let url = entry.documentationURL {
                Link(destination: url) {
                    Label("Open documentation", systemImage: "arrow.up.right.square")
                        .font(.bighelp(.body, weight: .semibold))
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .foregroundStyle(theme.action)
            }
        }
    }

    /// "Install and turn on Recall on Home? It adds 4 tools and 1 hook, from <repo> at aeefa20."
    static func installMessage(_ entry: PluginCatalogEntry, hostName: String) -> String {
        let capabilities = entry.capabilities
        let tools = capabilities.tools.count, hooks = capabilities.hooks.count
        let adds = String(localized: "It adds \(tools.formatted()) \(tools == 1 ? "tool" : "tools") and \(hooks.formatted()) \(hooks == 1 ? "hook" : "hooks")")
        let keys = capabilities.requiredEnvironment.isEmpty ? ""
            : " " + String(localized: "You add its keys after: \(capabilities.requiredEnvironment.prefix(10).joined(separator: ", ")).")
        return String(localized: "Install and turn on \(entry.displayName) on \(hostName)? \(adds), from \(entry.repository) at \(String(entry.commitSHA.prefix(7))).") + keys
    }

    /// "4 tools · 1 hook", or that it declares nothing.
    static func additions(_ capabilities: PluginCapabilitySummary) -> String {
        let parts = [
            Self.count(capabilities.tools.count, one: "tool", many: "tools"),
            Self.count(capabilities.hooks.count, one: "hook", many: "hooks"),
            Self.count(capabilities.middleware.count, one: "middleware", many: "middleware"),
        ].compactMap { $0 }
        return parts.isEmpty ? String(localized: "Nothing declared") : parts.joined(separator: " · ")
    }

    private static func count(_ value: Int, one: String, many: String) -> String? {
        value == 0 ? nil : "\(value.formatted()) \(value == 1 ? one : many)"
    }

    private struct Screenshot: Identifiable {
        let url: URL
        var id: URL { url }
    }

    @BighelpThemeReader private var theme
}

/// "See all": a topic's plugins (or the official and verified ones) in a grid.
@MainActor
struct PluginCategoryView: View {
    @Bindable var model: PluginLifecycleManagementModel
    let hostName: String
    let title: String
    let entries: [PluginCatalogEntry]

    var body: some View {
        ScrollView {
            CatalogGrid(items: entries) { entry in
                NavigationLink {
                    PluginCatalogPageView(model: model, hostName: hostName, entry: entry)
                } label: {
                    PluginCatalogCard(entry: model.snapshot?.catalog.first { $0.name == entry.name } ?? entry)
                }
                .bighelpPlainButtonStyle(.rounded(CatalogMetrics.artworkRadius))
                .accessibilityIdentifier("plugins.card.\(entry.name)")
            }
            .padding(.vertical, BighelpTokens.space16)
        }
        .catalogPage()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("plugins.category")
    }
}
