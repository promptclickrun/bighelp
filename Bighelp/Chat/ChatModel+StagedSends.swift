import Foundation
import SwiftUI

/// A message sent before the chat could take it. It waits at the bottom of the chat with
/// "Sending…" under it (`ChatCanvasRow.staged`) and goes out as this same row, so it stays put.
struct ChatStagedSend: Identifiable {
    let item: TimelineItem
    let outgoing: ChatOutgoingMessage
    /// Picked from Send's choices (steer, queue, interrupt), for a turn still running when it goes.
    let midSessionBehavior: MidSessionChatBehavior?
    var id: String { item.id }
}

/// Send doesn't wait for the connection. While a chat comes back from the background, opens on a
/// computer that's still connecting, or catches up with what Hermes saved, a message goes into the
/// chat at once and waits there, then goes out the moment the chat can take it. Only a connection
/// missing for `connectionGrace` turns Send off.
///
/// Waiting messages live in memory: closing the app while one waits loses it.
extension ChatModel {
    /// The chat has no working connection yet: back from the background, a computer still
    /// connecting, or a chat still opening or catching up with what Hermes saved. A connected chat
    /// still sorting out a lost message (`needsRecovery`) isn't connecting: Send stays off there.
    var lacksConnection: Bool {
        guard !isBotMode else { return false }
        #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
        if ChatConnectingPreview.isConnecting { return true }
        #endif
        if client is NativeWorkspaceUnavailableClient { return true }
        return nativeConversationClient.map { !$0.connected || $0.isHydrating } ?? false
    }

    /// No connection at all yet: the computer is still connecting, or the app just came back.
    var lacksSocket: Bool {
        guard !isBotMode else { return false }
        #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
        if ChatConnectingPreview.isConnecting { return true }
        #endif
        return client is NativeWorkspaceUnavailableClient || nativeConversationClient?.connected == false
    }

    /// Without a connection, but not for long enough to give up on it.
    var waitsForConnection: Bool { lacksConnection && !connectionIsOverdue }

    /// Send takes the box now, though Hermes can't yet: the chat waits for its connection or for
    /// the turn it just started, or earlier messages still wait. Commands (`/…`) and PDF pages
    /// need the connection to be read, so they wait in the box as before. A file over 8 MB waits
    /// in the chat on its own row, with its tile (`sendBigFileDraft`).
    var stagesComposerMessage: Bool {
        guard !isBotMode, !connectionIsOverdue, draft.first(where: { !$0.isWhitespace }) != "/",
              !orderedDraftAttachments.contains(where: { $0.pdfSelection != nil || $0.bigFile != nil })
        else { return false }
        if lacksConnection || !stagedSends.isEmpty { return true }
        return isSending && nativeConversationClient?.sessionActionsAreRunning == false
    }

    /// Hermes can take a message now, the way Send would send it: a new turn, or a steer of a live one.
    var takesMessageNow: Bool {
        guard !lacksConnection else { return false }
        guard isSending else { return directTransportIsReady }
        return isMidSessionTurnLive && !hasExclusiveMidSessionSubmission
            && nativeConversationClient.map { $0.hasAuthoritativeEventCoverage && $0.preparingAttachmentID == nil } ?? true
    }

    /// Moves the box into the chat, where the message waits for `drainStagedSends`; the box
    /// clears for the next one.
    func stageComposerMessage(midSessionBehavior: MidSessionChatBehavior? = nil) {
        let outgoing = ChatOutgoingMessage(composerOf: self)
        guard !outgoing.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !outgoing.orderedAttachments.isEmpty else { return }
        let item = humanItem(content: outgoing.message, attachments: outgoing.attachments)
        stagedSends.append(ChatStagedSend(item: item, outgoing: outgoing.staged(as: item),
                                          midSessionBehavior: midSessionBehavior))
        failureMessage = nil
        draft = ""
        replyDraft = nil
        draftAttachments = []
        orderedDraftAttachments = []
        drainStagedSendsIfNeeded()
    }

    /// The staged row a send goes out as. It leaves the staged list in the same step it joins the
    /// chat, so it never shows twice or blinks out, and it takes the chat's next order: a reload
    /// while it waited may have moved the order on, or (rarely) given its ID to a reloaded row.
    func takeStagedItem(of outgoing: ChatOutgoingMessage) -> TimelineItem? {
        guard let item = outgoing.stagedItem,
              let index = stagedSends.firstIndex(where: { $0.id == item.id }) else { return nil }
        stagedSends.remove(at: index)
        guard itemIndexByID[item.id] == nil else {
            return humanItem(content: outgoing.message, attachments: outgoing.attachments)
        }
        return item.ordered(takeTranscriptOrder())
    }

    /// How a staged message goes into a running turn. Files go only in the queue.
    func stagedMidSessionBehavior(_ staged: ChatStagedSend) -> MidSessionChatBehavior {
        guard staged.outgoing.attachments.isEmpty else { return .queued }
        return staged.midSessionBehavior ?? midSessionBehavior()
    }

