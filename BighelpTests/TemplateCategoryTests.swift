import Foundation
import Testing
import UIKit
@testable import Bighelp

/// Template pickers by topic: the catalog's `category` read leniently (unknown and missing ones are
/// Other), topics in one fixed order, search and the topic chips, and My Templates first.
@MainActor
struct TemplateCategoryTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "template-topics-\(UUID().uuidString)")! }

    private func agentRows(_ json: String) -> [Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [Any]
    }

    private func template(_ id: String, _ category: String?, title: String? = nil, community: Bool = false,
                          updated: String? = nil) -> String {
        var row: [String: Any] = ["id": id, "name": title ?? id.capitalized, "role": "Helper for \(id)",
                                  "instructions": "# {{agent_name}}", "source": community ? "community" : "bighelp"]
        if let category { row["category"] = category }
        if let updated { row["updatedAt"] = updated }
        return String(data: try! JSONSerialization.data(withJSONObject: row), encoding: .utf8)!
    }

    // MARK: Reading the topic

    @Test func agentTemplatesReadTheirTopicAndUnknownOrMissingIsOther() {
        let rows = agentRows("[" + [
            template("forge", "coding"),
            template("guard", " Security "),
            template("trail", "hiking"),
            template("plain", nil),
            #"{"id":"odd","name":"Odd","role":"x","instructions":"x","category":42}"#,
        ].joined(separator: ",") + "]")
        let templates = AgentSoulTemplate.remote(rows: rows)
        #expect(templates.map(\.id) == ["forge", "guard", "trail", "plain", "odd"], "No template is dropped for its topic")
        #expect(templates.map(\.category.id) == ["coding", "security", "other", "other", "other"])
        #expect(templates[0].category.title == "Coding" && templates[1].category.title == "Security")
        #expect(templates[2].category == .other && TemplateCategory.other.title == "Other")
    }

    @Test func theTenAgentTopicsHaveFriendlyNamesAndIconsInAFixedOrder() {
        #expect(TemplateCategory.agentTopics.map(\.id) == ["productivity", "business", "coding", "science", "education",
                                                            "health", "creative", "personal", "leadership", "security"])
        #expect(TemplateCategory.agentTopics.map(\.title) == ["Productivity", "Business", "Coding", "Science", "Education",
                                                               "Health", "Creative", "Personal", "Leadership", "Security"])
        #expect(TemplateCategory.blueprintTopics.map(\.title) == ["Productivity", "Marketing", "Content creation",
                                                                   "Personal life", "Research"])
        let all = TemplateCategory.agentTopics + TemplateCategory.blueprintTopics + [.other]
        #expect(all.allSatisfy { !$0.systemImage.isEmpty && UIImage(systemName: $0.systemImage) != nil },
                "Every icon is an SF Symbol")
    }

    /// The bundled fallback sorts the same way the catalog does.
    @Test func bundledTemplatesHaveTheCatalogsTopics() {
        let topics = Dictionary(uniqueKeysWithValues: AgentSoulTemplate.bundled.map { ($0.id, $0.category.id) })
        #expect(topics == [
            "anchor": "personal", "compass": "productivity", "spark": "productivity", "lumen": "education",
            "lens": "science", "forge": "coding", "beacon": "coding", "counterpoint": "leadership", "muse": "creative",
            "quill": "creative", "bridge": "business", "hearth": "personal", "harbor": "health", "waypoint": "personal",
            "fable": "creative",
        ])
        #expect(AgentSoulTemplate.demoFieldLead.category != .other)
    }

    @Test func blueprintsReadTheirTopicAndGroupInTheFixedOrderWithOtherLast() {
        let rows = agentRows("""
        [{"id":"i1","board":"ideas","category":"research","text":"Look into [topic]"},
         {"id":"i2","board":"ideas","category":"hiking","text":"Plan a hike"},
         {"id":"i3","board":"ideas","text":"No topic"},
         {"id":"i4","board":"ideas","category":"PRODUCTIVITY","text":"Tidy my week"},
         {"id":"i5","board":"ideas","category":"research","text":"Read a paper"}]
        """)
        let groups = BoardBlueprintCatalog(catalogRows: rows).groups(for: .idea)
        #expect(groups.map(\.id) == ["productivity", "research", "other"])
        #expect(groups.map(\.title) == ["Productivity", "Research", "Other"])
        #expect(groups.map { $0.blueprints.map(\.id) } == [["i4"], ["i1", "i5"], ["i2", "i3"]])
        #expect(groups[1].blueprints[0].category == .blueprint("research"))
    }

    // MARK: Grouping, search and chips

    private var catalog: [AgentSoulTemplate] {
        AgentSoulTemplate.remote(rows: agentRows("[" + [
            template("muse", "creative", title: "Muse", updated: "2026-10-01T00:00:00Z"),
            template("forge", "coding", title: "Forge", updated: "2026-10-03T00:00:00Z"),
            template("trail", "hiking", title: "Trail Guide", community: true, updated: "2026-10-05T00:00:00Z"),
            template("compass", "productivity", title: "Compass", updated: "2026-10-02T00:00:00Z"),
            template("beacon", "coding", title: "Beacon", updated: "2026-10-04T00:00:00Z"),
        ].joined(separator: ",") + "]"))
    }

    private var mine: [AgentSoulTemplate] {
        [AgentSoulTemplate(id: "mine-1", title: "Weekend Planner", profile: "Plans easy weekends", voice: "Cheerful",
                           strength: "", systemImage: "person.crop.square", inlineSoul: "x",
                           savedTemplateID: "3d2b7c1e-5a4f-4b6d-9e8c-1f2a3b4c5d6e")]
    }

    private func listing(search: String = "", filter: TemplateTopicFilter = .all, order: TemplateOrder = .forYou,
                         officialOnly: Bool = false, mine: [AgentSoulTemplate]? = nil,
                         usage: TemplateUsage? = nil) -> TemplateListing<AgentSoulTemplate> {
        let mine = mine ?? self.mine
        return AgentTemplateBrowsing.listing(catalog: catalog, mine: mine, hasMine: !mine.isEmpty, search: search,
                                             officialOnly: officialOnly, filter: filter, order: order,
                                             usage: usage ?? TemplateUsage(defaults: defaults()))
    }

    @Test func sectionsFollowTheTopicOrderAndKeepTheCatalogsOrderInside() {
        let shown = listing()
        #expect(shown.sections.map(\.category?.id) == ["productivity", "coding", "creative", "other"])
        #expect(shown.sections.map(\.title) == ["Productivity", "Coding", "Creative", "Other"])
        #expect(shown.sections.map { $0.items.map(\.id) } == [["compass"], ["forge", "beacon"], ["muse"], ["trail"]])
    }

    @Test func myTemplatesComeFirstAndHaveTheirOwnChip() {
        let shown = listing()
        #expect(shown.mine.map(\.id) == ["mine-1"])
        #expect(shown.filters == [.all, .mine, .topic(.agent("productivity")), .topic(.agent("coding")),
                                  .topic(.agent("creative")), .topic(.other)],
                "All, My Templates, then only the topics that have templates, Other last")
        let onlyMine = listing(filter: .mine)
        #expect(onlyMine.mine.map(\.id) == ["mine-1"] && onlyMine.sections.isEmpty)
        let none = listing(mine: [])
        #expect(!none.filters.contains(.mine) && none.mine.isEmpty)
    }

    @Test func aTopicChipShowsOnlyThatTopic() {
        let coding = listing(filter: .topic(.agent("coding")))
        #expect(coding.mine.isEmpty, "My Templates have their own chip")
        #expect(coding.sections.map(\.title) == ["Coding"])
        #expect(coding.sections.first?.items.map(\.id) == ["forge", "beacon"])
        let gone = listing(filter: .topic(.agent("security")))
        #expect(gone.filter == .all, "A topic without templates falls back to All")
        #expect(gone.sections.count == 4)
    }

    @Test func searchKeepsTheSectionsAndMatchesTopicNamesToo() {
        let forge = listing(search: "forge")
        #expect(forge.mine.isEmpty && forge.sections.map { $0.items.map(\.id) } == [["forge"]])
        let byTopic = listing(search: "coding")
        #expect(byTopic.sections.map(\.title) == ["Coding"] && byTopic.sections[0].items.count == 2)
        let weekend = listing(search: "weekend")
        #expect(weekend.mine.map(\.id) == ["mine-1"] && weekend.sections.isEmpty)
        let both = listing(search: "helper", filter: .topic(.agent("creative")))
        #expect(both.sections.map { $0.items.map(\.id) } == [["muse"]], "Search and the chip together")
    }

    @Test func aSearchWithNoResultsSaysSo() {
        let none = listing(search: "zzz")
        #expect(none.isEmpty)
        #expect(TemplateEmptyState(search: "zzz", filter: .all, noun: "templates").detail == "Nothing matches “zzz”.")
        let inTopic = TemplateEmptyState(search: "zzz", filter: .topic(.agent("coding")), noun: "templates")
        #expect(inTopic.title == "No matching templates")
        #expect(inTopic.detail == "Nothing in Coding matches “zzz”." && inTopic.offersAll)
        #expect(!TemplateEmptyState(search: "zzz", filter: .all, noun: "blueprints").offersAll)
        #expect(!listing().isEmpty)
    }

    @Test func newestAndMostUsedAreOneRankedListAfterMyTemplates() {
        let newest = listing(order: .newest)
        #expect(newest.mine.map(\.id) == ["mine-1"])
        #expect(newest.sections.count == 1 && newest.sections[0].category == nil && newest.sections[0].title == "Newest")
        #expect(newest.sections[0].items.map(\.id) == ["trail", "beacon", "forge", "compass", "muse"])
        let usage = TemplateUsage(defaults: defaults())
        usage.recordUse(AgentTemplateBrowsing.usageID(catalog[0]))
        let used = listing(filter: .topic(.agent("creative")), order: .mostUsed, usage: usage)
        #expect(used.sections.map(\.title) == ["Most used"] && used.sections[0].items.map(\.id) == ["muse"])
    }

    @Test func bighelpOnlyHidesCommunityTemplatesAndTheirTopic() {
        let official = listing(officialOnly: true)
        #expect(!official.sections.flatMap(\.items).contains { $0.isCommunity })
        #expect(!official.filters.contains(.topic(.other)), "Other held only the community one")
    }

    @Test func blueprintListingsGroupSearchAndFilterTheSameWay() throws {
        let blueprints = try BoardBlueprintCatalog.bundled().groups(for: .idea).flatMap(\.blueprints)
        let usage = TemplateUsage(defaults: defaults())
        let all = BlueprintBrowsing.listing(blueprints, search: "", officialOnly: false, filter: .all, order: .forYou,
                                            usage: usage)
        #expect(all.filters == [.all] + TemplateCategory.blueprintTopics.map(TemplateTopicFilter.topic))
        #expect(all.sections.map(\.title) == ["Productivity", "Marketing", "Content creation", "Personal life", "Research"])
        #expect(all.mine.isEmpty)
        let marketing = BlueprintBrowsing.listing(blueprints, search: "", officialOnly: false,
                                                  filter: .topic(.blueprint("marketing")), order: .forYou, usage: usage)
        #expect(marketing.sections.map(\.title) == ["Marketing"] && marketing.sections[0].items.count == 3)
        let none = BlueprintBrowsing.listing(blueprints, search: "zzz", officialOnly: false, filter: .all,
                                             order: .forYou, usage: usage)
        #expect(none.isEmpty)
    }
}
