import Foundation
import Testing
import UIKit
@testable import Bighelp

/// A share from another app goes into the message box of the chat the person picked, through the
/// same path as Add and a drop, and its saved copy goes only once Hermes takes the message carrying
/// it, or the person deletes it (#922).
@Suite(.serialized)
@MainActor
struct PendingShareComposerTests {
    private let inbox: PendingShareInbox

    init() {
        inbox = PendingShareInbox(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-share-composer-" + UUID().uuidString, isDirectory: true))
    }

    private typealias SharedFile = (name: String, data: Data, type: String, mime: String, kind: PendingShare.File.Kind)

    private func save(text: String = "", link: String? = nil, note: String = "", files: [SharedFile] = [],
                      placedIn sessionID: String? = "chat-1") throws -> PendingShare {
        let draft = try inbox.begin()
        if !text.isEmpty { try draft.addText(text) }
        if let link { try draft.addLink(link) }
        for file in files {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + file.name)
            try file.data.write(to: source)
            try draft.addFile(copying: source, suggestedName: file.name, kind: file.kind, typeIdentifier: file.type,
                              mimeType: file.mime, preferredExtension: nil)
        }
        let share = try draft.commit(note: note)
        if let sessionID {
            try inbox.place(share.id, PendingSharePlacement(
                destination: .init(scope: "scope-a", agentID: "default", sessionID: sessionID),
                agentName: "Juno", placedAt: .now))
        }
        return share
    }

    private func center() async -> PendingShareCenter {
        let center = PendingShareCenter(inbox: inbox)
        await center.refresh()
        return center
    }

    private var savedIDs: [String] { inbox.entries().map(\.id) }

    private func placement(_ id: String) -> PendingSharePlacement? {
        guard case .share(_, let placement)? = inbox.entries().first(where: { $0.id == id }) else { return nil }
        return placement
    }

    private let notes: SharedFile = ("Made-up notes.txt", Data("synthetic notes".utf8), "public.plain-text",
                                     "text/plain", .file)

    // MARK: - Into the box, and out only once Hermes has it

