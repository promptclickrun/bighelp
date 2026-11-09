import Foundation
import Testing
@testable import Bighelp

/// A share from another app goes into the message box of the chat the person picked, through the
/// same path as Add and a drop, and its saved copy goes only once it has left that box (#922).
@Suite(.serialized)
@MainActor
struct PendingShareComposerTests {
    private let inbox: PendingShareInbox

    init() {
        inbox = PendingShareInbox(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-share-composer-" + UUID().uuidString, isDirectory: true))
    }

    private func save(text: String = "", link: String? = nil, note: String = "",
                      files: [(name: String, data: Data, type: String, mime: String, kind: PendingShare.File.Kind)] = []) throws -> PendingShare {
        let draft = try inbox.begin()
        if !text.isEmpty { try draft.addText(text) }
        if let link { try draft.addLink(link) }
        for file in files {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + file.name)
            try file.data.write(to: source)
            try draft.addFile(copying: source, suggestedName: file.name, kind: file.kind, typeIdentifier: file.type,
                              mimeType: file.mime, preferredExtension: nil)
        }
        return try draft.commit(note: note)
    }

    private var savedIDs: [String] { inbox.entries().map(\.id) }

    @Test func aLinkAndNoteFillTheBoxAndStaySavedUntilTheBoxEmpties() async throws {
        let share = try save(link: "https://example.com/made-up", note: "Thoughts?")
        let model = ChatModel(conversationID: "share-link", client: ConversationFixtureClient(), initialItems: [])
        var settled: [String] = []

        #expect(await model.placeShare(share, from: inbox) { settled.append($0) } == .placed)
        #expect(model.draft == "Thoughts?\n\nhttps://example.com/made-up")
        #expect(savedIDs == [share.id], "Nothing is deleted while it's only in the box")

        model.draft += " Please be brief."
        #expect(settled.isEmpty)
        // Send clears the box, as does the person removing everything.
        model.draft = ""
        #expect(settled == [share.id])
    }

    @Test func aFileGoesThroughTheDropPathAndKeepsItsName() async throws {
        let share = try save(text: "See attached",
                             files: [("Made-up notes.txt", Data("synthetic notes".utf8), "public.plain-text", "text/plain", .file)])
        let model = ChatModel(conversationID: "share-file", client: ConversationFixtureClient(), initialItems: [])
        var settled: [String] = []

        #expect(await model.placeShare(share, from: inbox) { settled.append($0) } == .placed)
        #expect(model.draftAttachmentFailures.isEmpty)
        let attachment = try #require(model.draftAttachments.first)
        #expect(attachment.fileName == "Made-up notes.txt" && attachment.mimeType == "text/plain")
        #expect(attachment.data == Data("synthetic notes".utf8))
        #expect(attachment.id == "attachment_share_\(share.id)_0")

        model.draft = ""
        #expect(settled.isEmpty, "The file is still in the box")
        model.removeDraftAttachment(id: attachment.id)
        #expect(settled == [share.id])
    }

    @Test func aFileThatCantAttachSaysWhyAndKeepsTheShare() async throws {
        let share = try save(files: [("Broken.png", Data("not a picture".utf8), "public.png", "image/png", .image)])
        let model = ChatModel(conversationID: "share-broken", client: ConversationFixtureClient(), initialItems: [])
        var settled: [String] = []

        #expect(await model.placeShare(share, from: inbox) { settled.append($0) } == .placed)
        let failure = try #require(model.draftAttachmentFailures.first)
        #expect(failure.name == "Broken.png")
        #expect(settled.isEmpty && savedIDs == [share.id])

        model.removeDraftAttachmentFailure(id: failure.id)
        #expect(settled == [share.id])
    }

    @Test func addingTheSameShareAgainChangesNothing() async throws {
        let share = try save(text: "Once", files: [("a.txt", Data("a".utf8), "public.plain-text", "text/plain", .file)])
        let model = ChatModel(conversationID: "share-twice", client: ConversationFixtureClient(), initialItems: [])
        #expect(await model.placeShare(share, from: inbox) { _ in } == .placed)
        #expect(await model.placeShare(share, from: inbox) { _ in } == .alreadyHere)
        #expect(model.draft == "Once")
        #expect(model.draftAttachments.count == 1)
    }

