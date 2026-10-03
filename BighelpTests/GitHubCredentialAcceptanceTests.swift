import CryptoKit
import Foundation
import Testing
@testable import Bighelp

@MainActor
struct GitHubCredentialAcceptanceTests {
    private let token = "github_pat_fixtureNotAnActualCredential"

    @Test func confirmedCredentialIsTheDefaultForAnUnconfiguredChat() async throws {
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
            transport: ReferenceTestGitHubTransport(), vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        let selected = try #require(store.selectedCredential)
        #expect(store.referenceCredentialID(savedID: nil, disabled: false) == selected.id)
        #expect(store.referenceCredentialID(savedID: nil, disabled: true) == nil)
        #expect(store.referenceCredentialID(savedID: "different-credential", disabled: false) == nil)
        store.setOwner("owner-b")
        #expect(store.referenceCredentialID(savedID: nil, disabled: false) == nil)
    }

    @Test func singleSavedCredentialRestoresWithoutNetworkButMultipleCredentialsRequireChoice() async throws {
        let vault = ReferenceTestGitHubVault()
        let transport = ReferenceTestGitHubTransport()
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil, transport: transport, vault: vault)
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        let saved = try #require(store.selectedCredential)
        let reopened = GitHubConnectionStore(ownerID: "owner-a", configuration: nil, transport: transport, vault: vault)
        reopened.restoreDefaultCredentialIfUnambiguous()
        #expect(reopened.selectedCredential?.id == saved.id)
        #expect(await transport.paths == ["/user"])
        await store.connectPersonalAccessToken(token + "Second")
        store.confirmAccount(userID: 42)
        let ambiguous = GitHubConnectionStore(ownerID: "owner-a", configuration: nil, transport: transport, vault: vault)
        ambiguous.restoreDefaultCredentialIfUnambiguous()
        #expect(ambiguous.selectedCredential == nil)
        #expect(ambiguous.savedCredentials.count == 2)
    }

    @Test func confirmationPersistenceReloadAndExactDisconnect() async throws {
        let vault = ReferenceTestGitHubVault()
        let transport = ReferenceTestGitHubTransport()
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
                                           transport: transport, vault: vault)
        #expect(vault.readCount == 0)
        #expect(await transport.paths.isEmpty)
        await store.connectPersonalAccessToken(token)
        #expect(vault.values.isEmpty)
        store.confirmAccount(userID: 42)
        let first = try #require(store.selectedCredential)
        #expect(first.origin == .personalAccessToken)
        #expect(vault.values.count == 1)
        #expect(vault.values.first?.tokens == nil)
        await store.connectPersonalAccessToken(token + "Second")
        store.confirmAccount(userID: 42)
        let second = try #require(store.selectedCredential)
        #expect(first.id != second.id)
        #expect(vault.values.count == 2)
        let reopened = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
                                             transport: transport, vault: vault)
        reopened.loadSavedIdentities()
        #expect(reopened.selectedIdentity == nil)
        #expect(reopened.savedCredentials.count == 2)
        reopened.selectIdentity(userID: 42)
        #expect(reopened.selectedIdentity == nil)
        reopened.selectCredential(id: first.id)
        #expect(reopened.selectedCredential?.id == first.id)
        try reopened.disconnectCredential(id: first.id)
        #expect(vault.values.map(\.id) == [second.id])
        #expect(await transport.paths == ["/user", "/user"])
    }

    @Test func wrongConfirmationAndVaultFailureNeverActivate() async {
        let vault = ReferenceTestGitHubVault()
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
                                           transport: ReferenceTestGitHubTransport(), vault: vault)
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 99)
        #expect(store.selectedIdentity == nil)
        #expect(vault.values.isEmpty)
        await store.connectPersonalAccessToken(token)
        vault.failWrites = true
        store.confirmAccount(userID: 42)
        #expect(store.selectedIdentity == nil)
        #expect(vault.values.isEmpty)
    }

    @Test func malformedTokensAreNotTrimmedOrSent() async {
        let transport = ReferenceTestGitHubTransport()
        let vault = ReferenceTestGitHubVault()
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
                                           transport: transport, vault: vault)
        for invalid in ["", " " + token, token + "\n", "abc\rdef", String(repeating: "a", count: 1025)] {
            await store.connectPersonalAccessToken(invalid)
            #expect(store.selectedIdentity == nil)
        }
        #expect(await transport.paths.isEmpty)
        #expect(vault.readCount == 0)
    }

    @Test func patDiscoveryUsesUserReposWithoutOAuthOrInstallations() async throws {
        let transport = ReferenceTestGitHubTransport()
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
                                           transport: transport, vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        _ = try await store.repositories(userID: 42)
        #expect(await transport.paths == ["/user", "/user/repos"])
    }

    @Test func credentialDerivedHubAccountBridgesOnlyThePinnedGitHubNamespace() async throws {
        let deviceID = "device-a"
        let wiki = WikiOwner(accountID: "wiki-account-a", hostID: "host-a", profileID: "default",
                             deviceID: deviceID, authorizationEpoch: "1")
        let owner = ReferenceHubOwner(accountID: wiki.accountID, hostID: wiki.hostID,
            deviceID: try #require(wiki.deviceID), authorizationEpoch: try #require(wiki.authorizationEpoch),
            sessionID: "session-a", agentID: wiki.profileID, recipientIDs: [wiki.profileID])
        let transport = ReferenceTestGitHubTransport(withResources: true)
        let vault = ReferenceTestGitHubVault()
        let store = GitHubConnectionStore(ownerID: deviceID, configuration: nil,
            transport: transport, vault: vault)
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        let selected = try #require(store.selectedCredential)
        let generation = store.generation
        #expect(owner.accountID != store.ownerID)
        // Existing callers still require the hub account to equal the credential namespace.
        let legacy = try #require(ReferenceProviderAdapters.github(store: store, ownerIsCurrent: { $0 == owner }))
        do { _ = try await legacy.search(owner, .repos, ""); Issue.record("Bridge must be explicit") }
        catch { #expect(error as? ReferenceAdapterError == .authorityChanged) }
        let provider = try #require(ReferenceProviderAdapters.github(store: store,
            expectedHubAccountID: owner.accountID, ownerIsCurrent: { $0 == owner }))
        let page = try await provider.search(owner, .repos, "")
        let row = try #require(page.results.first)
        let preview = try await provider.resolve(owner, row)
        let snapshot = try #require(preview.options.first?.snapshot)
        let fresh = try await provider.revalidate(owner, snapshot)
        #expect(fresh.anchor == snapshot.anchor)
        #expect(store.ownerID == deviceID)
        #expect(store.selectedCredential?.id == selected.id)
        #expect(store.generation == generation)
        #expect(vault.values.map(\.scope.ownerID) == [deviceID])

        // Even an overly permissive caller cannot bypass the explicit account pin.
        let wrong = ReferenceHubOwner(accountID: "other-account", hostID: owner.hostID,
            deviceID: owner.deviceID, authorizationEpoch: owner.authorizationEpoch,
            sessionID: owner.sessionID, agentID: owner.agentID, recipientIDs: owner.recipientIDs)
        let pinned = try #require(ReferenceProviderAdapters.github(store: store,
            expectedHubAccountID: owner.accountID, ownerIsCurrent: { _ in true }))
        let paths = await transport.paths
        do { _ = try await pinned.search(wrong, .repos, ""); Issue.record("Wrong account must fail before first bind") }
        catch { #expect(error as? ReferenceAdapterError == .authorityChanged) }
        #expect(await transport.paths == paths)
    }

    @Test(arguments: ["scope", "generation", "currentOwner", "host", "device", "epoch", "session", "agent", "recipients"])
    func bridgedGitHubReferencesInvalidateChangedAuthority(_ change: String) async throws {
        let deviceID = "device-a"
        let owner = ReferenceHubOwner(accountID: "wiki-account-a", hostID: "host-a",
            deviceID: deviceID, authorizationEpoch: "1", sessionID: "session-a",
            agentID: "default", recipientIDs: ["default"])
        let transport = ReferenceTestGitHubTransport(withResources: true)
        let store = GitHubConnectionStore(ownerID: deviceID, configuration: nil,
            transport: transport, vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        var isCurrent = true
        let provider = try #require(ReferenceProviderAdapters.github(store: store,
            expectedHubAccountID: owner.accountID, ownerIsCurrent: { _ in isCurrent }))
        let page = try await provider.search(owner, .repos, "")
        let row = try #require(page.results.first)
        let preview = try await provider.resolve(owner, row)
        let snapshot = try #require(preview.options.first?.snapshot)
        if change == "scope" {
            store.setOwner("other-device")
            store.setOwner(deviceID)
            store.restoreDefaultCredentialIfUnambiguous()
        } else if change == "generation" {
            await store.connectPersonalAccessToken(token + "Replacement")
            store.confirmAccount(userID: 42)
        } else if change == "currentOwner" { isCurrent = false }
        let candidate = ReferenceHubOwner(accountID: owner.accountID,
            hostID: change == "host" ? "other-host" : owner.hostID,
            deviceID: change == "device" ? "other-device" : owner.deviceID,
            authorizationEpoch: change == "epoch" ? "2" : owner.authorizationEpoch,
            sessionID: change == "session" ? "other-session" : owner.sessionID,
            agentID: change == "agent" ? "other-agent" : owner.agentID,
            recipientIDs: change == "recipients" ? ["default", "other-agent"] : owner.recipientIDs)
        let paths = await transport.paths
        do { _ = try await provider.search(candidate, .repos, ""); Issue.record("Stale search must fail") }
        catch { #expect(error as? ReferenceAdapterError == .authorityChanged) }
        do { _ = try await provider.resolve(candidate, row); Issue.record("Stale resolve must fail") }
        catch { #expect(error as? ReferenceAdapterError == .authorityChanged) }
        do { _ = try await provider.revalidate(candidate, snapshot); Issue.record("Stale send must fail") }
        catch { #expect(error as? ReferenceAdapterError == .authorityChanged) }
        #expect(await transport.paths == paths)
    }

    @Test func referencesBrowseWithoutTypingAndCachedRowsCanBeInspected() async throws {
        let transport = ReferenceTestGitHubTransport(withResources: true)
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
            transport: transport, vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        let owner = ReferenceHubOwner(accountID: "owner-a", hostID: "host-a", deviceID: "device-a",
            authorizationEpoch: "1", sessionID: "session-a", agentID: "default", recipientIDs: ["default"])
        let provider = try #require(ReferenceProviderAdapters.github(store: store, ownerIsCurrent: { $0 == owner }))
        let initial = try await provider.search(owner, .all, "")
        #expect(Set(initial.results.map(\.category)) == [.repos, .issues, .prs])
        #expect(initial.results.count == 3)
        let cached = try await provider.search(owner, .repos, "")
        let row = try #require(cached.results.first)
        #expect(row.isCached)
        let preview = try await provider.resolve(owner, row)
        #expect(preview.result == row)
        #expect(preview.options.first?.snapshot.anchor.contains("https://github.com/fixture-owner/notes") == true)
        let issues = try await provider.search(owner, .issues, "")
        #expect(issues.results.first?.title == "Fix references")
        let queries = await transport.searchQueries
        #expect(queries == ["repo:fixture-owner/notes is:issue", "repo:fixture-owner/notes is:pr"])
        let pathsBeforeRepeat = await transport.paths
        _ = try await provider.search(owner, .all, "")
        #expect(await transport.paths == pathsBeforeRepeat)
    }

    @Test func issueDiscoverySearchesTheBoundedCatalogInOneRequest() async throws {
        let transport = ReferenceTestGitHubTransport(withResources: true, withSecondRepository: true)
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
            transport: transport, vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        let page = try await store.search(kind: .issue, query: "", userID: 42)
        #expect(page.resources.map(\.title) == ["Fix references"])
        #expect(await transport.searchQueries == ["repo:fixture-owner/zebra repo:fixture-owner/notes is:issue"])
    }

    @Test func emptyQueryCatalogShowsNestedRepositoriesWorkItemsAndCanonicalSelection() async throws {
        let transport = ReferenceTestGitHubTransport(withResources: true, withSecondRepository: true,
                                                      withNestedWorkItems: true)
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
            transport: transport, vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        let owner = ReferenceHubOwner(accountID: "owner-a", hostID: "host-a", deviceID: "device-a",
            authorizationEpoch: "1", sessionID: "session-a", agentID: "default", recipientIDs: ["default"])
        let provider = try #require(ReferenceProviderAdapters.github(store: store,
            ownerIsCurrent: { $0 == owner }))

        let page = try await provider.search(owner, .all, "")
        #expect(!page.isPartial)
        #expect(Set(page.results.map(\.category)) == [.repos, .issues, .prs])
        #expect(Set(page.results.filter { $0.category == .repos }.map(\.subtitle)) ==
            ["fixture-owner/notes", "fixture-owner/zebra"])
        #expect(page.results.contains { $0.category == .issues && $0.subtitle == "fixture-owner/zebra #202" })
        #expect(page.results.contains { $0.category == .prs && $0.subtitle == "fixture-owner/notes #144" })

        let nestedIssue = try #require(page.results.first {
            $0.category == .issues && $0.subtitle == "fixture-owner/zebra #202"
        })
        let preview = try await provider.resolve(owner, nestedIssue)
        let snapshot = try #require(preview.options.first?.snapshot)
        #expect(snapshot.anchor.contains("https://github.com/fixture-owner/zebra/issues/202"))
        let fresh = try await provider.revalidate(owner, snapshot)
        #expect(fresh.anchor == snapshot.anchor)
    }

    @Test func allCatalogKeepsRepositoryRowsWhenIssueSearchFails() async throws {
        let transport = ReferenceTestGitHubTransport(withResources: true, failIssueSearch: true)
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
            transport: transport, vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        let owner = ReferenceHubOwner(accountID: "owner-a", hostID: "host-a", deviceID: "device-a",
            authorizationEpoch: "1", sessionID: "session-a", agentID: "default", recipientIDs: ["default"])
        let provider = try #require(ReferenceProviderAdapters.github(store: store,
            ownerIsCurrent: { $0 == owner }))

        let page = try await provider.search(owner, .all, "")
        #expect(page.results.map(\.category) == [.repos, .prs])
        #expect(page.results.contains { $0.category == .repos && $0.subtitle == "fixture-owner/notes" })
        #expect(page.isPartial)
    }

    @Test func allCatalogRejectsRepositoryRowsWhenIssueSearchRequiresReconnect() async throws {
        let transport = ReferenceTestGitHubTransport(withResources: true, failIssueSearchWithAuth: true)
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
            transport: transport, vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        let owner = ReferenceHubOwner(accountID: "owner-a", hostID: "host-a", deviceID: "device-a",
            authorizationEpoch: "1", sessionID: "session-a", agentID: "default", recipientIDs: ["default"])
        let provider = try #require(ReferenceProviderAdapters.github(store: store,
            ownerIsCurrent: { $0 == owner }))

        do {
            _ = try await provider.search(owner, .all, "")
            Issue.record("An authentication failure after repository discovery must reject the whole catalog")
        } catch {
            #expect(error as? ReferenceAdapterError == .authorityChanged)
        }
    }

    @Test func allCatalogDoesNotRetainRowsAfterOwnerSwitch() async throws {
        let transport = ReferenceTestGitHubTransport(withResources: true)
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
            transport: transport, vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        let owner = ReferenceHubOwner(accountID: "owner-a", hostID: "host-a", deviceID: "device-a",
            authorizationEpoch: "1", sessionID: "session-a", agentID: "default", recipientIDs: ["default"])
        var isCurrent = true
        let provider = try #require(ReferenceProviderAdapters.github(store: store,
            ownerIsCurrent: { _ in isCurrent }))
        let page = try await provider.search(owner, .repos, "")
        let row = try #require(page.results.first)

        isCurrent = false
        do {
            _ = try await provider.search(owner, .all, "")
            Issue.record("An owner switch must not publish retained rows")
        } catch {
            #expect(error as? ReferenceAdapterError == .authorityChanged)
        }
        do {
            _ = try await provider.resolve(owner, row)
            Issue.record("An owner switch must clear previously observed rows")
        } catch {
            #expect(error as? ReferenceAdapterError == .authorityChanged)
        }
    }

    @Test func warmDiscoveryIsSharedAcrossAdaptersButNotCredentialsOrOwners() async throws {
        let transport = ReferenceTestGitHubTransport(withResources: true)
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
            transport: transport, vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        await store.warmReferences()
        let warmedPaths = await transport.paths
        let checkedAt = store.referenceLastCheckedAt
        let owner = ReferenceHubOwner(accountID: "owner-a", hostID: "host-a", deviceID: "device-a",
            authorizationEpoch: "1", sessionID: "session-a", agentID: "default", recipientIDs: ["default"])
        for _ in 0..<2 {
            let provider = try #require(ReferenceProviderAdapters.github(store: store, ownerIsCurrent: { $0 == owner }))
            let page = try await provider.search(owner, .all, "")
            #expect(page.results.count == 3)
            #expect(page.results.allSatisfy { $0.isCached })
        }
        #expect(await transport.paths == warmedPaths)
        #expect(store.referenceLastCheckedAt == checkedAt)
        await store.connectPersonalAccessToken(token + "Second")
        store.confirmAccount(userID: 42)
        #expect(store.referenceLastCheckedAt == nil)
        _ = try await store.repositories(userID: 42)
        #expect(await transport.paths.filter { $0 == "/user/repos" }.count == 2)
        store.setOwner("owner-b")
        #expect(store.referenceLastCheckedAt == nil)
        do { _ = try await store.search(kind: .repository, query: "", userID: 42); Issue.record("Owner B must not inherit A's cache") }
        catch { #expect(error as? GitHubError == .accountNotConfirmed) }
    }

    @Test func warmCacheCannotAuthorizeSendAfterRevocation() async throws {
        let transport = ReferenceTestGitHubTransport(withResources: true)
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
            transport: transport, vault: ReferenceTestGitHubVault())
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        let owner = ReferenceHubOwner(accountID: "owner-a", hostID: "host-a", deviceID: "device-a",
            authorizationEpoch: "1", sessionID: "session-a", agentID: "default", recipientIDs: ["default"])
        let provider = try #require(ReferenceProviderAdapters.github(store: store, ownerIsCurrent: { $0 == owner }))
        let page = try await provider.search(owner, .repos, "")
        let row = try #require(page.results.first)
        let preview = try await provider.resolve(owner, row)
        let snapshot = try #require(preview.options.first?.snapshot)
        let requestsBeforeSend = await transport.paths.count
        await transport.revoke()
        do { _ = try await provider.revalidate(owner, snapshot); Issue.record("Cached display must not authorize send") } catch {}
        #expect(await transport.paths.count == requestsBeforeSend + 1)
        #expect(store.selectedCredential == nil)
        #expect(store.referenceLastCheckedAt == nil)
    }

    @Test(arguments: [false, true])
    func deviceUserTokenReadsEligibleInstallationsEvenAfterRefresh(_ refreshRequired: Bool) async throws {
        let configuration = try GitHubConfiguration(clientID: "Iv1.fixture123456",
            installationURL: URL(string: "https://github.com/apps/fixture-app/installations/new")!)
        let vault = ReferenceTestGitHubVault()
        let record = GitHubCredentialRecord(scope: GitHubCredentialScope(ownerID: "owner-a", clientID: configuration.clientID),
            identity: GitHubIdentity(id: 42, login: "fixture-user"),
            tokens: GitHubTokenPair(accessToken: "ghu_" + "fixture", refreshToken: "ghr_" + "fixture",
                accessExpiresAt: Date().addingTimeInterval(refreshRequired ? 30 : 3600), refreshExpiresAt: Date().addingTimeInterval(7200)),
            refreshPending: false)
        try vault.save(record)
        let transport = ReferenceTestGitHubTransport(withResources: true)
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: configuration, transport: transport, vault: vault)
        store.selectCredential(id: record.id)
        let owner = ReferenceHubOwner(accountID: "owner-a", hostID: "host-a", deviceID: "device-a",
            authorizationEpoch: "1", sessionID: "session-a", agentID: "default", recipientIDs: ["default"])
        let provider = try #require(ReferenceProviderAdapters.github(store: store, ownerIsCurrent: { $0 == owner }))
        let page = try await provider.search(owner, .repos, "")
        #expect(page.results.map(\.title) == ["fixture-owner/notes"])
        #expect(!page.isPartial)
        let expected = (refreshRequired ? ["/login/oauth/access_token", "/user"] : [])
            + ["/user/installations", "/user/installations/7/repositories"]
        #expect(await transport.paths == expected)
    }

    @Test func ownerErasurePreservesOtherOwners() async throws {
        let vault = ReferenceTestGitHubVault()
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
                                           transport: ReferenceTestGitHubTransport(), vault: vault)
        await store.connectPersonalAccessToken(token)
        store.confirmAccount(userID: 42)
        store.setOwner("owner-b")
        await store.connectPersonalAccessToken(token + "B")
        store.confirmAccount(userID: 42)
        try store.eraseOwnerCredentials()
        #expect(vault.values.map(\.scope.ownerID) == ["owner-a"])
        #expect(store.selectedIdentity == nil)
        #expect(store.savedCredentials.isEmpty)
    }

    @Test func lateIdentityCannotCrossOwnerChange() async {
        let transport = ReferenceTestGitHubTransport(held: true)
        let vault = ReferenceTestGitHubVault()
        let store = GitHubConnectionStore(ownerID: "owner-a", configuration: nil,
                                           transport: transport, vault: vault)
        let attempt = Task { await store.connectPersonalAccessToken(token) }
        await transport.waitUntilStarted()
        store.setOwner("owner-b")
        await transport.release()
        await attempt.value
        #expect(store.ownerID == "owner-b")
        #expect(store.selectedIdentity == nil)
        #expect(store.pendingOrigin == nil)
        #expect(vault.values.isEmpty)
    }

    @Test func personalTokenDescriptionsAndReflectionAreRedacted() throws {
        let credential = try GitHubPersonalAccessToken(token)
        #expect(!String(describing: credential).contains(token))
        #expect(!String(reflecting: credential).contains(token))
        #expect(!String(describing: Mirror(reflecting: credential).children.map(\.value)).contains(token))
    }
}

