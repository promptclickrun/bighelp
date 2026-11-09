import Foundation
import Testing
@testable import Bighelp

/// A share's way from a chat's message box to Hermes (`PendingShareLedger`), the journal entries
/// that carry one (`PendingShareCorrelations`), and the saved copy that only Hermes taking it
/// spends (`PendingShareInbox.markDelivered`). Foundation only: these run on any platform Swift runs on.
@Suite(.serialized)
struct PendingShareLedgerTests {
    private let directory: URL
    private let inbox: PendingShareInbox
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-share-ledger-" + UUID().uuidString, isDirectory: true)
        inbox = PendingShareInbox(root: directory.appendingPathComponent("PendingShares/v1", isDirectory: true))
    }

    private func share(_ text: String, file: String? = nil) throws -> PendingShare {
        let draft = try inbox.begin()
        try draft.addText(text)
        if let file {
            let source = directory.appendingPathComponent(UUID().uuidString)
            try Data("made-up".utf8).write(to: source)
            try draft.addFile(copying: source, suggestedName: file, kind: .file, typeIdentifier: "com.adobe.pdf",
                              mimeType: "application/pdf", preferredExtension: "pdf")
        }
        let share = try draft.commit(note: "")
        try inbox.place(share.id, PendingSharePlacement(
            destination: .init(scope: "scope-a", agentID: "juno", sessionID: "chat-1"), agentName: "Juno", placedAt: now))
        return share
    }

    private func inBox(_ share: PendingShare, files: [Int: String] = [:], in ledger: inout PendingShareLedger) {
        let placing = ledger.beginPlacing(share)
        #expect(placing)
        for (index, id) in files { ledger.fileLanded(shareID: share.id, index: index, attachmentID: id) }
        #expect(ledger.finishPlacing(share.id) == [.inBox(share.id)])
    }

    private func sent(_ effects: [PendingShareLedger.Effect]) -> [PendingShareSubmission] {
        effects.compactMap { if case .submission(_, let submission) = $0 { return submission } else { return nil } }
    }

    // MARK: - Correlated, one message at a time

    @Test func onlyAnOutcomeNamingItsMessageMovesAShareOn() throws {
        let first = try share("First words")
        var ledger = PendingShareLedger(conversationID: "chat-1")
        inBox(first, in: &ledger)

        let staged = sent(ledger.leaveBox(as: "row-1", text: "First words", attachmentIDs: [], now: now))
        let id = try #require(staged.first?.id)
        #expect(staged.first?.state == .staged)
        let sending = sent(ledger.dispatch("row-1", now: now))
        #expect(sending.map(\.id) == [id] && sending.first?.state == .sending)

        #expect(ledger.admitted(UUID(), now: now).isEmpty, "Another message's admission")
        #expect(ledger.admitted(id, now: now) == [.accepted(first.id, sending[0].with(.accepted, at: now))])
        #expect(ledger.admitted(id, now: now).isEmpty, "Once")
        #expect(ledger.isEmpty)
    }

    @Test func aLaterMessageAdmittedFirstSettlesOnlyItsOwnShare() throws {
        // A goes first and is held; B, staged separately, goes after and is admitted first. A is
        // then refused: nothing of A is ever spent. And the other way round.
        for refusesFirst in [false, true] {
            let a = try share("Share A \(refusesFirst)")
            let b = try share("Share B \(refusesFirst)")
            var ledger = PendingShareLedger(conversationID: "chat-1")
            inBox(a, in: &ledger)
            let aID = try #require(sent(ledger.leaveBox(as: "row-a", text: "Share A \(refusesFirst)",
                                                        attachmentIDs: [], now: now)).first?.id)
            inBox(b, in: &ledger)
            let bID = try #require(sent(ledger.leaveBox(as: "row-b", text: "Share B \(refusesFirst)",
                                                        attachmentIDs: [], now: now)).first?.id)
            #expect(aID != bID)
            _ = ledger.dispatch("row-a", now: now)
            _ = ledger.dispatch("row-b", now: now)

            if refusesFirst {
                #expect(ledger.refused(row: "row-a") == [.released(a.id, .refused)])
                #expect(ledger.admitted(bID, now: now).map(\.shareID) == [b.id])
            } else {
                #expect(ledger.admitted(bID, now: now).map(\.shareID) == [b.id])
                #expect(ledger.admitted(UUID(), now: now).isEmpty)
                #expect(ledger.refused(row: "row-a") == [.released(a.id, .refused)])
            }
            #expect(ledger.admitted(aID, now: now).isEmpty, "A was refused; nothing can spend it now")
        }
    }

    @Test func eachJournalEntryAdmitsOnlyTheShareMessageBoundToIt() {
        var correlations = PendingShareCorrelations()
        let entryA = UUID(), entryB = UUID(), shareA = UUID(), shareB = UUID()
        correlations.bind(entry: entryA, to: shareA)
        correlations.bind(entry: entryB, to: shareB)
        correlations.bind(entry: UUID(), to: nil)

        // B's receipt comes first, then A is refused (dropped), in either order.
        #expect(correlations.admit(entry: entryB) == shareB)
        #expect(correlations.admit(entry: entryB) == nil, "Once")
        correlations.drop(entry: entryA)
        #expect(correlations.admit(entry: entryA) == nil)
        #expect(correlations.admit(entry: UUID()) == nil, "An entry nobody bound")

        var reversed = PendingShareCorrelations()
        reversed.bind(entry: entryA, to: shareA)
        reversed.bind(entry: entryB, to: shareB)
        #expect(reversed.admit(entry: entryA) == shareA)
        #expect(reversed.submission(for: entryB) == shareB)
    }

    @Test func aStagedMessageThatTakesANewRowKeepsItsID() throws {
        let first = try share("Waiting words")
        var ledger = PendingShareLedger(conversationID: "chat-1")
        inBox(first, in: &ledger)
        let id = try #require(sent(ledger.leaveBox(as: "staged-1", text: "Waiting words", attachmentIDs: [],
                                                   now: now)).first?.id)
        let dispatched = sent(ledger.dispatch("staged-1", as: "row-7", now: now))
        #expect(dispatched.first?.id == id && dispatched.first?.messageID == "row-7")
        #expect(ledger.message(row: "row-7")?.id == id)
    }

    // MARK: - Every outcome

    @Test func anUnansweredSendStaysKnownUntilItsHistoryAnswers() throws {
        let first = try share("Reference words")
        var ledger = PendingShareLedger(conversationID: "chat-1")
        inBox(first, in: &ledger)
        let id = try #require(sent(ledger.leaveBox(as: "ref-1", text: "Reference words", attachmentIDs: [],
                                                   now: now)).first?.id)
        _ = ledger.dispatch("ref-1", now: now)
        let unconfirmed = sent(ledger.unknown(row: "ref-1", now: now))
        #expect(unconfirmed.first?.state == .unconfirmed && unconfirmed.first?.id == id)
        #expect(ledger.returnToBox(["ref-1"]).isEmpty, "Never back in the box as if unsent")
        #expect(ledger.admitted(row: "ref-1", now: now).map(\.shareID) == [first.id])
    }

    @Test func aMessageTriedAgainKeepsItsID() throws {
        let first = try share("Big file words")
        var ledger = PendingShareLedger(conversationID: "chat-1")
        inBox(first, in: &ledger)
        let id = try #require(sent(ledger.leaveBox(as: "row-1", text: "Big file words", attachmentIDs: [],
                                                   now: now)).first?.id)
        _ = ledger.dispatch("row-1", now: now)
        #expect(sent(ledger.waits(row: "row-1", now: now)).first?.state == .staged)
        #expect(sent(ledger.dispatch("row-1", now: now)).first?.id == id)
        #expect(ledger.removed(row: "row-1").isEmpty, "Only a waiting message can be removed")
        _ = ledger.waits(row: "row-1", now: now)
        #expect(ledger.removed(row: "row-1") == [.released(first.id, .removed)])
    }

    @Test func backInTheBoxOrRetiredNeverSpendsAShare() throws {
        let boxed = try share("In the box")
        let waiting = try share("Waiting")
        let going = try share("Going")
        var ledger = PendingShareLedger(conversationID: "chat-1")
        inBox(waiting, in: &ledger)
        _ = ledger.leaveBox(as: "row-w", text: "Waiting", attachmentIDs: [], now: now)
        inBox(going, in: &ledger)
        _ = ledger.leaveBox(as: "row-g", text: "Going", attachmentIDs: [], now: now)
        _ = ledger.dispatch("row-g", now: now)
        // Put back in the box before it went (a lost owner, a save that didn't take).
        #expect(ledger.returnToBox(["row-g"]) == [.inBox(going.id)])
        _ = ledger.leaveBox(as: "row-g2", text: "Going", attachmentIDs: [], now: now)
        _ = ledger.dispatch("row-g2", now: now)
        inBox(boxed, in: &ledger)

        let effects = ledger.retire(now: now)
        #expect(effects.contains(.released(boxed.id, .retired)))
        #expect(effects.contains(.released(waiting.id, .retired)))
        #expect(sent(effects).map(\.state) == [.unconfirmed], "Sending may have arrived")
        #expect(!effects.contains { if case .accepted = $0 { return true } else { return false } })
        #expect(ledger.isEmpty)
    }

    // MARK: - What the box still holds

    @Test func takingTheOnlyFileOutOrErasingTheOnlyTextLetsTheShareGoKept() throws {
        let words = try share("Only words")
        let file = try share("Note", file: "Only file.pdf")
        var ledger = PendingShareLedger(conversationID: "chat-1")
        inBox(words, in: &ledger)
        inBox(file, files: [0: "attachment-1"], in: &ledger)

        // The person erased the text but the file is still there.
        #expect(ledger.reviewBox(text: "", attachmentIDs: ["attachment-1"], failedNames: [])
                == [.released(words.id, .removed)])
        #expect(ledger.reviewBox(text: "", attachmentIDs: [], failedNames: []) == [.released(file.id, .removed)])
        #expect(!ledger.holds(words.id) && !ledger.holds(file.id), "Free to open from the list again")
        let placedAgain = ledger.beginPlacing(words)
        #expect(placedAgain)
        // Still being read in: nothing about it is decided yet.
        #expect(ledger.reviewBox(text: "", attachmentIDs: [], failedNames: []).isEmpty)
    }

    @Test func aFileThatLandsOnTryAgainCountsForItsShare() throws {
        let first = try share("Caption", file: "Video.pdf")
        var ledger = PendingShareLedger(conversationID: "chat-1")
        // The file didn't attach at first (the computer couldn't take big files yet).
        inBox(first, in: &ledger)
        #expect(ledger.reviewBox(text: "", attachmentIDs: [], failedNames: ["Video.pdf"]).isEmpty,
                "A file that didn't attach is still the share's")
        // Try again works: the file is a new big file copy now.
        ledger.fileLanded(shareID: first.id, index: 0, attachmentID: "big-file-9")
        let effects = ledger.leaveBox(as: "row-1", text: "", attachmentIDs: ["big-file-9"], now: now)
        #expect(sent(effects).count == 1, "It went with the message, not taken out")
        let id = try #require(sent(effects).first?.id)
        _ = ledger.dispatch("row-1", now: now)
        #expect(ledger.admitted(id, now: now).count == 1)
        #expect(ledger.admitted(id, now: now).isEmpty, "Settled once")
    }

    @Test func aMessageWithNoneOfTheShareLeavesItKept() throws {
        let first = try share("Shared paragraph")
        var ledger = PendingShareLedger(conversationID: "chat-1")
        inBox(first, in: &ledger)
        #expect(ledger.leaveBox(as: "row-1", text: "Something else", attachmentIDs: [], now: now)
                == [.released(first.id, .removed)])
    }

    // MARK: - The saved copy

    @Test func aMarkThatCantBeSavedFailsLoudly() throws {
        let first = try share("Must be saved")
        let folder = inbox.folder(first.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let submission = PendingShareSubmission(id: UUID(), conversationID: "chat-1", messageID: "row-1",
                                                state: .sending, at: now)
        #expect(throws: PendingShareError.storageUnavailable) { try inbox.recordSubmission(first.id, submission) }
    }

    @Test func aDeliveredShareIsNeverListedAgainEvenWhenDeletingItFails() throws {
        let first = try share("Delivered")
        let submission = PendingShareSubmission(id: UUID(), conversationID: "chat-1", messageID: "row-1",
                                                state: .sending, at: now)
        try inbox.recordSubmission(first.id, submission)

        // The share can't be moved out (its folder's parent is read-only): the mark still takes.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inbox.root.path)
        let gone = try inbox.markDelivered(first.id, submission)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.root.path)
        #expect(!gone)
        #expect(inbox.entries().isEmpty)
        // A fresh start never offers it either.
        let reopened = PendingShareInbox(root: inbox.root)
        #expect(reopened.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: inbox.folder(first.id).path))
        // Later, the deletion goes through.
        #expect(reopened.removeDelivered().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: inbox.folder(first.id).path))
    }

    @Test func aDeliveredShareWhoseMarkCantBeSavedIsDeletedOutright() throws {
        let first = try share("Delivered too")
        let submission = PendingShareSubmission(id: UUID(), conversationID: "chat-1", messageID: "row-1",
                                                state: .sending, at: now)
        try inbox.recordSubmission(first.id, submission)
        // Its placement can't be written any more (something else is in its place).
        let folder = inbox.folder(first.id)
        let placement = folder.appendingPathComponent("placement.json")
        try FileManager.default.removeItem(at: placement)
        try FileManager.default.createDirectory(at: placement, withIntermediateDirectories: false)
        #expect(try inbox.markDelivered(first.id, submission))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aMessageFoundInItsHistoryAfterARelaunchSettlesItsShare() throws {
        let first = try share("Reference after relaunch")
        let other = try share("Another chat's")
        try inbox.recordSubmission(first.id, PendingShareSubmission(
            id: UUID(), conversationID: "chat-1", messageID: "ref-msg-1", state: .unconfirmed, at: now))
        try inbox.recordSubmission(other.id, PendingShareSubmission(
            id: UUID(), conversationID: "chat-2", messageID: "ref-msg-1", state: .unconfirmed, at: now))

        let relaunched = PendingShareInbox(root: inbox.root)
        #expect(relaunched.markDelivered(conversationID: "chat-1", messageID: "ref-msg-other", at: now).isEmpty)
        #expect(relaunched.markDelivered(conversationID: "chat-1", messageID: "ref-msg-1", at: now) == [first.id])
        #expect(relaunched.entries().map(\.id) == [other.id])
    }
}

private extension PendingShareLedger.Effect {
    var shareID: String {
        switch self {
        case .inBox(let id), .submission(let id, _), .accepted(let id, _), .released(let id, _): id
        }
    }
}
