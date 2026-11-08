import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ProviderUsageTests {
    /// The plugin contract's sample, plus things an older or newer plugin might send.
    private let sample: [String: BighelpJSONValue] = [
        "agentId": .string("default"),
        "fetchedAt": .string("2026-09-27T20:00:00Z"),
        "cached": .boolean(true),
        "futureField": .string("ignored"),
        "providers": .array([
            .object([
                "id": .string("claude"), "name": .string("Claude"), "status": .string("ok"),
                "plan": .string("Pro"), "detectedVia": .array([.string("cli")]), "activeInHermes": .boolean(false),
                "windows": .array([.object(["label": .string("Session (5 hours)"), "usedPercent": .number(142),
                                            "resetsAt": .string("2026-09-27T23:00:00Z"), "detail": .null])]),
                "facts": .array([]), "manageUrl": .string("https://claude.ai/settings/usage"), "approximate": .boolean(false),
            ]),
            .object([
                "id": .string("openrouter"), "name": .string("OpenRouter"), "status": .string("ok"),
                "activeInHermes": .boolean(true),
                "facts": .array([.object(["label": .string("Balance"), "value": .string("$25.00")])]),
                "manageUrl": .string("http://not-https.example.com"),
            ]),
            .object(["id": .string("hermes-xai"), "name": .string("xAI"), "status": .string("somethingNew"),
                     "message": .string("New status")]),
            .object(["name": .string("No id")]),
        ]),
    ]

    @Test func decodesTolerantlyAndClampsPercentages() throws {
        let report = try ProviderUsageReport(json: sample)
        #expect(report.agentID == "default" && report.cached)
        #expect(report.fetchedAt == ISO8601DateFormatter().date(from: "2026-09-27T20:00:00Z"))
        #expect(report.providers.map(\.id) == ["claude", "openrouter", "hermes-xai"], "A row without an id is skipped")
        let claude = report.providers[0]
        #expect(claude.windows.first?.usedPercent == 100)
        #expect(claude.windows.first?.leftPercent == 0)
        #expect(claude.windows.first?.detail == nil)
        #expect(claude.manageURL?.absoluteString == "https://claude.ai/settings/usage")
        #expect(report.providers[1].manageURL == nil, "Only https links open")
        #expect(report.providers[1].facts == [.init(label: "Balance", value: "$25.00")])
        #expect(report.providers[2].status == .error, "Unknown statuses read as errors with their message")
        #expect(report.providers[2].message == "New status")
        #expect(throws: WorkspaceClientError.self) { try ProviderUsageReport(json: ["providers": .string("nope")]) }
    }

    @Test func activeProviderComesFirstAndHiddenOnesAreLeftOut() throws {
        let providers = try ProviderUsageReport(json: sample).providers
        #expect(ProviderUsagePresentation.visible(providers, hidden: [], order: []).map(\.id)
                == ["openrouter", "claude", "hermes-xai"])
        #expect(ProviderUsagePresentation.visible(providers, hidden: ["claude"], order: []).map(\.id)
                == ["openrouter", "hermes-xai"])
        let hidden: Set<String> = ["b", "a"]
        #expect(ProviderUsagePreferences.hidden(ProviderUsagePreferences.raw(hidden)) == hidden)
        #expect(ProviderUsagePreferences.hidden("").isEmpty, "Nothing saved shows every provider")
    }

    /// Usage › Limits › Choose: the person's order wins, by provider, so it holds when the host names a
    /// provider differently; a provider set up later goes after the ones they placed.
    @Test func providersFollowTheOrderThePersonChose() throws {
        let providers = try ProviderUsageReport(json: sample).providers
        let order = ProviderUsagePreferences.moving(providers, from: [2], to: 0)
        let raw = ProviderUsagePreferences.raw(order: order)
        #expect(ProviderUsagePresentation.visible(providers, hidden: [], order: ProviderUsagePreferences.order(raw))
                    .map(\.id) == ["hermes-xai", "claude", "openrouter"])
        // Only one placed: it leads, the others keep their usual order after it.
        #expect(ProviderUsagePresentation.visible(providers, hidden: [], order: [order[0]]).map(\.id)
                == ["hermes-xai", "openrouter", "claude"])
        #expect(ProviderUsagePresentation.visible(providers, hidden: ["claude"], order: order).map(\.id)
                == ["hermes-xai", "openrouter"])
        #expect(ProviderUsagePreferences.order("xai\nxai\nclaude") == ["xai", "claude"], "Each provider once")
    }

    /// Hidden providers came back after updates: the host names one provider differently
    /// depending on where it found the sign-in and which agent asks. Choices hold per provider.
    @Test func aHiddenProviderStaysHiddenWhenTheHostRenamesIt() throws {
        let saved = ProviderUsagePreferences.hidden(ProviderUsagePreferences.raw(
            [ProviderUsagePreferences.key(for: "codex"), ProviderUsagePreferences.key(for: "hermes-openrouter")]))
        for id in ["codex", "codex-hermes", "openrouter", "hermes-openrouter"] {
            #expect(ProviderUsagePreferences.isHidden(id, in: saved), "\(id)")
        }
        #expect(!ProviderUsagePreferences.isHidden("claude", in: saved))
        // Choices saved by earlier builds, under the exact id, still count.
        let earlier = ProviderUsagePreferences.hidden("codex-hermes\nhermes-xai")
        #expect(ProviderUsagePreferences.isHidden("codex", in: earlier))
        #expect(ProviderUsagePreferences.isHidden("hermes-xai", in: earlier))
        #expect(ProviderUsagePreferences.isHidden("xai", in: earlier))
        // The saved key never changes, or every choice would be lost on update.
        #expect(ProviderUsagePreferences.hiddenKey == "bighelp.provider-usage.hidden")
    }

    @Test func resetAndUpdatedTimesReadNaturally() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ProviderUsagePresentation.resetText(now.addingTimeInterval(3 * 3_600 + 12 * 60), now: now) == "Resets in 3 h 12 min")
        #expect(ProviderUsagePresentation.resetText(now.addingTimeInterval(2 * 3_600), now: now) == "Resets in 2 h")
        #expect(ProviderUsagePresentation.resetText(now.addingTimeInterval(20), now: now) == "Resets in 1 min")
        #expect(ProviderUsagePresentation.resetText(now.addingTimeInterval(3 * 86_400), now: now) == "Resets in 3 days")
        #expect(ProviderUsagePresentation.resetText(now.addingTimeInterval(-5), now: now) == "Resets soon")
        #expect(ProviderUsagePresentation.resetText(nil, now: now) == nil)
        #expect(ProviderUsagePresentation.updatedText(now.addingTimeInterval(-20), now: now) == "Updated just now")
        #expect(ProviderUsagePresentation.updatedText(now.addingTimeInterval(-180), now: now) == "Updated 3 min ago")
    }

    @Test func pluginIDsMapToTheirBrandLogos() {
        #expect(ProviderUsagePresentation.logoProviderID("codex-hermes") == "codex")
        #expect(ProviderUsagePresentation.logoProviderID("hermes-xai") == "xai")
        #expect(AIProviderBrandRegistry.resolve(id: "claude", name: "Claude") == .claude)
        #expect(AIProviderBrandRegistry.resolve(id: "codex", name: "Codex") == .codex)
        #expect(AIProviderBrandRegistry.resolve(id: "copilot", name: "GitHub Copilot") == .githubCopilot)
        #expect(AIProviderBrandRegistry.resolve(id: "gemini", name: "Google AI Studio") == .google)
    }

    @Test func olderPluginAskForAnUpdateAndFailuresKeepTheLastResult() async throws {
        let client = ScriptedUsageClient()
        let store = ProviderUsageStore()
        store.configure(client: client)
        #expect(store.isAvailable)

        client.result = .failure(WorkspaceClientError.unavailable(.unsupportedOperation))
        await store.load(refresh: false)
        #expect(store.state == .needsPluginUpdate)

        client.result = .success(try ProviderUsageReport(json: sample))
        await store.load(refresh: false)
        #expect(store.state == .loaded && store.report?.providers.count == 3)

        client.result = .failure(WorkspaceClientError.transportUnavailable)
        await store.load(refresh: true)
        #expect(store.report?.providers.count == 3, "The last result stays on screen")
        #expect(store.state == .unavailable("Couldn't refresh. Showing the last result."))
        #expect(!store.isRefreshing)
        #expect(client.refreshes == [false, false, true])

        store.configure(client: nil)
        #expect(!store.isAvailable && store.report == nil)
    }

    /// bighelp reconnects every time you come back to it. The same computer and
    /// sign-in keeps the usage already on screen; another one starts over.
    @Test func aReconnectKeepsTheLastResultAndAnotherSignInStartsOver() async throws {
        let client = ScriptedUsageClient()
        client.result = .success(try ProviderUsageReport(json: sample))
        let store = ProviderUsageStore()
        store.configure(client: client, scope: "host-a")
        await store.load(refresh: false)
        #expect(store.report != nil)

        store.configure(client: ScriptedUsageClient(), scope: "host-a")
        #expect(store.report?.providers.count == 3 && store.state == .loaded)
        await store.load(refresh: false)
        #expect(client.refreshes == [false, false], "The first client, which follows the connection, stays")

        store.configure(client: ScriptedUsageClient(), scope: "host-b")
        #expect(store.report == nil && store.state == .idle)
    }

    /// Opening usage from a chat after the app came back used the connection
    /// from before, which is closed, so it failed every time.
    @Test func theHostClientFollowsTheCurrentConnection() async throws {
        let before = try UsagePerformer(sample: sample)
        var current: UsagePerformer? = before
        let client = DirectHermesProviderUsageClient(currentWorkspace: { current })

        let reconnected = try UsagePerformer(sample: sample, signIn: before.owner?.signIn)
        current = reconnected
        before.owner = nil
        let report = try await client.usage(agentID: "default", refresh: false)
        #expect(report.providers.count == 3)
        #expect(reconnected.calls == 1 && before.calls == 0)
    }

    /// The home screen hands the panel its client, and a chat covering it kept
    /// the first one after the sign-in changed (at launch, or another host):
    /// "Usage couldn't be loaded" until the chat closed. The panel follows the
    /// current sign-in and starts over for it, so one host's numbers never show
    /// as another's.
    @Test func anotherSignInLoadsItsOwnUsageInsteadOfFailing() async throws {
        var current: UsagePerformer? = try UsagePerformer(sample: sample)
        let store = ProviderUsageStore()
        let client = DirectHermesProviderUsageClient(currentWorkspace: { current })
        store.configure(client: client, scope: current?.owner?.signIn)
        await store.load(refresh: false)
        #expect(store.state == .loaded)

        current = try UsagePerformer(sample: ["providers": .array([sample["providers"]!.array!.first!])])
        await store.load(refresh: false)
        #expect(store.state == .loaded, "The new sign-in's usage loads")
        #expect(store.report?.providers.count == 1, "Only the new sign-in's numbers show")
    }

    /// Hermes doesn't know the chat's agent (deleted, or not a Hermes profile):
    /// the host's usage is the same for every agent, so it asks for the default.
    @Test func anAgentHermesDoesntKnowFallsBackToTheDefaultAgent() async throws {
        let performer = try UsagePerformer(sample: sample)
        performer.unknownAgents = ["sage"]
        let client = DirectHermesProviderUsageClient(currentWorkspace: { performer })
        let report = try await client.usage(agentID: "sage", refresh: false)
        #expect(report.providers.count == 3)
        #expect(performer.agents == ["sage", "default"])
    }

    /// A dropped connection or a slow answer gets one more try once the
    /// connection is back, instead of a dead end.
    @Test func aConnectionHiccupIsTriedOnceMore() async throws {
        let performer = try UsagePerformer(sample: sample)
        performer.failures = [WorkspaceClientError.transportUnavailable]
        let client = DirectHermesProviderUsageClient(currentWorkspace: { performer }, reconnectWait: .milliseconds(10))
        let report = try await client.usage(agentID: "default", refresh: false)
        #expect(report.providers.count == 3 && performer.calls == 2)
    }

    /// The message says what went wrong, in plain words.
    @Test(arguments: [
        (WorkspaceClientError.authenticationRequired as any Error, "turned down bighelp's sign-in"),
        (DirectHermesError.timedOut(outcomeUnknown: false) as any Error, "took too long"),
        (WorkspaceClientError.transportUnavailable as any Error, "isn't connected"),
        (WorkspaceClientError.invalidResponse as any Error, "couldn't be loaded"),
    ])
    func failuresSayWhy(error: any Error, words: String) async {
        let client = ScriptedUsageClient()
        client.result = .failure(error)
        let store = ProviderUsageStore()
        store.configure(client: client)
        await store.load(refresh: false)
        guard case .unavailable(let message) = store.state else { Issue.record("Not unavailable"); return }
        #expect(message.contains(words), "\(message)")
    }

    /// Right after the app comes back the connection is still on its way.
    @Test func theHostClientWaitsForTheConnectionToComeBack() async throws {
        let performer = try UsagePerformer(sample: sample)
        var current: UsagePerformer?
        let client = DirectHermesProviderUsageClient(currentWorkspace: { current },
                                                     reconnectWait: .milliseconds(20), reconnectAttempts: 50)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            current = performer
        }
        let report = try await client.usage(agentID: "default", refresh: false)
        #expect(report.providers.count == 3 && performer.calls == 1)
    }
}

