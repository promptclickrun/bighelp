import Foundation
import Testing
@testable import Bighelp

/// Plugins as Hermes serves them now: an update that asks first (new tools, scan findings), a refusal in
/// Hermes' own words, and the marketplace's stars, featured picks and dates from the bighelp plugin.
@MainActor
struct PluginMarketplaceTests {
    @Test func anUpdateThatAddsToolsAsksFirstAndAppliesOnlyWithTheYes() async throws {
        let host = UpdateHost(answer: .addsTools)
        let model = PluginLifecycleManagementModel(client: host.client())
        await model.load()
        let plugin = try #require(model.snapshot?.installed.first)

        await model.update(plugin)

        // Hermes changed nothing and asked; that's a question, not a failure.
        let question = try #require(model.updateQuestion)
        #expect(question.kind == .addsCapabilities)
        #expect(question.additions == ["tools: lantern_export"])
        #expect(question.approval == .capabilities)
        #expect(question.message.text?.hasPrefix("Updating 'lantern'") == true)
        #expect(model.errorMessage == nil)
        #expect(model.successMessage == nil)
        #expect(host.updateBodies == [nil])

        await model.answerUpdateQuestion()

        #expect(host.updateBodies == [nil, ["accept_capabilities": .boolean(true)]])
        #expect(model.updateQuestion == nil)
        #expect(model.errorMessage == nil)
        #expect(model.successMessage != nil)
    }

