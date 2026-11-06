import Foundation
import Testing
@testable import Bighelp

/// The Chats list's Draft (#862): what the chat last saved, typing still in the draft journal, and
/// a saved draft after a relaunch, when the list holds only each chat's row.
@Suite(.serialized)
@MainActor
struct SessionDraftMarkTests {
    private static func chat(_ id: String) -> SessionRecord {
        SessionRecord(id: id, kind: .direct, agentIDs: ["default"], title: "Weekend plans",
                      remoteStoredID: "stored-" + id, remoteSource: "bighelp",
                      items: [TimelineItem(id: id + "-answer", role: .assistant,
                                           sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                                           content: .message("Here's the plan."), metadata: .init(delivery: "Delivered"))],
                      isUnread: false, hasAcceptedMessage: true)
    }


    @Test func aDraftTypedSinceTheChatSavedShowsInTheList() throws {
        let record = Self.chat("draft-chat")
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(records: [record]), records: [record])
        let journal = ChatDraftJournal(repository: nil)
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog, draftJournal: journal)
        #expect(features.unsentDraft(record.id) == nil, "The saved draft is the latest")

        journal.write("Can you also book", over: "", for: record.id)
        #expect(features.unsentDraft(record.id) == true)
        journal.write("   ", over: "", for: record.id)
        #expect(features.unsentDraft(record.id) == false, "Cleared since the chat saved")

        let list = SessionsModel(fixtures: [record], calendar: .current, now: .now)
        list.unsentDraft = { features.unsentDraft($0) }
        journal.write("Can you also book", over: "", for: record.id)
        let row = try #require(list.filteredSections.flatMap(\.sessions).first { $0.id == record.id })
        #expect(row.hasDraft)
    }

    @Test func aSavedDraftStillShowsWhenTheChatIsOnlyListed() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "draft-mark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var record = Self.chat("saved-draft")
        record.draft = "Book the table for"
        var plain = Self.chat("no-draft")
        plain.draft = " \n"
        try SessionContentRepository(directory: directory).save([record, plain])

        // After a relaunch the list holds each chat's row, not its draft.
        let rows = try SessionContentRepository(directory: directory).load()
        let listed = try #require(rows.first { $0.id == record.id })
        #expect(!listed.isContentLoaded)
        #expect(listed.summary.hasDraft)
        #expect(rows.first { $0.id == plain.id }?.summary.hasDraft == false)
    }
}
