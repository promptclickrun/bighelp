import Foundation
import UIKit
import UserNotifications

/// The chat an action from outside the app is for: a reply typed on an alert, or a button on the
/// Dynamic Island. It names its computer, so nothing meant for one computer's chat reaches another's.
struct ChatOutsideTarget: Equatable, Sendable {
    enum Chat: Equatable, Sendable {
        /// An alert's chat (`ManagedNotificationValidation.sessionReference`).
        case reference(String)
        /// A Live Activity row's chat, by Hermes' stored ID.
        case stored(String)
    }
    let hostID: UUID
    let profileID: String
    let chat: Chat
}

enum ChatOutsideFailure: Error, Equatable {
    /// Bighelp isn't set up to do this (no computer, the AI data agreement not given, demo data).
    case unavailable
    /// The chat is on another computer, and the person is using the app on this one.
    case otherComputerInUse
    case chatGone
    /// Nothing waits for an answer in the chat any more.
    case nothingWaits
    /// The request has to be read in the app before it gets a yes.
    case mustReview
    case notSent
}

/// Picks the one request an answer from outside the app is for.
enum ChatOutsidePrompt {
    /// The approval that waits in `chatID`. A yes needs one request whose command the island could show
    /// whole: with two waiting, or a longer command, the person decides in the app.
    static func approval(in items: [DashboardAttentionItem], chatID: String, decision: ApprovalDecision,
                         now: Date) -> Result<DashboardAttentionItem, ChatOutsideFailure> {
        let waiting = items.filter { item in
            guard item.sessionID == chatID, case .approval(let request) = item.interaction else { return false }
            return !request.isExpired(at: now)
        }
        guard let item = waiting.first else { return .failure(.nothingWaits) }
        guard waiting.count == 1, case .approval(let request) = item.interaction,
              request.allowedDecisions.contains(decision) else { return .failure(.mustReview) }
        if decision != .deny, item.title.count > BighelpIslandMoment.wholeCommandCharacters { return .failure(.mustReview) }
        return .success(item)
    }

    /// The question that waits in `chatID`, when words alone can answer it.
    static func question(in items: [DashboardAttentionItem], chatID: String, answer: String,
                         now: Date) -> Result<DashboardAttentionItem, ChatOutsideFailure> {
        let waiting = items.filter { item in
            guard item.sessionID == chatID, case .clarification(let request) = item.interaction else { return false }
            return !request.isExpired(at: now)
        }
        guard let item = waiting.first else { return .failure(.nothingWaits) }
        guard waiting.count == 1, case .clarification(let request) = item.interaction,
              request.questions.count == 1, !request.isMultiSelect, request.questions[0].lockedAnswer == nil,
              request.allowsCustomResponse || request.choices.contains(answer) else { return .failure(.mustReview) }
        return .success(item)
    }
}

/// Does what a person asked for from outside the app, through the Shortcuts host path, which
/// connects with Bighelp in the background. It never starts a chat, never moves a person who is
/// using the app to another computer, and never touches what they are typing.
@MainActor
struct ChatOutsideActions {
    /// Set as the app starts. Nil in the Live Activity extension and in tests that don't need it.
    static var shared: ChatOutsideActions?

    var connect: @MainActor () async throws -> BighelpShortcutWorkspace
    var selectedHostID: @MainActor () -> UUID?
    /// Makes a computer the one in use. False when it can't be.
    var selectHost: @MainActor (UUID) -> Bool
    var appIsActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    var now: @MainActor () -> Date = { .now }
    /// The chat an alert or a Live Activity row is about, from the phone's own notification setup.
    var alertTarget: @MainActor (BighelpProactiveNotificationOpen) -> ChatOutsideTarget? = { _ in nil }
    var rowTarget: @MainActor (String) -> ChatOutsideTarget? = { _ in nil }
    var notify: @MainActor (ChatOutsideFailure, _ text: String?, _ agentName: String?, _ thread: String) async -> Void = {
        await ChatOutsideNotice.post($0, text: $1, agentName: $2, thread: $3)
    }

