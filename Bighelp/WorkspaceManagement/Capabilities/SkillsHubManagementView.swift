import SwiftUI

/// The Skills Hub as a storefront: search across the hubs, the agent's own skills, Hermes'
/// official collection as a hero and a shelf, and the hubs to search. A tile opens the skill's
/// page, where Hermes' scan runs before its one Add button.
@MainActor
struct SkillsHubManagementView: View {
    @Bindable var model: SkillsHubManagementModel
    let hostName: String
    let profileName: String

    private static let top = "skills.top"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSearching: Bool { ManagementSearch.isActive(model.query) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CatalogMetrics.sectionSpacing) {
                    searchArea.id(Self.top)
                    CatalogStatusBanner(support: model.support, isBusy: model.isBusy,
                                        errorMessage: model.errorMessage, successMessage: model.successMessage,
                                        retry: { Task { await model.load() } })
                    if let snapshot = model.snapshot {
                        if isSearching {
                            results(snapshot)
                        } else {
                            storefront(snapshot) {
                                model.source = $0
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                                    proxy.scrollTo(Self.top, anchor: .top)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, BighelpTokens.space32)
            }
        }
        .catalogPage()
        .bighelpRefreshable { await model.load() }
        .task { if model.snapshot == nil { await model.load() } }
        .onChange(of: model.query) { _, query in
            if !ManagementSearch.isActive(query) { model.clearSearch() }
        }
        .onChange(of: model.source) {
            if model.searchResult != nil, isSearching { Task { await model.search() } }
        }
        .accessibilityIdentifier("skills.storefront")
    }

    // MARK: Search

