import Foundation
import Testing
@testable import Bighelp

@MainActor
struct WorkspaceManagementTests {
    @Test func retiredAppDestinationsStayOutOfTheWorkspaceMenu() {
        #expect(WorkspaceDestination.allCases.contains(.wiki))
        #expect(!WorkspaceDestination.appMenuCases.contains(.wiki))
        #expect(!WorkspaceDestination.appMenuCases.contains(.tasks))
        #expect(!WorkspaceDestination.appMenuCases.contains(.usage), "Usage has one page, in ☰")
        #expect(WorkspaceDestination.appMenuCases.contains(.scheduledTasks))
        #expect(WorkspaceDestination.appMenuCases.contains(.artifacts))
        // This app's own settings (look, permissions, Apple Watch…) live in Settings, not Hermes Tools.
        #expect(!WorkspaceDestination.appMenuCases.contains { $0.section == .app })
        #expect(WorkspaceDestination.appMenuCases.count
            == WorkspaceDestination.allCases.count - 3 - WorkspaceDestination.allCases.filter { $0.section == .app }.count)
        let visibleTitles = Set(WorkspaceDestination.appMenuCases.map(\.title))
        #expect(visibleTitles.isDisjoint(with: ["Scratchpad", "GitHub", "Wiki", "Tasks"]))
    }

    @Test func allRequestedDestinationsHaveOneGroupAndExistingFeaturesStayRouted() {
        #expect(Set(WorkspaceDestination.allCases).count == 33)
        #expect(WorkspaceDestination.skills.usesExistingDestination)
        #expect(WorkspaceDestination.voice.usesExistingDestination)
        #expect(WorkspaceDestination.artifacts.usesExistingDestination)
        #expect(WorkspaceDestination.tasks.usesExistingDestination)
        #expect(WorkspaceDestination.sessionMaintenance.usesExistingDestination)
        #expect(WorkspaceDestination.profileLifecycle.usesExistingDestination)
        #expect(!WorkspaceDestination.projects.usesExistingDestination)
        #expect(WorkspaceDestination.allCases.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty && !$0.symbol.isEmpty })
    }

    @Test func projectDecoderRejectsDuplicatesAndMalformedArchiveState() throws {
        var project = projectPayload()
        #expect(try WorkspaceManagementDecoder.projects(["projects": .array([.object(project)])]).count == 1)
        #expect(throws: WorkspaceManagementError.invalidResponse) {
            try WorkspaceManagementDecoder.projects(["projects": .array([.object(project), .object(project)])])
        }
        project["archived"] = .string("false")
        #expect(throws: WorkspaceManagementError.invalidResponse) { try WorkspaceManagementDecoder.project(project) }
    }

    @Test func boundedCatalogRejectsOversizeAndAllowsAdditiveMetadata() throws {
        var project = projectPayload()
        project["future_metadata"] = .object(["secret": .string("fixture-not-rendered")])
        #expect(try WorkspaceManagementDecoder.project(project).name == "Research")
        project["name"] = .string(String(repeating: "a", count: 201))
        #expect(throws: WorkspaceManagementError.invalidResponse) { try WorkspaceManagementDecoder.project(project) }
        #expect(throws: WorkspaceManagementError.invalidResponse) {
            try WorkspaceManagementDecoder.rows(.array(Array(repeating: .null, count: 1_001)))
        }
    }

    @Test func fileBrowserUsesThePolicyPublishedByTheDirectHost() throws {
        var payload = filesPayload()
        payload["locked_root"] = .null
        payload["root"] = .null
        payload["can_change_path"] = .boolean(true)
        let listing = try WorkspaceManagementDecoder.files(payload, expectedPath: nil, expectedRoot: nil)
        #expect(listing.root == "/")
        #expect(listing.path == "/workspace")
    }

    @Test func fileBrowserRejectsSiblingRootTraversalAndChangedPolicy() throws {
        #expect(!WorkspaceManagementDecoder.contains(root: "/workspace", path: "/workspace-private/secret"))
        for path in ["/workspace/../secret", "/workspace/./secret", "/workspace//secret", "file:///workspace/a", "/workspace\\secret"] {
            #expect(throws: WorkspaceManagementError.invalidResponse) {
                try WorkspaceManagementDecoder.path(.string(path))
            }
        }
        #expect(throws: WorkspaceManagementError.fileRootNotConfined) {
            try WorkspaceManagementDecoder.files(filesPayload(), expectedPath: nil, expectedRoot: "/another")
        }
        var payload = filesPayload()
        payload["entries"] = .array([.object([
            "name": .string("secret"), "path": .string("/workspace-private/secret"),
            "is_directory": .boolean(false), "size": .integer(1)
        ])])
        #expect(throws: WorkspaceManagementError.invalidResponse) {
            try WorkspaceManagementDecoder.files(payload, expectedPath: nil, expectedRoot: nil)
        }
    }

    @Test func fileBrowserPreservesAliasesWithTheSameResolvedPath() throws {
        var payload = filesPayload()
        payload["entries"] = .array(["Documents", "Documents shortcut"].map { name in
            .object(["name": .string(name), "path": .string("/workspace/Documents"),
                     "is_directory": .boolean(true), "size": .null])
        })
        let listing = try WorkspaceManagementDecoder.files(payload, expectedPath: nil, expectedRoot: nil)
        #expect(listing.entries.count == 2)
        #expect(Set(listing.entries.map(\.id)).count == 2)
        #expect(listing.entries.allSatisfy { $0.path == "/workspace/Documents" })
        payload["entries"] = .array([payload["entries"]!.array![0], payload["entries"]!.array![0]])
        #expect(throws: WorkspaceManagementError.invalidResponse) {
            try WorkspaceManagementDecoder.files(payload, expectedPath: nil, expectedRoot: nil)
        }
    }

    @Test func filePreviewVerifiesPathRootExactBytesAndText() throws {
        var payload = filePayload()
        #expect(try WorkspaceManagementDecoder.file(payload, expectedPath: "/workspace/readme.txt", root: "/workspace").text == "hello")
        payload["size"] = .integer(6)
        #expect(throws: WorkspaceManagementError.filePreviewUnavailable) {
            try WorkspaceManagementDecoder.file(payload, expectedPath: "/workspace/readme.txt", root: "/workspace")
        }
        payload = filePayload()
        payload["data_url"] = .string("data:text/plain;base64,AAECAwQ=")
        #expect(throws: WorkspaceManagementError.filePreviewUnavailable) {
            try WorkspaceManagementDecoder.file(payload, expectedPath: "/workspace/readme.txt", root: "/workspace")
        }
    }

    @Test func logsNeverExposePromptCredentialsOrPaths() throws {
        let raw = "2026 ERROR secret-token=fixture-123 prompt=user private question /Users/example/private.txt"
        let result = try WorkspaceManagementDecoder.logs(["lines": .array([.string(raw)])])
        #expect(result == ["ERROR - Message withheld to protect private host data"])
        #expect(!result.joined().contains("fixture-123"))
        #expect(!result.joined().contains("/Users"))
    }

    @Test func keysIgnoreEvenUnexpectedRawSecretsAndMarkManagedKeysReadOnly() throws {
        var row = keyPayload()
        row["value"] = .string("fixture-secret-never-render")
        row["redacted_value"] = .string("fixture-secret-never-render")
        let result = try WorkspaceInventoryDecoder.keys(["EXAMPLE_API_KEY": .object(row)])
        #expect(result == [.init(id: "EXAMPLE_API_KEY", description: "Example", category: "Models", isSet: false, canReplace: true)])
        row["channel_managed"] = .boolean(true)
        #expect(try !WorkspaceInventoryDecoder.keys(["EXAMPLE_API_KEY": .object(row)])[0].canReplace)
    }

    @Test func memoryEndpointIsStatusNotAnInventedDocumentAPI() throws {
        let result = try WorkspaceInventoryDecoder.memory([
            "active": .string(""), "providers": .array([]),
            "builtin_files": .object(["memory": .integer(42), "user": .integer(9)]),
            "memory": .string("fixture-private-content")
        ])
        #expect(result[0].details[0].value == "42")
        #expect(!String(describing: result).contains("fixture-private-content"))
    }

    @Test func usageNullAggregateDoesNotBecomeFakeZero() throws {
        let result = try WorkspaceInventoryDecoder.usage([
            "period_days": .integer(30), "totals": .object(["total_input": .null]), "by_model": .array([])
        ])
        #expect(result[0].details.first?.value == "Not reported")
        #expect(throws: WorkspaceManagementError.invalidResponse) { try WorkspaceInventoryDecoder.number(.integer(-1)) }
    }

    @Test func clientSendsExactProfileAndNarrowConfigurationKey() async throws {
        let fixture = try Performer()
        fixture.responses[.configGet] = ["value": .string("medium"), "display": .string("show")]
        let client = makeClient(fixture)
        #expect(try await client.load(.config) == .configuration(.init(effort: .medium, showsReasoning: true)))
        #expect(fixture.calls.last?.payload == ["profile": .string("research"), "key": .string("reasoning")])
    }

    @Test func acceptsReleasedReasoningLevelsAndDisabledAliases() {
        #expect(WorkspaceReasoningConfiguration.Effort(hostValue: "max") == .max)
        #expect(WorkspaceReasoningConfiguration.Effort(hostValue: "ultra") == .ultra)
        #expect(WorkspaceReasoningConfiguration.Effort(hostValue: "disabled") == WorkspaceReasoningConfiguration.Effort.none)
        #expect(WorkspaceReasoningConfiguration.Effort(hostValue: "false") == WorkspaceReasoningConfiguration.Effort.none)
        #expect(WorkspaceReasoningConfiguration.Effort(hostValue: "unknown") == nil)
    }

    @Test func processRoutesUseTheSelectedHostWithoutRequiringAPluginProfile() async throws {
        let fixture = try Performer()
        fixture.responses[.memoryGet] = ["active": .string(""), "providers": .array([]), "builtin_files": .object([:])]
        fixture.responses[.webhooksList] = ["enabled": .boolean(false), "subscriptions": .array([])]
        fixture.responses[.logsList] = ["file": .string("agent"), "lines": .array([])]
        let client = makeClient(fixture, servingProfile: nil)
        for destination in [WorkspaceDestination.memory, .webhooks, .logs] { _ = try await client.load(destination) }
        #expect(fixture.calls.map(\.operation) == [.memoryGet, .webhooksList, .logsList])
        #expect(fixture.calls.allSatisfy { $0.payload["profile"] == nil })
        #expect(client.editableDestinations.contains(.webhooks))
    }

    @Test func nativeFilesDiscoverTheHostsDefaultWithoutAnExtraPluginOrClientRoot() async throws {
        let fixture = try Performer()
        fixture.responses[.filesList] = filesPayload()
        let client = makeClient(fixture)
        guard case .files(let listing) = try await client.load(.files) else { Issue.record("No files"); return }
        #expect(listing.root == "/workspace")
        #expect(fixture.calls.count == 1)
        #expect(fixture.calls.first?.payload == [:])
    }

    @Test func explicitNativeRootIsStillVerifiedByHostResponse() async throws {
        let fixture = try Performer()
        fixture.responses[.filesList] = filesPayload()
        let client = NativeWorkspaceManagementClient(owner: fixture.owner!, profileID: "research",
            configuredNativeFileRoot: "/workspace", performer: fixture, isCurrent: { true })
        guard case .files(let listing) = try await client.load(.files) else {
            Issue.record("Missing native files listing")
            return
        }
        #expect(listing.root == "/workspace")
        #expect(fixture.calls.last?.payload == ["path": .string("/workspace")])
    }

    @Test func replacedConnectionRejectsLateReadEvenWhenProfileMatches() async throws {
        let fixture = try Performer()
        fixture.responses[.projectsList] = ["projects": .array([.object(projectPayload())])]
        fixture.suspend = true
        let client = makeClient(fixture)
        let task = Task { try await client.load(.projects) }
        while fixture.continuation == nil { await Task.yield() }
        fixture.owner = try Performer.makeOwner()
        fixture.continuation?.resume()
        await #expect(throws: WorkspaceManagementError.staleOwner) { try await task.value }
    }

    @Test func mutationRequiresVerifiedCapabilityNotAReadOrPing() async throws {
        let fixture = try Performer()
        fixture.capabilities = .init(owner: fixture.owner)
        let client = makeClient(fixture)
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await client.apply(.archiveProject(id: "research", restore: false))
        }
        #expect(fixture.calls.isEmpty)
    }

    @Test func projectMutationRequiresMatchingAuthoritativeResult() async throws {
        let fixture = try Performer()
        var project = projectPayload()
        project["id"] = .string("wrong-project")
        project["archived"] = .boolean(true)
        fixture.responses[.projectsArchive] = ["projects": .array([.object(project)])]
        let client = makeClient(fixture)
        await #expect(throws: WorkspaceManagementError.unconfirmedMutation) {
            try await client.apply(.archiveProject(id: "research", restore: false))
        }
        #expect(fixture.calls.count == 1)
    }

    @Test func reasoningMutationChecksReceiptAndFreshRead() async throws {
        let fixture = try Performer()
        fixture.responses[.configSet] = ["key": .string("reasoning"), "value": .string("high")]
        fixture.responses[.configGet] = ["value": .string("medium"), "display": .string("show")]
        await #expect(throws: WorkspaceManagementError.unconfirmedMutation) {
            try await makeClient(fixture).apply(.reasoning(.high))
        }
        #expect(fixture.calls.map(\.operation) == [.configSet, .configGet])
    }

    @Test func failedRefreshPreservesReadButDisablesWrites() async {
        let client = FixtureWorkspaceManagementClient()
        let store = makeStore(client)
        await store.load(.projects)
        let oldContent = store.content
        client.failure = .invalidResponse
        await store.refresh()
        #expect(store.content == oldContent)
        #expect(store.errorMessage != nil)
        #expect(!store.canEdit)
    }

    @Test func fixtureMutationsAreReviewedAndRefreshed() async {
        let store = makeStore(FixtureWorkspaceManagementClient())
        await store.load(.projects)
        store.review = .archiveProject(id: "research", restore: false)
        await store.confirmReview()
        guard case .projects(let rows) = store.content else { Issue.record("Missing projects"); return }
        #expect(rows.first(where: { $0.id == "research" })?.isArchived == true)
        #expect(store.review == nil)
        #expect(store.successMessage != nil)
        #expect(!store.isSaving)
    }

    @Test func retirementClearsSensitiveStateAndCannotReload() async {
        let store = makeStore(FixtureWorkspaceManagementClient())
        await store.load(.keys)
        store.review = .replaceCredential(key: "EXAMPLE_API_KEY", value: "synthetic-secret")
        store.retire()
        await store.load(.keys)
        #expect(store.content == nil)
        #expect(store.review == nil)
        #expect(store.filePreview == nil)
        #expect(!store.ownsScope)
    }

    @Test func retiredStoreRejectsLateSnapshotAndSettlesLoading() async {
        let client = SuspendedManagementClient()
        let store = makeStore(client)
        let pending = Task { await store.load(.projects) }
        while client.continuation == nil { await Task.yield() }
        store.retire()
        client.continuation?.resume(returning: .projects([]))
        await pending.value
        #expect(store.content == nil)
        #expect(store.errorMessage == nil)
        #expect(!store.isLoading)
    }

    @Test func reviewForAnotherDestinationNeverExecutes() async {
        let store = makeStore(FixtureWorkspaceManagementClient())
        await store.load(.projects)
        store.review = .replaceCredential(key: "EXAMPLE_API_KEY", value: "fixture")
        await store.confirmReview()
        #expect(store.successMessage == nil)
        #expect(!store.isSaving)
    }

    @Test func changedReviewCannotConfirmADifferentIntent() async {
        let store = makeStore(FixtureWorkspaceManagementClient())
        await store.load(.config)
        let presented = WorkspaceManagementMutation.reasoning(.high)
        store.review = .reasoning(.low)
        await store.confirmReview(expected: presented)
        #expect(store.errorMessage != nil)
        #expect(store.review == nil)
        #expect(store.successMessage == nil)
        #expect(store.content == .configuration(.init(effort: .medium, showsReasoning: true)))
    }

    @Test func unsupportedCredentialReplacementNeverWrites() async throws {
        let fixture = try Performer()
        var row = keyPayload()
        row["channel_managed"] = .boolean(true)
        fixture.responses[.keysList] = ["EXAMPLE_API_KEY": .object(row)]
        await #expect(throws: (any Error).self) {
            try await makeClient(fixture).apply(.replaceCredential(key: "EXAMPLE_API_KEY", value: "fixture-secret"))
        }
        #expect(fixture.calls.map(\.operation) == [.keysList])
    }

    @Test func successfulKeyReplacementUsesPresenceReadbackWithoutReturningSecret() async throws {
        let fixture = try Performer()
        var row = keyPayload()
        row["is_set"] = .boolean(true)
        fixture.responses[.keysList] = ["EXAMPLE_API_KEY": .object(row)]
        fixture.responses[.keysSet] = ["ok": .boolean(true), "key": .string("EXAMPLE_API_KEY"), "config_updates": .array([])]
        let client = makeClient(fixture)
        try await client.apply(.replaceCredential(key: "EXAMPLE_API_KEY", value: "fixture-secret"))
        #expect(fixture.calls.map(\.operation) == [.keysList, .keysSet, .keysList])
        let readback = try await client.load(.keys)
        #expect(!String(describing: readback).contains("fixture-secret"))
    }

    @Test func localSearchAndPagingDoNotDiscardUnderlyingRows() async {
        let store = makeStore(FixtureWorkspaceManagementClient())
        await store.load(.projects)
        let before = store.content
        store.search = "RESEARCH"
        #expect(store.matches("Research"))
        #expect(!store.matches("Website"))
        store.loadMore()
        #expect(store.visibleLimit == 100)
        #expect(store.content == before)
    }

    @MainActor
    private final class SuspendedManagementClient: WorkspaceManagementClient {
        let editableDestinations: Set<WorkspaceDestination> = []
        var continuation: CheckedContinuation<WorkspaceManagementContent, any Error>?

        func load(_ destination: WorkspaceDestination, path: String?, root: String?) async throws -> WorkspaceManagementContent {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func apply(_ mutation: WorkspaceManagementMutation) async throws { throw WorkspaceManagementError.invalidInput }
        func previewFile(path: String, root: String) async throws -> WorkspaceFilePreview { throw WorkspaceManagementError.invalidInput }
    }

    private func makeClient(_ performer: Performer, servingProfile: String? = "research") -> NativeWorkspaceManagementClient {
        NativeWorkspaceManagementClient(owner: performer.owner!, profileID: "research",
            servingProfileID: servingProfile, performer: performer, isCurrent: { true })
    }

    private func makeStore(_ client: any WorkspaceManagementClient) -> WorkspaceManagementStore {
        .init(hostName: "Demo Hermes", profileName: "Research", client: client, isCurrent: { true })
    }

    private func projectPayload() -> [String: BighelpJSONValue] {
        ["id": .string("research"), "name": .string("Research"), "description": .null,
         "archived": .boolean(false), "folders": .array([])]
    }

    private func keyPayload() -> [String: BighelpJSONValue] {
        ["description": .string("Example"), "category": .string("Models"), "is_set": .boolean(false),
         "is_password": .boolean(true), "channel_managed": .boolean(false)]
    }

    private func filesPayload() -> [String: BighelpJSONValue] {
        ["path": .string("/workspace"), "parent": .null, "entries": .array([]),
         "root": .string("/workspace"), "locked_root": .string("/workspace"), "can_change_path": .boolean(false)]
    }

    private func filePayload() -> [String: BighelpJSONValue] {
        ["path": .string("/workspace/readme.txt"), "name": .string("readme.txt"), "size": .integer(5),
         "root": .string("/workspace"), "locked_root": .string("/workspace"), "can_change_path": .boolean(false),
         "data_url": .string("data:text/plain;base64,aGVsbG8=")]
    }
}

@MainActor
private final class Performer: WorkspaceOperationPerforming {
    struct Call { let operation: WorkspaceOperation; let payload: [String: BighelpJSONValue] }
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities
    var calls: [Call] = []
    var responses: [WorkspaceOperation: [String: BighelpJSONValue]] = [:]
    var suspend = false
    var continuation: CheckedContinuation<Void, Never>?

    init() throws {
        let owner = try Self.makeOwner()
        self.owner = owner
        self.capabilities = .init(owner: owner, values: [.projectsEdit: .available, .configEdit: .available, .keysEdit: .available, .webhooksEdit: .available])
    }

    static func makeOwner() throws -> WorkspaceOwner {
        .init(authority: try .fixture(id: "workspace-test"), authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue], owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        calls.append(.init(operation: operation, payload: payload))
        if suspend { await withCheckedContinuation { continuation = $0 } }
        guard let response = responses[operation] else { throw WorkspaceClientError.invalidResponse }
        return response
    }
}
