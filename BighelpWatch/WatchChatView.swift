import SwiftUI

/// One chat: the latest messages, and replies by voice or typing. Replies to
/// what you send here are read aloud while the chat is on screen.
struct WatchChatView: View {
    enum Start: Hashable {
        case existing(String)
        case new(String, UUID)
    }

    @Bindable var store: WatchStore
    let start: Start
    @State private var sessionID: String?
    @State private var startedNew = false
    @State private var phoneNotice: String?

    init(store: WatchStore, start: Start) {
        self.store = store
        self.start = start
        if case .existing(let id) = start { _sessionID = State(initialValue: id) }
    }

    private var key: String { sessionID ?? "new" }
    private var chat: WatchChat? { sessionID.flatMap { store.chats[$0] } }
    private var messages: [WatchMessage] { store.messages(in: key) }
    private var isWorking: Bool { sessionID.map(store.isWorking) ?? true }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(messages) { message in
                        WatchBubble(message: message).id(message.id)
                    }
                    if isWorking {
                        WatchThinking(name: chat?.agentName ?? store.agent?.name ?? "Your bot",
                                      activity: chat?.activity, isSending: sessionID == nil).id("thinking")
                    }
                    if let problem = store.problem(in: key) ?? phoneNotice {
                        WatchNotice(text: problem).padding(.top, 4)
                    }
                    // Room to scroll the last message above the buttons.
                    Color.clear.frame(height: 52).id("end")
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: messages.count) { _, _ in withAnimation { scroller.scrollTo("end", anchor: .bottom) } }
            .onChange(of: isWorking) { _, _ in withAnimation { scroller.scrollTo("end", anchor: .bottom) } }
            .onAppear { scroller.scrollTo("end", anchor: .bottom) }
        }
        .navigationTitle(chat?.title ?? "New chat")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    store.readsRepliesAloud.toggle()
                    if !store.readsRepliesAloud { store.stopSpeaking() }
                } label: {
                    Image(systemName: store.readsRepliesAloud ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .accessibilityLabel(store.readsRepliesAloud ? "Stop reading replies aloud" : "Read replies aloud")
                .accessibilityIdentifier("watch.read-aloud")
                TextFieldLink(prompt: Text("Reply")) {
                    Image(systemName: "mic.fill")
                } onSubmit: { text in
                    Task { await reply(text) }
                }
                .disabled(sessionID == nil)
                .accessibilityLabel("Reply")
                .accessibilityIdentifier("watch.reply")
                Button {
                    Task { await openOnPhone() }
                } label: {
                    Image(systemName: "iphone")
                }
                .disabled(sessionID == nil)
                .accessibilityLabel("Open on iPhone")
                .accessibilityIdentifier("watch.open-on-iphone")
            }
        }
        .userActivity(WatchPhoneLink.handoffActivityType, element: phoneLink) { link, activity in
            activity.title = link.title
            activity.userInfo = ["url": link.url]
            activity.isEligibleForHandoff = true
        }
        .task(id: sessionID) { await follow() }
        .onDisappear {
            if store.visibleChatID == sessionID { store.visibleChatID = nil }
            store.stopSpeaking()
        }
    }

    private var phoneLink: WatchPhoneLink? {
        sessionID.map { WatchPhoneLink.chat($0, title: chat?.title ?? "Chat") }
    }

    /// Starts the new chat once, then keeps the chat fresh: quickly while
    /// the agent works, rarely otherwise.
    private func follow() async {
        if case .new(let text, _) = start, sessionID == nil {
            guard !startedNew else { return }
            startedNew = true
            if let id = await store.send(text, to: nil) { sessionID = id }
            return
        }
        guard let sessionID else { return }
        store.visibleChatID = sessionID
        while !Task.isCancelled {
            await store.loadChat(sessionID)
            try? await Task.sleep(for: store.isWorking(sessionID) ? .seconds(3) : .seconds(20))
        }
    }

    private func reply(_ text: String) async {
        guard let sessionID else { return }
        phoneNotice = nil
        await store.send(text, to: sessionID)
    }

    private func openOnPhone() async {
        guard let phoneLink else { return }
        phoneNotice = await store.openOnPhone(phoneLink) ?? "Check your iPhone."
    }
}

struct WatchBubble: View {
    let message: WatchMessage

    var body: some View {
        HStack {
            if message.isYou { Spacer(minLength: 16) }
            Text(message.text)
                .font(.body)
                .foregroundStyle(message.isYou ? Color.white : WatchDesign.Color.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(message.isYou ? WatchDesign.Color.outgoing : WatchDesign.Color.raised)
                )
                .fixedSize(horizontal: false, vertical: true)
            if !message.isYou { Spacer(minLength: 16) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.isYou ? "You: \(message.text)" : message.text)
        .accessibilityIdentifier(message.isYou ? "watch.message.you" : "watch.message.agent")
    }
}

/// "Searching the web…" (the phone's words for the work) or "Avery is
/// working", with three breathing dots and a soft shimmer across the words,
/// like the iPhone's activity row. Both rest with Reduce Motion and when the
/// screen dims.
struct WatchThinking: View {
    let name: String
    var activity: String?
    var isSending = false
    @State private var phase = 0.0
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    private var words: String {
        if isSending { return "Sending…" }
        return activity ?? "\(firstName) is working"
    }

    private var moves: Bool { !reduceMotion && !isLuminanceReduced }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(WatchDesign.Color.accent)
                        .frame(width: 5, height: 5)
                        .opacity(moves ? 0.35 + 0.65 * abs(sin(phase + Double(index) * 0.7)) : 1)
                }
            }
            Text(words)
                .font(.caption2)
                .foregroundStyle(WatchDesign.Color.secondaryText)
                .lineLimit(2)
                .overlay {
                    if moves {
                        // One band crossing the words, drawn by the system's
                        // animation rather than a timer.
                        GeometryReader { proxy in
                            LinearGradient(colors: [.clear, WatchDesign.Color.text.opacity(0.9), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: proxy.size.width * 0.5)
                                .offset(x: sweep ? proxy.size.width : -proxy.size.width * 0.5)
                        }
                        .mask { Text(words).font(.caption2).lineLimit(2) }
                        .allowsHitTesting(false)
                    }
                }
        }
        .padding(.vertical, 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { phase = .pi }
            withAnimation(.linear(duration: 1.9).repeatForever(autoreverses: false)) { sweep = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isSending || activity == nil ? words : "\(firstName): \(words)")
    }
}