    private var searchArea: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            BighelpSearchField(
                text: $model.query,
                prompt: model.source == "all" ? String(localized: "Search skills on every hub")
                                              : String(localized: "Search \(model.sourceLabel(model.source))"),
                accessibilityLabel: String(localized: "Search skills"),
                accessibilityIdentifier: "skills.search"
            ) { Task { await model.search() } }
            if isSearching || model.source != "all", let snapshot = model.snapshot {
                // Every hub's name stays whole: the chips wrap onto more lines rather than scroll.
                BighelpFlowLayout(spacing: BighelpTokens.space8) {
                    CatalogChip(title: String(localized: "All hubs"), isSelected: model.source == "all") {
                        model.source = "all"
                    }
                    ForEach(snapshot.sources.filter(\.isSearchable)) { source in
                        CatalogChip(title: source.label, isSelected: model.source == source.id) {
                            model.source = source.id
                        }
                        .accessibilityIdentifier("skills.source.\(source.id)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("skills.sources")
            }
        }
        .padding(.horizontal, CatalogMetrics.margin)
        .padding(.top, BighelpTokens.space8)
    }

    @ViewBuilder
    private func results(_ snapshot: SkillHubSnapshot) -> some View {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let mine = snapshot.installedSkills.filter { ManagementSearch.matches(query, $0.name, $0.summary, $0.category) }
        let official = snapshot.official.filter {
            ManagementSearch.matches(query, $0.name, $0.summary, $0.category)
        }
        let hubName = model.source == "all" ? String(localized: "every hub") : model.sourceLabel(model.source)

        Button {
            Task { await model.search() }
        } label: {
            Label("Search \(hubName) for “\(query)”", systemImage: "magnifyingglass")
                .font(.bighelp(.body, weight: .semibold))
                .foregroundStyle(theme.action)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .disabled(model.isBusy)
        .padding(.horizontal, CatalogMetrics.margin)
        .accessibilityIdentifier("skills.hub.search")

        if let result = model.searchResult {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                CatalogSectionHeader(title: String(localized: "From the hubs"), count: result.items.count)
                if result.items.isEmpty {
                    plain("No skills on \(hubName) match.")
                } else {
                    CatalogGrid(items: result.items, minimumWidth: 104) { tile($0) }
                }
                if !result.timedOutSources.isEmpty {
                    plain("These hubs didn't answer in time: \(result.timedOutSources.joined(separator: ", ")).")
                }
            }
        }
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                CatalogSectionHeader(title: String(localized: "\(profileName)'s skills"), count: mine.count)
                ForEach(mine.prefix(20)) { skill in
                    NavigationLink { SkillsInstalledView(model: model, profileName: profileName) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.bighelp(.body, weight: .semibold))
                            if !skill.summary.isEmpty {
                                Text(skill.summary).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .bighelpPlainButtonStyle()
                    .padding(.horizontal, CatalogMetrics.margin)
                }
            }
        }
        if !official.isEmpty {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                CatalogSectionHeader(title: String(localized: "Official"), count: official.count)
                CatalogGrid(items: official, minimumWidth: 104) { tile($0) }
            }
        }
        if model.searchResult == nil, mine.isEmpty, official.isEmpty {
            plain("Nothing on this computer or in the official list matches. Search the hubs to look further.")
                .accessibilityIdentifier("management.search.empty")
        }
    }

    // MARK: Storefront

    @ViewBuilder
    private func storefront(_ snapshot: SkillHubSnapshot, browse: @escaping (String) -> Void) -> some View {
        let storefront = SkillStorefront(snapshot: snapshot)
        NavigationLink { SkillsInstalledView(model: model, profileName: profileName) } label: {
            MySkillsRow(name: profileName, enabled: storefront.enabledCount, disabled: storefront.disabledCount)
        }
        .bighelpPlainButtonStyle(.rounded(18))
        .padding(.horizontal, CatalogMetrics.margin)
        .accessibilityIdentifier("skills.mine")

        if storefront.officialCount > 0 {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Text("From Hermes")
                    .font(.bighelp(.footnote, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                NavigationLink { officialPage(storefront) } label: { OfficialSkillsHero(storefront: storefront) }
                    .bighelpPlainButtonStyle(.rounded(CatalogMetrics.heroRadius))
                    .accessibilityIdentifier("skills.hero")
            }
            .padding(.horizontal, CatalogMetrics.margin)

            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                CatalogSectionHeader(title: String(localized: "Official"), count: nil,
                                     seeAllIdentifier: "skills.seeAll.official") { officialPage(storefront) }
                CatalogShelf(items: storefront.officialShelf, width: CatalogMetrics.tileWidth) { tile($0) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("skills.shelf.official")
        } else if !snapshot.indexAvailable {
            plain("This computer's Skills Hub index isn't ready yet. Search still asks each hub.")
        }

        if !storefront.hubs.isEmpty {
            BighelpDeferredSection {
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    CatalogSectionHeader(title: String(localized: "Browse a hub"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(storefront.hubs) { hub in
                            Button { browse(hub.id) } label: { HubTile(source: hub) }
                                .bighelpPlainButtonStyle(.rounded(16))
                                .accessibilityIdentifier("skills.hub.\(hub.id)")
                                .accessibilityHint(Text("Searches only this hub"))
                        }
                    }
                    .padding(.horizontal, CatalogMetrics.margin)
                }
            }
        }
    }

    private func officialPage(_ storefront: SkillStorefront) -> some View {
        SkillsOfficialView(model: model, profileName: profileName, topics: storefront.officialTopics)
    }

    private func tile(_ item: SkillHubItem) -> some View {
        NavigationLink {
            SkillHubPageView(model: model, profileName: profileName, item: item)
        } label: {
            SkillCatalogTile(item: item, sourceLabel: model.sourceLabel(item.source))
        }
        .bighelpPlainButtonStyle(.rounded(CatalogMetrics.heroRadius))
        .accessibilityIdentifier("skills.tile.\(item.id)")
    }

    private func plain(_ text: String) -> some View {
        Text(text)
            .font(.bighelp(.subheadline))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, CatalogMetrics.margin)
    }

    @BighelpThemeReader private var theme
}

/// "<Agent>'s skills": how many are on and off; opens the list of them.
private struct MySkillsRow: View {
    let name: String
    let enabled: Int
    let disabled: Int

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: 40, height: 40)
                .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name)'s skills").font(.bighelp(.body, weight: .bold))
                Text(disabled == 0 ? "\(enabled.formatted()) on" : "\(enabled.formatted()) on · \(disabled.formatted()) off")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, BighelpTokens.space12)
        .frame(minHeight: BighelpTokens.hitTarget)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}

/// Hermes' official collection: how many there are and a few of their names; opens them all.
private struct OfficialSkillsHero: View {
    let storefront: SkillStorefront

    private let color = BighelpBlockColor.lilac