    /// Words typed on an alert: an answer to its question, or the person's next message in its chat.
    /// Anything that doesn't go is said on the phone, with the words.
    func receiveReply(_ text: String, alert: BighelpProactiveNotificationOpen?, agentName: String?, thread: String) async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        do {
            guard let alert, let target = alertTarget(alert) else { throw ChatOutsideFailure.chatGone }
            if alert.eventType == BighelpAlertReply.questionEvent {
                try await answer(words, to: target)
            } else {
                try await reply(words, to: target)
            }
        } catch {
            await notify(error as? ChatOutsideFailure ?? .notSent, words, agentName, thread)
        }
    }

    /// Approve or Deny on the island.
    func receiveDecision(rowID: String, approves: Bool) async {
        do {
            guard let target = rowTarget(rowID) else { throw ChatOutsideFailure.chatGone }
            try await decide(approves: approves, in: target)
        } catch {
            await notify(error as? ChatOutsideFailure ?? .notSent, nil, nil, rowID)
        }
    }

    /// iOS gives an alert's action about half a minute in all, so the wait for the reply to start is short.
    private static let replyGrace = Duration.seconds(5)

    /// Sends `text` into the chat as the person's next message. A running turn takes it as a steer.
    func reply(_ text: String, to target: ChatOutsideTarget) async throws {
        try await holdingConnection {
            let (workspace, chatID) = try await chat(target)
            let agentID = workspace.catalog.session(id: chatID)?.agentIDs.first ?? target.profileID
            guard try await workspace.sendFromOutside(text, chatID: chatID, agentID: agentID, replyGrace: Self.replyGrace) else {
                throw ChatOutsideFailure.notSent
            }
        }
    }

    /// Answers the question that waits in the chat. With no question waiting any more, the words go as a
    /// message instead: the person still meant them for this chat.
    func answer(_ text: String, to target: ChatOutsideTarget) async throws {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw ChatOutsideFailure.notSent }
        try await holdingConnection {
            let (workspace, chatID) = try await chat(target)
            let dashboard = workspace.featureStore.dashboardModel
            await dashboard.refreshAfterExternalChange()
            switch ChatOutsidePrompt.question(in: dashboard.snapshot?.attentionItems ?? [], chatID: chatID,
                                              answer: answer, now: now()) {
            case .success(let item):
                await dashboard.respondToClarification(itemID: item.id, response: answer)
                guard dashboard.snapshot?.attentionItems.contains(where: { $0.id == item.id }) != true else {
                    throw ChatOutsideFailure.notSent
                }
            case .failure(.nothingWaits):
                let agentID = workspace.catalog.session(id: chatID)?.agentIDs.first ?? target.profileID
                guard try await workspace.sendFromOutside(answer, chatID: chatID, agentID: agentID, replyGrace: Self.replyGrace) else {
                    throw ChatOutsideFailure.notSent
                }
            case .failure(let failure):
                throw failure
            }
        }
    }

    /// Approves once, or denies, the command that waits in the chat.
    func decide(approves: Bool, in target: ChatOutsideTarget) async throws {
        try await holdingConnection {
            let (workspace, chatID) = try await chat(target)
            let dashboard = workspace.featureStore.dashboardModel
            await dashboard.refreshAfterExternalChange()
            let decision: ApprovalDecision = approves ? .once : .deny
            let item = try ChatOutsidePrompt.approval(in: dashboard.snapshot?.attentionItems ?? [], chatID: chatID,
                                                      decision: decision, now: now()).get()
            await dashboard.respondToApproval(itemID: item.id, decision: decision)
            guard dashboard.snapshot?.attentionItems.contains(where: { $0.id == item.id }) != true else {
                throw ChatOutsideFailure.notSent
            }
        }
    }

    private func holdingConnection(_ work: @MainActor () async throws -> Void) async throws {
        // The answer may use another computer than the one in use. With the app closed it does, and the
        // person's own computer is put back after, so the app opens where they left it.
        let before = selectedHostID()
        defer {
            if let before, selectedHostID() != before, !appIsActive() { _ = selectHost(before) }
        }
        // The host connection stays open while the answer goes, with Bighelp in the background.
        try await BighelpShortcutService.holdingHostConnection(named: "Bighelp answer", work)
    }

    /// The target's computer, connected, and the app's ID for its chat.
    private func chat(_ target: ChatOutsideTarget) async throws -> (BighelpShortcutWorkspace, String) {
        if selectedHostID() != target.hostID {
            // Switching under a person who is using the app would move them without asking.
            guard !appIsActive() else { throw ChatOutsideFailure.otherComputerInUse }
            guard selectHost(target.hostID), selectedHostID() == target.hostID else { throw ChatOutsideFailure.unavailable }
        }
        let workspace: BighelpShortcutWorkspace
        do { workspace = try await connect() } catch { throw ChatOutsideFailure.unavailable }
        guard selectedHostID() == target.hostID else { throw ChatOutsideFailure.otherComputerInUse }
        // Never let a message meant for one chat start another.
        switch target.chat {
        case .reference(let reference):
            guard let record = SessionRecord.matching(reference: reference, profileID: target.profileID,
                                                      in: workspace.catalog.records) else { throw ChatOutsideFailure.chatGone }
            return (workspace, record.id)
        case .stored(let storedID):
            if let record = SessionRecord.matching(storedID: storedID, profileID: target.profileID,
                                                   in: workspace.catalog.records) { return (workspace, record.id) }
            guard let record = try? await workspace.catalog.resolveStoredSession(
                profileID: target.profileID, storedSessionID: storedID) else { throw ChatOutsideFailure.chatGone }
            return (workspace, record.id)
        }
    }
}