    private func drainStagedSendsIfNeeded() {
        guard stagedSendDrain == nil else { return }
        let id = UUID()
        stagedSendDrain = (id, Task { [weak self] in await self?.drainStagedSends(id) })
    }

    /// Sends the staged messages in order, each the way Send would once the chat can take it: a
    /// new turn, or into the running one. If the chat gives up first, they go back in the box.
    private func drainStagedSends(_ id: UUID) async {
        defer { if stagedSendDrain?.id == id { stagedSendDrain = nil } }
        while let next = stagedSends.first {
            let ready = await waitForConnection(until: { takesMessageNow || failureMessage != nil })
            // A send ahead of them failed (and says why): the rest don't go out without it.
            guard ready, failureMessage == nil, stagedSends.first?.id == next.id else {
                returnStagedSendsToBox()
                return
            }
            if isSending {
                await sendMidSession(next.outgoing, using: stagedMidSessionBehavior(next))
                returnStagedSendsToBox(ifStillWaiting: next)
            } else {
                // The turn runs until it ends, so the messages after it get a drain of their own and
                // go into it. It starts in this same step, so nothing gets in between.
                stagedSendDrain = nil
                drainStagedSendsIfNeeded()
                await send(next.outgoing)
                returnStagedSendsToBox(ifStillWaiting: next)
                return
            }
        }
    }

    /// A send that stopped before it took its row (an attachment the chat can't send) leaves the
    /// row waiting: it goes back in the box with the rest.
    private func returnStagedSendsToBox(ifStillWaiting staged: ChatStagedSend) {
        if stagedSends.first?.id == staged.id { returnStagedSendsToBox() }
    }

    /// Waits until `condition` holds. False if the chat gives up first: Send went off
    /// (`connectionIsOverdue`), or `connectionGrace` of time with the app open went by. Time away
    /// doesn't count, so a message sent just before the phone locks goes once the chat is back.
    func waitForConnection(until condition: () -> Bool) async -> Bool {
        let step = Duration.milliseconds(100)
        var waited = Duration.zero
        while !condition() {
            guard !Task.isCancelled, !connectionIsOverdue, !referenceOwnerRetired, waited < connectionGrace
            else { return false }
            try? await Task.sleep(for: step)
            if retryScheduling.appIsActive() { waited += step }
        }
        return true
    }

    /// The chat never came for the staged messages: they go back in the box, oldest first and
    /// before anything typed since, so nothing is lost.
    func returnStagedSendsToBox() {
        let count = stagedSends.count
        guard count > 0 else { return }
        putBackInBox("", attachments: [], orderedAttachments: [])
        // A send that stopped on its own (an attachment the chat can't send) already said why.
        guard failureMessage == nil else { return }
        let messages = count == 1 ? "your message is" : "your messages are"
        failureMessage = lacksConnection
            ? "Your computer didn't answer, so \(messages) back in the message box."
            : "Hermes couldn't take it yet, so \(messages) back in the message box."
    }

    /// Puts an unsent message back in the box, before anything typed since, so neither is lost.
    /// Messages still waiting behind it can't go out without it: they come back too, after it.
    func putBackInBox(_ message: String, attachments: [ChatAttachment], orderedAttachments: [ChatDraftAttachment]) {
        let waiting = stagedSends
        stagedSends = []
        draft = ([message] + waiting.map(\.outgoing.message) + [draft])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        draftAttachments = attachments + waiting.flatMap(\.outgoing.attachments) + draftAttachments
        orderedDraftAttachments = orderedAttachments + waiting.flatMap(\.outgoing.orderedAttachments)
            + orderedDraftAttachments
    }
}

/// Counts how long the chat on screen goes without a connection while the app is open, and turns
/// Send off (`connectionIsOverdue`) once that passes `connectionGrace`. Time away from the app
/// doesn't count: coming back starts the count again, so Send is on the moment the app opens.
/// Pulling down Control Center or a notification doesn't restart it.
struct ChatConnectionGrace: ViewModifier {
    let model: ChatModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: model.lacksConnection && scenePhase != .background) {
            model.connectionIsOverdue = false
            guard model.lacksConnection, scenePhase != .background else { return }
            try? await Task.sleep(for: model.connectionGrace)
            if !Task.isCancelled { model.connectionIsOverdue = true }
        }
    }
}

#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
/// "-test-chat-connecting <seconds>": demo chats act as if their computer were still connecting for
/// that long after the first chat shows, so screenshots show Send staying on and a message waiting.
enum ChatConnectingPreview {
    private static let until: Date? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-test-chat-connecting"), arguments.indices.contains(index + 1),
              let seconds = TimeInterval(arguments[index + 1]) else { return nil }
        return Date(timeIntervalSinceNow: seconds)
    }()
    static var isConnecting: Bool { until.map { Date() < $0 } ?? false }
}
#endif