    @Test func scanFindingsAskAndADangerousVerdictOffersNoYes() async throws {
        let caution = UpdateHost(answer: .scan(verdict: "caution"))
        let model = PluginLifecycleManagementModel(client: caution.client())
        await model.load()
        await model.update(try #require(model.snapshot?.installed.first))

        let question = try #require(model.updateQuestion)
        #expect(question.kind == .scanCaution)
        #expect(question.findings.map(\.detail) == ["Downloads a file from the web."])
        #expect(question.findings.first?.line == 12)
        await model.answerUpdateQuestion()
        #expect(caution.updateBodies.last == ["force": .boolean(true)])
        #expect(model.updateQuestion == nil)

        let dangerous = UpdateHost(answer: .scan(verdict: "dangerous"))
        let blocked = PluginLifecycleManagementModel(client: dangerous.client())
        await blocked.load()
        await blocked.update(try #require(blocked.snapshot?.installed.first))
        #expect(blocked.updateQuestion?.kind == .scanBlocked)
        #expect(blocked.updateQuestion?.approval == nil)
        await blocked.answerUpdateQuestion()
        #expect(dangerous.updateBodies == [nil], "No answer applies a blocked update")
        blocked.dismissUpdateQuestion()
        #expect(blocked.updateQuestion == nil)
    }

    @Test func aRefusedInstallShowsHermesOwnWords() async throws {
        func response(_ status: Int, _ body: String) -> DirectHermesHTTP.Response {
            .init(http: HTTPURLResponse(url: URL(string: "https://host.example/api/dashboard/agent-plugins/install")!,
                                        statusCode: status, httpVersion: nil, headerFields: nil)!,
                  body: Data(body.utf8))
        }
        let install = DirectHermesHTTPRequest(path: "/api/dashboard/agent-plugins/install", method: .post)
        let words = "lantern needs Hermes >=0.30.0; this is 0.22.6. Update Hermes (`hermes update`) and install again."
        let refusal = try #require(DirectHermesHTTP.pluginChangeRefusal(install, response(400, #"{"detail":"\#(words)"}"#)))
        guard case .rpcRejected(400, let message) = refusal else { Issue.record("\(refusal)"); return }
        #expect(message.text == words)
        // Only a plugin change's 400 with words; anything else keeps its old meaning.
        #expect(DirectHermesHTTP.pluginChangeRefusal(install, response(500, #"{"detail":"x"}"#)) == nil)
        #expect(DirectHermesHTTP.pluginChangeRefusal(install, response(400, #"{"detail":{"errors":[]}}"#)) == nil)
        #expect(DirectHermesHTTP.pluginChangeRefusal(
            DirectHermesHTTPRequest(path: "/api/dashboard/plugins/catalog", method: .get), response(400, #"{"detail":"x"}"#)) == nil)

        let host = UpdateHost(answer: .addsTools, installRefusal: words)
        let model = PluginLifecycleManagementModel(client: host.client())
        await model.load()
        await model.install(try #require(model.snapshot?.catalog.first { !$0.isInstalled }))
        #expect(model.errorMessage == "Hermes said: \(words)")
    }

    @Test func marketplaceFactsReadLenientlyAndJoinTheCatalog() async throws {
        let facts = try #require(DirectHermesPluginMarketplaceClient.facts(from: [
            "fetchedAt": .string("2027-01-15T08:00:00Z"),
            "plugins": .array([
                .object(["name": .string("lantern"), "stars": .integer(4_120), "featured": .integer(2),
                         "addedAt": .string("2026-09-20T22:06:49Z"), "updatedAt": .string("not a date")]),
                .object(["name": .string("quill"), "stars": .integer(-3), "featured": .integer(0),
                         "installRefusal": .string("quill needs Hermes >=0.30.0;\nthis is 0.22.6.")]),
                .object(["name": .string("lantern"), "stars": .integer(1)]),
                .object(["stars": .integer(9)]),
                .string("not a row"),
            ]),
        ]))
        #expect(facts.count == 2)
        #expect(facts["lantern"]?.stars == 4_120)
        #expect(facts["lantern"]?.featuredRank == 2)
        #expect(facts["lantern"]?.addedAt == Date(timeIntervalSince1970: 1_789_942_009))
        #expect(facts["lantern"]?.updatedAt == nil)
        #expect(facts["quill"] == PluginMarketplaceFacts(installRefusal: "quill needs Hermes >=0.30.0; this is 0.22.6."))
        #expect(DirectHermesPluginMarketplaceClient.facts(from: ["entries": .array([])]) == nil)

        let host = UpdateHost(answer: .addsTools)
        let snapshot = try await host.client(marketplace: FixedMarketplace(facts)).load()
        #expect(snapshot.catalog.first { $0.name == "lantern" }?.marketplace.stars == 4_120)
        #expect(snapshot.catalog.first { $0.name == "quill" }?.marketplace.installRefusal != nil)
    }

    @Test func theFeaturedPickRotatesWeeklyLikeTheMarketplace() {
        let catalog = [
            entry("tidy", tier: "community", facts: .init(stars: 90)),
            entry("lantern", tier: "official", facts: .init(stars: 4_120, featuredRank: 1)),
            entry("quill", tier: "community", image: true, facts: .init(stars: 860, featuredRank: 3)),
            entry("moss", tier: "official", facts: .init(stars: 4_120, featuredRank: 2)),
        ]
        // Hermes' featuredPicks: floor(now / week) % picks picks this week's first slide.
        let week: TimeInterval = 7 * 24 * 60 * 60
        let picks = ["lantern", "moss", "quill"]
        for weekIndex in 2_900..<2_906 {
            let now = Date(timeIntervalSince1970: Double(weekIndex) * week + 3_600)
            let storefront = PluginStorefront(catalog: catalog, now: now)
            #expect(storefront.hero?.name == picks[weekIndex % 3], "week \(weekIndex)")
            #expect(storefront.heroIsFeatured)
        }
        // A featured community plugin's banner shows in lists: Nous picked it.
        #expect(catalog[2].listedImageURL != nil)
        #expect(entry("art", tier: "community", image: true).listedImageURL == nil)

        // Without the marketplace's picks, the app's own official pick, as before.
        let plain = PluginStorefront(catalog: [entry("tidy", tier: "community"), entry("wiki", tier: "official")])
        #expect(plain.hero?.name == "wiki")
        #expect(!plain.heroIsFeatured)
        #expect(plain.popular.isEmpty && plain.recent.isEmpty)
    }

    @Test func popularGoesByStarsAndNewByTheLast30Days() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let storefront = PluginStorefront(catalog: [
            entry("old-big", tier: "community", facts: .init(stars: 68_000, addedAt: now - 300 * day)),
            entry("fresh", tier: "community", facts: .init(stars: 12, addedAt: now - 2 * day)),
            entry("starless", tier: "community", facts: .init(addedAt: now - 29 * day)),
            entry("mid", tier: "official", facts: .init(stars: 4_120, addedAt: now - 31 * day)),
            entry("gone", tier: "community", facts: .init(stars: 99_000, addedAt: now - day), removed: true),
        ], now: now)
        #expect(storefront.popular.map(\.name) == ["old-big", "mid", "fresh"])
        #expect(storefront.recent.map(\.name) == ["fresh", "starless"])
    }

    private func entry(_ name: String, tier: String, image: Bool = false,
                       facts: PluginMarketplaceFacts = .init(), removed: Bool = false) -> PluginCatalogEntry {
        var entry = PluginCatalogEntry(
            name: name, repository: "https://example.com/\(name)", commitSHA: String(repeating: "a", count: 40),
            summary: "", maintainer: "Example", tier: tier, requiredHermesVersion: "", documentationURL: nil,
            platforms: [], capabilities: .init(tools: [], hooks: [], middleware: [], requiredEnvironment: []),
            isInstalled: false, installedSHA: nil, updateAvailable: false, runtimeStatus: nil,
            removedReason: removed ? "Removed." : nil, category: "tools",
            imageURL: image ? URL(string: "https://example.com/\(name).png") : nil)
        entry.marketplace = facts
        return entry
    }
}

