import SwiftUI

/// Plugins as a storefront (Settings › Hermes tools › Plugins): search, a featured official
/// plugin, the official and verified ones, then a shelf per topic. A card opens the plugin's page,
/// whose one Install button installs the pinned commit it shows. Installed plugins are a toolbar
/// button away.
@MainActor
struct PluginLifecycleManagementView: View {
    @Bindable var model: PluginLifecycleManagementModel
    let hostName: String
    @State private var search = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CatalogMetrics.sectionSpacing) {
                BighelpSearchField(text: $search, prompt: String(localized: "Search plugins"),
                                   accessibilityLabel: String(localized: "Search plugins"),
                                   accessibilityIdentifier: "plugins.search")
                    .padding(.horizontal, CatalogMetrics.margin)
                    .padding(.top, BighelpTokens.space8)
                status
                if let snapshot = model.snapshot {
                    if ManagementSearch.isActive(search) {
                        results(PluginStorefront.matching(search, in: snapshot.catalog))
                    } else {
                        storefront(snapshot)
                    }
                }
            }
            .padding(.bottom, BighelpTokens.space32)
        }
        .catalogPage()
        .bighelpRefreshable { await model.load() }
        .task { if model.snapshot == nil { await model.load() } }
        .toolbar {
            if let snapshot = model.snapshot {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        InstalledPluginsView(model: model, hostName: hostName)
                    } label: {
                        Text("Installed \(snapshot.installed.count.formatted())").bighelpToolbarText()
                    }
                    .accessibilityIdentifier("plugins.installed.open")
                }
            }
        }
        .accessibilityIdentifier("plugins.storefront")
    }

    private var status: some View {
        CatalogStatusBanner(support: model.support, isBusy: model.isBusy,
                            errorMessage: model.errorMessage, successMessage: model.successMessage,
                            retry: { Task { await model.load() } })
    }

    @ViewBuilder
    private func storefront(_ snapshot: PluginSnapshot) -> some View {
        let storefront = PluginStorefront(catalog: snapshot.catalog)
        if snapshot.catalog.isEmpty {
            Text("This computer's plugin catalog is empty.")
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, CatalogMetrics.margin)
        }
        if let hero = storefront.hero {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Text("Featured")
                    .font(.bighelp(.footnote, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                NavigationLink { page(hero) } label: { PluginHeroCard(entry: hero) }
                    .bighelpPlainButtonStyle(.rounded(CatalogMetrics.heroRadius))
                    .accessibilityIdentifier("plugins.hero")
            }
            .padding(.horizontal, CatalogMetrics.margin)
        }
        if !storefront.trusted.isEmpty {
            shelf(String(localized: "Official and verified"), id: "trusted", entries: storefront.trusted, count: nil)
        }
        ForEach(storefront.shelves) { shelf in
            BighelpDeferredSection {
                self.shelf(shelf.category.title, id: shelf.id, entries: shelf.entries, count: shelf.entries.count)
            }
        }
        if snapshot.skippedCatalogRows > 0 {
            Text(snapshot.skippedCatalogRows == 1
                 ? "1 plugin in the catalog couldn't be read, so it isn't shown."
                 : "\(snapshot.skippedCatalogRows.formatted()) plugins in the catalog couldn't be read, so they aren't shown.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, CatalogMetrics.margin)
        }
    }

    private func shelf(_ title: String, id: String, entries: [PluginCatalogEntry], count: Int?) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            CatalogSectionHeader(title: title, count: count, seeAllIdentifier: "plugins.seeAll.\(id)") {
                PluginCategoryView(model: model, hostName: hostName, title: title, entries: entries)
            }
            CatalogShelf(items: Array(entries.prefix(12)), width: CatalogMetrics.cardWidth) { entry in
                card(entry)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugins.shelf.\(id)")
    }

    @ViewBuilder
    private func results(_ entries: [PluginCatalogEntry]) -> some View {
        if entries.isEmpty {
            Text("No plugins match “\(search.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, CatalogMetrics.margin)
                .accessibilityIdentifier("management.search.empty")
        } else {
            CatalogGrid(items: entries) { card($0) }
        }
    }

    private func card(_ entry: PluginCatalogEntry) -> some View {
        NavigationLink { page(entry) } label: { PluginCatalogCard(entry: entry) }
            .bighelpPlainButtonStyle(.rounded(CatalogMetrics.artworkRadius))
            .accessibilityIdentifier("plugins.card.\(entry.name)")
    }

    private func page(_ entry: PluginCatalogEntry) -> some View {
        PluginCatalogPageView(model: model, hostName: hostName, entry: entry)
    }

    @BighelpThemeReader private var theme
}

/// The featured plugin: its banner with tier, topic and name over it, then one line and Get.
private struct PluginHeroCard: View {
    let entry: PluginCatalogEntry
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: sizeClass == .regular ? 260 : 176)
                .frame(maxWidth: .infinity)
                .overlay {
                    CatalogArtwork(url: entry.imageURL, category: entry.catalogCategory, symbolSize: 56, cornerRadius: 0)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        BighelpFlowLayout(spacing: 6) {
                            CatalogBadge(text: entry.tier, style: .tier)
                            CatalogBadge(text: entry.catalogCategory.title, style: .onArtwork)
                        }
                        Text(entry.displayName)
                            .font(.bighelp(.title, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(CatalogMetrics.margin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                }
                .clipped()
            HStack(alignment: .center, spacing: BighelpTokens.space12) {
                Text(entry.summary)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CatalogGetLabel(text: entry.isInstalled ? String(localized: "Open") : String(localized: "Get"),
                                prominent: !entry.isInstalled)
            }
            .padding(.horizontal, CatalogMetrics.margin)
            .padding(.vertical, 14)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: CatalogMetrics.heroRadius, style: .continuous))
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}

/// Every installed plugin on the computer, with Rescan; a row opens it.
@MainActor
private struct InstalledPluginsView: View {
    @Bindable var model: PluginLifecycleManagementModel
    let hostName: String

    var body: some View {
        List {
            CapabilitiesScopeSection(hostName: hostName, profileName: nil)
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let snapshot = model.snapshot {
                Section {
                    if snapshot.installed.isEmpty { Text("No installed plugins were reported.").foregroundStyle(.secondary) }
                    ForEach(snapshot.installed) { plugin in
                        NavigationLink {
                            InstalledPluginDetailView(model: model, pluginName: plugin.name)
                        } label: {
                            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                Text(plugin.name)
                                Text("\(plugin.source) • \(plugin.runtimeStatus.capitalized)")
                                    .font(.bighelp(.caption)).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: BighelpTokens.hitTarget)
                        }
                    }
                    Button("Rescan installed plugins", systemImage: "arrow.clockwise") {
                        Task { await model.rescan() }
                    }
                    .disabled(model.isBusy)
                    .frame(minHeight: BighelpTokens.hitTarget)
                } header: { Text("Installed") }
                  footer: { Text("Rescan refreshes discovery only; it does not install, enable, or restart plugins.") }

                if !snapshot.removedCatalogEntries.isEmpty {
                    Section("Advanced · Removed from catalog") {
                        ForEach(snapshot.removedCatalogEntries, id: \.self) { Text($0).font(.bighelp(.footnote)) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Installed")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await model.load() }
        .accessibilityIdentifier("plugins.installed")
    }
}

/// One installed plugin: enable or disable, update from Git, remove.
@MainActor
struct InstalledPluginDetailView: View {
    @Bindable var model: PluginLifecycleManagementModel
    let pluginName: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemoval = false
    @State private var confirmsToggle = false

    private var plugin: InstalledPlugin? { model.snapshot?.installed.first { $0.name == pluginName } }

    var body: some View {
        List {
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let plugin {
                Section("Overview") {
                    LabeledContent("Version", value: plugin.version.isEmpty ? "Not reported" : plugin.version)
                    LabeledContent("Source", value: plugin.source)
                    LabeledContent("Runtime", value: plugin.runtimeStatus.capitalized)
                    if !plugin.summary.isEmpty { Text(plugin.summary) }
                    if let removed = plugin.removedReason {
                        Label(removed, systemImage: "exclamationmark.shield").foregroundStyle(.red)
                    }
                }
                if plugin.requiresAuthentication {
                    Section("Authentication") {
                        Text("This plugin requires host-side authentication.")
                        if !plugin.authenticationCommand.isEmpty {
                            Text(plugin.authenticationCommand).font(.bighelp(.footnote).monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section("Manage plugin") {
                    Button(plugin.isEnabled ? "Disable" : "Enable") { confirmsToggle = true }
                    if plugin.canUpdate {
                        Button("Update from its configured Git source") { Task { await model.update(plugin) } }
                    }
                    if plugin.canRemove {
                        Button("Remove plugin", role: .destructive) { confirmsRemoval = true }
                    }
                }
            } else {
                ContentUnavailableView("Plugin unavailable", systemImage: "puzzlepiece.extension")
            }
        }
        .navigationTitle(pluginName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Change this plugin’s runtime state?", isPresented: $confirmsToggle, titleVisibility: .visible) {
            if let plugin {
                Button(plugin.isEnabled ? "Disable \(plugin.name)" : "Enable \(plugin.name)") {
                    Task { await model.setEnabled(!plugin.isEnabled, plugin: plugin) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only the selected plugin is changed. Hermes may require a later restart before runtime-loaded code changes take effect.")
        }
        .confirmationDialog("Remove this plugin?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            if let plugin {
                Button("Remove \(plugin.name)", role: .destructive) {
                    Task { await model.remove(plugin); if model.errorMessage == nil { dismiss() } }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Hermes will remove only this user or Git plugin. Bundled and project plugins are not presented as removable.")
        }
    }
}
