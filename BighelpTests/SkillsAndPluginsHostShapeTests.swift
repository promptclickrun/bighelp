import Foundation
import Testing
@testable import Bighelp

/// Skills Hub and Plugins showed "Hermes returned an unsupported response" on
/// stock hosts: a skill without a category (`null`) or one catalog plugin with a
/// long description refused the whole page. Building the plugin list can also
/// take a busy host longer than an ordinary request's 20 seconds.
@MainActor
struct SkillsAndPluginsHostShapeTests {
    @Test func skillsHubShowsASkillWithoutACategory() async throws {
        let owner = try Self.owner()
        let client = DirectHermesSkillsHubClient(
            http: SkillsHost(), owner: owner, profileID: "default", currentOwner: { owner }
        )

        let snapshot = try await client.load()

        #expect(snapshot.installedSkills.map(\.name) == ["notes", "scratch"])
        #expect(snapshot.installedSkills.first { $0.name == "scratch" }?.category == "")
        #expect(snapshot.official.map(\.name) == ["planner"])
    }

    @Test func pluginsShortensALongDescriptionAndHidesOnlyAnOddRow() async throws {
        let owner = try Self.owner()
        let client = DirectHermesPluginLifecycleClient(http: PluginsHost(), owner: owner, currentOwner: { owner })

        let snapshot = try await client.load()

        #expect(snapshot.installed.map(\.name) == ["bundled-tool"])
        #expect(snapshot.catalog.map(\.name) == ["short", "wordy"])
        let wordy = try #require(snapshot.catalog.last)
        #expect(wordy.summary.count == CapabilitiesPayload.summaryCharacterLimit + 1)
        #expect(wordy.summary.hasSuffix("…"))
    }

    @Test func pluginsWaitsForASlowHost() async throws {
        let owner = try Self.owner()
        let host = PluginsHost(secondsToBuildList: 26)
        let client = DirectHermesPluginLifecycleClient(http: host, owner: owner, currentOwner: { owner })

        let snapshot = try await client.load()

        #expect(snapshot.installed.count == 1)
    }

    private static func owner() throws -> WorkspaceOwner {
        WorkspaceOwner(
            authority: try .direct(endpointIdentity: "https://hermes.example", providerID: "basic", userID: "person"),
            authenticationGeneration: UUID(), connectionGeneration: UUID()
        )
    }
}

/// Answers like stock Hermes: `/api/skills` sends `"category": null` for a skill
/// outside any category folder.
@MainActor
private final class SkillsHost: DirectHermesAuthenticatedHTTP {
    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        switch request.path {
        case "/api/skills/hub/sources":
            return .object([
                "sources": .array([.object(["id": .string("official"), "label": .string("Official"), "searchable": .boolean(true)])]),
                "index_available": .boolean(true),
                "featured": .array([]),
                "installed": .object([:]),
            ])
        case "/api/skills/hub/official":
            return .object(["skills": .array([.object([
                "name": .string("planner"), "description": .string("Plans the week."), "source": .string("official"),
                "identifier": .string("official/productivity/planner"), "trust_level": .string("builtin"),
                "repo": .string("example/skills"), "tags": .array([]), "category": .string("productivity"),
                "installed": .boolean(false),
            ])])])
        case "/api/skills":
            return .array([
                .object([
                    "name": .string("notes"), "description": .string("Keeps notes."), "category": .string("productivity"),
                    "enabled": .boolean(true), "usage": .integer(3), "provenance": .string("bundled"),
                ]),
                .object([
                    "name": .string("scratch"), "description": .string("Made by the agent."), "category": .null,
                    "enabled": .boolean(true), "usage": .integer(1), "provenance": .string("agent"),
                ]),
            ])
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }
}

/// Answers like stock Hermes' plugin hub and curated catalog. With
/// `secondsToBuildList`, the hub answers that late, so a request that gives up
/// sooner times out the way URLSession does.
@MainActor
private final class PluginsHost: DirectHermesAuthenticatedHTTP {
    private let secondsToBuildList: TimeInterval

    init(secondsToBuildList: TimeInterval = 0) {
        self.secondsToBuildList = secondsToBuildList
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        switch request.path {
        case "/api/dashboard/plugins/hub":
            guard request.timeout > secondsToBuildList else { throw URLError(.timedOut) }
            return .object(["plugins": .array([.object([
                "name": .string("bundled-tool"), "version": .string("1.0.0"), "description": .string("A bundled tool."),
                "source": .string("bundled"), "runtime_status": .string("enabled"), "dashboard_manifest": .null,
                "can_remove": .boolean(false), "can_update_git": .boolean(false),
                "auth_required": .boolean(false), "auth_command": .string(""), "removed_reason": .null,
            ])])])
        case "/api/dashboard/plugins/catalog":
            return .object([
                "entries": .array([
                    Self.entry(name: "short", description: "Does one thing."),
                    Self.entry(name: "wordy", description: String(repeating: "Long words. ", count: 1_000)),
                    Self.entry(name: "odd", description: "", sha: "main"),
                ]),
                "removed": .array([]),
                "generated_at": .string("2026-01-01T00:00:00Z"),
            ])
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }

    private static func entry(name: String, description: String,
                              sha: String = String(repeating: "a", count: 40)) -> BighelpJSONValue {
        .object([
            "name": .string(name), "repo": .string("https://github.com/example/\(name)"), "sha": .string(sha),
            "description": .string(description), "maintainer": .string("Example"), "tier": .string("community"),
            "docs_url": .string(""), "requires_hermes": .string(""), "platforms": .array([]),
            "capabilities": .object([
                "provides_tools": .array([]), "provides_hooks": .array([]),
                "provides_middleware": .array([]), "requires_env": .array([]),
            ]),
            "installed": .boolean(false), "update_available": .boolean(false),
        ])
    }
}