extension BighelpShortcutWorkspace {
    /// Sends `message` into a chat this computer holds, as a message of its own: what the person is
    /// typing there and any attachments they staged stay where they are, and a running turn takes it
    /// as a steer. False when it didn't go. Used with Bighelp in the background, so it waits until the
    /// message is really in the chat and a little longer (`replyGrace`) for the reply to start.
    func sendFromOutside(_ message: String, chatID: String, agentID: String,
                         replyGrace: Duration = .seconds(20)) async throws -> Bool {
        let (_, chat) = try await readyChat(agentID: agentID, reusing: chatID)
        guard chat.acceptsCardReply(message) else { return false }
        let known = Set(chat.items.map(\.id))
        var finished = false
        Task { @MainActor in await chat.sendCardReply(message); finished = true }
        let accepted = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < accepted {
            if chat.failureMessage != nil { break }
            if chat.items.contains(where: { !known.contains($0.id) && $0.role == .human }) { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard chat.failureMessage == nil,
              chat.items.contains(where: { !known.contains($0.id) && $0.role == .human }) else { return false }
        // The host answers on its own; stay connected a little for the reply to start.
        let grace = ContinuousClock.now + replyGrace
        while !finished, ContinuousClock.now < grace { try await Task.sleep(for: .milliseconds(150)) }
        featureStore.flushChatPersistence()
        return true
    }
}

/// Tells the person, with an alert on the phone, that something they did outside the app didn't go
/// through. Their words are in it, so nothing they typed is lost.
enum ChatOutsideNotice {
    static func body(for failure: ChatOutsideFailure, text: String?) -> String {
        let reason = switch failure {
        case .unavailable, .notSent: "Bighelp couldn't reach the computer."
        case .otherComputerInUse: "That chat is on another computer."
        case .chatGone: "That chat isn't on this phone any more."
        case .nothingWaits: "Nothing is waiting for an answer there now."
        case .mustReview: "This one needs a look in Bighelp first."
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return "\(reason) Open Bighelp to answer."
        }
        return "\(reason) Open Bighelp to send it: “\(String(text.prefix(300)))”"
    }

    @MainActor
    static func post(_ failure: ChatOutsideFailure, text: String?, agentName: String?, thread: String) async {
        let content = UNMutableNotificationContent()
        content.title = text == nil ? "Not answered" : "Not sent"
        if let agentName, !agentName.isEmpty { content.subtitle = agentName }
        content.body = body(for: failure, text: text)
        content.threadIdentifier = thread
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "bighelp.outside." + UUID().uuidString, content: content, trigger: nil))
    }
}
