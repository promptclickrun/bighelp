import Foundation
import Testing
@testable import Bighelp

/// The Plugins and Skills Hub storefronts are built only from what the host lists: its catalog
/// rows' tier, category and pictures, and the official skills' topics.
@MainActor
struct CatalogStorefrontTests {
    @Test func pluginCatalogReadsStorefrontFieldsAndSkipsUnreadableAndRepeatedRows() async throws {
        let owner = WorkspaceOwner(
            authority: try .direct(endpointIdentity: "https://hermes.example", providerID: "basic", userID: "person"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
        let client = DirectHermesPluginLifecycleClient(http: CatalogHost(), owner: owner, currentOwner: { owner })

        let snapshot = try await client.load()

        // One name is one card: a second "recall" row is left out and counted, like the unpinned row.
        #expect(snapshot.catalog.map(\.name) == ["recall", "plain"])
        #expect(snapshot.skippedCatalogRows == 2)
        let recall = try #require(snapshot.catalog.first)
        #expect(recall.displayName == "Recall")
        #expect(recall.category == "memory")
        #expect(recall.imageURL?.absoluteString == "https://example.com/recall.png")
        #expect(recall.screenshotURLs.map(\.absoluteString) == ["https://example.com/shot.png"])
        #expect(recall.version == "0.4.2")
        #expect(recall.knownIssues == ["Slow on first run."])
        // A plain row: odd display fields hide themselves, never the row.
        let plain = try #require(snapshot.catalog.last)
        #expect(plain.displayName == "plain")
        #expect(plain.imageURL == nil)
        #expect(plain.documentationURL == nil)
        #expect(plain.category == nil)
        #expect(plain.knownIssues == ["One.", "Two."])
    }

    @Test func pluginStorefrontFeaturesAnOfficialPluginAndShelvesByTopic() {
        let catalog = [
            entry("tidy", tier: "community", category: "tools"),
            entry("wiki", tier: "official", category: "memory"),
            entry("recall", tier: "official", category: "memory", image: true),
            entry("installed-official", tier: "official", category: "tools", image: true, installed: true),
            entry("panel", tier: "official", category: "desktop", image: true),
            entry("relay", tier: "verified", category: "platform"),
            entry("clock", tier: "verified", category: "desktop"),
            entry("hammer", tier: "community", category: "tools"),
            entry("habit", tier: "community", category: "memory"),
            entry("loose", tier: "community", category: nil),
        ]

        let storefront = PluginStorefront(catalog: catalog)

        // Official, not for Desktop, not installed yet, with a banner.
        #expect(storefront.hero?.name == "recall")
        // Official before verified, without the hero, Desktop's last.
        #expect(storefront.trusted.map(\.name) == ["wiki", "installed-official", "relay", "panel", "clock"])
        // Biggest topic first, ties by name, a missing topic is General, Desktop last.
        #expect(storefront.shelves.map(\.id) == ["memory", "tools", "general", "platform", "desktop"])
        #expect(storefront.shelves.first?.entries.map(\.name) == ["wiki", "recall", "habit"])
        #expect(storefront.shelves.last?.category.title == "For Hermes Desktop")
        // Lists load banners only from official and verified plugins' rows.
        #expect(storefront.hero?.listedImageURL != nil)
        #expect(entry("art", tier: "community", category: "tools", image: true).listedImageURL == nil)
        #expect(PluginStorefront.matching("memory", in: catalog).map(\.name) == ["wiki", "recall", "habit"])
        #expect(PluginStorefront.matching("", in: catalog).last?.catalogCategory == .desktop)
    }

    @Test func pluginStorefrontHasNoHeroWithoutAnOfficialPlugin() {
        let storefront = PluginStorefront(catalog: [entry("relay", tier: "verified", category: "platform"),
                                                    entry("panel", tier: "official", category: "desktop")])
        #expect(storefront.hero == nil)
        #expect(storefront.trusted.map(\.name) == ["relay", "panel"])
    }

    @Test func skillStorefrontNamesOneOfficialSkillPerTopicAndListsOtherHubs() {
        let snapshot = SkillHubSnapshot(
            sources: [
                SkillHubSource(id: "official", label: "Official", isAvailable: true, isSearchable: true, isRateLimited: false),
                SkillHubSource(id: "skills-sh", label: "skills.sh", isAvailable: true, isSearchable: true, isRateLimited: false),
                SkillHubSource(id: "down", label: "Down", isAvailable: false, isSearchable: true, isRateLimited: false),
                SkillHubSource(id: "index", label: "Index", isAvailable: nil, isSearchable: false, isRateLimited: false),
            ],
            featured: [],
            official: [skill("pdf", "documents"), skill("docx", "documents"), skill("budget", "finance"),
                       skill("vault", "security"), skill("notes", "productivity")],
            installedSkills: [
                InstalledSkill(name: "a", summary: "", category: "", isEnabled: true, provenance: "hub", usageCount: 0),
                InstalledSkill(name: "b", summary: "", category: "", isEnabled: false, provenance: "hub", usageCount: 0),
            ],
            installedIdentifiers: [], indexAvailable: true
        )

        let storefront = SkillStorefront(snapshot: snapshot)

        #expect(storefront.heroNames == ["pdf", "budget", "vault"])
        #expect(storefront.officialCount == 5)
        #expect(storefront.officialTopics.first?.category.id == "documents")
        #expect(storefront.officialTopics.first?.items.count == 2)
        #expect(storefront.hubs.map(\.id) == ["skills-sh"])
        #expect(storefront.enabledCount == 1 && storefront.disabledCount == 1)
    }

    @Test func shelvesShowOnlyWholeCards() {
        // A phone's width inside the page margins, then an iPad's.
        for length in [358.0, 992.0] {
            for columns in [CatalogShelfColumns.cards, .tiles, .screenshots] {
                let count = CGFloat(columns.count(in: length))
                let width = columns.width(in: length)
                #expect(abs(width * count + CatalogMetrics.shelfSpacing * (count - 1) - length) < 0.001)
                #expect(width >= columns.minimumWidth)
            }
        }
        #expect(CatalogShelfColumns.cards.count(in: 358) == 2)
        #expect(CatalogShelfColumns.tiles.count(in: 358) == 3)
        #expect(CatalogShelfColumns.cards.count(in: 992) > 2)
    }

    @Test func aSkillAddedFromSearchResultsReadsAsInstalledAfterAReload() async throws {
        let client = SkillsHost()
        let model = SkillsHubManagementModel(client: client)
        await model.load()
        model.query = "trip"
        await model.search()
        let found = try #require(model.searchResult?.items.first)
        #expect(!model.latest(found).isInstalled)

        client.installed = [found.id]
        await model.load()

        // The search results still say not installed; the reload's installed list wins.
        #expect(model.searchResult?.items.first?.isInstalled == false)
        #expect(model.latest(found).isInstalled)
    }

    private func entry(_ name: String, tier: String, category: String?, image: Bool = false,
                       installed: Bool = false) -> PluginCatalogEntry {
        PluginCatalogEntry(
            name: name, repository: "https://example.com/\(name)", commitSHA: String(repeating: "a", count: 40),
            summary: "", maintainer: "Example", tier: tier, requiredHermesVersion: "", documentationURL: nil,
            platforms: [], capabilities: PluginCapabilitySummary(tools: [], hooks: [], middleware: [], requiredEnvironment: []),
            isInstalled: installed, installedSHA: nil, updateAvailable: false, runtimeStatus: nil, removedReason: nil,
            category: category, imageURL: image ? URL(string: "https://example.com/\(name).png") : nil
        )
    }

    private func skill(_ name: String, _ category: String) -> SkillHubItem {
        SkillHubItem(id: "official/\(category)/\(name)", name: name, summary: "", source: "official",
                     trustLevel: "builtin", repository: nil, tags: [], category: category, isInstalled: false)
    }
}

/// Answers like a Hermes catalog with storefront fields: one full row, one with odd display
/// fields, and one without a pinned commit, which can't be installed and is skipped.
@MainActor
private final class CatalogHost: DirectHermesAuthenticatedHTTP {
    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        switch request.path {
        case "/api/dashboard/plugins/hub":
            return .object(["plugins": .array([])])
        case "/api/dashboard/plugins/catalog":
            return .object([
                "entries": .array([
                    row("recall", extra: [
                        "title": .string("Recall"), "category": .string("Memory"),
                        "image": .string("https://example.com/recall.png"),
                        "screenshots": .array([.string("https://example.com/shot.png"), .string("http://example.com/x.png"),
                                               .integer(3)]),
                        "version": .string("0.4.2"), "known_issues": .string("Slow on first run."),
                    ]),
                    row("plain", extra: [
                        "title": .string("  "), "image": .string("javascript:alert(1)"), "category": .integer(4),
                        "docs_url": .string("not a link"), "known_issues": .array([.string("One."), .null, .string("Two.")]),
                    ]),
                    row("unpinned", extra: ["sha": .string("main")]),
                    row("recall", extra: ["title": .string("A second Recall")]),
                ]),
                "removed": .array([]),
            ])
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }

    private func row(_ name: String, extra: [String: BighelpJSONValue]) -> BighelpJSONValue {
        var row: [String: BighelpJSONValue] = [
            "name": .string(name), "repo": .string("https://example.com/\(name)"),
            "sha": .string(String(repeating: "b", count: 40)), "description": .string("Does a thing."),
            "maintainer": .string("Example"), "tier": .string("official"), "docs_url": .string(""),
            "requires_hermes": .string(""), "platforms": .array([]),
            "capabilities": .object([
                "provides_tools": .array([]), "provides_hooks": .array([]),
                "provides_middleware": .array([]), "requires_env": .array([]),
            ]),
            "installed": .boolean(false), "update_available": .boolean(false),
        ]
        row.merge(extra) { _, new in new }
        return .object(row)
    }
}

/// A Skills Hub whose installed list changes between loads, as Hermes' does after an install.
@MainActor
private final class SkillsHost: SkillsHubManagementClient {
    let owner = WorkspaceOwner(
        authority: try! .direct(endpointIdentity: "https://hermes.example", providerID: "basic", userID: "person"),
        authenticationGeneration: UUID(), connectionGeneration: UUID()
    )
    let profileID = "default"
    var installed: Set<String> = []

    private let trip = SkillHubItem(id: "clawhub/trip-planner", name: "trip-planner", summary: "Plans a trip.",
                                    source: "clawhub", trustLevel: "community", repository: nil, tags: [],
                                    category: nil, isInstalled: false)

    func load() async throws -> SkillHubSnapshot {
        SkillHubSnapshot(sources: [], featured: [], official: [], installedSkills: [],
                         installedIdentifiers: installed, indexAvailable: true)
    }
    func search(query: String, source: String) async throws -> SkillHubSearchResult {
        SkillHubSearchResult(items: [trip], sourceCounts: [:], timedOutSources: [])
    }
    func preview(identifier: String) async throws -> SkillHubPreview { throw CapabilitiesManagementError.invalidRequest }
    func scan(identifier: String) async throws -> SkillHubScan { throw CapabilitiesManagementError.invalidRequest }
    func setEnabled(_ enabled: Bool, skillName: String) async throws -> InstalledSkill {
        throw CapabilitiesManagementError.invalidRequest
    }
    func install(identifier: String, preview: SkillHubPreview, scan: SkillHubScan) async throws -> CapabilityWriteResult {
        throw CapabilitiesManagementError.invalidRequest
    }
    func uninstall(name: String) async throws -> CapabilityWriteResult { throw CapabilitiesManagementError.invalidRequest }
    func updateInstalled() async throws -> CapabilityWriteResult { throw CapabilitiesManagementError.invalidRequest }
}
