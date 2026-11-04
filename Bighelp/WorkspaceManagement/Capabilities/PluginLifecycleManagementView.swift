import SwiftUI

/// Plugins as a storefront (Settings › Hermes tools › Plugins): search, this week's featured plugin, the
/// official and verified ones, the most starred and newest, then a shelf per topic. A card opens the plugin's page,
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
                if let snapshot = model.snapshot, let storefront = model.storefront {
                    if ManagementSearch.isActive(search) {
                        results(PluginStorefront.matching(search, in: snapshot.catalog))
                    } else {
                        self.storefront(snapshot, storefront)
                    }
                }
            }
            .padding(.bottom, BighelpTokens.space32)
        }
        .catalogPage()
        .bighelpRefreshable { await model.load() }
        .task { await model.loadIfNeeded() }
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
    private func storefront(_ snapshot: PluginSnapshot, _ storefront: PluginStorefront) -> some View {
        if snapshot.catalog.isEmpty {
            Text("This computer's plugin catalog is empty.")
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, CatalogMetrics.margin)
        }
        if let hero = storefront.hero {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                // Nous' pick of the week, as the marketplace shows it; without the plugin's facts, the
                // first official plugin Hermes lists.
                Text(storefront.heroIsFeatured ? "Featured" : "Official pick")
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
        if !storefront.popular.isEmpty {
            shelf(String(localized: "Popular"), id: "popular", entries: storefront.popular, count: nil)
        }
        if !storefront.recent.isEmpty {
            shelf(String(localized: "New this month"), id: "recent", entries: storefront.recent, count: nil)
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
            CatalogShelf(items: Array(entries.prefix(12)), columns: .cards) { entry in
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
                    CatalogArtwork(url: entry.listedImageURL, category: entry.catalogCategory, symbolSize: 56, cornerRadius: 0)
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
                                prominent: !entry.isInstalled, filled: !entry.isInstalled)
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

/// Every installed plugin on the computer by state, each with its switch, with Rescan. A plugin's
/// name opens its page.
@MainActor
private struct InstalledPluginsView: View {
    @Bindable var model: PluginLifecycleManagementModel
    let hostName: String
    @State private var search = ""
    @State private var filter: HermesToolFilter = .all
    @State private var opened: String?

    var body: some View {
        List {
            HermesToolSearchSection(search: $search, prompt: String(localized: "Search installed plugins"),
                                    searchIdentifier: "plugins.installed.search",
                                    filters: [.all, .on, .off, .updates],
                                    filter: $filter, filtersIdentifier: "plugins.installed.filters")
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy && model.change == nil,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let snapshot = model.snapshot {
                content(snapshot)
            }
            CapabilitiesScopeSection(hostName: hostName, profileName: nil)
        }
        .bighelpFormSurface()
        .navigationTitle("Installed")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await model.load() }
        .navigationDestination(item: $opened) { name in
            InstalledPluginDetailView(model: model, pluginName: name)
        }
        .accessibilityIdentifier("plugins.installed")
    }

    @ViewBuilder
    private func content(_ snapshot: PluginSnapshot) -> some View {
        let listings = InstalledPluginListing.byName(snapshot.catalog)
        let plugins = snapshot.installed.filter { plugin in
            let listing = listings[plugin.name]
            return ManagementSearch.matches(search, plugin.name, listing?.title, plugin.summary, plugin.source)
                && filter.admits(isOn: plugin.isEnabled, hasUpdate: listing?.updateAvailable == true)
        }
        if ManagementSearch.isActive(search), plugins.isEmpty {
            ManagementSearchEmptySection(search: search)
        } else if snapshot.installed.isEmpty {
            Section { Text("No installed plugins were reported.").foregroundStyle(.secondary) }
        } else if plugins.isEmpty {
            Section { Text("No plugins match this filter.").foregroundStyle(.secondary) }
        }
        section(String(localized: "On"), plugins.filter(\.isEnabled), listings: listings)
        section(String(localized: "Off"), plugins.filter { !$0.isEnabled }, listings: listings)
        Section {
            Button("Rescan installed plugins", systemImage: "arrow.clockwise") {
                Task { await model.rescan() }
            }
            .disabled(model.isBusy)
            .frame(minHeight: BighelpTokens.hitTarget)
        } footer: {
            Text("Rescan refreshes discovery only; it does not install, enable, or restart plugins.")
        }
        if !snapshot.removedCatalogEntries.isEmpty, filter == .all, !ManagementSearch.isActive(search) {
            Section("Advanced · Removed from catalog") {
                ForEach(snapshot.removedCatalogEntries, id: \.self) { Text($0).font(.bighelp(.footnote)) }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ plugins: [InstalledPlugin],
                         listings: [String: PluginCatalogEntry]) -> some View {
        if !plugins.isEmpty {
            Section(HermesTools.heading(title, plugins.count)) {
                ForEach(plugins) { row($0, listing: listings[$0.name]) }
            }
        }
    }

    private func row(_ plugin: InstalledPlugin, listing: PluginCatalogEntry?) -> some View {
        let change = model.change?.pluginName == plugin.name ? model.change?.kind : nil
        let hasUpdate = listing?.updateAvailable == true
        return HermesToolRow(
            art: InstalledPluginListing.art(listing),
            name: listing?.displayName ?? plugin.name,
            detail: change?.word ?? (hasUpdate ? String(localized: "Update available")
                                     : plugin.summary.isEmpty ? plugin.source : plugin.summary),
            detailColor: change == nil && hasUpdate ? theme.warning : nil,
            open: { opened = plugin.name }
        ) {
            HermesToolSwitch(title: listing?.displayName ?? plugin.name, isOn: plugin.isEnabled,
                             pending: change?.target, isLocked: model.isBusy,
                             identifier: "plugins.installed.switch.\(plugin.name)") { isOn in
                Task { await model.setEnabled(isOn, plugin: plugin) }
            }
        }
        .accessibilityIdentifier("plugins.installed.plugin.\(plugin.name)")
    }

    @BighelpThemeReader private var theme
}

/// What the catalog says about installed plugins: their title, banner, topic and updates.
private enum InstalledPluginListing {
    /// The catalog's entries for plugins it lists as installed, by name.
    static func byName(_ catalog: [PluginCatalogEntry]) -> [String: PluginCatalogEntry] {
        Dictionary(catalog.lazy.filter(\.isInstalled).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The listed banner over its topic's tile, or the General tile for a plugin the catalog doesn't list.
    static func art(_ listing: PluginCatalogEntry?) -> HermesToolArt {
        guard let listing else { return .topic(.general) }
        return .artwork(listing.listedImageURL, listing.catalogCategory)
    }
}

private extension PluginChange.Kind {
    /// What a row or page says while the change runs.
    var word: String {
        switch self {
        case .turningOn: String(localized: "Enabling…")
        case .turningOff: String(localized: "Disabling…")
        case .updating: String(localized: "Updating…")
        case .removing: String(localized: "Removing…")
        }
    }

    /// The value the switch shows while it runs; updates and removals leave it as it was.
    var target: Bool? {
        switch self {
        case .turningOn: true
        case .turningOff: false
        case .updating, .removing: nil
        }
    }
}

/// One installed plugin: its switch, its setup, update from Git (and what Hermes asks before one),
/// Advanced details and Remove.
@MainActor
struct InstalledPluginDetailView: View {
    @Bindable var model: PluginLifecycleManagementModel
    let pluginName: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemoval = false

    private var plugin: InstalledPlugin? { model.snapshot?.installed.first { $0.name == pluginName } }
    private var listing: PluginCatalogEntry? {
        model.snapshot?.catalog.first { $0.name == pluginName && $0.isInstalled }
    }

    var body: some View {
        List {
            if let plugin {
                let change = model.change?.pluginName == plugin.name ? model.change?.kind : nil
                Section {
                    HermesToolHeader(art: InstalledPluginListing.art(listing),
                                     name: listing?.displayName ?? plugin.name,
                                     summary: change?.word ?? plugin.summary)
                }
                CapabilitiesStatusSections(
                    support: model.support, isBusy: model.isBusy && model.change == nil,
                    errorMessage: model.errorMessage, successMessage: model.successMessage,
                    retry: { Task { await model.load() } }
                )
                Section {
                    HermesToolSwitch(title: String(localized: "Turned on"), isOn: plugin.isEnabled,
                                     pending: change?.target, isLocked: model.isBusy, showsTitle: true,
                                     identifier: "plugins.installed.enabled") { isOn in
                        Task { await model.setEnabled(isOn, plugin: plugin) }
                    }
                    if let removed = plugin.removedReason {
                        Label(removed, systemImage: "exclamationmark.shield").foregroundStyle(.red)
                    }
                } footer: {
                    Text("Only this plugin changes. Hermes may need a restart before its code changes take effect.")
                }
                setupSections(plugin, change: change)
                Section("Advanced") {
                    LabeledContent("Name", value: plugin.name)
                    LabeledContent("Version", value: plugin.version.isEmpty ? "Not reported" : plugin.version)
                    LabeledContent("Source", value: plugin.source)
                    LabeledContent("Runtime", value: plugin.runtimeStatus.capitalized)
                }
                if plugin.canRemove {
                    Section {
                        Button(change == .removing ? "Removing…" : "Remove plugin", role: .destructive) {
                            confirmsRemoval = true
                        }
                        .disabled(model.isBusy)
                    }
                }
            } else {
                ContentUnavailableView("Plugin unavailable", systemImage: "puzzlepiece.extension")
            }
        }
        .bighelpFormSurface()
        .navigationTitle(pluginName)
        .navigationBarTitleDisplayMode(.inline)
        // A question left open asks about an update the person walked away from.
        .onDisappear { if model.updateQuestion?.pluginName == pluginName { model.dismissUpdateQuestion() } }
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

    @ViewBuilder
    private func setupSections(_ plugin: InstalledPlugin, change: PluginChange.Kind?) -> some View {
        if plugin.requiresAuthentication {
            Section("Setup") {
                Text("This plugin requires host-side authentication.")
                if !plugin.authenticationCommand.isEmpty {
                    Text(plugin.authenticationCommand).font(.bighelp(.footnote).monospaced()).textSelection(.enabled)
                }
            }
        }
        if plugin.canUpdate {
            Section {
                if listing?.updateAvailable == true {
                    LabeledContent("Update") {
                        HermesToolStatus(text: String(localized: "Available"), tone: .warning)
                    }
                }
                Button(change == .updating ? "Updating…" : "Update from its configured Git source") {
                    Task { await model.update(plugin) }
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("plugins.installed.update")
            }
            if let question = model.updateQuestion, question.pluginName == plugin.name {
                updateQuestionSection(question)
            }
        }
    }

    /// Hermes stopped before the update to ask: what it adds, or what its security check found.
    private func updateQuestionSection(_ question: PluginUpdateQuestion) -> some View {
        Section {
            Text(Self.questionText(question.kind))
                .font(.bighelp(.body, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(question.additions, id: \.self) { line in
                Text(line)
                    .font(.bighelp(.footnote).monospaced())
                    .textSelection(.enabled)
            }
            ForEach(question.findings.prefix(20)) { finding in
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text("\(finding.severity.capitalized) · \(finding.category)")
                        .font(.bighelp(.footnote, weight: .semibold))
                    Text([finding.detail, finding.file.isEmpty ? nil
                          : finding.line.map { "\(finding.file):\($0)" } ?? finding.file]
                        .compactMap { $0 }.joined(separator: "\n"))
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                }
            }
            if let approval = question.approval {
                Button(approval == .capabilities ? "Update and allow them" : "Update anyway") {
                    Task { await model.answerUpdateQuestion() }
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("plugins.installed.update.approve")
            }
            Button(question.approval == nil ? "OK" : "Not now", role: .cancel) { model.dismissUpdateQuestion() }
                .disabled(model.isBusy)
        } header: {
            Text("Hermes asks first")
        } footer: {
            if let words = question.message.sentence { Text(words) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugins.installed.update.question")
    }

    static func questionText(_ kind: PluginUpdateQuestion.Kind) -> String {
        switch kind {
        case .addsCapabilities: String(localized: "This update adds new parts to the plugin. Nothing changes until you allow them.")
        case .scanCaution: String(localized: "Hermes' security check found things to look at in this update. Nothing changes until you choose.")
        case .scanBlocked: String(localized: "Hermes' security check blocked this update, so Hermes won't install it.")
        }
    }

    @BighelpThemeReader private var theme
}
