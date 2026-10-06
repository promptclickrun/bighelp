import Foundation
import Testing
@testable import Bighelp

/// Codex and Claude Code chats in Sessions: listed from the computer's Hermes, previewed,
/// then brought in as a Hermes chat (or the copy Hermes already has).
@MainActor
struct OtherAppChatsTests {
    @Test func listsPreviewsAndBringsAChatIn() async throws {
        let source = FakeSource()
        let store = OtherAppChatsStore(source: source)
        await store.load()
        #expect(store.items.map(\.title) == ["Polish the Mac menus", "Trip budget script"])

        await store.showPreview(try #require(store.items.first))
        #expect(store.preview?.title == "Polish the Mac menus")
        #expect(await store.bringIn() == "hermes-session-1")
        #expect(store.preview == nil)
        #expect(source.broughtIn == 1)
    }

    @Test func oneAppsChatsAreAskedForByThatApp() async {
        let source = FakeSource()
        let store = OtherAppChatsStore(source: source)
        await store.load(app: SessionAppFilter.claudeCode.foreignSource)
        #expect(store.items.map(\.title) == ["Trip budget script"])
        await store.load(app: SessionAppFilter.codex.foreignSource)
        #expect(store.items.map(\.title) == ["Polish the Mac menus"])
        #expect(source.askedSources == ["claude", "codex"])
    }

    @Test func appChoicesSplitChatsByWhereTheyCameFrom() {
        // Hermes' own chats, and the ones it brought in from each app.
        #expect(SessionAppFilter.hermes.includes(source: "bighelp"))
        #expect(SessionAppFilter.hermes.includes(source: "telegram"))
        #expect(SessionAppFilter.hermes.includes(source: nil))
        #expect(!SessionAppFilter.hermes.includes(source: "codex-cli"))
        #expect(!SessionAppFilter.hermes.includes(source: "claude-code"))
        #expect(SessionAppFilter.codex.includes(source: "codex-cli"))
        #expect(SessionAppFilter.codex.includes(source: "codex"))
        #expect(!SessionAppFilter.codex.includes(source: "claude"))
        #expect(SessionAppFilter.claudeCode.includes(source: "claude-code"))
        #expect(SessionAppFilter.claudeCode.includes(source: "claude"))
        #expect(!SessionAppFilter.claudeCode.includes(source: "bighelp"))
        #expect(SessionAppFilter.all.includes(source: "codex-cli") && SessionAppFilter.all.includes(source: nil))
        #expect(!SessionAppFilter.hermes.showsOtherAppChats)
        #expect(SessionAppFilter.codex.foreignSource == "codex" && SessionAppFilter.claudeCode.foreignSource == "claude")
    }

    @Test func aChatAlreadyInHermesOpensThatCopyWithoutImportingAgain() async throws {
        let client = FakeMaintenance()
        let live = LiveOtherAppChats(client: client, profileID: "default")
        let known = HermesForeignSessionPreview(demoTitle: "Menus", source: "codex", cwd: nil,
                                                alreadyImported: "hermes-session-0")
        #expect(try await live.bringIn(known) == "hermes-session-0")
        #expect(client.imports == 0)
        let fresh = HermesForeignSessionPreview(demoTitle: "Menus", source: "codex", cwd: nil)
        #expect(try await live.bringIn(fresh) == "hermes-session-1", "A new one is imported")
        #expect(client.imports == 1)
    }

    @Test func aComputerThatCantListThemShowsNothing() async {
        let source = FakeSource()
        source.fails = true
        let store = OtherAppChatsStore(source: source)
        await store.load()
        #expect(store.items.isEmpty)
        #expect(store.errorMessage == nil, "Nothing to explain: the section just isn't there")
    }

    @MainActor private final class FakeSource: OtherAppChatsSource {
        var fails = false
        var broughtIn = 0
        var askedSources: [String?] = []
        func list(offset: Int, source: String?) async throws -> HermesForeignSessionPage {
            if fails { throw HermesSessionMaintenanceError.invalidResponse }
            askedSources.append(source)
            let items = [
                HermesForeignSessionItem(id: String(repeating: "c", count: 64), source: "codex", sourceLabel: "Codex CLI",
                                         title: "Polish the Mac menus", cwd: nil, modifiedAt: nil, turnCount: 4,
                                         excerpt: "Menus"),
                HermesForeignSessionItem(id: String(repeating: "d", count: 64), source: "claude", sourceLabel: "Claude Code",
                                         title: "Trip budget script", cwd: nil, modifiedAt: nil, turnCount: 2,
                                         excerpt: "Hotels"),
            ].filter { source == nil || $0.source == source }
            return HermesForeignSessionPage(profileID: "default", host: "Studio", sessions: items,
                                            nextOffset: nil, unreadable: 0)
        }
        func preview(_ item: HermesForeignSessionItem) async throws -> HermesForeignSessionPreview {
            HermesForeignSessionPreview(demoTitle: item.title, source: item.source, cwd: nil)
        }
        func bringIn(_ preview: HermesForeignSessionPreview) async throws -> String {
            broughtIn += 1
            return "hermes-session-1"
        }
    }

    /// Only the importer is used here.
    @MainActor private final class FakeMaintenance: HermesSessionMaintenanceManaging {
        var imports = 0
        var ownsScope: Bool { true }
        func importForeign(reviewed: HermesForeignSessionPreview) async throws -> HermesForeignSessionImportResult {
            imports += 1
            return .init(profileID: reviewed.profileID, foreignID: reviewed.foreignID, sessionID: "hermes-session-1",
                         alreadyImported: false)
        }
        func foreignSessions(profileID: String, source: String?, offset: Int, limit: Int) async throws -> HermesForeignSessionPage { throw CancellationError() }
        func foreignPreview(profileID: String, item: HermesForeignSessionItem) async throws -> HermesForeignSessionPreview { throw CancellationError() }
        func statistics(profileID: String) async throws -> HermesSessionStoreStats { throw CancellationError() }
        func sessions(profileID: String) async throws -> [HermesSessionMaintenanceItem] { throw CancellationError() }
        func mostRecentSession(profileID: String) async throws -> HermesSessionMostRecentLookup { throw CancellationError() }
        func setHidden(profileID: String, sessionID: String, hidden: Bool) async throws -> HermesSessionVisibilityResult { throw CancellationError() }
        func closeLiveSession(profileID: String, sessionID: String) async throws -> HermesSessionCloseResult { throw CancellationError() }
        func prepareOwnerBackfill(profileID: String) async throws -> HermesSessionOwnerBackfillReview { throw CancellationError() }
        func ownerBackfill(reviewed: HermesSessionOwnerBackfillReview) async throws -> HermesSessionOwnerBackfillResult { throw CancellationError() }
        func prepareBulkDelete(profileID: String, sessionIDs: [String]) async throws -> HermesSessionBulkDeleteReview { throw CancellationError() }
        func deleteBulk(reviewed: HermesSessionBulkDeleteReview) async throws -> HermesSessionDeletionResult { throw CancellationError() }
        func prepareEmptyDelete(profileID: String) async throws -> HermesSessionEmptyDeleteReview { throw CancellationError() }
        func deleteEmpty(reviewed: HermesSessionEmptyDeleteReview) async throws -> HermesSessionDeletionResult { throw CancellationError() }
        func preparePrune(profileID: String, filter: HermesSessionPruneFilter) async throws -> HermesSessionPruneReview { throw CancellationError() }
        func prune(reviewed: HermesSessionPruneReview) async throws -> HermesSessionDeletionResult { throw CancellationError() }
        func exportSession(profileID: String, sessionID: String) async throws -> HermesSessionExport { throw CancellationError() }
        func prepareImport(profileID: String, data: Data) throws -> HermesSessionImportReview { throw CancellationError() }
        func importSessions(reviewed: HermesSessionImportReview) async throws -> HermesSessionImportResult { throw CancellationError() }
        func latestDescendant(profileID: String, sessionID: String) async throws -> HermesSessionLineage { throw CancellationError() }
    }
}