@MainActor
private final class UsagePerformer: WorkspaceOperationPerforming {
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
    private let sample: [String: BighelpJSONValue]
    private(set) var calls = 0
    private(set) var agents: [String] = []
    var unknownAgents: Set<String> = []
    var failures: [any Error] = []

    init(sample: [String: BighelpJSONValue], signIn: WorkspaceSignIn? = nil) throws {
        self.sample = sample
        owner = WorkspaceOwner(authority: try signIn?.authority ?? .fixture(id: UUID().uuidString),
                               authenticationGeneration: signIn?.authenticationGeneration ?? UUID(),
                               connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        guard owner == self.owner, operation == .usageList else { throw WorkspaceClientError.ownerChanged }
        calls += 1
        let agent = payload["agentId"]?.string ?? ""
        agents.append(agent)
        if !failures.isEmpty { throw failures.removeFirst() }
        if unknownAgents.contains(agent) { throw WorkspaceClientError.rejected(code: "profile_not_found") }
        return sample
    }
}

@MainActor
private final class ScriptedUsageClient: ProviderUsageClient {
    var result: Result<ProviderUsageReport, any Error> = .failure(WorkspaceClientError.invalidResponse)
    var refreshes: [Bool] = []
    var currentScope: AnyHashable? { nil }
    func usage(agentID: String, refresh: Bool) async throws -> ProviderUsageReport {
        refreshes.append(refresh)
        return try result.get()
    }
}
