import Foundation
import SwiftUI

/// A message sent before the chat could take it. It waits at the bottom of the chat with
/// "Sending…" under it (`ChatCanvasRow.staged`) and goes out as this same row, so it stays put.
struct ChatStagedSend: Identifiable {
    let item: TimelineItem
    let outgoing: ChatOutgoingMessage
    var id: String { item.id }
}

/// Send doesn't wait for the connection. While a chat comes back from the background, opens on a
/// computer that's still connecting, or catches up with what Hermes saved, a message goes into the
/// chat at once and waits there, then goes out the moment the chat can take it. Only a connection
/// missing for `connectionGrace` turns Send off.
extension ChatModel {
    /// The chat has no working connection yet: back from the background, a computer still
    /// connecting, or a chat still opening or catching up with what Hermes saved.
    var lacksConnection: Bool {
        guard !isBotMode else { return false }
        if client is NativeWorkspaceUnavailableClient { return true }
        return nativeConversationClient.map { !$0.hasAuthoritativeEventCoverage } ?? false
    }

    /// Without a connection, but not for long enough to give up on it.
    var waitsForConnection: Bool { lacksConnection && !connectionIsOverdue }

    /// Send takes the box now, though Hermes can't yet: the chat waits for its connection or for
    /// the turn it just started, or earlier messages still wait. Commands (`/…`) and PDF pages
    /// need the connection to be read, so they wait in the box as before.
    var stagesComposerMessage: Bool {
        guard !isBotMode, !connectionIsOverdue, draft.first(where: { !$0.isWhitespace }) != "/",
              !orderedDraftAttachments.contains(where: { $0.pdfSelection != nil }) else { return false }
        if lacksConnection || !stagedSends.isEmpty { return true }
        return isSending && nativeConversationClient?.sessionActionsAreRunning == false
    }

    /// Moves the box into the chat, where the message waits for `drainStagedSends`; the box
    /// clears for the next one.
    func stageComposerMessage() {
        let outgoing = ChatOutgoingMessage(composerOf: self)
        guard !outgoing.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !outgoing.orderedAttachments.isEmpty else { return }
        let item = humanItem(content: outgoing.message, attachments: outgoing.attachments)
        stagedSends.append(ChatStagedSend(item: item, outgoing: outgoing.staged(as: item)))
        failureMessage = nil
        draft = ""
        replyDraft = nil
        draftAttachments = []
        orderedDraftAttachments = []
        guard stagedSendDrain == nil else { return }
        stagedSendDrain = Task { [weak self] in
            await self?.drainStagedSends()
            self?.stagedSendDrain = nil
        }
    }

    /// The staged row a send goes out as; it leaves the staged list in the same step it joins
    /// the chat, so it never shows twice or blinks out.
    func takeStagedItem(of outgoing: ChatOutgoingMessage) -> TimelineItem? {
        guard let item = outgoing.stagedItem,
              let index = stagedSends.firstIndex(where: { $0.id == item.id }) else { return nil }
        stagedSends.remove(at: index)
        return item
    }

    /// Sends the staged messages in order, each the way Send would once the chat can take it: a
    /// new turn, or a steer while the agent works. If the chat gives up on its connection first,
    /// they go back in the box.
    private func drainStagedSends() async {
        while let next = stagedSends.first {
            guard await waitForConnection(until: { takesMessageNow }), stagedSends.first?.id == next.id else {
                returnStagedSendsToBox()
                return
            }
            if isSending {
                await sendMidSession(next.outgoing, using: defaultMidSessionBehavior)
                returnStagedSendsToBox(ifStillWaiting: next)
            } else {
                // A turn runs until it ends; the next message steers it meanwhile.
                Task { [weak self] in
                    await self?.send(next.outgoing)
                    self?.returnStagedSendsToBox(ifStillWaiting: next)
                }
                _ = await waitForConnection(until: { stagedSends.first?.id != next.id })
            }
        }
    }

    /// A send that stopped before it took its row (an attachment the chat can't send) leaves the
    /// row waiting: it goes back in the box with the rest.
    private func returnStagedSendsToBox(ifStillWaiting staged: ChatStagedSend) {
        if stagedSends.first?.id == staged.id { returnStagedSendsToBox() }
    }

    /// Hermes can take a message now, the way Send would send it: a new turn, or a steer of a live one.
    var takesMessageNow: Bool {
        guard !lacksConnection else { return false }
        guard isSending else { return directTransportIsReady }
        return isMidSessionTurnLive && !hasExclusiveMidSessionSubmission
            && nativeConversationClient?.preparingAttachmentID == nil
    }

    /// Waits until `condition` holds. False if the chat gives up first: its connection stays away
    /// past `connectionGrace` while the app is open (`connectionIsOverdue`), or, connected, it
    /// still can't take the message after that long.
    func waitForConnection(until condition: () -> Bool) async -> Bool {
        var deadline = ContinuousClock.now + connectionGrace
        while !condition() {
            guard !Task.isCancelled, !connectionIsOverdue, !referenceOwnerRetired else { return false }
            // Time without a connection counts only while the app is open, which `connectionIsOverdue` follows.
            if lacksConnection { deadline = .now + connectionGrace }
            else if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// The chat never came for the staged messages: they go back in the box, oldest first and
    /// before anything typed since, so nothing is lost.
    func returnStagedSendsToBox() {
        let staged = stagedSends
        guard !staged.isEmpty else { return }
        stagedSends = []
        draft = (staged.map(\.outgoing.message) + [draft])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        draftAttachments = staged.flatMap(\.outgoing.attachments) + draftAttachments
        orderedDraftAttachments = staged.flatMap(\.outgoing.orderedAttachments) + orderedDraftAttachments
        // A send that stopped on its own (an attachment the chat can't send) already said why.
        guard failureMessage == nil else { return }
        failureMessage = staged.count == 1
            ? "Your computer didn't answer, so your message is back in the message box."
            : "Your computer didn't answer, so your messages are back in the message box."
    }
}

/// Counts how long the chat on screen goes without a connection while the app is open, and turns
/// Send off (`connectionIsOverdue`) once that passes `connectionGrace`. Time away from the app
/// doesn't count: coming back starts the count again, so Send is on the moment the app opens.
struct ChatConnectionGrace: ViewModifier {
    let model: ChatModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: model.lacksConnection && scenePhase == .active) {
            model.connectionIsOverdue = false
            guard model.lacksConnection, scenePhase == .active else { return }
            try? await Task.sleep(for: model.connectionGrace)
            if !Task.isCancelled { model.connectionIsOverdue = true }
        }
    }
}
