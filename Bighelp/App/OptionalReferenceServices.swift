import Foundation
import Observation
import SwiftUI

/// One optional-provider owner for the app. Construction never opens a vault,
/// reads document storage or contacts either provider.
@MainActor
@Observable
final class OptionalReferenceServices {
    let wiki: WikiStore
    let drafts = WikiDraftStore(owner: nil)
    private(set) var lifecycleFailure: String?
    let github: GitHubConnectionStore
    private(set) var wikiClient: WikiLinkClient?
    @ObservationIgnored private let workspace: BighelpLinkWorkspaceClient?
    @ObservationIgnored private var currentOwner: @MainActor () -> WikiOwner? = { nil }
    @ObservationIgnored private var erasureAccountID: String?
    @ObservationIgnored private var erasureWikiAccountID: String?
    @ObservationIgnored private let wikiPersistence: any WikiPersistence
    var activeOwner: WikiOwner? { currentOwner() }

    init(workspace: BighelpLinkWorkspaceClient? = nil, configuration: GitHubConfiguration?,
         wikiPersistence: (any WikiPersistence)? = nil) {
        self.workspace = workspace
        let persistence = wikiPersistence ?? WikiLocalPersistence()
        self.wikiPersistence = persistence
        wiki = WikiStore(owner: nil, client: nil, persistence: persistence)
        github = GitHubConnectionStore(ownerID: nil, configuration: configuration)
    }

    func bind(owner: WikiOwner?, accountID: String?, currentOwner: @escaping @MainActor () -> WikiOwner?) {
        self.currentOwner = currentOwner
        if let owner { erasureWikiAccountID = owner.accountID }
        if let accountID { erasureAccountID = accountID }
        if github.ownerID != accountID { github.setOwner(accountID) }
        guard wiki.owner != owner else { return }
        let client = owner.flatMap { owner -> WikiLinkClient? in
            guard let workspace else { return nil }
            return WikiLinkClient(owner: owner, workspace: workspace, currentOwner: { [weak self] in
                self?.currentOwner()
            })
        }
        wikiClient = client
        do { try drafts.setContext(owner: owner) }
        catch { lifecycleFailure = "A Wiki draft could not be saved on this device. Return to its original account and host to recover it before closing the app." }
        wiki.setContext(owner: owner, client: client)
    }

    func invalidate() {
        currentOwner = { nil }
        wikiClient = nil
        wiki.setContext(owner: nil, client: nil)
        do { try drafts.setContext(owner: nil) }
        catch { lifecycleFailure = "A Wiki draft remains only in memory because device storage was unavailable." }
        github.setOwner(nil)
    }

    /// Invalidates every in-flight request before deleting provider storage;
    /// failures remain retryable.
    func eraseAccountData(preservingWikiFolders: Bool = false) throws {
        let accountID = github.ownerID ?? erasureAccountID
        let wikiAccountID = erasureWikiAccountID ?? wiki.owner?.accountID
        wikiClient = nil
        currentOwner = { nil }
        wiki.setContext(owner: nil, client: nil)
        if let wikiAccountID {
            try drafts.deleteAccountData(accountID: wikiAccountID)
            if preservingWikiFolders { try wiki.signOutAccountData(accountID: wikiAccountID) }
            else { try wiki.deleteAccountData(accountID: wikiAccountID) }
        }
        if let accountID {
            github.setOwner(accountID)
            try github.eraseOwnerCredentials()
        }
        invalidate()
        erasureAccountID = nil
        erasureWikiAccountID = nil
    }
}

private struct OptionalReferenceServicesKey: EnvironmentKey {
    static let defaultValue: OptionalReferenceServices? = nil
}

private struct OpenWikiKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}
private struct OpenGitHubKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}
extension EnvironmentValues {
    var optionalReferenceServices: OptionalReferenceServices? {
        get { self[OptionalReferenceServicesKey.self] }
        set { self[OptionalReferenceServicesKey.self] = newValue }
    }
    var openWiki: (@MainActor () -> Void)? {
        get { self[OpenWikiKey.self] }
        set { self[OpenWikiKey.self] = newValue }
    }
    var openGitHub: (@MainActor () -> Void)? {
        get { self[OpenGitHubKey.self] }
        set { self[OpenGitHubKey.self] = newValue }
    }
}
