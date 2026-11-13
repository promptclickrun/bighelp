import CryptoKit
import Foundation
import Testing
@testable import Bighelp

/// A bot's Core Files through the plugin's `core-files/*` routes, answered as the plugin does: the list, a read
/// that keeps the file's hash, and a save that sends it so the computer never overwrites a newer file.
@MainActor
struct CoreFilesTests {
    @Test func theListReadsLenientlyAndNamesAgentsMdsProject() async throws {
        let host = try CoreFilesHost()
        let files = try await host.client().list()
        #expect(files.map(\.kind) == [.soul, .user, .memory, .agents], "A kind this build doesn't know is left out")
        #expect(files.map(\.exists) == [true, true, false, true])
        #expect(files.last?.project == "Garden")
        #expect(files.last?.detail(botName: "Lantern") == "Rules for the Garden project")
        #expect(host.payloads.first?["profile"] == .string("lantern"))
    }

    @Test func aSaveSendsTheHashItReadAndANewFileSendsNone() async throws {
        let host = try CoreFilesHost()
        let client = host.client()

        let soul = try await client.read("SOUL.md")
        #expect(soul.text == "You are Lantern.")
        #expect(soul.isEditable)
        try await client.write("SOUL.md", text: "You are Lantern, a calm helper.")
        #expect(host.writes.last?["expectedSha256"] == .string(CoreFilesHost.hash("You are Lantern.")))
        #expect(host.writes.last?["text"] == .string("You are Lantern, a calm helper."))
        // The next save is based on what the computer now holds.
        try await client.write("SOUL.md", text: "Again.")
        #expect(host.writes.last?["expectedSha256"] == .string(CoreFilesHost.hash("You are Lantern, a calm helper.")))

        _ = try await client.read("MEMORY.md")
        try await client.write("MEMORY.md", text: "Waters on Sundays.")
        #expect(host.writes.last?["expectedSha256"] == .null, "A file that wasn't there is saved as new")

        await #expect(throws: WorkspaceClientError.self, "A save needs a read first") {
            try await client.write("USER.md", text: "x")
        }
        await #expect(throws: WorkspaceClientError.self, "Only the four files") {
            _ = try await client.read("config.yaml")
        }
    }

    /// AGENTS.md is the one Hermes loads for the chat (its folder), so each request names the chat when the
    /// app has one; older plugins refuse the field, so there's none without one.
    @Test func requestsNameTheChatWhoseAgentsMdToShow() async throws {
        let host = try CoreFilesHost()
        _ = try await DirectHermesCoreFilesClient(agentID: "lantern", sessionID: "local-7f3a") { [weak host] in host }.list()
        #expect(host.payloads.last?["sessionId"] == .string("local-7f3a"))
        _ = try await host.client().list()
        #expect(host.payloads.last?["sessionId"] == nil)
    }

    /// A bot's Active Project page reads and chooses in a store of its own: the shell's Projects keep theirs.
    @Test func aBotsActiveProjectNeverMovesTheShellsProjects() async {
        let shell = HermesWorkspaceStore(client: FixtureHermesWorkspaceClient())
        await shell.load(agentID: "atlas")
        let bot = shell.separateStore()
        await bot.load(agentID: "lantern")
        #expect(await bot.select(id: "home", agentID: "lantern"))
        #expect(bot.catalog?.activeWorkspaceID == "home")
        #expect(shell.catalogAgentID == "atlas")
        #expect(shell.catalog?.activeWorkspaceID == "loopdy")
    }

    @Test func theMarketplaceHoldsTheSkillsHubMCPServersAndPluginsNotAdvancedOptions() {
        let pages = AdvancedOptionsCatalog.groups.flatMap(\.rows).compactMap { row -> AdvancedPage? in
            if case .page(let page) = row { return page }
            return nil
        }
        #expect(!pages.contains(.skillsHub) && !pages.contains(.toolServers) && !pages.contains(.plugins))
        #expect(MarketplaceSection.allCases == [.skills, .plugins, .mcp, .messaging, .toolsets])
    }
}

/// Answers `core-files/*` as the plugin does, keeping the files it was given.
@MainActor
private final class CoreFilesHost: WorkspaceOperationPerforming {
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
    private(set) var payloads: [[String: BighelpJSONValue]] = []
    private(set) var writes: [[String: BighelpJSONValue]] = []
    private var files: [String: String] = ["soul": "You are Lantern.", "user": "Likes short answers.",
                                           "agents": "# Garden rules"]

    init() throws {
        owner = WorkspaceOwner(authority: try .fixture(id: UUID().uuidString),
                               authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func client() -> DirectHermesCoreFilesClient {
        DirectHermesCoreFilesClient(agentID: "lantern") { [weak self] in self }
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        guard owner == self.owner else { throw WorkspaceClientError.ownerChanged }
        payloads.append(payload)
        let kind = payload["kind"]?.string ?? ""
        switch operation {
        case .coreFilesList:
            return ["files": .array([
                .object(["kind": .string("soul"), "name": .string("SOUL.md"), "exists": .boolean(true)]),
                .object(["kind": .string("user"), "name": .string("USER.md"), "exists": .boolean(true)]),
                .object(["kind": .string("memory"), "name": .string("MEMORY.md"), "exists": .boolean(false)]),
                .object(["kind": .string("agents"), "name": .string("AGENTS.md"), "exists": .boolean(true),
                         "project": .string("Garden")]),
                .object(["kind": .string("heartbeat"), "name": .string("HEARTBEAT.md"), "exists": .boolean(true)]),
            ])]
        case .coreFilesRead:
            let text = files[kind]
            return ["kind": .string(kind), "exists": .boolean(text != nil), "text": .string(text ?? ""),
                    "truncated": .boolean(false), "sha256": text.map { .string(Self.hash($0)) } ?? .null]
        case .coreFilesWrite:
            writes.append(payload)
            let expected = payload["expectedSha256"]?.string
            guard expected == files[kind].map(Self.hash) else { throw WorkspaceClientError.conflict }
            let text = payload["text"]?.string ?? ""
            files[kind] = text
            return ["kind": .string(kind), "exists": .boolean(true), "text": .string(text),
                    "truncated": .boolean(false), "sha256": .string(Self.hash(text))]
        default:
            throw WorkspaceClientError.invalidRequest
        }
    }
}