    @Test func aChatBackAfterARelaunchDoesNotRepeatTheWords() async throws {
        let share = try save(text: "Shared words")
        // Its draft came back from the journal; its files didn't, since they were only in memory.
        let model = ChatModel(conversationID: "share-relaunch", client: ConversationFixtureClient(), initialItems: [],
                              initialDraft: "Typed\n\nShared words")
        #expect(await model.placeShare(share, from: inbox) { _ in } == .placed)
        #expect(model.draft == "Typed\n\nShared words")
    }

    @Test func aChatLetGoBeforeSendKeepsTheShareForNextTime() async throws {
        let share = try save(text: "Not sent yet")
        let center = PendingShareCenter(inbox: inbox)
        await center.refresh()
        var model: ChatModel? = ChatModel(conversationID: "share-gone", client: ConversationFixtureClient(),
                                          initialItems: [])
        center.hold(share.id, by: try #require(model))
        _ = await model?.placeShare(share, from: inbox) { center.settled($0) }
        #expect(center.next() == nil, "It's in a chat's message box")

        // The app ends, or the chat is let go, with the share still in its box.
        model = nil
        let relaunched = PendingShareCenter(inbox: inbox)
        await relaunched.refresh()
        #expect(relaunched.next()?.id == share.id)
    }

    // MARK: - The handoff

    private func handoff(to sessionID: String?, agentID: String = "juno", since: Date = .now,
                         dropped: @escaping @MainActor (String) -> Void = { _ in }) throws -> PendingShareHandoff {
        PendingShareHandoff(share: try save(text: "Handed off"), inbox: inbox,
                            destination: .init(scope: "scope-a", agentID: agentID, sessionID: sessionID),
                            since: since, onDropped: dropped)
    }

    @Test func onlyThePickedChatTakesTheShare() throws {
        let state = AppState()
        state.handOff(try handoff(to: "chat-1"))
        #expect(state.takePendingShare(conversationID: "chat-2", memberIDs: ["juno"], isOnTop: true, isNewChat: false) == nil)
        #expect(state.takePendingShare(conversationID: "chat-1", memberIDs: ["juno"], isOnTop: false, isNewChat: false) == nil)
        #expect(state.takePendingShare(conversationID: "chat-1", memberIDs: ["juno"], isOnTop: true, isNewChat: false) != nil)
        #expect(state.pendingShare == nil, "Taken once")
    }

    @Test func aNewChatTakesItOnlyForThatAgent() throws {
        let state = AppState()
        state.handOff(try handoff(to: nil))
        #expect(state.takePendingShare(conversationID: "new", memberIDs: ["kai"], isOnTop: true, isNewChat: true) == nil)
        #expect(state.takePendingShare(conversationID: "old", memberIDs: ["juno"], isOnTop: true, isNewChat: false) == nil)
        #expect(state.takePendingShare(conversationID: "new", memberIDs: ["juno"], isOnTop: true, isNewChat: true) != nil)
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
        #expect(state.takePendingShare(conversationID: "chat-1", memberIDs: ["juno"], isOnTop: true, isNewChat: false) == nil)
        #expect(dropped == [late.share.id])
    }

    // MARK: - The review

    @Test func notNowWaitsForTheNextShareAndPlacingWaitsForItsChat() async throws {
        let first = try save(text: "First")
        let center = PendingShareCenter(inbox: inbox)
        await center.refresh()
        #expect(center.next()?.id == first.id)

        center.later(first.id)
        #expect(center.next() == nil)
        let second = try save(text: "Second")
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
        guard case .share(_, let placement)? = inbox.entries().first(where: { $0.id == first.id }) else {
            Issue.record("The share should still be saved")
            return
        }
        #expect(placement?.agentName == "Juno")
    }

    @Test func deletingOrSendingRemovesItFromTheDevice() async throws {
        let kept = try save(text: "Delete me")
        let sent = try save(text: "Send me")
        let center = PendingShareCenter(inbox: inbox)
        await center.refresh()
        try await center.delete(kept.id)
        center.settled(sent.id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(inbox.entries().isEmpty)
        #expect(center.next() == nil)
    }
}
