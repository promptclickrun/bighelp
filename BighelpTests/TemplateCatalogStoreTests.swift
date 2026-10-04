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

    private let blueprints = Data("""
    {"schemaVersion":1,"revision":"r1","pages":[{"page":"ideas","groups":[{"id":"fun","title":"Fun","prompts":[
      {"id":"ideas-fun-1","text":"Plan a [weekend] trip","credit":"sam_hikes"},
      {"id":"ideas-fun-2","text":"   "}]}]}]}
    """.utf8)

    @Test func remoteTemplatesReadLeniently() {
        let templates = AgentSoulTemplate.remote(agents)
        #expect(templates.map(\.id) == ["anchor", "trail-guide"], "Bad items are dropped, not the file")
        let community = templates[1]
        #expect(community.title == "Trail Guide" && community.profile == "Hiking planner" && community.voice == "Cheerful")
        #expect(community.systemImage == "person.crop.square", "An unknown symbol falls back")
        #expect(community.credit == "sam_hikes" && community.isCommunity)
        #expect(AgentNamePlaceholder.fill(community.soul ?? "", name: "Juniper") == "# Juniper\n\nPlan hikes as Juniper.")
        #expect(!templates[0].isCommunity)
    }

    @Test func bundledUntilACatalogArrivesThenTheCatalogEvenAfterRelaunch() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = Transport()
        transport.responses[TemplateCatalogPolicy.agentTemplatesURL] = .fetched(agents, etag: "\"a1\"")
        transport.responses[TemplateCatalogPolicy.blueprintsURL] = .fetched(blueprints, etag: "\"b1\"")
        let store = TemplateCatalogStore(transport: transport, cacheDirectory: folder, defaults: defaults())
        #expect(store.agentTemplates == AgentSoulTemplate.bundled)
        await store.refreshIfNeeded()
        #expect(store.agentTemplates.map(\.id) == ["anchor", "trail-guide"])
        #expect(store.blueprints.groups(for: .idea).first?.blueprints.map(\.credit) == ["sam_hikes"])

        let relaunched = TemplateCatalogStore(transport: Transport(), cacheDirectory: folder, defaults: defaults())
        #expect(relaunched.agentTemplates.map(\.id) == ["anchor", "trail-guide"], "The last good copy, offline")
    }

    @Test func atMostEverySixHoursWithTheETag() async {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let transport = Transport()
        transport.responses[TemplateCatalogPolicy.agentTemplatesURL] = .fetched(agents, etag: "\"a1\"")
        let store = TemplateCatalogStore(transport: transport, cacheDirectory: folder, defaults: defaults(),
                                         now: { clock })
        await store.refreshIfNeeded()
        #expect(transport.requests.count == 2)
        clock += 60 * 60
        await store.refreshIfNeeded()
        #expect(transport.requests.count == 2, "Not again within six hours")
        clock += 6 * 60 * 60
        transport.responses[TemplateCatalogPolicy.agentTemplatesURL] = .notModified
        await store.refreshIfNeeded()
        let agentRequest = transport.requests.last { $0.url == TemplateCatalogPolicy.agentTemplatesURL }
        #expect(agentRequest?.etag == "\"a1\"", "If-None-Match with the saved ETag")
        #expect(store.agentTemplates.map(\.id) == ["anchor", "trail-guide"], "Not modified keeps it")
    }

    @Test func aBadOrFailedDownloadKeepsTheGoodCopy() async {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = Transport()
        transport.responses[TemplateCatalogPolicy.agentTemplatesURL] = .fetched(agents, etag: nil)
        let store = TemplateCatalogStore(transport: transport, cacheDirectory: folder, defaults: defaults())
        await store.refreshIfNeeded(force: true)
        transport.responses[TemplateCatalogPolicy.agentTemplatesURL] = .fetched(Data("{\"templates\":[]}".utf8), etag: nil)
        await store.refreshIfNeeded(force: true)
        #expect(store.agentTemplates.map(\.id) == ["anchor", "trail-guide"], "Empty doesn't replace it")
        transport.failures = [TemplateCatalogPolicy.agentTemplatesURL]
        await store.refreshIfNeeded(force: true)
        #expect(store.agentTemplates.map(\.id) == ["anchor", "trail-guide"], "Nor does a failure")
        let relaunched = TemplateCatalogStore(transport: Transport(), cacheDirectory: folder, defaults: defaults())
        #expect(relaunched.agentTemplates.count == 2)
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
        #expect(TemplateCatalogPolicy.isAllowed(TemplateCatalogPolicy.blueprintsURL))
        #expect(!TemplateCatalogPolicy.isAllowed(URL(string: "http://catalog.bighelp.app/v1/board-blueprints.json")))
        #expect(!TemplateCatalogPolicy.isAllowed(URL(string: "https://evil.example/v1/board-blueprints.json")))
    }
}

/// Against the live catalog, only when TEMPLATE_CATALOG_LIVE (TEST_RUNNER_…) is set.
@MainActor
struct TemplateCatalogLiveTests {
    @Test func theLiveCatalogReadsAndAnswersNotModified() async throws {
        guard ProcessInfo.processInfo.environment["TEMPLATE_CATALOG_LIVE"] != nil else { return }
        let transport = TemplateCatalogURLSessionTransport()
        guard case .fetched(let agents, let etag) = try await transport.fetch(TemplateCatalogPolicy.agentTemplatesURL, etag: nil)
        else { Issue.record("Expected the templates"); return }
        #expect(AgentSoulTemplate.remote(agents).count >= 15)
        #expect(try await transport.fetch(TemplateCatalogPolicy.agentTemplatesURL, etag: etag) == .notModified)
        guard case .fetched(let blueprints, _) = try await transport.fetch(TemplateCatalogPolicy.blueprintsURL, etag: nil)
        else { Issue.record("Expected the blueprints"); return }
        #expect(try BoardBlueprintCatalog(data: blueprints).count >= 45)
    }
}
