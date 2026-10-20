import SwiftUI

/// Every agent template from the catalog, by topic: search, topic chips, My Templates first, and
/// Sort (For you, Newest, Most used; bighelp only when there are community ones). Picking one fills
/// in the editor like the Templates rail.
struct AgentTemplateBrowser: View {
    var title = "Agent templates"
    var myTemplates: MyTemplatesStore = .shared
    let onPick: (AgentSoulTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var filter = TemplateTopicFilter.all
    @State private var order = TemplateOrder.forYou
    @State private var officialOnly = false

    var body: some View {
        let catalog = AgentSoulTemplate.all
        let offersOfficialOnly = catalog.contains(where: \.isCommunity)
        let hasMine = !myTemplates.templates.isEmpty || myTemplates.skipped > 0
        let listing = AgentTemplateBrowsing.listing(
            catalog: catalog, mine: myTemplates.templates, hasMine: hasMine, search: search,
            officialOnly: officialOnly && offersOfficialOnly, filter: filter, order: order, usage: TemplateUsage.shared)
        let showsSkipped = myTemplates.skipped > 0 && search.isEmpty && (listing.filter == .all || listing.filter == .mine)
        NavigationStack {
            List {
                Section {
                    BighelpSearchField(text: $search, prompt: "Search templates", accessibilityLabel: "Search templates",
                                       accessibilityIdentifier: "agent.templates.search")
                        .bighelpListSearchRow()
                    TemplateTopicChips(filters: listing.filters, selection: $filter, identifier: "agent.templates")
                        .templateChipsRow()
                }
                if !listing.mine.isEmpty || showsSkipped {
                    myTemplatesSection(listing.mine, showsSkipped: showsSkipped)
                }
                ForEach(listing.sections) { section in
                    Section {
                        ForEach(section.items) { template in
                            row(template, showsTopic: section.category == nil, showsSource: offersOfficialOnly)
                        }
                    } header: {
                        TemplateSectionHeader(title: section.title, systemImage: section.category?.systemImage,
                                              count: section.items.count,
                                              identifier: "agent.templates.section.\(section.id)")
                    }
                }
                if listing.isEmpty, !showsSkipped {
                    TemplateEmptyView(state: TemplateEmptyState(search: search, filter: listing.filter, noun: "templates"),
                                      identifier: "agent.templates.empty") { filter = .all }
                        .listRowBackground(Color.clear)
                }
                Section {
                    Link(destination: TemplateCatalogPolicy.submitURL) {
                        Label("Share yours", systemImage: "square.and.arrow.up")
                            .font(.bighelp(.body))
                    }
                    .listRowBackground(theme.surface)
                    .accessibilityIdentifier("agent.templates.share")
                } footer: {
                    Text("Send a template on bighelp.app. Approved ones show up here for everyone.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
            .dismissesKeyboardOnScroll(true)
            .animation(.snappy, value: filter)
            .animation(.snappy, value: order)
            .animation(.snappy, value: officialOnly)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .bighelpToolbarText()
                        .accessibilityIdentifier("agent.templates.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    TemplateSortMenu(order: $order, officialOnly: $officialOnly, offersOfficialOnly: offersOfficialOnly,
                                     identifier: "agent.templates.sort")
                }
            }
        }
        .accessibilityIdentifier("agent.templates.browser")
        .task { await myTemplates.refresh() }
    }

    /// My Templates: bots the person saved as templates on their computer. Hold one to delete it.
    private func myTemplatesSection(_ mine: [AgentSoulTemplate], showsSkipped: Bool) -> some View {
        Section {
            ForEach(mine) { template in
                row(template, showsTopic: false, showsSource: false)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await myTemplates.delete(template) }
                        }
                    }
            }
        } header: {
            TemplateSectionHeader(title: "My Templates", systemImage: "person.fill", count: mine.count,
                                  identifier: "agent.templates.mine")
        } footer: {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text("Saved on your computer. Hold one to delete it.")
                    .foregroundStyle(theme.secondaryText)
                if showsSkipped {
                    Text(myTemplates.skipped == 1 ? "One saved template couldn't be opened, so it's hidden."
                                                  : "\(myTemplates.skipped) saved templates couldn't be opened, so they're hidden.")
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityIdentifier("agent.templates.mine.skipped")
                }
            }
            .font(.bighelp(.footnote))
        }
    }

    private func row(_ template: AgentSoulTemplate, showsTopic: Bool, showsSource: Bool) -> some View {
        Button {
            onPick(template)
            dismiss()
        } label: {
            AgentTemplateRow(template: template, uses: TemplateUsage.shared.count(AgentTemplateBrowsing.usageID(template)),
                             showsTopic: showsTopic, showsSource: showsSource)
        }
        .bighelpPlainButtonStyle()
        .listRowBackground(theme.surface)
        .accessibilityLabel("\(template.title), \(template.cardRole)")
        .accessibilityIdentifier("agent.templates.\(template.id)")
    }

    @BighelpThemeReader private var theme
}

