import Foundation
import Testing
import UserNotifications
@testable import Bighelp

/// Which alerts take typed words, and how the field is put on them.
struct AlertReplyCategoryTests {
    private final class Categories: BighelpNotificationCategoryStore, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Set<UNNotificationCategory>
        init(_ stored: Set<UNNotificationCategory> = []) { self.stored = stored }
        func categories() async -> Set<UNNotificationCategory> { lock.withLock { stored } }
        func setCategories(_ categories: Set<UNNotificationCategory>) { lock.withLock { stored = categories } }
    }

    private let reference = String(repeating: "r", count: 43)

    private func userInfo(_ eventType: String, reference: String? = nil) -> [AnyHashable: Any] {
        var loopdy: [String: Any] = ["version": 2, "eventType": eventType]
        if let reference { loopdy["sessionReference"] = reference }
        return ["loopdy": loopdy]
    }

    @Test func aReplyAndAQuestionTakeWordsAndNothingElseDoes() {
        #expect(BighelpAlertReply.categoryID(for: userInfo("session.completed", reference: reference)) == "BIGHELP_REPLY")
        #expect(BighelpAlertReply.categoryID(for: userInfo("clarification.required", reference: reference)) == "BIGHELP_ANSWER")
        #expect(BighelpAlertReply.categoryID(for: userInfo("approval.required", reference: reference)) == nil)
        #expect(BighelpAlertReply.categoryID(for: userInfo("scheduled.completed", reference: reference)) == nil)
        // An alert that names no chat has nowhere to send words.
        #expect(BighelpAlertReply.categoryID(for: userInfo("session.completed")) == nil)
        #expect(BighelpAlertReply.categoryID(for: [:]) == nil)
    }

    @Test func theAlertGetsATextFieldThatNeedsTheUnlockedPhone() async throws {
        let old = UNNotificationCategory(identifier: "LOOPDY_AGENT_UPDATE", actions: [], intentIdentifiers: [], options: [])
        let store = Categories([old])
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "LOOPDY_AGENT_UPDATE"
        content.userInfo = userInfo("session.completed", reference: reference)
        await BighelpAlertReply.add(to: content, categories: store)

        #expect(content.categoryIdentifier == "BIGHELP_REPLY")
        let registered = await store.categories()
        #expect(registered.contains(old))
        let category = try #require(registered.first { $0.identifier == "BIGHELP_REPLY" })
        let field = try #require(category.actions.first as? UNTextInputNotificationAction)
        #expect(field.identifier == BighelpAlertReply.actionID)
        #expect(field.options.contains(.authenticationRequired))
        #expect(!field.options.contains(.foreground))
        #expect(category.actions.last?.options.contains(.foreground) == true)
        #expect(registered.contains { $0.identifier == "BIGHELP_ANSWER" })

        // Any other alert keeps the buttons its push brought.
        let approval = UNMutableNotificationContent()
        approval.categoryIdentifier = "LOOPDY_REVIEW"
        approval.userInfo = userInfo("approval.required", reference: reference)
        await BighelpAlertReply.add(to: approval, categories: store)
        #expect(approval.categoryIdentifier == "LOOPDY_REVIEW")
    }
}

/// Words typed on an alert, and the island's Approve and Deny: which request they are for, and where they go.
@MainActor
struct AlertReplyTests {
    private let reference = String(repeating: "r", count: 43)

    // MARK: Which request an answer is for

    private func approval(_ id: String, chat: String, command: String = "rm -rf build/cache",
                          allowed: [ApprovalDecision] = [.once, .session, .deny],
                          expires: Date = .distantFuture) -> DashboardAttentionItem {
        DashboardAttentionItem(id: id, title: command, detail: "recursive delete", urgency: .important,
                               approvalID: id, sessionID: chat, agentID: "scout",
                               interaction: .approval(.init(eventID: id, approvalID: id, allowedDecisions: allowed, expiresAt: expires)),
                               createdAt: .distantPast)
    }

    private func question(_ id: String, chat: String, choices: [String] = [], custom: Bool = true) -> DashboardAttentionItem {
        DashboardAttentionItem(id: id, title: "Which fare?", detail: "", urgency: .needsReview, sessionID: chat, agentID: "scout",
                               interaction: .clarification(.init(eventID: id, requestID: id, sessionID: chat, question: "Which fare?",
                                                                 choices: choices, allowsCustomResponse: custom,
                                                                 isMultiSelect: false, expiresAt: nil)),
                               createdAt: .distantPast)
    }