    var body: some View {
        let fill = color.fill(dark: theme.isDarkPalette)
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .top) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(fill)
                    .frame(width: 52, height: 52)
                    .background(color.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                Spacer()
                Text("OFFICIAL")
                    .font(.bighelp(.caption, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(fill)
                    .padding(.horizontal, BighelpTokens.space8)
                    .padding(.vertical, BighelpTokens.space4)
                    .background(color.ink, in: RoundedRectangle(cornerRadius: BighelpTokens.radius8, style: .continuous))
            }
            Text("Official skills")
                .font(.bighelp(.title2, weight: .heavy))
            HStack(alignment: .center, spacing: BighelpTokens.space12) {
                Text(summary)
                    .font(.bighelp(.subheadline))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Browse")
                    .font(.bighelp(.subheadline, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(color.ink, in: Capsule())
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(color.ink)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: CatalogMetrics.heroRadius, style: .continuous))
        .contentShape(.rect)
    }

    private var summary: String {
        let count = storefront.officialCount.formatted()
        let names = storefront.heroNames
        guard !names.isEmpty else { return String(localized: "\(count) skills Hermes keeps itself.") }
        let listed = names.formatted(.list(type: .and))
        return storefront.officialCount > names.count
            ? String(localized: "\(count) skills Hermes keeps itself, like \(listed).")
            : String(localized: "Hermes keeps these itself: \(listed).")
    }

    @BighelpThemeReader private var theme
}

/// A hub to search, by its name.
private struct HubTile: View {
    let source: SkillHubSource

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            Text(source.label)
                .font(.bighelp(.body, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if source.isRateLimited {
                Image(systemName: "tortoise")
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityLabel("Busy right now")
            }
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, BighelpTokens.space12)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}

/// Every official skill, by topic.
@MainActor
private struct SkillsOfficialView: View {
    @Bindable var model: SkillsHubManagementModel
    let profileName: String
    let topics: [SkillStorefront.Topic]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CatalogMetrics.sectionSpacing) {
                ForEach(topics) { topic in
                    VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                        CatalogSectionHeader(title: topic.category.title, count: topic.items.count)
                        CatalogGrid(items: topic.items, minimumWidth: 104) { item in
                            NavigationLink {
                                SkillHubPageView(model: model, profileName: profileName, item: item)
                            } label: {
                                SkillCatalogTile(item: model.latest(item), sourceLabel: model.sourceLabel(item.source))
                            }
                            .bighelpPlainButtonStyle(.rounded(CatalogMetrics.heroRadius))
                            .accessibilityIdentifier("skills.tile.\(item.id)")
                        }
                    }
                }
            }
            .padding(.vertical, BighelpTokens.space16)
        }
        .catalogPage()
        .navigationTitle("Official skills")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("skills.official")
    }
}

/// The agent's own skills: turn each on or off, and check Hub skills for updates.
@MainActor
private struct SkillsInstalledView: View {
    @Bindable var model: SkillsHubManagementModel
    let profileName: String
    @State private var toggleCandidate: InstalledSkill?

    var body: some View {
        List {
            CapabilitiesStatusSections(
                support: model.support, isBusy: model.isBusy,
                errorMessage: model.errorMessage, successMessage: model.successMessage,
                retry: { Task { await model.load() } }
            )
            if let snapshot = model.snapshot {
                Section {
                    if snapshot.installedSkills.isEmpty {
                        Text("No active skills were reported.").foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.installedSkills) { skill in
                        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                            HStack {
                                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                    Text(skill.name).font(.bighelp(.headline))
                                    Text([skill.category, skill.provenance].filter { !$0.isEmpty }.joined(separator: " • "))
                                        .font(.bighelp(.caption)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(skill.isEnabled ? "On" : "Off").font(.bighelp(.caption))
                            }
                            if !skill.summary.isEmpty { Text(skill.summary).font(.bighelp(.subheadline)) }
                            Button(skill.isEnabled ? "Turn off" : "Turn on") { toggleCandidate = skill }
                                .buttonStyle(.bordered)
                                .frame(minHeight: BighelpTokens.hitTarget)
                        }
                    }
                } footer: {
                    Text("A skill you turn off stays here, so you can turn it back on.")
                }
                Section {
                    Button("Check Hub skills for updates", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.updateInstalled() }
                    }
                    .disabled(model.isBusy || snapshot.installedIdentifiers.isEmpty)
                    .frame(minHeight: BighelpTokens.hitTarget)
                } footer: {
                    Text("Updates stay pending until a later refresh reports the result.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("\(profileName)'s skills")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpRefreshable { await model.load() }
        .accessibilityIdentifier("skills.installed")
        .confirmationDialog(
            "Change this skill?",
            isPresented: Binding(get: { toggleCandidate != nil }, set: { if !$0 { toggleCandidate = nil } }),
            titleVisibility: .visible
        ) {
            if let skill = toggleCandidate {
                Button(skill.isEnabled ? "Turn off \(skill.name)" : "Turn on \(skill.name)") {
                    toggleCandidate = nil
                    Task { await model.setEnabled(!skill.isEnabled, skill: skill) }
                }
            }
            Button("Cancel", role: .cancel) { toggleCandidate = nil }
        } message: {
            Text("Only this skill changes, for this agent. New chats use the change.")
        }
    }
}