@MainActor
private final class ReferenceTestGitHubVault: GitHubCredentialVault {
    var values: [GitHubCredentialRecord] = []
    var failWrites = false
    var readCount = 0
    func records(in scope: GitHubCredentialScope) throws -> [GitHubCredentialRecord] {
        readCount += 1
        return values.filter { $0.scope == scope }
    }
    func save(_ record: GitHubCredentialRecord) throws {
        if failWrites { throw GitHubError.vaultUnavailable }
        values.removeAll { $0.id == record.id && $0.scope == record.scope }
        values.append(record)
    }
    func remove(userID: Int, in scope: GitHubCredentialScope) throws {
        values.removeAll { $0.identity.id == userID && $0.scope == scope }
    }
    func remove(recordID: String, in scope: GitHubCredentialScope) throws {
        values.removeAll { $0.id == recordID && $0.scope == scope }
    }
    func removeAll(in scope: GitHubCredentialScope) throws {
        values.removeAll { $0.scope == scope }
    }
}

private actor ReferenceTestGitHubTransport: GitHubTransport {
    private(set) var paths: [String] = []
    private let held: Bool
    private let withResources: Bool
    private let withSecondRepository: Bool
    private let withNestedWorkItems: Bool
    private let failIssueSearch: Bool
    private let failIssueSearchWithAuth: Bool
    private(set) var searchQueries: [String] = []
    private var isRevoked = false
    func revoke() { isRevoked = true }
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    init(held: Bool = false, withResources: Bool = false, withSecondRepository: Bool = false,
         withNestedWorkItems: Bool = false, failIssueSearch: Bool = false,
         failIssueSearchWithAuth: Bool = false) {
        self.held = held
        self.withResources = withResources
        self.withSecondRepository = withSecondRepository
        self.withNestedWorkItems = withNestedWorkItems
        self.failIssueSearch = failIssueSearch
        self.failIssueSearchWithAuth = failIssueSearchWithAuth
    }
    private static let repository = #"{"id":17,"node_id":"R_fixture17","full_name":"fixture-owner/notes","html_url":"https://github.com/fixture-owner/notes","private":true,"archived":false,"disabled":false,"description":"Team notes","updated_at":"2026-09-07T00:00:00Z"}"#
    func waitUntilStarted() async {
        if !paths.isEmpty { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        try GitHubURLSessionTransport.validate(request)
        guard let url = request.url else { throw GitHubError.invalidResponse }
        paths.append(url.path)
        if failIssueSearchWithAuth, url.path == "/search/issues",
           URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value?.contains("is:issue") == true {
            return GitHubHTTPResponse(data: Data(), statusCode: 401, url: url, headers: [:])
        }
        if isRevoked { return GitHubHTTPResponse(data: Data(), statusCode: 401, url: url, headers: [:]) }
        if held {
            await withCheckedContinuation { continuation = $0; startWaiter?.resume(); startWaiter = nil }
        } else { startWaiter?.resume(); startWaiter = nil }
        let source: String
        switch url.path {
        case "/user": source = #"{"id":42,"login":"fixture-user","type":"User"}"#
        case "/login/oauth/access_token":
            let fields: [String: Any] = [
                "access_token": "ghu_" + "fixtureReplacement", "refresh_token": "ghr_" + "fixtureReplacement",
                "token_type": "bearer", "scope": "", "expires_in": 3600, "refresh_token_expires_in": 7200
            ]
            source = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        case "/user/repos":
            let second = Self.repository.replacingOccurrences(of: "notes", with: "zebra")
                .replacingOccurrences(of: "17", with: "18").replacingOccurrences(of: "09-07", with: "09-08")
            source = withResources ? "[" + Self.repository + (withSecondRepository ? "," + second : "") + "]" : "[]"
        case "/user/installations":
            source = #"{"total_count":1,"installations":[{"id":7,"app_slug":"fixture-app","permissions":{"metadata":"read","issues":"write","pull_requests":"read","contents":"read"},"suspended_at":null}]}"#
        case "/user/installations/7/repositories":
            source = "{\"total_count\":1,\"repositories\":[" + Self.repository + "]}"
        case "/repos/fixture-owner/notes": source = Self.repository
        case "/repos/fixture-owner/zebra":
            source = Self.repository.replacingOccurrences(of: "notes", with: "zebra")
                .replacingOccurrences(of: "17", with: "18").replacingOccurrences(of: "09-07", with: "09-08")
        case "/search/issues":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            searchQueries.append(query)
            if failIssueSearch && query.contains("is:issue") {
                throw GitHubError.networkUnavailable
            } else if searchQueries.last?.contains("is:pr") == true {
                source = withNestedWorkItems
                    ? #"{"total_count":2,"incomplete_results":false,"items":[{"number":144,"html_url":"https://github.com/fixture-owner/notes/pull/144","pull_request":{}},{"number":145,"html_url":"https://github.com/fixture-owner/zebra/pull/145","pull_request":{}}]}"#
                    : #"{"total_count":1,"incomplete_results":false,"items":[{"number":144,"html_url":"https://github.com/fixture-owner/notes/pull/144","pull_request":{}}]}"#
            } else {
                source = withNestedWorkItems
                    ? #"{"total_count":2,"incomplete_results":false,"items":[{"id":143,"node_id":"I_fixture143","number":143,"title":"Fix references","html_url":"https://github.com/fixture-owner/notes/issues/143","state":"open","updated_at":"2026-09-07T00:00:00Z"},{"id":202,"node_id":"I_fixture202","number":202,"title":"Nested references","html_url":"https://github.com/fixture-owner/zebra/issues/202","state":"open","updated_at":"2026-09-08T00:00:00Z"}]}"#
                    : #"{"total_count":1,"incomplete_results":false,"items":[{"id":143,"node_id":"I_fixture143","number":143,"title":"Fix references","html_url":"https://github.com/fixture-owner/notes/issues/143","state":"open","updated_at":"2026-09-07T00:00:00Z"}]}"#
            }
        case "/repos/fixture-owner/notes/pulls/144":
            source = #"{"id":144,"node_id":"PR_fixture144","number":144,"title":"Restore references","html_url":"https://github.com/fixture-owner/notes/pull/144","state":"open","draft":false,"merged":false,"base":{"repo":{"id":17,"node_id":"R_fixture17","full_name":"fixture-owner/notes"}},"updated_at":"2026-09-07T00:00:00Z"}"#
        case "/repos/fixture-owner/zebra/pulls/145":
            source = #"{"id":145,"node_id":"PR_fixture145","number":145,"title":"Restore nested references","html_url":"https://github.com/fixture-owner/zebra/pull/145","state":"open","draft":false,"merged":false,"base":{"repo":{"id":18,"node_id":"R_fixture18","full_name":"fixture-owner/zebra"}},"updated_at":"2026-09-08T00:00:00Z"}"#
        case "/repos/fixture-owner/notes/issues/143":
            source = #"{"id":143,"node_id":"I_fixture143","number":143,"title":"Fix references","html_url":"https://github.com/fixture-owner/notes/issues/143","state":"open","updated_at":"2026-09-07T00:00:00Z"}"#
        case "/repos/fixture-owner/zebra/issues/202":
            source = #"{"id":202,"node_id":"I_fixture202","number":202,"title":"Nested references","html_url":"https://github.com/fixture-owner/zebra/issues/202","state":"open","updated_at":"2026-09-08T00:00:00Z"}"#
        default: throw GitHubError.invalidResponse
        }
        return GitHubHTTPResponse(data: Data(source.utf8), statusCode: 200, url: url,
                                  headers: ["content-type": "application/json"])
    }
}