    @Test func aLinkAndNoteFillTheBoxAndGoOnlyOnceHermesTakesThem() async throws {
        let share = try save(link: "https://example.com/made-up", note: "Thoughts?")
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [])

        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)
        #expect(model.draft == "Thoughts?\n\nhttps://example.com/made-up")
        // Emptying the box by hand sends nothing and deletes nothing.
        model.draft = ""
        #expect(savedIDs == [share.id])
        model.draft = "Thoughts?\n\nhttps://example.com/made-up"

        await model.send()
        #expect(savedIDs.isEmpty, "Hermes took it")
        #expect(center.entries.isEmpty)
    }

    @Test func aFileGoesThroughTheDropPathAndKeepsItsName() async throws {
        let share = try save(text: "See attached", files: [notes])
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [])

        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)
        #expect(model.draftAttachmentFailures.isEmpty)
        let attachment = try #require(model.draftAttachments.first)
        #expect(attachment.fileName == "Made-up notes.txt" && attachment.mimeType == "text/plain")
        #expect(attachment.data == Data("synthetic notes".utf8))
        #expect(attachment.id == "attachment_share_\(share.id)_0")
        // Taking the file out and erasing the words: out of this chat, kept, and free to open again.
        model.shareBoxReviewDelay = .milliseconds(10)
        model.removeDraftAttachment(id: attachment.id)
        #expect(model.holdsShare(share.id), "Its words are still there")
        model.draft = ""
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.holdsShare(share.id) && !center.isHeld(share.id))
        #expect(savedIDs == [share.id])
        #expect(center.entries.map(\.id) == [share.id], "Listed, to open in any chat")
    }

    @Test func retryingTheOnlyFileThatDidntAttachStillFindsIt() async throws {
        let share = try save(files: [("Broken.png", Data("not a picture".utf8), "public.png", "image/png", .image)])
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [])

        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)
        let first = try #require(model.draftAttachmentFailures.first)
        // Try again clears the failure before the file is read again; the box is empty for a moment.
        await model.retryFailedDraftAttachments()
        let again = try #require(model.draftAttachmentFailures.first)
        #expect(again.name == "Broken.png" && again.message == first.message, "Read again, not missing")
        let file = try #require(share.files.first)
        #expect(FileManager.default.fileExists(atPath: inbox.fileURL(file, in: share).path))
        #expect(savedIDs == [share.id])
    }

    @Test func addingTheSameShareAgainChangesNothing() async throws {
        let share = try save(text: "Once", files: [notes])
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [])
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .alreadyHere)
        #expect(model.draft == "Once")
        #expect(model.draftAttachments.count == 1)
    }

    @Test func aChatBackAfterARelaunchDoesNotRepeatTheWords() async throws {
        let share = try save(text: "Shared words")
        let center = await center()
        // Its draft came back from the journal; its files didn't, since they were only in memory.
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [],
                              initialDraft: "Typed\n\nShared words")
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)
        #expect(model.draft == "Typed\n\nShared words")
    }

    // MARK: - Every way it can fail to go

    @Test func aMessageWaitingForTheConnectionKeepsTheShareThroughARelaunch() async throws {
        let share = try save(text: "Sent while offline")
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: NativeWorkspaceUnavailableClient(), initialItems: [])
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)

        await model.send()
        #expect(model.stagedSends.count == 1, "Waiting in the chat, in memory only")
        #expect(model.draft.isEmpty)
        #expect(placement(share.id)?.submission?.state == .staged)
        #expect(placement(share.id)?.submission?.messageID == model.stagedSends.first?.id)

        // bighelp ends with the message still waiting: it was never sent, and says so.
        let relaunched = PendingShareCenter(inbox: inbox)
        await relaunched.refresh()
        #expect(relaunched.next()?.id == share.id)
        #expect(placement(share.id)?.recovery == .notSent)
    }

    @Test func anotherComputerBeforeSendLetsTheShareGoWithoutDeletingIt() async throws {
        let share = try save(text: "Not sent yet", files: [notes])
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [])
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)
        #expect(center.isHeld(share.id))

        // A host or account switch retires the chat and clears its box.
        model.invalidateReferenceOwnership()
        #expect(model.draft.isEmpty && model.draftAttachments.isEmpty)
        #expect(savedIDs == [share.id])
        #expect(!center.isHeld(share.id))
        #expect(center.next()?.id == share.id, "Offered again, for the computer in use")
        #expect(placement(share.id)?.recovery == .notSent)
    }

    @Test func aSendThatDefinitelyFailedPutsItBackInTheBoxWithItsShare() async throws {
        let share = try save(text: "Not delivered")
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(shouldFail: true),
                              initialItems: [])
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)

        await model.send()
        // Not Try again, which would send it without its share: back in the box with it.
        #expect(model.failureMessage != nil && model.retryRequest == nil)
        #expect(model.draft == "Not delivered")
        #expect(model.holdsShare(share.id))
        #expect(placement(share.id)?.submission == nil && placement(share.id)?.recovery == .notSent)
        #expect(savedIDs == [share.id])
    }

    @Test func aMessagePutBackInTheBoxTakesItsShareWithIt() async throws {
        let share = try save(text: "Back again")
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: NativeWorkspaceUnavailableClient(), initialItems: [])
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)
        await model.send()
        #expect(placement(share.id)?.submission?.state == .staged)

        // The chat never came for it: it goes back in the box, and so does its share.
        model.returnStagedSendsToBox()
        #expect(model.draft == "Back again")
        #expect(placement(share.id)?.submission == nil)
        #expect(center.isHeld(share.id))
    }

    @Test func aMessageWithoutAnyOfTheShareLeavesItSaved() async throws {
        let share = try save(text: "Shared paragraph")
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [])
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)
        model.draft = "Something else entirely"
        await model.send()
        #expect(savedIDs == [share.id], "Taken out by the person, not sent")
        #expect(center.next() == nil && center.entries.map(\.id) == [share.id])
    }

    // MARK: - The handoff

    private func handoff(to sessionID: String?, since: Date = .now,
                         dropped: @escaping @MainActor (String) -> Void = { _ in }) throws -> PendingShareHandoff {
        PendingShareHandoff(share: try save(text: "Handed off", files: [notes], placedIn: sessionID), inbox: inbox,
                            destination: .init(scope: "scope-a", agentID: "default", sessionID: sessionID),
                            since: since, onDropped: dropped)
    }

    @Test func onlyThePickedChatTakesTheShare() throws {
        let state = AppState()
        state.handOff(try handoff(to: "chat-1"))
        #expect(state.takePendingShare(conversationID: "chat-2", isOnTop: true) == nil)
        #expect(state.takePendingShare(conversationID: "chat-1", isOnTop: false) == nil)
        #expect(state.takePendingShare(conversationID: "chat-1", isOnTop: true) != nil)
        #expect(state.pendingShare == nil, "Taken once")
    }

    @Test func aNewChatTakesItOnlyOnceHermesHasMadeIt() async throws {
        // The new chat's local canvas shows first; Hermes makes the chat a moment later, and the
        // canvas passes on only its text. The share waits for the chat Hermes made.
        let state = AppState()
        state.handOff(try handoff(to: "session-9"))
        #expect(state.takePendingShare(conversationID: "local-draft:canvas", isOnTop: true) == nil)
        #expect(state.pendingShare != nil)
        let taken = try #require(state.takePendingShare(conversationID: "session-9", isOnTop: true))
        #expect(state.takePendingShare(conversationID: "session-9", isOnTop: true) == nil, "Once")

        let center = await center()
        let model = ChatModel(conversationID: "session-9", client: ConversationFixtureClient(), initialItems: [])
        #expect(await model.placeShare(taken.share, from: inbox, tracker: center) == .placed)
        #expect(model.draft == "Handed off" && model.draftAttachments.count == 1)
        await model.send()
        #expect(savedIDs.isEmpty)
    }

    @Test func anotherComputerOrAccountNeverTakesItAndItIsOfferedAgain() throws {
        var dropped: [String] = []
        let state = AppState()
        let first = try handoff(to: "chat-1", dropped: { dropped.append($0) })
        state.handOff(first)
        state.resetForHostBoundary()
        #expect(state.pendingShare == nil && dropped == [first.share.id])

        let second = try handoff(to: "chat-1", dropped: { dropped.append($0) })
        state.handOff(second)
        state.resetForAccountBoundary()
        #expect(state.pendingShare == nil && dropped == [first.share.id, second.share.id])
    }

    @Test func aChatThatOpensTooLateDoesNotTakeIt() throws {
        var dropped: [String] = []
        let state = AppState()
        let late = try handoff(to: "chat-1", since: Date().addingTimeInterval(-(AppState.pendingComposerLifetime + 1)),
                               dropped: { dropped.append($0) })
        state.handOff(late)
        #expect(state.takePendingShare(conversationID: "chat-1", isOnTop: true) == nil)
        #expect(dropped == [late.share.id])
    }

    // MARK: - The review and the list

    @Test func notNowWaitsForTheNextShareAndPlacingWaitsForItsChat() async throws {
        let first = try save(text: "First", placedIn: nil)
        let center = await center()
        #expect(center.next()?.id == first.id)

        center.later(first.id)
        #expect(center.next() == nil)
        let second = try save(text: "Second", placedIn: nil)
        await center.refresh()
        #expect(center.next() != nil, "A new share brings back the ones put off")

        let destination = PendingShareDestination(scope: "scope-a", agentID: "juno", sessionID: nil)
        let now = Date()
        try await center.place(first, at: destination, agentName: "Juno", now: now)
        #expect(center.next(now: now) == nil, "The next review waits until Bighelp comes back to the front")
        await center.refresh()
        #expect(center.next(now: now)?.id == second.id, "The first is on its way to its chat")
        try await center.place(second, at: destination, agentName: "Juno", now: now)
        await center.refresh()
        #expect(center.next(now: now) == nil)
        #expect(center.next(now: now.addingTimeInterval(PendingShareCenter.handOffLifetime + 1)) != nil,
                "Offered again when no chat took them")
        center.release(first.id)
        #expect(center.next(now: now)?.id == first.id, "A chat that couldn't take it gives it back at once")

        // The new chat Hermes made is named in its placement from now on.
        try await center.bind(first.id, to: "session-9")
        #expect(placement(first.id)?.destination.sessionID == "session-9")
    }

    @Test func everyShareStaysInTheListAndAFullInboxEmptiesThroughIt() async throws {
        // Filled to the standard limit, every share put off and bighelp back in front: nothing opens
        // on its own, but the list (☰ › Shared with bighelp) has every one, and Delete makes room.
        var ids: [String] = []
        for index in 0..<PendingShareLimits.standard.shares {
            ids.append(try save(text: "Put off \(index)", placedIn: nil).id)
        }
        let center = await center()
        for id in ids { center.later(id) }
        await center.refresh()
        #expect(center.next() == nil)
        #expect(center.waitingCount == ids.count)
        center.showList()
        #expect(center.isListShown)

        let refused = try inbox.begin()
        try refused.addText("One more")
        #expect(throws: PendingShareError.inboxFull(shares: ids.count)) { _ = try refused.commit(note: "") }
        refused.rollback()

        try await center.delete(ids[0])
        #expect(center.waitingCount == ids.count - 1)
        let next = try inbox.begin()
        try next.addText("Fits now")
        _ = try next.commit(note: "")
        await center.refresh()
        #expect(center.waitingCount == ids.count)
    }

    // MARK: - Second review: one lifecycle per message

    @Test func aSendingMarkThatCantBeSavedSendsNothing() async throws {
        let share = try save(text: "Must not go unsaved")
        let center = await center()
        let client = ShareCountingClient()
        let model = ChatModel(conversationID: "chat-1", client: client, initialItems: [])
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)

        // Its placement can't be written any more.
        let placementFile = inbox.folder(share.id).appendingPathComponent("placement.json")
        try FileManager.default.removeItem(at: placementFile)
        try FileManager.default.createDirectory(at: placementFile, withIntermediateDirectories: false)
        await model.send()
        #expect(client.sent.isEmpty, "Nothing reached the computer")
        #expect(model.failureMessage == ChatModel.unsavedShareMessage)
        #expect(model.draft == "Must not go unsaved" && model.holdsShare(share.id))
        #expect(!model.items.contains { $0.role == .human })
    }

    @Test func aDeliveredShareWhoseDeletionFailsIsNeverOfferedAgain() async throws {
        let share = try save(text: "Delivered once")
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [])
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)

        // The share's folder can't be moved out: only the spent mark takes.
        let root = inbox.root.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root) }
        await model.send()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
        #expect(center.entries.isEmpty && center.next() == nil)
        #expect(FileManager.default.fileExists(atPath: inbox.folder(share.id).path))

        // A fresh start never lists it, and its refresh finishes deleting it.
        let relaunched = PendingShareCenter(inbox: PendingShareInbox(root: inbox.root))
        await relaunched.refresh()
        #expect(relaunched.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: inbox.folder(share.id).path))
    }

    @Test func onlyTheJournalEntryAMessageWasRecordedAsSettlesItsShare() async throws {
        // Two messages, each carrying a share: B is admitted first, A is refused; then the other way.
        for refusesFirst in [false, true] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try DirectHermesConversationClient(rpc: ShareGateRPC(), hostIdentity: "host",
                profile: "default", runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch",
                drafts: .init(root: root))
            let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
            client.model = model
            let center = await center()
            let a = try save(text: "Share A \(refusesFirst)")
            let b = try save(text: "Share B \(refusesFirst)")
            #expect(await model.placeShare(a, from: inbox, tracker: center) == .placed)
            model.sharesLeaveBox(as: "row-a", message: "Share A \(refusesFirst)", attachments: [])
            let aID = try #require(model.dispatchShares("row-a").id)
            model.draft = ""
            #expect(await model.placeShare(b, from: inbox, tracker: center) == .placed)
            model.sharesLeaveBox(as: "row-b", message: "Share B \(refusesFirst)", attachments: [])
            let bID = try #require(model.dispatchShares("row-b").id)
            let entryA = try PendingShareCorrelation.$submission.withValue(aID) {
                try client.recordSubmission("Share A", method: "prompt.submit")
            }
            let entryB = try PendingShareCorrelation.$submission.withValue(bID) {
                try client.recordSubmission("Share B", method: "prompt.submit")
            }
            let unrelated = try client.recordSubmission("No share", method: "prompt.submit")

            if refusesFirst { try client.retainRejectedSubmission(entryA, code: 4007) }
            client.takeSubmissionAdmitted(unrelated.id)
            #expect(savedIDs.contains(a.id) && savedIDs.contains(b.id), "Another entry's admission settles nothing")
            client.takeSubmissionAdmitted(entryB.id)
            #expect(!savedIDs.contains(b.id))
            #expect(savedIDs.contains(a.id), "B's admission never spends A")
            if !refusesFirst { try client.retainRejectedSubmission(entryA, code: 4007) }
            client.admitShares(of: entryA.id)
            #expect(savedIDs.contains(a.id), "A refused: nothing can spend it")
        }
    }

    @Test func hermesAdmittingTheMessageSpendsItsShareBeforeTheTurnEnds() async throws {
        let share = try save(text: "Admitted early")
        let center = await center()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = ShareGateRPC()
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        try await client.recover(epoch: "epoch")
        defer { client.suspend() }
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)

        let sending = Task { await model.send() }
        defer { sending.cancel() }
        for _ in 0..<500 where !savedIDs.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(rpc.submits == ["Admitted early"])
        #expect(savedIDs.isEmpty, "Spent on admission; the turn hasn't ended")
    }

    @Test func aRefusalWithNewerWordsInTheBoxIsNotSentNotMaybe() async throws {
        let share = try save(text: "Refused words")
        let center = await center()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = ShareGateRPC()
        rpc.holdsSubmit = true
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        try await client.recover(epoch: "epoch")
        defer { client.suspend() }
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)

        let sending = Task { await model.send() }
        for _ in 0..<500 where !rpc.isHoldingSubmit { try await Task.sleep(for: .milliseconds(2)) }
        model.draft = "Newer words typed meanwhile"
        rpc.releaseSubmit(throwing: DirectHermesError.rpcRejected(code: 4007))
        await sending.value

        #expect(model.draft == "Newer words typed meanwhile", "The newer words are left alone")
        #expect(!model.holdsShare(share.id))
        #expect(placement(share.id)?.submission == nil, "Definitely not sent, not 'may have arrived'")
        #expect(placement(share.id)?.recovery == .notSent)
        #expect(center.entries.map(\.id) == [share.id])
    }

    @Test func anotherHermesHoldingTheChatDoesntSendTheShareOnInABranch() async throws {
        let share = try save(text: "Held elsewhere")
        let center = await center()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = ShareGateRPC()
        rpc.refusal = DirectHermesError.rpcRejected(code: 4090)
        let client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        try await client.recover(epoch: "epoch")
        defer { client.suspend() }
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)

        await model.send()
        #expect(model.branchContinuation == nil, "A branch would send it without its shared items")
        #expect(model.draft == "Held elsewhere" && model.holdsShare(share.id))
        #expect(placement(share.id)?.recovery == .notSent)
    }

    @Test func aLostReceiptThenItsHistorySpendsTheShareOnceHereOrAfterARelaunch() async throws {
        for relaunches in [false, true] {
            let share = try save(text: "Reference \(relaunches)")
            let center = await center()
            let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [])
            #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)
            model.sharesLeaveBox(as: "ref-message-\(relaunches)", message: "Reference \(relaunches)", attachments: [])
            model.draft = ""
            #expect(model.dispatchShares("ref-message-\(relaunches)").id != nil)
            // The receipt was lost: it may have arrived, and isn't put back to be sent again.
            model.shareMessageUnknown(row: "ref-message-\(relaunches)")
            #expect(placement(share.id)?.submission?.state == .unconfirmed)
            #expect(model.draft.isEmpty)

            // Later its history shows it arrived (`finishReferenceAcceptance`).
            if relaunches {
                let reopened = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [])
                let freshCenter = PendingShareCenter(inbox: PendingShareInbox(root: inbox.root))
                await freshCenter.refresh()
                reopened.shareTracker = freshCenter
                reopened.shareMessageAdmitted(row: "ref-message-\(relaunches)")
            } else {
                model.shareMessageAdmitted(row: "ref-message-\(relaunches)")
            }
            #expect(!savedIDs.contains(share.id))
        }
    }

    @Test func aFileThatOnlyAttachesOnTryAgainGoesWithItsMessageOnce() async throws {
        let share = try save(files: [notes])
        let center = await center()
        let client = ShareCountingClient()
        client.supportedAttachmentKinds = [.image]
        let model = ChatModel(conversationID: "chat-1", client: client, initialItems: [])
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)
        #expect(model.draftAttachmentFailures.count == 1, "Files aren't taken yet")

        client.supportedAttachmentKinds = [.image, .file]
        await model.retryFailedDraftAttachments()
        #expect(model.draftAttachmentFailures.isEmpty && model.draftAttachments.count == 1)
        await model.send()
        #expect(client.sent.count == 1)
        #expect(savedIDs.isEmpty, "It went with the message, and settled once")
    }

    @Test func sharesStagedSeparatelyGoInMessagesOfTheirOwn() async throws {
        let a = try save(text: "First while offline")
        let b = try save(text: "Second while offline")
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: NativeWorkspaceUnavailableClient(), initialItems: [])
        #expect(await model.placeShare(a, from: inbox, tracker: center) == .placed)
        await model.send()
        #expect(await model.placeShare(b, from: inbox, tracker: center) == .placed)
        await model.send()
        let messages = model.shareLedger.messages
        #expect(messages.count == 2 && Set(messages.map(\.id)).count == 2)
        #expect(placement(a.id)?.submission?.id != placement(b.id)?.submission?.id)
    }

    @Test func aDraftBackFromItsJournalAfterARelaunchStillCarriesItsShare() async throws {
        let share = try save(text: "Shared words")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = { DemoRepository<[String: ChatDraftJournal.Entry]>(directory: directory, name: "chat-drafts", seed: [:]) }
        let firstCenter = await center()
        let first = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [])
        #expect(await first.placeShare(share, from: inbox, tracker: firstCenter) == .placed)
        first.draft = "Typed first\n\n" + first.draft
        let journal = ChatDraftJournal(repository: repository())
        journal.write(first.draft, over: "", for: "chat-1")
        journal.flush()

        // bighelp opens again: the draft comes back from its journal, and Not now puts the review off.
        let relaunched = PendingShareCenter(inbox: PendingShareInbox(root: inbox.root))
        await relaunched.refresh()
        let draft = ChatDraftJournal(repository: repository()).openingDraft(
            for: SessionRecord(id: "chat-1", kind: .direct, agentIDs: ["default"], title: "Chat", draft: ""))
        #expect(draft == "Typed first\n\nShared words")
        #expect(relaunched.next()?.id == share.id)
        relaunched.later(share.id)

        // The chat opens with it (`PendingShareIntake`), before any Send.
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(), initialItems: [],
                              initialDraft: draft)
        model.shareTracker = relaunched
        model.restoreSharesInBox(scope: "scope-b")
        #expect(!model.holdsShare(share.id), "Never on another computer")
        model.restoreSharesInBox(scope: "scope-a")
        #expect(model.holdsShare(share.id) && relaunched.isHeld(share.id))

        await model.send()
        #expect(!savedIDs.contains(share.id), "The message carrying its words settled it")
        #expect(relaunched.entries.isEmpty)
    }

    // Its words are in the box already when the chat opens with it: after a relaunch (the draft came
    // back, the photo was only in memory), or by chance on its first Open. The photo still comes.
    @Test(arguments: [true, false])
    func openingAShareWhoseWordsTheBoxHoldsStillBringsItsPhoto(afterARelaunch: Bool) async throws {
        let share = try save(text: "Look at this", files: [photo])
        if afterARelaunch {
            let first = ChatModel(conversationID: "chat-1", client: ShareCountingClient(), initialItems: [])
            let firstCenter = await center()
            #expect(await first.placeShare(share, from: inbox, tracker: firstCenter) == .placed)
            #expect(first.draft == "Look at this" && first.draftAttachments.count == 1)
        }
        let center = PendingShareCenter(inbox: PendingShareInbox(root: inbox.root))
        await center.refresh()
        let client = ShareCountingClient()
        let model = ChatModel(conversationID: "chat-1", client: client, initialItems: [], initialDraft: "Look at this")

        await open(model, center: center, handingOff: share)
        #expect(model.draft == "Look at this", "Its words once")
        #expect(model.draftAttachments.count == 1, "Its photo is in the box")

        await model.send()
        #expect(client.sentAttachmentCounts == [1], "The photo went with the words")
        #expect(!savedIDs.contains(share.id))
    }

    @Test func wordsBackAfterARelaunchNeverSpendAShareWhosePhotoDidntComeBack() async throws {
        let share = try save(text: "Look at this", files: [photo])
        let center = PendingShareCenter(inbox: PendingShareInbox(root: inbox.root))
        await center.refresh()
        center.later(share.id)
        let client = ShareCountingClient()
        let model = ChatModel(conversationID: "chat-1", client: client, initialItems: [], initialDraft: "Look at this")

        await open(model, center: center)
        #expect(!model.holdsShare(share.id), "Only its words are here")
        await model.send()
        #expect(client.sent == ["Look at this"])
        #expect(savedIDs.contains(share.id), "Kept, photo and all, to send")
        let file = try #require(share.files.first)
        #expect(FileManager.default.fileExists(atPath: inbox.fileURL(file, in: share).path))
        #expect(center.entries.map(\.id) == [share.id])
    }

    /// The chat on top as it opens (`PendingShareIntake`), with a share handed to it, if any.
    private func open(_ model: ChatModel, center: PendingShareCenter, handingOff share: PendingShare? = nil) async {
        let state = AppState()
        state.path = [.chat(conversationID: model.conversationID)]
        if let share {
            state.handOff(PendingShareHandoff(share: share, inbox: inbox,
                destination: .init(scope: "scope-a", agentID: "default", sessionID: model.conversationID),
                since: .now, onDropped: { _ in }))
        }
        await PendingShareIntake.take(into: model, appState: state, scope: "scope-a", center: center)
    }

    private var photo: SharedFile {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return ("Made-up photo.png", png, "public.png", "image/png", .image)
    }

    @Test func aRefusedMessageIsBackInTheBoxOnceAndGoesOnceLater() async throws {
        for carriesShare in [true, false] {
            let words = "Refused words \(carriesShare)"
            let rpc = ShareGateRPC()
            rpc.refusal = DirectHermesError.rpcRejected(code: 4004)
            let chat = try await NativeShareChat(rpc: rpc)
            defer { chat.close() }
            let center = await center()
            let share: PendingShare? = try carriesShare ? save(text: words) : nil
            if let share { #expect(await chat.model.placeShare(share, from: inbox, tracker: center) == .placed) }
            else { chat.model.draft = words }

            await chat.model.send()
            #expect(chat.model.draft == words, "Back in the box once")
            if let share { #expect(chat.model.holdsShare(share.id)) }

            rpc.refusal = nil
            let sending = Task { await chat.model.send() }
            defer { sending.cancel() }
            try await until { rpc.submits.count == 2 && (share.map { !savedIDs.contains($0.id) } ?? true) }
            #expect(rpc.submits == [words, words])
            #expect(chat.model.draft.isEmpty)
        }
    }

    // MARK: - Messages with files over 8 MB

    @Test func aBigFileMessageHermesMayHaveTakenIsNeverSentAgainEvenAfterARelaunch() async throws {
        let share = try save(text: "Words with a big file")
        let center = await center()
        let rpc = ShareGateRPC()
        rpc.losesReceipt = true
        let chat = try await NativeShareChat(rpc: rpc)
        defer { chat.close() }
        #expect(await chat.model.placeShare(share, from: inbox, tracker: center) == .placed)
        let file = try await bigFile("Clip.mov")
        defer { BigFileStore.remove(file) }
        try chat.model.addDraftBigFile(file)

        // Hermes takes the prompt with its file, and its answer is lost.
        await chat.model.send()
        #expect(rpc.submits.count == 1 && rpc.submits.first?.hasPrefix("Words with a big file\n@file:") == true)
        #expect(chat.model.bigFileSends.isEmpty, "Shown as sent, not waiting for Try again")
        #expect(chat.model.items.contains { Self.text($0).hasPrefix("Words with a big file\n@file:") })
        #expect(BigFileUploadBoard.shared.state(for: file.id) == nil)
        BigFileUploadBoard.shared.retry(file.id)
        #expect(rpc.submits.count == 1, "Nothing sends it again")
        #expect(chat.model.retryRequest == nil && chat.model.failureMessage?.contains("unconfirmed") == true)
        #expect(placement(share.id)?.submission?.state == .unconfirmed)

        // bighelp opens again: it may have arrived, never "not sent".
        let relaunched = PendingShareCenter(inbox: PendingShareInbox(root: inbox.root))
        await relaunched.refresh()
        #expect(relaunched.entries.map(\.id) == [share.id])
        #expect(placement(share.id)?.recovery == .maybeSent)
    }

    // A starts the turn and Hermes is slow to answer its prompt, though its events say the turn runs;
    // B goes queued behind it and is refused. Both orders.
    @Test(arguments: [true, false])
    func eachMessageWithBigFilesSettlesOnlyOnItsOwnAdmission(aAnswersFirst: Bool) async throws {
        let rpc = ShareGateRPC()
        rpc.holdsPrompts = ["Message A", "Message B"]
        let chat = try await NativeShareChat(rpc: rpc)
        defer { chat.close() }
        let a = try await bigFile("A.mov")
        let b = try await bigFile("B.mov")
        defer {
            for file in [a, b] { BigFileUploadBoard.shared.finish(file.id); BigFileStore.remove(file) }
        }
        let model = chat.model

        model.draft = "Message A"
        try model.addDraftBigFile(a)
        let sendingA = Task { await model.send() }
        defer { sendingA.cancel() }
        try await until { rpc.isHolding("Message A") }
        chat.client.receive(.init(type: "message.start", sessionID: "runtime", payload: [:], sequence: 1))
        try await until { model.isMidSessionTurnLive }

        model.draft = "Message B"
        try model.addDraftBigFile(b)
        let sendingB = Task { await model.send() }
        try await until { rpc.isHolding("Message B") }

        let streaming = BighelpJSONValue.object(["status": .string("streaming"), "user_row_id": .integer(41)])
        let refusal = DirectHermesError.rpcRejected(code: 4004)
        if aAnswersFirst {
            rpc.answer("Message A", with: .success(streaming))
            try await until { !model.bigFileSends.contains { Self.text($0) == "Message A" } }
            rpc.answer("Message B", with: .failure(refusal))
            await sendingB.value
        } else {
            rpc.answer("Message B", with: .failure(refusal))
            await sendingB.value
            rpc.answer("Message A", with: .success(streaming))
            try await until { !model.bigFileSends.contains { Self.text($0) == "Message A" } }
        }

        // A: Hermes took it, so it's in the chat and the phone's copy of its file is gone.
        #expect(model.items.contains { Self.text($0).hasPrefix("Message A\n@file:") })
        #expect(!FileManager.default.fileExists(atPath: a.localURL.path))
        // B: refused, waiting with Try again, its own file kept.
        #expect(model.bigFileSends.map { Self.text($0) } == ["Message B"])
        #expect(FileManager.default.fileExists(atPath: b.localURL.path), "B's file is kept for Try again")
        #expect(Self.waitsForTryAgain(b.id))
    }

    private func bigFile(_ name: String) async throws -> ChatBigFile {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + name)
        try Data("synthetic \(name) \(UUID().uuidString)".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        return try await BigFileStore.prepare(copying: source, fileName: name, mimeType: "application/octet-stream")
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() { try await Task.sleep(for: .milliseconds(2)) }
        try #require(condition())
    }

    private static func text(_ item: TimelineItem) -> String {
        guard case .message(let text) = item.content else { return "" }
        return text
    }

    private static func waitsForTryAgain(_ fileID: String) -> Bool {
        if case .failed = BigFileUploadBoard.shared.state(for: fileID) { return true }
        return false
    }
}

/// A chat on a real native client over `ShareGateRPC`, with a computer that takes big files.
@MainActor
private struct NativeShareChat {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let rpc: ShareGateRPC
    let client: DirectHermesConversationClient
    let model: ChatModel

    init(rpc: ShareGateRPC) async throws {
        self.rpc = rpc
        client = try DirectHermesConversationClient(rpc: rpc, hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "saved", title: "Chat", epoch: "epoch", drafts: .init(root: root))
        client.bigFileHost = WholeFileUploadHost()
        model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        try await client.recover(epoch: "epoch")
    }

    func close() {
        rpc.hangUp()
        client.suspend()
        try? FileManager.default.removeItem(at: root)
    }
}

/// The plugin's `uploads/*` for files it already holds whole: every piece is there from the start.
@MainActor
private final class WholeFileUploadHost: BigFileUploadHost, @unchecked Sendable {
    private var names: [String: String] = [:]

    func supportsBigFiles() async -> Bool { true }

    func supportsSmallPieces() async -> Bool { true }

    func perform(_ operation: WorkspaceOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        switch operation {
        case .uploadsStart:
            let id = String((payload["sha256"]?.string ?? "").prefix(32))
            let byteCount = payload["byteCount"]?.integer ?? 0
            names[id] = payload["fileName"]?.string
            return ["uploadId": .string(id), "byteCount": .integer(byteCount), "chunkBytes": .integer(4 * 1_024 * 1_024),
                    "receivedChunks": .array([.integer(0)]), "finished": .boolean(false)]
        case .uploadsFinish:
            let id = payload["uploadId"]?.string ?? ""
            return ["uploadId": .string(id), "finished": .boolean(true), "inWorkspace": .boolean(true),
                    "path": .string("/srv/agent/uploads/2026-11-09/" + (names[id] ?? ""))]
        case .uploadsDiscard:
            return ["discarded": .boolean(true)]
        default:
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    func chunkRequest(_ chunk: DirectHermesBigFileChunk) async throws -> URLRequest {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }

    func reloadContext() async throws {}
}

/// Counts what reached the computer, and takes the kinds of attachment a test says.
private final class ShareCountingClient: AttachmentConversationClient {
    var supportedAttachmentKinds: Set<ChatAttachment.Kind> = [.image, .file]
    private(set) var sent: [String] = []
    private(set) var sentAttachmentCounts: [Int] = []

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        sent.append(message)
        sentAttachmentCounts.append(0)
        return ConversationResponse(items: [])
    }

    func send(message: String, attachments: [ChatAttachment], conversationID: String,
              onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        sent.append(message)
        sentAttachmentCounts.append(attachments.count)
        return ConversationResponse(items: [])
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        ConversationResponse(items: [])
    }
}

/// A computer that answers a prompt with `streaming` and never ends the turn, refuses it, takes it
/// and loses its answer, or holds its answer until the test gives one.
@MainActor
private final class ShareGateRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var refusal: DirectHermesError?
    var holdsSubmit = false
    /// Prompts starting with one of these wait for `answer(_:with:)`.
    var holdsPrompts: Set<String> = []
    var losesReceipt = false
    private(set) var submits: [String] = []
    private var held: CheckedContinuation<BighelpJSONValue, any Error>?
    private var heldPrompts: [String: CheckedContinuation<BighelpJSONValue, any Error>] = [:]
    var isHoldingSubmit: Bool { held != nil }

    func releaseSubmit(throwing error: any Error) {
        held?.resume(throwing: error)
        held = nil
    }

    func isHolding(_ prefix: String) -> Bool { heldPrompts[prefix] != nil }

    func answer(_ prefix: String, with result: Result<BighelpJSONValue, any Error>) {
        heldPrompts.removeValue(forKey: prefix)?.resume(with: result)
    }

    /// The connection drops: every prompt still held ends.
    func hangUp() {
        for prompt in heldPrompts.values { prompt.resume(throwing: DirectHermesError.notConnected) }
        heldPrompts = [:]
    }

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        switch method {
        case "session.events.since":
            return .object(["epoch": .string("epoch"), "latest_seq": .integer(0), "truncated": .boolean(false),
                            "events": .array([]), "count": .integer(0)])
        case "session.activate":
            return .object(["session_id": .string("runtime"), "stored_session_id": .string("saved"),
                            "running": .boolean(false), "messages": .array([])])
        case "prompt.submit":
            let text = params["text"]?.string ?? ""
            submits.append(text)
            if let refusal { throw refusal }
            if losesReceipt { throw DirectHermesError.disconnected(outcomeUnknown: true) }
            if let prefix = holdsPrompts.first(where: { text.hasPrefix($0) }) {
                return try await withCheckedThrowingContinuation { heldPrompts[prefix] = $0 }
            }
            if holdsSubmit { return try await withCheckedThrowingContinuation { held = $0 } }
            return .object(["status": .string("streaming"), "user_row_id": .integer(40 + submits.count)])
        case "file.attach":
            let path = params["path"]?.string ?? ""
            return .object(["attached": .boolean(true), "uploaded": .boolean(false),
                            "name": .string(params["name"]?.string ?? ""), "path": .string(path),
                            "ref_path": .string(path), "ref_text": .string("@file:" + path)])
        case "subagent.list":
            return .object(["subagents": .array([])])
        case "session.control.read":
            return .object(["control": .object(["goal": .null, "loop": .null, "heartbeat": .null,
                                                "revision": .string("fixture"), "updated_at": .integer(0)])])
        default:
            throw DirectHermesError.invalidResponse
        }
    }

    func disconnect() async {}
}
