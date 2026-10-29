import Foundation

// The Skills Hub and Plugins storefronts, worked out from what the host lists. Everything here
// comes from the host's own fields (tier, category, source): nothing is curated, starred or dated
// by the app, because the host routes say nothing of the kind.

/// A catalog topic as the host names it (`memory`, `data-science`), with its name, symbol and
/// tile color. The same topic always gets the same color.
struct CatalogCategory: Hashable, Identifiable, Sendable {
    /// The host's value, lowercased.
    let id: String

    static let general = CatalogCategory(id: "general")
    /// Plugins that ship JavaScript for the Hermes Desktop app.
    static let desktop = CatalogCategory(id: "desktop")

    init(id: String) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The topic for a host value; a missing one is General.
    init(_ value: String?) {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(id: value.isEmpty ? "general" : value)
    }

    var title: String {
        if let known = Self.titles[id] { return known }
        let words = id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var symbol: String { Self.symbols[id] ?? "sparkles" }

    var color: BighelpBlockColor { BighelpBlockColor.pastel(for: id) }

    private static let titles: [String: String] = [
        "desktop": String(localized: "For Hermes Desktop"),
        "platform": String(localized: "Platforms"),
        "mlops": String(localized: "ML ops"),
        "devops": String(localized: "DevOps"),
        "mcp": String(localized: "MCP"),
    ]

    private static let symbols: [String: String] = [
        "tools": "wrench.and.screwdriver", "desktop": "desktopcomputer", "models": "cpu",
        "memory": "brain.head.profile", "general": "puzzlepiece.extension", "automation": "gearshape.2",
        "web": "globe", "platform": "square.stack.3d.up", "voice": "waveform",
        "security": "lock", "finance": "chart.bar", "productivity": "checklist", "research": "magnifyingglass",
        "creative": "paintbrush", "media": "photo", "devops": "server.rack", "mlops": "cpu",
        "data-science": "chart.xyaxis.line", "email": "envelope", "communication": "bubble.left.and.bubble.right",
        "github": "chevron.left.forwardslash.chevron.right",
        "software-development": "chevron.left.forwardslash.chevron.right", "documents": "doc.text",
        "note-taking": "note.text", "health": "heart", "gaming": "gamecontroller", "smart-home": "house",
        "social-media": "person.2", "autonomous-ai-agents": "person.2.wave.2", "mcp": "point.3.connected.trianglepath.dotted",
        "blockchain": "link", "migration": "arrow.right.arrow.left", "web-development": "globe",
    ]
}

extension PluginCatalogEntry {
    var catalogCategory: CatalogCategory { CatalogCategory(category) }

    /// Hermes' own tiers: official, then verified, then community.
    var tierRank: Int {
        switch tier.lowercased() {
        case "official": 0
        case "verified": 1
        default: 2
        }
    }

    var isTrusted: Bool { tierRank < 2 }

    /// The banner a list (shelf, hero, grid) may load: official and verified plugins only. A
    /// community plugin's picture is on its author's server and loads only on its own page.
    var listedImageURL: URL? { isTrusted ? imageURL : nil }
}

/// The Plugins home: one featured plugin, a shelf of official and verified ones, then a shelf per
/// topic. Desktop plugins (JavaScript for the Hermes Desktop app) come last everywhere.
struct PluginStorefront: Equatable {
    struct Shelf: Identifiable, Equatable {
        let category: CatalogCategory
        let entries: [PluginCatalogEntry]
        var id: String { category.id }
    }

    /// An official plugin, preferring one not installed yet and one with a banner.
    let hero: PluginCatalogEntry?
    /// Official before verified, without the hero.
    let trusted: [PluginCatalogEntry]
    /// Biggest topic first, ties by the host's topic name; desktop last.
    let shelves: [Shelf]

