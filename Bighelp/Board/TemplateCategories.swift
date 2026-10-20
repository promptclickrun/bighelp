import Foundation

/// A topic the template pickers group by, with its friendly name and icon. The catalog names it by
/// ID (services/catalog `AGENT_CATEGORIES`, `BLUEPRINT_CATEGORIES`; the same names as bighelp.app's
/// templates page). One the app doesn't know, or none, is Other, so a template is never hidden.
struct TemplateCategory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String

    static let other = TemplateCategory(id: "other", title: "Other", systemImage: "ellipsis.circle")

    /// Agent templates' topics, in the order the pickers list them.
    static let agentTopics: [TemplateCategory] = [
        .init(id: "productivity", title: "Productivity", systemImage: "checklist"),
        .init(id: "business", title: "Business", systemImage: "briefcase"),
        .init(id: "coding", title: "Coding", systemImage: "chevron.left.forwardslash.chevron.right"),
        .init(id: "science", title: "Science", systemImage: "flask"),
        .init(id: "education", title: "Education", systemImage: "graduationcap"),
        .init(id: "health", title: "Health", systemImage: "heart"),
        .init(id: "creative", title: "Creative", systemImage: "paintpalette"),
        .init(id: "personal", title: "Personal", systemImage: "person"),
        .init(id: "leadership", title: "Leadership", systemImage: "flag"),
        .init(id: "security", title: "Security", systemImage: "lock.shield"),
    ]

    /// Feed, Ideas and Goals blueprints' topics.
    static let blueprintTopics: [TemplateCategory] = [
        .init(id: "productivity", title: "Productivity", systemImage: "checklist"),
        .init(id: "marketing", title: "Marketing", systemImage: "megaphone"),
        .init(id: "content", title: "Content creation", systemImage: "pencil.line"),
        .init(id: "personal", title: "Personal life", systemImage: "person"),
        .init(id: "research", title: "Research", systemImage: "magnifyingglass"),
    ]

    /// An agent template's `category`, leniently.
    static func agent(_ stored: String?) -> TemplateCategory { match(stored, in: agentTopics) }

    /// A blueprint's `category` (or its bundled group's ID), leniently.
    static func blueprint(_ stored: String?) -> TemplateCategory { match(stored, in: blueprintTopics) }

    private static func match(_ stored: String?, in topics: [TemplateCategory]) -> TemplateCategory {
        guard let id = stored?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !id.isEmpty, id.count <= 40 else { return .other }
        return topics.first { $0.id == id } ?? .other
    }
}

/// The chip under a template picker's search.
enum TemplateTopicFilter: Hashable, Sendable {
    case all
    /// My Templates: the person's own, saved on their computer.
    case mine
    case topic(TemplateCategory)
}

/// For you keeps the catalog's order by topic; Newest and Most used rank everything in one list.
enum TemplateOrder: String, CaseIterable, Identifiable, Sendable {
    case forYou, newest, mostUsed
    var id: Self { self }
    var title: String {
        switch self {
        case .forYou: "For you"
        case .newest: "Newest"
        case .mostUsed: "Most used"
        }
    }
}

/// One heading's worth of templates.
struct TemplateSection<Item>: Identifiable {
    /// Its topic, or nil for the one ranked list (Newest, Most used).
    let category: TemplateCategory?
    let title: String
    let items: [Item]
    var id: String { category?.id ?? "ranked" }
}

/// What a template picker shows for a search, a chip and an order.
struct TemplateListing<Item> {
    /// All, My Templates when there are some, then each topic that has templates (Other last).
    let filters: [TemplateTopicFilter]
    /// The chip in effect: one whose topic has no templates any more is All.
    let filter: TemplateTopicFilter
    /// My Templates, shown first.
    let mine: [Item]
    let sections: [TemplateSection<Item>]

    var isEmpty: Bool { mine.isEmpty && sections.allSatisfy(\.items.isEmpty) }
}

enum TemplateTopics {
    /// Items by topic in the topics' order, Other last, each keeping the items' own order. Topics
    /// without items are left out.
    static func sections<Item>(_ items: [Item], topics: [TemplateCategory],
                               category: (Item) -> TemplateCategory) -> [TemplateSection<Item>] {
        let grouped = Dictionary(grouping: items, by: category)
        return (topics + [.other]).compactMap { topic in
            guard let items = grouped[topic], !items.isEmpty else { return nil }
            return TemplateSection(category: topic, title: topic.title, items: items)
        }
    }

    /// `catalog` is what the picker offers (bighelp-only already applied); `matches` is the search.
    /// The chips come from the whole catalog, so they stay put while the person types.
    static func listing<Item>(catalog: [Item], mine: [Item] = [], hasMine: Bool = false,
                              topics: [TemplateCategory], filter: TemplateTopicFilter,
                              category: (Item) -> TemplateCategory, matches: (Item) -> Bool,
                              ranked: (title: String, sort: ([Item]) -> [Item])?) -> TemplateListing<Item> {
        var filters: [TemplateTopicFilter] = [.all]
        if hasMine { filters.append(.mine) }
        filters += sections(catalog, topics: topics, category: category).compactMap(\.category).map { .topic($0) }
        let filter = filters.contains(filter) ? filter : .all

        let shownMine = filter == .all || filter == .mine ? mine.filter(matches) : []
        var items = filter == .mine ? [] : catalog.filter(matches)
        if case .topic(let topic) = filter { items = items.filter { category($0) == topic } }
        let shown: [TemplateSection<Item>]
        if let ranked {
            let sorted = ranked.sort(items)
            shown = sorted.isEmpty ? [] : [TemplateSection(category: nil, title: ranked.title, items: sorted)]
        } else {
            shown = sections(items, topics: topics, category: category)
        }
        return TemplateListing(filters: filters, filter: filter, mine: shownMine, sections: shown)
    }

    /// The search's words, each of which must appear somewhere in a template's text.
    static func words(_ search: String) -> [String] {
        search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// What a picker says when nothing matches.
struct TemplateEmptyState: Equatable {
    let title: String
    let detail: String
    /// A chip narrowed it: offer to look everywhere.
    let offersAll: Bool

    init(search: String, filter: TemplateTopicFilter, noun: String) {
        title = "No matching \(noun)"
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = "\u{201C}\(query)\u{201D}"
        switch filter {
        case .all:
            detail = query.isEmpty ? "There are no \(noun) here yet." : "Nothing matches \(quoted)."
            offersAll = false
        case .mine:
            detail = query.isEmpty ? "You haven't saved any \(noun) yet." : "None of yours match \(quoted)."
            offersAll = !query.isEmpty
        case .topic(let topic):
            detail = query.isEmpty ? "There are no \(noun) in \(topic.title) yet."
                                   : "Nothing in \(topic.title) matches \(quoted)."
            offersAll = true
        }
    }
}
