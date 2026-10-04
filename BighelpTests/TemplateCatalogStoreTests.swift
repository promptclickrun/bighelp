import Foundation
import Testing
@testable import Bighelp

/// The Template Catalog: the last good copy wins, bundled data until there is one, at most every
/// six hours with If-None-Match, and a bad download never replaces a good copy.
@MainActor
struct TemplateCatalogStoreTests {
    private final class Transport: TemplateCatalogFetching, @unchecked Sendable {
        var responses: [URL: TemplateCatalogFetchResult] = [:]
        var failures: Set<URL> = []
        private(set) var requests: [(url: URL, etag: String?)] = []
        func fetch(_ url: URL, etag: String?) async throws -> TemplateCatalogFetchResult {
            requests.append((url, etag))
            if failures.contains(url) { throw URLError(.notConnectedToInternet) }
            return responses[url] ?? .notModified
        }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "catalog-\(UUID().uuidString)")! }

    private let agents = Data("""
    {"schemaVersion":1,"revision":"r1","templates":[
      {"id":"anchor","name":"Anchor","role":"Everyday generalist","vibe":"Warm, direct","description":"Helps.",
       "instructions":"# {{agent_name}}\\n\\nYou are {{agent_name}}.","category":"personal","symbol":"sun.max",
       "source":"bighelp","updatedAt":"2026-10-04T00:00:00.000Z"},
      {"id":"trail-guide","name":"Trail Guide","role":"Hiking planner","vibe":"Cheerful",
       "instructions":"# {{agent_name}}\\n\\nPlan hikes as {{agent_name}}.","category":"fun","symbol":"not-a-symbol",
       "source":"community","credit":"@sam_hikes","updatedAt":"2026-10-04T00:00:00.000Z"},
      {"id":"Bad ID","name":"Nope","role":"x","instructions":"x"},
      {"id":"no-soul","name":"Empty","role":"x","instructions":""}
    ]}
    """.utf8)

    private let blueprintRows = """
      {"id":"ideas-fun-1","board":"ideas","category":"personal","text":"Plan a [weekend] trip",
       "source":"community","credit":"sam_hikes","updatedAt":"2026-10-05T00:00:00.000Z"},
      {"id":"feed-productivity-1","board":"feed","category":"productivity","text":"Morning brief",
       "source":"bighelp","updatedAt":"2026-10-04T00:00:00.000Z"},
      {"id":"goals-health-1","board":"goals","category":"personal","text":"Walk more","goalCategory":"health",
       "source":"bighelp","updatedAt":"2026-10-04T00:00:00.000Z"},
      {"id":"ideas-blank","board":"ideas","category":"personal","text":"   "},
      {"id":"ideas-nowhere","board":"nowhere","category":"personal","text":"Lost"}
    """

    /// `/v1/catalog.json`: both lists in one file.
    private var catalog: Data {
        let object = try! JSONSerialization.jsonObject(with: agents) as! [String: Any]
        let agentsJSON = String(data: try! JSONSerialization.data(withJSONObject: object["templates"]!), encoding: .utf8)!
        return Data(#"{"schemaVersion":1,"revision":"r2","blueprints":[\#(blueprintRows)],"agents":\#(agentsJSON)}"#.utf8)
    }

    @Test func remoteTemplatesReadLeniently() {
        let templates = AgentSoulTemplate.remote(agents)
        #expect(templates.map(\.id) == ["anchor", "trail-guide"], "Bad items are dropped, not the file")
        let community = templates[1]
        #expect(community.title == "Trail Guide" && community.profile == "Hiking planner" && community.voice == "Cheerful")
        #expect(community.systemImage == "person.crop.square", "An unknown symbol falls back")
        #expect(community.credit == "sam_hikes" && community.isCommunity)
        #expect(community.updatedAt != nil)
        #expect(AgentNamePlaceholder.fill(community.soul ?? "", name: "Juniper") == "# Juniper\n\nPlan hikes as Juniper.")
        #expect(!templates[0].isCommunity)
    }

    @Test func catalogBlueprintsGroupByBoardAndCategory() {
        let rows = try! JSONSerialization.jsonObject(with: Data("[\(blueprintRows)]".utf8)) as! [Any]
        let catalog = BoardBlueprintCatalog(catalogRows: rows)
        #expect(catalog.count == 3, "Blank and unknown-board items are dropped")
        let idea = catalog.groups(for: .idea).first?.blueprints.first
        #expect(catalog.groups(for: .idea).map(\.title) == ["Personal life"])
        #expect(idea?.isOfficial == false && idea?.credit == "sam_hikes" && idea?.category == "personal")
        #expect(catalog.blueprints(for: .health).map(\.id) == ["goals-health-1"])
        #expect(catalog.groups(for: .feed).first?.blueprints.first?.isOfficial == true)
    }

    @Test func bundledUntilACatalogArrivesThenTheCatalogEvenAfterRelaunch() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = Transport()
        transport.responses[TemplateCatalogPolicy.catalogURL] = .fetched(catalog, etag: "\"c1\"")
        let store = TemplateCatalogStore(transport: transport, cacheDirectory: folder, defaults: defaults())
        #expect(store.agentTemplates == AgentSoulTemplate.bundled)
        await store.refreshIfNeeded()
        #expect(transport.requests.map(\.url) == [TemplateCatalogPolicy.catalogURL], "One file for both")
        #expect(store.agentTemplates.map(\.id) == ["anchor", "trail-guide"])
        #expect(store.blueprints.groups(for: .idea).first?.blueprints.map(\.credit) == ["sam_hikes"])

        let relaunched = TemplateCatalogStore(transport: Transport(), cacheDirectory: folder, defaults: defaults())
        #expect(relaunched.agentTemplates.map(\.id) == ["anchor", "trail-guide"], "The last good copy, offline")
        #expect(relaunched.blueprints.count == 3)
    }

    @Test func atMostEverySixHoursWithTheETag() async {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let transport = Transport()
        transport.responses[TemplateCatalogPolicy.catalogURL] = .fetched(catalog, etag: "\"c1\"")
        let store = TemplateCatalogStore(transport: transport, cacheDirectory: folder, defaults: defaults(),
                                         now: { clock })
        await store.refreshIfNeeded()
        #expect(transport.requests.count == 1)
        clock += 60 * 60
        await store.refreshIfNeeded()
        #expect(transport.requests.count == 1, "Not again within six hours")
        clock += 6 * 60 * 60
        transport.responses[TemplateCatalogPolicy.catalogURL] = .notModified
        await store.refreshIfNeeded()
        #expect(transport.requests.last?.etag == "\"c1\"", "If-None-Match with the saved ETag")
        #expect(store.agentTemplates.map(\.id) == ["anchor", "trail-guide"], "Not modified keeps it")
    }

    @Test func aBadOrFailedDownloadKeepsTheGoodCopy() async {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = Transport()
        transport.responses[TemplateCatalogPolicy.catalogURL] = .fetched(catalog, etag: nil)
        let store = TemplateCatalogStore(transport: transport, cacheDirectory: folder, defaults: defaults())
        await store.refreshIfNeeded(force: true)
        transport.responses[TemplateCatalogPolicy.catalogURL] = .fetched(Data(#"{"blueprints":[],"agents":[]}"#.utf8), etag: nil)
        await store.refreshIfNeeded(force: true)
        #expect(store.agentTemplates.map(\.id) == ["anchor", "trail-guide"], "Empty doesn't replace it")
        transport.failures = [TemplateCatalogPolicy.catalogURL]
        await store.refreshIfNeeded(force: true)
        #expect(store.agentTemplates.map(\.id) == ["anchor", "trail-guide"], "Nor does a failure")
        let relaunched = TemplateCatalogStore(transport: Transport(), cacheDirectory: folder, defaults: defaults())
        #expect(relaunched.agentTemplates.count == 2)
    }

    @Test func searchOfficialCategoryAndOrder() {
        let rows = try! JSONSerialization.jsonObject(with: Data("[\(blueprintRows)]".utf8)) as! [Any]
        let all = BoardBlueprintCatalog(catalogRows: rows).groups(for: .idea).flatMap(\.blueprints)
            + BoardBlueprintCatalog(catalogRows: rows).groups(for: .feed).flatMap(\.blueprints)
        #expect(BlueprintBrowsing.filter(all, search: "weekend", officialOnly: false, category: nil).map(\.id) == ["ideas-fun-1"])
        #expect(BlueprintBrowsing.filter(all, search: "", officialOnly: true, category: nil).map(\.id) == ["feed-productivity-1"])
        #expect(BlueprintBrowsing.filter(all, search: "", officialOnly: false, category: "productivity").map(\.id)
                == ["feed-productivity-1"])
        let usage = TemplateUsage(defaults: defaults())
        #expect(BlueprintBrowsing.sorted(all, by: .newest, usage: usage).first?.id == "ideas-fun-1", "Newest first")
        usage.recordUse("feed-productivity-1")
        usage.recordUse("feed-productivity-1")
        #expect(BlueprintBrowsing.sorted(all, by: .mostUsed, usage: usage).first?.id == "feed-productivity-1")
        #expect(usage.count("feed-productivity-1") == 2)
    }

    @Test func demoAndTestsStayBundledAndOffline() async {
        let transport = Transport()
        let store = TemplateCatalogStore(transport: transport, cacheDirectory: directory(), defaults: defaults(),
                                         isEnabled: false)
        await store.refreshIfNeeded(force: true)
        #expect(transport.requests.isEmpty)
        #expect(store.agentTemplates == AgentSoulTemplate.bundled)
    }

    @Test func onlyTheCatalogHostOverHTTPS() {
        #expect(TemplateCatalogPolicy.isAllowed(TemplateCatalogPolicy.catalogURL))
        #expect(!TemplateCatalogPolicy.isAllowed(URL(string: "http://catalog.bighelp.app/v1/catalog.json")))
        #expect(!TemplateCatalogPolicy.isAllowed(URL(string: "https://evil.example/v1/catalog.json")))
    }
}

/// Against the live catalog, only when TEMPLATE_CATALOG_LIVE (TEST_RUNNER_…) is set.
@MainActor
struct TemplateCatalogLiveTests {
    @Test func theLiveCatalogReadsAndAnswersNotModified() async throws {
        guard ProcessInfo.processInfo.environment["TEMPLATE_CATALOG_LIVE"] != nil else { return }
        let transport = TemplateCatalogURLSessionTransport()
        guard case .fetched(let data, let etag) = try await transport.fetch(TemplateCatalogPolicy.catalogURL, etag: nil)
        else { Issue.record("Expected the catalog"); return }
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(AgentSoulTemplate.remote(rows: object["agents"] as? [Any] ?? []).count >= 15)
        #expect(BoardBlueprintCatalog(catalogRows: object["blueprints"] as? [Any] ?? []).count >= 45)
        #expect(try await transport.fetch(TemplateCatalogPolicy.catalogURL, etag: etag) == .notModified)
    }
}
