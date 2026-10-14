import SwiftUI
import UIKit
import UserNotifications

/// A turn Hermes reported failed: its card (`ChatTurnFailureCard`) and the one
/// retry a chat may schedule for when a limit lifts. The schedule belongs to
/// the open chat: sending something else, leaving the chat or another turn
/// starting cancels it, and it never sends for a chat that changed owner.
extension ChatModel {
    struct FailedTurn: Equatable {
        let failure: ChatTurnFailure
        /// The message this chat sent for the failed turn; nil when the turn
        /// came from somewhere else (a command, Voice, another device).
        let message: String?
        let attachments: [ChatAttachment]

        var canResend: Bool { message != nil }
    }

    func acceptNativeTurnFailure(_ failure: ChatTurnFailure, from owner: DirectHermesConversationClient) {
        guard nativeConversationClient === owner, !referenceOwnerRetired, !isBotMode else { return }
        cancelScheduledRetry()
        let sent = isSending ? lastSubmittedMessage : nil
        failedTurn = FailedTurn(failure: failure, message: sent?.text, attachments: sent?.attachments ?? [])
    }

    /// The card for the failed turn, or nil to leave the chat as it was.
    func failedTurnPresentation(now: Date) -> ChatTurnFailurePresentation? {
        guard let failedTurn, failureMessage == nil else { return nil }
        return ChatTurnFailurePresentation.resolve(failedTurn.failure, canResend: failedTurn.canResend, now: now)
    }

    func clearFailedTurn() {
        cancelScheduledRetry()
        failedTurn = nil
    }

    /// Sends the failed message again, the way Retry does: no second bubble.
    /// False when the chat can't send now; the card stays.
    @discardableResult
    func retryFailedTurn() async -> Bool {
        guard let failedTurn, let message = failedTurn.message, !isSending, retryRequest == nil else { return false }
        retryRequest = .send(message, failedTurn.attachments)
        guard canRetry else {
            retryRequest = nil
            return false
        }
        clearFailedTurn()
        await retry()
        return true
    }

    // MARK: Try again at a time

    func scheduleRetry(at date: Date) {
        guard failedTurn?.canResend == true else { return }
        cancelScheduledRetry()
        let schedule = ChatScheduledRetry(id: UUID(), at: date)
        scheduledRetry = schedule
        let reminder = ChatRetryReminder(id: schedule.id, conversationID: conversationID,
                                         agentName: workingAgentName ?? "Your agent", at: date)
        let remind = retryScheduling.remind
        Task { [weak self] in
            await remind(reminder) { self?.scheduledRetry?.id == schedule.id }
        }
        startScheduledRetryTimer()
    }

    func cancelScheduledRetry() {
        scheduledRetryTask?.cancel()
        scheduledRetryTask = nil
        if let scheduledRetry { retryScheduling.cancelReminder(scheduledRetry.id) }
        scheduledRetry = nil
    }

    /// bighelp left the foreground: the reminder covers the wait, and nothing is
    /// sent while the person is away.
    func pauseScheduledRetry() {
        scheduledRetryTask?.cancel()
        scheduledRetryTask = nil
    }

    /// Back in front: keep waiting, or, if the time came while away, leave
    /// Try again to the person (the reminder already told them).
    func resumeScheduledRetry() {
        guard let schedule = scheduledRetry, scheduledRetryTask == nil else { return }
        guard schedule.at > retryScheduling.now() else {
            cancelScheduledRetry()
            return
        }
        startScheduledRetryTimer()
    }

    private func startScheduledRetryTimer() {
        scheduledRetryTask?.cancel()
        guard let schedule = scheduledRetry else { return }
        let owner = nativeConversationClient
        let wait = retryScheduling.wait
        let delay = max(0, schedule.at.timeIntervalSince(retryScheduling.now()))
        scheduledRetryTask = Task { [weak self] in
            do { try await wait(delay) } catch { return }
            guard !Task.isCancelled, let self, self.scheduledRetry?.id == schedule.id else { return }
            await self.fireScheduledRetry(schedule, owner: owner)
        }
    }

    private func fireScheduledRetry(_ schedule: ChatScheduledRetry, owner: DirectHermesConversationClient?) async {
        scheduledRetryTask = nil
        guard retryScheduling.appIsActive() else { return }
        cancelScheduledRetry()
        guard !referenceOwnerRetired, owner != nil, nativeConversationClient === owner else { return }
        await retryFailedTurn()
    }
}

struct ChatScheduledRetry: Equatable, Sendable {
    let id: UUID
    let at: Date
}

struct ChatRetryReminder: Equatable, Sendable {
    let id: UUID
    let conversationID: String
    let agentName: String
    let at: Date
}

/// What a timed retry needs from outside the chat. Tests replace it.
@MainActor
struct ChatRetryScheduling {
    var now: @MainActor () -> Date = { Date() }
    var wait: @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var appIsActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    /// Schedules the reminder; the closure says whether it's still wanted.
    var remind: @MainActor (ChatRetryReminder, @escaping @MainActor () -> Bool) async -> Void = ChatRetryReminders.schedule
    var cancelReminder: @MainActor (UUID) -> Void = ChatRetryReminders.cancel
}

/// "<Agent> can try again now": a local notification at the reset time, for
/// when bighelp isn't in front then. Tapping it opens the chat. It never asks
/// for permission; without it there's no reminder.
@MainActor
enum ChatRetryReminders {
    static func identifier(_ id: UUID) -> String { "bighelp.retry." + id.uuidString.lowercased() }

    static func schedule(_ reminder: ChatRetryReminder, stillWanted: @escaping @MainActor () -> Bool) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus), stillWanted() else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(reminder.agentName) can try again now"
        content.body = "Your limit has reset. Open the chat to send your message again."
        content.sound = .default
        content.threadIdentifier = BighelpNotificationGrouping.thread(agentName: reminder.agentName)
        if let link = BighelpPromptAlertLink.url(conversationID: reminder.conversationID) {
            content.userInfo = [BighelpPromptAlertLink.userInfoKey: link.absoluteString]
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.at.timeIntervalSinceNow),
                                                        repeats: false)
        try? await center.add(UNNotificationRequest(identifier: identifier(reminder.id), content: content,
                                                    trigger: trigger))
        // Cancelled while it was being added.
        if !stillWanted() { cancel(reminder.id) }
    }

    static func cancel(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier(id)])
        center.removeDeliveredNotifications(withIdentifiers: [identifier(id)])
    }
}

/// Pauses a chat's timed retry while bighelp is away and cancels it when the
/// chat closes.
struct ChatScheduledRetryLifecycle: ViewModifier {
    let model: ChatModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.resumeScheduledRetry() } else { model.pauseScheduledRetry() }
            }
            .onDisappear { model.cancelScheduledRetry() }
    }
}