    init(catalog: [PluginCatalogEntry]) {
        let listed = catalog.filter { $0.removedReason == nil }
        let candidates = listed.filter { $0.tierRank == 0 && $0.catalogCategory != .desktop }
        let hero = candidates.stableSorted { entry in
            (entry.isInstalled ? 2 : 0) + (entry.imageURL == nil ? 1 : 0)
        }.first
        self.hero = hero

        trusted = listed
            .filter { $0.isTrusted && $0.id != hero?.id }
            .stableSorted { ($0.catalogCategory == .desktop ? 10 : 0) + $0.tierRank }

        let groups = Dictionary(grouping: listed, by: \.catalogCategory)
        shelves = groups
            .map { Shelf(category: $0.key, entries: $0.value) }
            .sorted { left, right in
                let leftDesktop = left.category == .desktop, rightDesktop = right.category == .desktop
                if leftDesktop != rightDesktop { return rightDesktop }
                if left.entries.count != right.entries.count { return left.entries.count > right.entries.count }
                return left.category.id < right.category.id
            }
    }

    /// Catalog plugins whose name, title, summary, maintainer, topic or tier mention `query`;
    /// all of them for an empty query. Desktop plugins last.
    static func matching(_ query: String, in catalog: [PluginCatalogEntry]) -> [PluginCatalogEntry] {
        catalog
            .filter {
                $0.removedReason == nil && ManagementSearch.matches(
                    query, $0.name, $0.title ?? "", $0.summary, $0.maintainer, $0.catalogCategory.title, $0.tier)
            }
            .stableSorted { $0.catalogCategory == .desktop ? 1 : 0 }
    }
}

extension SkillHubItem {
    /// Official skills have a topic; most others don't, so their tile goes by where they come from.
    var tileKey: String { category.flatMap { $0.isEmpty ? nil : $0 } ?? source }
    var catalogCategory: CatalogCategory? { category.flatMap { $0.isEmpty ? nil : CatalogCategory(id: $0) } }
}

/// The Skills Hub home: the agent's own skills, Hermes' official collection, and the hubs to search.
struct SkillStorefront: Equatable {
    struct Topic: Identifiable, Equatable {
        let category: CatalogCategory
        let items: [SkillHubItem]
        var id: String { category.id }
    }

    static let shelfLimit = 12

    let enabledCount: Int
    let disabledCount: Int
    let officialCount: Int
    /// A few official skills to name on the hero, one from each of the first topics.
    let heroNames: [String]
    /// The first official skills, in the host's order.
    let officialShelf: [SkillHubItem]
    /// Every official skill by topic, biggest first.
    let officialTopics: [Topic]
    /// Hubs to search, other than the official one (it has its own section).
    let hubs: [SkillHubSource]

    init(snapshot: SkillHubSnapshot) {
        enabledCount = snapshot.installedSkills.filter(\.isEnabled).count
        disabledCount = snapshot.installedSkills.count - enabledCount
        officialCount = snapshot.official.count
        officialShelf = Array(snapshot.official.prefix(Self.shelfLimit))

        let grouped = Dictionary(grouping: snapshot.official) { CatalogCategory($0.category) }
        officialTopics = grouped
            .map { Topic(category: $0.key, items: $0.value) }
            .sorted { left, right in
                if left.items.count != right.items.count { return left.items.count > right.items.count }
                return left.category.id < right.category.id
            }

        var seenTopics = Set<String>()
        var names: [String] = []
        for item in snapshot.official where names.count < 3 {
            if seenTopics.insert(item.tileKey).inserted { names.append(item.name) }
        }
        heroNames = names

        hubs = snapshot.sources.filter { $0.isSearchable && $0.isAvailable != false && $0.id != "official" }
    }
}

private extension Array {
    /// Sorted by `rank`, keeping the original order within a rank.
    func stableSorted(by rank: (Element) -> Int) -> [Element] {
        enumerated()
            .sorted { left, right in
                let leftRank = rank(left.element), rightRank = rank(right.element)
                return leftRank != rightRank ? leftRank < rightRank : left.offset < right.offset
            }
            .map(\.element)
    }
}