@MainActor
private final class FixedMarketplace: PluginMarketplaceReading {
    let facts: [String: PluginMarketplaceFacts]
    init(_ facts: [String: PluginMarketplaceFacts]) { self.facts = facts }
    func plugins() async -> [String: PluginMarketplaceFacts]? { facts }
}

/// One installed git plugin ("lantern") and one more in the catalog ("quill"), answered like Hermes'
/// dashboard: an update asks first (`consent_required`, or `scan_blocked` with findings) and applies
/// when the retry carries the yes; an install refused here answers 400 with Hermes' words.
@MainActor
private final class UpdateHost: DirectHermesAuthenticatedHTTP {
    enum Answer { case addsTools, scan(verdict: String) }

    let answer: Answer
    let installRefusal: String?
    private(set) var updateBodies: [[String: BighelpJSONValue]?] = []
    private let owner = WorkspaceOwner(authority: try! .fixture(id: "plugin-marketplace"),
                                       authenticationGeneration: UUID(), connectionGeneration: UUID())

    init(answer: Answer, installRefusal: String? = nil) {
        self.answer = answer
        self.installRefusal = installRefusal
    }

    func client(marketplace: (any PluginMarketplaceReading)? = nil) -> DirectHermesPluginLifecycleClient {
        let owner = owner
        return DirectHermesPluginLifecycleClient(http: self, owner: owner, currentOwner: { owner },
                                                 marketplace: marketplace)
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        switch (request.method, request.path) {
        case (.get, "/api/dashboard/plugins/hub"):
            return .object(["plugins": .array([.object([
                "name": .string("lantern"), "version": .string("1.0.0"), "description": .string("Lights the way."),
                "source": .string("git"), "runtime_status": .string("enabled"), "can_remove": .boolean(true),
                "can_update_git": .boolean(true), "auth_required": .boolean(false), "auth_command": .string(""),
                "removed_reason": .null,
            ])])])
        case (.get, "/api/dashboard/plugins/catalog"):
            return .object(["entries": .array([row("lantern", installed: true), row("quill", installed: false)]),
                            "removed": .array([])])
        case (.post, "/api/dashboard/agent-plugins/install"):
            // What `DirectHermesHTTP.pluginChangeRefusal` makes of Hermes' 400 with this `detail`.
            if let installRefusal { throw DirectHermesError.rpcRejected(code: 400, message: .init(installRefusal)) }
            throw WorkspaceClientError.invalidRequest
        case (.post, "/api/dashboard/agent-plugins/lantern/update"):
            updateBodies.append(request.body)
            switch answer {
            case .addsTools where request.body?["accept_capabilities"]?.boolean != true:
                return .object([
                    "ok": .boolean(false), "consent_required": .boolean(true), "name": .string("lantern"),
                    "sha": .string(String(repeating: "d", count: 40)),
                    "error": .string("Updating 'lantern' to dddddddd adds tools: lantern_export. Confirm to continue."),
                    "delta": .object(["tools": .array([.string("lantern_export")])]),
                    "delta_lines": .array([.string("tools: lantern_export")]),
                ])
            case .scan(let verdict) where request.body?["force"]?.boolean != true || verdict != "caution":
                return .object([
                    "ok": .boolean(false), "scan_blocked": .boolean(true), "scan_verdict": .string(verdict),
                    "error": .string("The security scan found issues."), "name": .string("lantern"),
                    "scan_findings": .array([.object([
                        "pattern_id": .string("net-download"), "severity": .string("medium"),
                        "category": .string("network"), "file": .string("tools/export.py"), "line": .integer(12),
                        "description": .string("Downloads a file from the web."),
                    ])]),
                ])
            default:
                return .object(["ok": .boolean(true), "name": .string("lantern"), "unchanged": .boolean(false)])
            }
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }

    private func row(_ name: String, installed: Bool) -> BighelpJSONValue {
        .object([
            "name": .string(name), "repo": .string("https://example.com/\(name)"),
            "sha": .string(String(repeating: "c", count: 40)), "description": .string("Does a thing."),
            "maintainer": .string("Example"), "tier": .string("community"), "docs_url": .string(""),
            "requires_hermes": .string(""), "platforms": .array([]),
            "capabilities": .object([
                "provides_tools": .array([]), "provides_hooks": .array([]),
                "provides_middleware": .array([]), "requires_env": .array([]),
            ]),
            "installed": .boolean(installed), "update_available": .boolean(installed),
        ])
    }
}
