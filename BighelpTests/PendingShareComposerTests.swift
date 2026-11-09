import Foundation
import Testing
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
        // Taking the file out leaves it saved: only a send that carries it lets it go.
        model.removeDraftAttachment(id: attachment.id)
        model.draft = ""
        #expect(savedIDs == [share.id])
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

    @Test func aSendHermesDidntConfirmKeepsTheShareAndSaysItMayHaveArrived() async throws {
        let share = try save(text: "Maybe sent")
        let center = await center()
        let model = ChatModel(conversationID: "chat-1", client: ConversationFixtureClient(shouldFail: true),
                              initialItems: [])
        #expect(await model.placeShare(share, from: inbox, tracker: center) == .placed)

        await model.send()
        #expect(model.failureMessage != nil)
        #expect(savedIDs == [share.id], "Never deleted on a send that didn't confirm")
        let saved = try #require(placement(share.id))
        #expect(saved.submission?.state == .unconfirmed)
        #expect(saved.submission?.conversationID == "chat-1")
        #expect(saved.recovery == .maybeSent)
        // Not offered as unsent: only the list shows it, saying it may have arrived.
        #expect(center.next() == nil)
        #expect(center.entries.map(\.id) == [share.id])
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
        #expect(center.next(now: now) == nil, "The next review waits until bighelp comes back to the front")
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
}
