import SwiftUI

/// Auto TTS (Settings › Voice, or a chat's + menu): reads each reply in the open chat aloud once,
/// when its turn ends, in the agent's voice. What the chat held when it opened stays quiet, and a
/// copy the host saves again (a new ID, the same words) isn't read twice. A new turn, voice mode
/// or leaving the chat stops it.
@MainActor
final class ChatReplyReader {
    struct Reply: Equatable, Sendable {
        let id: String
        let text: String
    }

    private var isPrimed = false
    /// A turn ran since the last reply was read; its reply is the next to read.
    private var awaitsReply = false
    private var heardText: String?
    private var output: (any VoiceSpeechOutput)?
    private var reading: Task<Void, Never>?

    /// The chat's newest reply: the agent's last message after the person's last one.
    static func latestReply(in items: [TimelineItem]) -> Reply? {
        for item in items.reversed() {
            if item.role == .human { return nil }
            guard item.role == .assistant, item.sender.kind == .agent,
                  case .message(let text) = item.content else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return Reply(id: item.id, text: trimmed) }
        }
        return nil
    }

    /// Call whenever the newest reply or the turn changes. `isOn` is Auto TTS on, for this chat
    /// on screen with nothing else speaking; while it's off, replies count as heard.
    func update(reply: Reply?, isTurnActive: Bool, isOn: Bool, rate: Float,
                makeOutput: () -> (any VoiceSpeechOutput)?) {
        if !isPrimed {
            isPrimed = true
            heardText = reply?.text
            awaitsReply = isTurnActive
            if !isTurnActive { return }
        }
        if isTurnActive {
            // The person sent something new: the last reply has had its say, and the next one is
            // new even in the same words ("Done." twice).
            stop()
            awaitsReply = true
            if reply == nil { heardText = nil }
            return
        }
        guard awaitsReply, let reply, reply.text != heardText else { return }
        awaitsReply = false
        heardText = reply.text
        guard isOn, let output = makeOutput() else { return }
        read(reply.text, with: output, rate: rate)
    }

    func stop() {
        reading?.cancel()
        reading = nil
        output?.stop()
        output = nil
    }

    /// The chat left the screen: quiet now, and what it holds when it's back counts as heard.
    func reset() {
        stop()
        isPrimed = false
        awaitsReply = false
    }

    private func read(_ text: String, with output: any VoiceSpeechOutput, rate: Float) {
        stop()
        self.output = output
        let spoken = MarkdownDocument(text).visiblePlainText
        reading = Task { [weak self] in
            try? await output.speak(spoken, rate: rate)
            guard let self, self.output === output else { return }
            self.output = nil
            self.reading = nil
        }
    }
}

/// Auto TTS's eye on the open chat. Apart from the chat's own view, so each streamed word
/// redraws only this.
struct ChatReplyReading: View {
    let model: ChatModel
    let reader: ChatReplyReader
    let isOn: Bool
    let rate: Float
    let makeOutput: @MainActor () -> (any VoiceSpeechOutput)?

    private struct Moment: Equatable {
        let reply: ChatReplyReader.Reply?
        let isTurnActive: Bool
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: Moment(reply: ChatReplyReader.latestReply(in: model.items), isTurnActive: model.isSending),
                      initial: true) { _, moment in
                reader.update(reply: moment.reply, isTurnActive: moment.isTurnActive, isOn: isOn, rate: rate,
                              makeOutput: makeOutput)
            }
            .onChange(of: isOn) { _, isOn in
                if !isOn { reader.stop() }
            }
            .onDisappear { reader.reset() }
    }
}
