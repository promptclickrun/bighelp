import Foundation
import Testing
import UIKit
@testable import Bighelp

/// A share the share sheet's Send saved goes to the default bot by itself, in a chat nobody has
/// open, and is offered for review only when that gave up (#1069).
@Suite(.serialized)
@MainActor
struct PendingShareSenderTests {
    private let inbox: PendingShareInbox
    private let destination = PendingShareDestination(scope: "scope-a", agentID: "default", sessionID: "chat-9")

    init() {
        inbox = PendingShareInbox(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-share-sender-" + UUID().uuidString, isDirectory: true))
    }

    private func save(text: String = "A made-up article", note: String = "Sum this up", sendsItself: Bool = true,
                      fileBytes: Int? = nil) throws -> PendingShare {
        let draft = try inbox.begin()
        try draft.addText(text)
        if let fileBytes {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
            try Data(count: fileBytes).write(to: source)
            try draft.addFile(copying: source, suggestedName: "Made-up data.bin", kind: .file,
                              typeIdentifier: "public.data", mimeType: "application/octet-stream",
                              preferredExtension: "bin")
        }
        return try draft.commit(note: note, sendsItself: sendsItself)
    }

    private var savedIDs: [String] { inbox.entries().map(\.id) }

    private func placement(_ id: String) -> PendingSharePlacement? {
        guard case .share(_, let placement)? = inbox.entries().first(where: { $0.id == id }) else { return nil }
        return placement
    }

    /// Stands in for the computer: counts the chats asked for, and hands out the next one.
    private final class Computer {
        var chats: [ChatModel] = []
        var failure: PendingShareSender.Failure?
        var asked: [PendingShareDestination?] = []
        var notSent: [String?] = []
        var isActive = true
        var backgroundTime: TimeInterval = 30
        /// What happens while the chat is being made.
        var whileAsked: () throws -> Void = {}
    }

    private func sender(_ center: PendingShareCenter, _ computer: Computer) -> PendingShareSender {
        let destination = destination
        let sender = PendingShareSender(center: center) { earlier in
            computer.asked.append(earlier)
            try computer.whileAsked()
            if let failure = computer.failure { throw failure }
            return PendingShareSender.Target(chat: computer.chats.removeFirst(), destination: destination,
                                             agentName: "Juno")
        }
        sender.appIsActive = { computer.isActive }
        sender.tellNotSent = { computer.notSent.append($0) }
        sender.backgroundTimeLeft = { computer.backgroundTime }
        sender.settleLimit = .seconds(2)
        sender.retryGap = .zero
        return sender
    }

    private func chat(_ client: any ConversationClient = ConversationFixtureClient()) -> ChatModel {
        ChatModel(conversationID: "chat-9", client: client, initialItems: [])
    }

    @Test(.timeLimit(.minutes(1))) func aShareForTheDefaultBotGoesByItselfWithNoReview() async throws {
        let share = try save()
        let center = PendingShareCenter(inbox: inbox)
        await center.refresh()
        #expect(center.next() == nil, "bighelp sends it; nothing asks the person where it goes")
        let computer = Computer()
        let model = chat()
        computer.chats = [model]

        await sender(center, computer).run()

        #expect(computer.asked.count == 1)
        #expect(savedIDs.isEmpty, "Hermes took it")
        #expect(center.entries.isEmpty)
        #expect(model.draft.isEmpty)
        #expect(model.items.contains { item in
            guard item.role == .human, case .message(let text) = item.content else { return false }
            return text.contains("Sum this up") && text.contains("A made-up article")
        })
        _ = share
    }

    @Test(.timeLimit(.minutes(1))) func aShareSavedForAReviewStillWaitsForThePerson() async throws {
        let share = try save(sendsItself: false)
        let center = PendingShareCenter(inbox: inbox)
        let computer = Computer()
        await sender(center, computer).run()
        #expect(computer.asked.isEmpty)
        #expect(center.next()?.id == share.id)
        #expect(savedIDs == [share.id])
    }

    @Test(.timeLimit(.minutes(1))) func aComputerThatDoesNotAnswerKeepsTheShareAndTheReviewTakesOverAfterThreeTries() async throws {
        let share = try save()
        let center = PendingShareCenter(inbox: inbox)
        let computer = Computer()
        computer.failure = .unreachable
        let sender = sender(center, computer)

        await sender.run()
        await sender.run()
        #expect(savedIDs == [share.id] && center.next() == nil, "Kept, and tried again on the next run")
        await sender.run()
        #expect(computer.asked.count == 3)
        #expect(center.next()?.id == share.id, "After three tries the person picks where it goes")
        await sender.run()
        #expect(computer.asked.count == 3, "Given up: no more tries")
        #expect(computer.notSent.isEmpty, "In front, the review says it; no alert")
    }

    @Test(.timeLimit(.minutes(1))) func aRefusedSendLeavesNothingInTheHiddenChatAndTheNextRunUsesThatChat() async throws {
        let share = try save()
        let center = PendingShareCenter(inbox: inbox)
        let computer = Computer()
        let refusing = chat(ConversationFixtureClient(shouldFail: true))
        let working = chat()
        computer.chats = [refusing, working]
        let sender = sender(center, computer)

        await sender.run()
        #expect(savedIDs == [share.id])
        #expect(refusing.draft.isEmpty && !refusing.holdsShare(share.id), "Nobody sees this chat's message box")
        #expect(!center.isHeld(share.id))
        #expect(placement(share.id)?.isAutomatic == true && placement(share.id)?.recovery == .notSent)

        await sender.run()
        #expect(computer.asked.last == .some(destination), "The chat the first try made, not one more")
        #expect(savedIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aChatThePersonPickedOrAMessageThatMayHaveArrivedIsNeverTakenOver() async throws {
        let picked = try save(text: "Picked by hand")
        try inbox.place(picked.id, PendingSharePlacement(destination: destination, agentName: "Juno", placedAt: .now))
        let maybeSent = try save(text: "May have arrived")
        try inbox.place(maybeSent.id, PendingSharePlacement(
            destination: destination, agentName: "Juno", placedAt: .now,
            submission: PendingShareSubmission(id: UUID(), conversationID: "chat-9", messageID: "m1",
                                               state: .sending, at: .now),
            isAutomatic: true))
        let center = PendingShareCenter(inbox: inbox)
        let computer = Computer()
        await sender(center, computer).run()
        #expect(computer.asked.isEmpty)
        #expect(Set(savedIDs) == [picked.id, maybeSent.id])
        #expect(center.next() != nil, "Both are the person's to look at, as before the sheet had Send")
        // And on disk: bighelp's own choice of chat never replaces either.
        let automatic = PendingSharePlacement(destination: destination, agentName: "Juno", placedAt: .now,
                                              isAutomatic: true)
        #expect(throws: PendingShareError.gone) { try inbox.place(picked.id, automatic, onlyUnsent: true) }
        #expect(throws: PendingShareError.gone) { try inbox.place(maybeSent.id, automatic, onlyUnsent: true) }
    }

    @Test(.timeLimit(.minutes(1))) func aShareThePersonSendsWhileTheChatIsMadeIsNotSentTwice() async throws {
        let share = try save()
        let center = PendingShareCenter(inbox: inbox)
        let computer = Computer()
        let model = chat()
        computer.chats = [model]
        let inbox = inbox
        let destination = destination
        // The person's own Send, saved by another chat while this one connects.
        computer.whileAsked = {
            try inbox.place(share.id, PendingSharePlacement(
                destination: destination, agentName: "Juno", placedAt: .now,
                submission: PendingShareSubmission(id: UUID(), conversationID: "chat-1", messageID: "m1",
                                                   state: .sending, at: .now)))
        }
        await sender(center, computer).run()
        #expect(model.items.isEmpty && model.draft.isEmpty, "Nothing went in the sender's chat")
        #expect(placement(share.id)?.submission?.state == .sending && placement(share.id)?.isAutomatic == nil)
    }

    @Test(.timeLimit(.minutes(1))) func whileBighelpSendsItNothingElseOpensIt() async throws {
        let share = try save()
        let center = PendingShareCenter(inbox: inbox)
        let computer = Computer()
        computer.chats = [chat()]
        var heldWhileAsked = false
        computer.whileAsked = { heldWhileAsked = center.isHeld(share.id) && center.isBeingSent(share.id) }
        await sender(center, computer).run()
        #expect(heldWhileAsked)
        #expect(!center.isBeingSent(share.id))
    }

    @Test(.timeLimit(.minutes(1))) func threeTriggersInOneMomentAreOneTry() async throws {
        _ = try save()
        let center = PendingShareCenter(inbox: inbox)
        let computer = Computer()
        computer.failure = .unreachable
        let sender = sender(center, computer)
        sender.retryGap = .seconds(15)
        for _ in 0..<3 { await sender.run() }
        #expect(computer.asked.count == 1)
        #expect(center.next() == nil, "Not given up after one bad moment")
    }

    @Test(.timeLimit(.minutes(1))) func inTheBackgroundAFailureIsSaidOnceAndWaitingForThePersonIsNotATry() async throws {
        let share = try save()
        let center = PendingShareCenter(inbox: inbox)
        let computer = Computer()
        computer.isActive = false
        computer.failure = .notReady
        let sender = sender(center, computer)
        for _ in 0..<5 { await sender.run() }
        #expect(computer.notSent.count == 1, "One alert for one share")
        #expect(center.next() == nil && savedIDs == [share.id], "No agreement or computer yet: it keeps waiting")

        // Too little time left in the background: nothing is started.
        computer.failure = nil
        computer.backgroundTime = 4
        await sender.run()
        #expect(computer.asked.count == 5)

        // bighelp opens, the computer answers: it goes.
        computer.isActive = true
        computer.chats = [chat()]
        await sender.run()
        #expect(savedIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func wordsThatWouldRunAsACommandAndABigFileAreLeftForThePerson() async throws {
        let command = try save(text: "/goal clear", note: "")
        #expect(!PendingShareSender.goesAlone(command))
        let center = PendingShareCenter(inbox: inbox)
        let computer = Computer()
        computer.isActive = false
        await sender(center, computer).run()
        #expect(computer.asked.isEmpty, "Nothing is connected or sent for it")
        #expect(center.next()?.id == command.id, "The review offers it, so the person sees it first")
        #expect(computer.notSent == [nil])
        try inbox.remove(command.id)

        let big = try save(fileBytes: ChatAttachment.maximumBytes + 1)
        #expect(!PendingShareSender.goesAlone(big))
        #expect(!PendingShareSender.goesAlone(try save(text: "Words only", note: "/remind me")), "The note comes first")
        #expect(PendingShareSender.goesAlone(try save(text: "Words only", note: "A note")))
    }

    @Test(.timeLimit(.minutes(1))) func aShareGivenUpAfterARefusedSendIsOfferedOnItsOwn() async throws {
        let share = try save()
        let center = PendingShareCenter(inbox: inbox)
        let computer = Computer()
        computer.chats = (0..<3).map { _ in chat(ConversationFixtureClient(shouldFail: true)) }
        let sender = sender(center, computer)
        for _ in 0..<3 { await sender.run() }
        #expect(center.next()?.id == share.id)
        #expect(placement(share.id)?.isAutomatic == true)
    }

    // MARK: - What the share sheet and the app agree on

    @Test func theSheetReadsTheDefaultBotFromTheWidgetsFile() throws {
        #expect(PendingShareDefaultBot.fileName == BighelpWidgetSnapshot.fileName)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var snapshot = BighelpWidgetSnapshot.empty
        snapshot.defaultAgentName = "  Juno "
        try JSONEncoder.bighelpWidget.encode(snapshot).write(to: file)
        #expect(PendingShareDefaultBot.name(in: file) == "Juno")
        try JSONEncoder.bighelpWidget.encode(BighelpWidgetSnapshot.empty).write(to: file)
        #expect(PendingShareDefaultBot.name(in: file) == nil)
        try Data("not json".utf8).write(to: file)
        #expect(PendingShareDefaultBot.name(in: file) == nil)
    }

    @Test func theWakeRequestCarriesNothingAndBelongsToTheAppGroup() {
        let request = PendingShareWake.request()
        #expect(request.httpMethod == "HEAD" && request.httpBody == nil && request.url?.query == nil)
        #expect(request.url?.scheme == "https")
        let configuration = PendingShareWake.configuration()
        #expect(configuration.identifier == PendingShareWake.sessionIdentifier)
        #expect(configuration.sharedContainerIdentifier == PendingShareInbox.appGroup)
        #expect(configuration.sessionSendsLaunchEvents)
    }

    @Test func aShareSavedBeforeTheSheetHadSendStillReads() throws {
        let old = try save(sendsItself: false)
        let manifest = try String(contentsOf: inbox.folder(old.id).appendingPathComponent("share.json"), encoding: .utf8)
        #expect(!manifest.contains("sendsItself"), "The saved file is what an older build wrote")
        guard case .share(let read, _)? = inbox.entries().first else {
            Issue.record("The share didn't read")
            return
        }
        #expect(read.sendsItself == nil)
        let new = try save(text: "Another made-up article")
        #expect(inbox.entries().contains { entry in
            if case .share(let share, _) = entry { return share.id == new.id && share.sendsItself == true }
            return false
        })
    }
}