    @Test func aYesGoesOnlyToTheOneShortCommandThatWaitsInTheChat() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mine = approval("a1", chat: "chat-1")
        let elsewhere = approval("a2", chat: "chat-2")
        #expect(try ChatOutsidePrompt.approval(in: [elsewhere, mine], chatID: "chat-1", decision: .once, now: now).get().id == "a1")
        #expect(ChatOutsidePrompt.approval(in: [elsewhere], chatID: "chat-1", decision: .once, now: now) == .failure(.nothingWaits))
        #expect(ChatOutsidePrompt.approval(in: [approval("old", chat: "chat-1", expires: now)], chatID: "chat-1", decision: .once, now: now)
                == .failure(.nothingWaits))
        // Two requests: a yes on the island could be for either.
        #expect(ChatOutsidePrompt.approval(in: [mine, approval("a3", chat: "chat-1")], chatID: "chat-1", decision: .once, now: now)
                == .failure(.mustReview))
        // A command longer than the island shows whole is read in the app; a no needs no reading.
        let long = approval("a4", chat: "chat-1", command: String(repeating: "x", count: BighelpIslandMoment.wholeCommandCharacters + 1))
        #expect(ChatOutsidePrompt.approval(in: [long], chatID: "chat-1", decision: .once, now: now) == .failure(.mustReview))
        #expect(try ChatOutsidePrompt.approval(in: [long], chatID: "chat-1", decision: .deny, now: now).get().id == "a4")
        #expect(ChatOutsidePrompt.approval(in: [approval("a5", chat: "chat-1", allowed: [.deny])], chatID: "chat-1", decision: .once, now: now)
                == .failure(.mustReview))
    }

    @Test func typedWordsAnswerAQuestionOnlyWhenWordsCanAnswerIt() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try ChatOutsidePrompt.question(in: [question("q1", chat: "chat-1")], chatID: "chat-1", answer: "The cheap one", now: now).get().id == "q1")
        let picks = question("q2", chat: "chat-1", choices: ["Economy", "Flex"], custom: false)
        #expect(try ChatOutsidePrompt.question(in: [picks], chatID: "chat-1", answer: "Flex", now: now).get().id == "q2")
        #expect(ChatOutsidePrompt.question(in: [picks], chatID: "chat-1", answer: "First class", now: now) == .failure(.mustReview))
        #expect(ChatOutsidePrompt.question(in: [question("q3", chat: "chat-2")], chatID: "chat-1", answer: "Yes", now: now) == .failure(.nothingWaits))
    }

    // MARK: Where the words go

    private final class Log { var notices: [(ChatOutsideFailure, String?)] = []; var selected: [UUID] = []; var connects = 0 }

    private func actions(selected: UUID?, appIsActive: Bool, target: ChatOutsideTarget?, log: Log) -> ChatOutsideActions {
        var actions = ChatOutsideActions(
            connect: { log.connects += 1; throw BighelpShortcutServiceError.connectionUnavailable },
            selectedHostID: { log.selected.last ?? selected },
            selectHost: { log.selected.append($0); return true })
        actions.appIsActive = { appIsActive }
        actions.alertTarget = { _ in target }
        actions.rowTarget = { _ in target }
        actions.notify = { failure, text, _, _ in log.notices.append((failure, text)) }
        return actions
    }

    private var alert: BighelpProactiveNotificationOpen? {
        BighelpProactiveNotificationOpen(userInfo: ["loopdy_notification_version": "1", "loopdy_event_id": "event-1",
                                                    "loopdy_event_type": "session.completed", "loopdy_agent_id": "scout"])
    }

    @Test func wordsForAnotherComputersChatNeverMoveAPersonWhoIsUsingTheApp() async {
        let here = UUID(), there = UUID(), log = Log()
        let target = ChatOutsideTarget(hostID: there, profileID: "scout", chat: .reference(reference))
        await actions(selected: here, appIsActive: true, target: target, log: log)
            .receiveReply("On my way", alert: alert, agentName: "Scout", thread: "scout")
        #expect(log.selected.isEmpty)
        #expect(log.connects == 0)
        #expect(log.notices.map(\.0) == [.otherComputerInUse])
        // The words are in the notice, so they are not lost.
        #expect(log.notices.first?.1 == "On my way")
    }

    @Test func withTheAppClosedTheChatsComputerIsUsedAndAFailureIsSaid() async {
        let here = UUID(), there = UUID(), log = Log()
        let target = ChatOutsideTarget(hostID: there, profileID: "scout", chat: .reference(reference))
        await actions(selected: here, appIsActive: false, target: target, log: log)
            .receiveReply("  On my way \n", alert: alert, agentName: "Scout", thread: "scout")
        // The chat's computer is used, and the person's own is put back after.
        #expect(log.selected == [there, here])
        #expect(log.connects == 1)
        #expect(log.notices.map(\.0) == [.unavailable])
        #expect(log.notices.first?.1 == "On my way")
    }

    @Test func anAlertThatNamesNoChatAndEmptyWordsSendNothing() async {
        let here = UUID(), log = Log()
        let none = actions(selected: here, appIsActive: false, target: nil, log: log)
        await none.receiveReply("Hello", alert: alert, agentName: nil, thread: "scout")
        await none.receiveReply("   ", alert: alert, agentName: nil, thread: "scout")
        await none.receiveDecision(rowID: "native-row", approves: true)
        #expect(log.connects == 0)
        #expect(log.notices.map(\.0) == [.chatGone, .chatGone])
        #expect(ChatOutsideNotice.body(for: .notSent, text: "Hello").contains("“Hello”"))
        #expect(!ChatOutsideNotice.body(for: .mustReview, text: nil).contains("“"))
    }
}
