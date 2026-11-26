import Observation
import SwiftUI

/// Auto TTS (Settings › Voice, or a chat's + menu): reads each reply in the open chat aloud once,
/// when its turn ends, in the agent's voice. What the chat held when it opened stays quiet, and a
/// copy the host saves again (a new ID, the same words) isn't read twice. A new turn, voice mode
/// or leaving the chat stops it.
///
/// The chat's Speak button reads on demand instead (`toggleSpeaking`): a reply is chosen after it
/// landed, so Auto TTS never had to be on when the turn ended. Both paths share one output, so the
/// button's second tap stops whatever is speaking.
@MainActor
@Observable
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

    /// True while a reply is being read, by Auto TTS or by the chat's Speak button. The button's
    /// symbol follows it, so a tap that starts a reading becomes a tap that stops it.
    private(set) var isReading = false

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

    /// A tap on the chat's Speak button: the newest reply, read now. Auto TTS only ever reads a
    /// reply that lands while its switch is on, so a reply that arrived before that is silent
    /// there; here the reply is picked after it landed. A second tap stops it even if the host has
    /// disconnected since playback began, and the words count as heard so Auto TTS doesn't repeat.
    func toggleSpeaking(_ reply: Reply, with output: any VoiceSpeechOutput, rate: Float) {
        toggleSpeaking(reply, rate: rate) { output }
    }

    func toggleSpeaking(_ reply: Reply, rate: Float, makeOutput: () -> (any VoiceSpeechOutput)?) {
        if isReading {
            stop()
            return
        }
        guard let output = makeOutput() else { return }
        heardText = reply.text
        read(reply.text, with: output, rate: rate)
    }

    func stop() {
        reading?.cancel()
        reading = nil
        output?.stop()
        output = nil
        isReading = false
    }

    /// The chat left the screen: quiet now, and what it holds when it's back counts as heard.
    func reset() {
        stop()
        isPrimed = false
        awaitsReply = false
    }

    private func read(_ text: String, with output: any VoiceSpeechOutput, rate: Float) {
        stop()
        let spoken = MarkdownDocument(text).visiblePlainText
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.output = output
        isReading = true
        reading = Task { [weak self] in
            try? await output.speak(spoken, rate: rate)
            guard let self, self.output === output else { return }
            self.output = nil
            self.reading = nil
            self.isReading = false
        }
    }
}

/// Auto TTS's eye on the open chat. Apart from the chat's own view, so each streamed word
/// redraws only this.
struct ChatReplyReading: View {
    let model: ChatModel
    let reader: ChatReplyReader
    let isOn: Bool
    var isVoiceActive = false
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
                reader.update(reply: moment.reply, isTurnActive: moment.isTurnActive, isOn: isOn && !isVoiceActive,
                              rate: rate, makeOutput: makeOutput)
            }
            .onChange(of: isOn) { _, isOn in
                if !isOn { reader.stop() }
            }
            .onChange(of: isVoiceActive) { _, isVoiceActive in
                // Stop on-demand Speak playback too when Live Voice or Push-to-Talk starts, even if Auto TTS is off.
                if isVoiceActive { reader.stop() }
            }
            .onDisappear { reader.reset() }
    }
}

/// The chat header's Speak button in its own view so reading `model.items`, `model.isSending`,
/// and `replyReader.isReading` never redraws `ChatView`.
struct ChatSpeakReplyButton: View {
    let model: ChatModel
    let replyReader: ChatReplyReader
    let makeHostReplySpeech: @MainActor () -> (any VoiceSpeechOutput)?
    let rate: Float
    @BighelpThemeReader private var theme

    var body: some View {
        let reply = ChatReplyReader.latestReply(in: model.items)
        let isReading = replyReader.isReading
        if isReading || reply != nil {
            let isSending = model.isSending && !isReading
            Button {
                if isReading {
                    replyReader.stop()
                } else if !model.isSending, let reply {
                    replyReader.toggleSpeaking(reply, rate: rate, makeOutput: makeHostReplySpeech)
                }
            } label: {
                Image(systemName: isReading ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: HeaderButtonMetrics.glass, height: HeaderButtonMetrics.glass)
                    .contentShape(Circle())
                    .bighelpNavigationGlass(in: Circle(), isInteractive: true)
                    .padding(HeaderButtonMetrics.slop)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .opacity(isSending ? 0.35 : 1)
            .accessibilityIdentifier("chat.speak.reply")
            .accessibilityLabel(isReading ? "Stop reading the reply" : "Read the newest reply")
            .accessibilityHint(isReading ? "Stops the voice." : "Reads it aloud in the bot's voice.")
        }
    }
}