/// One agent template in a picker: its icon, name, role and what it's good at.
struct AgentTemplateRow: View {
    let template: AgentSoulTemplate
    let uses: Int
    /// In a ranked list (Newest, Most used), which topic it's from.
    let showsTopic: Bool
    /// The catalog holds community templates too, so each says whose it is.
    let showsSource: Bool
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: template.systemImage)
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(theme.action)
                .frame(width: BighelpTokens.scaled(40), height: BighelpTokens.scaled(40))
                .background(theme.action.opacity(0.12), in: .rect(cornerRadius: BighelpTokens.radius12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: template.title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                if !template.profile.isEmpty {
                    Text(verbatim: template.cardRole)
                        .font(.bighelp(.subheadline).weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
                if !template.strength.isEmpty {
                    Text(verbatim: template.cardStrength)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
                if !details.isEmpty {
                    Text(verbatim: details.joined(separator: " · "))
                        .font(.bighelp(.caption).weight(.medium))
                        .foregroundStyle(theme.tertiaryText)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, BighelpTokens.space4)
        .contentShape(.rect)
    }

    /// Whose it is, its topic and how often it was used: only what tells this one apart.
    private var details: [String] {
        var parts: [String] = []
        if showsSource {
            if !template.isCommunity { parts.append("bighelp") }
            else if let credit = template.credit { parts.append("by @\(credit)") }
            else { parts.append("Community") }
        }
        if showsTopic { parts.append(template.category.title) }
        if uses > 0 { parts.append(uses == 1 ? "Used once" : "Used \(uses) times") }
        return parts
    }
}

enum AgentTemplateBrowsing {
    static func usageID(_ template: AgentSoulTemplate) -> String { "agent:" + template.id }

    /// Every word of the search somewhere in its name, role, vibe, strength, credit or topic.
    private static func matches(_ template: AgentSoulTemplate, words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let text = [template.title, template.profile, template.voice, template.strength, template.credit ?? "",
                    template.isMine ? "" : template.category.title]
            .joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    /// What the picker shows: My Templates first, then the catalog by topic, or ranked for
    /// Newest and Most used.
    @MainActor
    static func listing(catalog: [AgentSoulTemplate], mine: [AgentSoulTemplate], hasMine: Bool, search: String,
                        officialOnly: Bool, filter: TemplateTopicFilter, order: TemplateOrder,
                        usage: TemplateUsage) -> TemplateListing<AgentSoulTemplate> {
        let words = TemplateTopics.words(search)
        let offered = officialOnly ? catalog.filter { !$0.isCommunity } : catalog
        let ranked: (title: String, sort: ([AgentSoulTemplate]) -> [AgentSoulTemplate])? = order == .forYou ? nil
            : (order.title, { sorted($0, by: order, usage: usage) })
        return TemplateTopics.listing(catalog: offered, mine: mine, hasMine: hasMine,
                                      topics: TemplateCategory.agentTopics, filter: filter, category: \.category,
                                      matches: { matches($0, words: words) }, ranked: ranked)
    }

    @MainActor
    static func sorted(_ items: [AgentSoulTemplate], by order: TemplateOrder,
                       usage: TemplateUsage) -> [AgentSoulTemplate] {
        let indexed = Array(items.enumerated())
        switch order {
        case .forYou:
            return items
        case .newest:
            return indexed.sorted { lhs, rhs in
                let left = lhs.element.updatedAt ?? .distantPast, right = rhs.element.updatedAt ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left > right
            }.map(\.element)
        case .mostUsed:
            return indexed.sorted { lhs, rhs in
                let left = usage.count(usageID(lhs.element)), right = usage.count(usageID(rhs.element))
                return left == right ? lhs.offset < rhs.offset : left > right
            }.map(\.element)
        }
    }
}
