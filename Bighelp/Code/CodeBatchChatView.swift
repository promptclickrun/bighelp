import SwiftUI

/// Orchestration mode's chat for one batch. The app combines the batch's sessions: a
/// message goes to every session, or the ones it mentions with `#`, through each chat's
/// own send (steering a running turn, as Send does), and each session's answer shows
/// under it. Every session stays an ordinary chat; its pill opens it.
@MainActor
@Observable
final class CodeBatchChatModel {
    let batchID: UUID
    private(set) var chats: [String: ChatModel] = [:]
    var errorMessage: String?

    @ObservationIgnored let store: CodeHomeStore
    @ObservationIgnored let status: any CodeSessionStatusReading
    /// The session's chat model, ready to take a message.
    @ObservationIgnored private let prepareChat: @MainActor (String) async throws -> ChatModel

    init(batchID: UUID, store: CodeHomeStore, status: any CodeSessionStatusReading,
         prepareChat: @escaping @MainActor (String) async throws -> ChatModel) {
        self.batchID = batchID
        self.store = store
        self.status = status
        self.prepareChat = prepareChat
    }

    var batch: CodeBatch? { store.batch(id: batchID) }

    var members: [CodeBatchMember] {
        batch.map { CodeBatchMember.members(of: $0, sessions: store.sessions) } ?? []
    }

    /// Open pull requests in the batch's project, for `#`.
    var pullRequests: [StockGitPullRequest] {
        guard batch?.projectID == store.projectID else { return [] }
        return (store.git?.pullRequests ?? []).filter { $0.state.uppercased() == "OPEN" }
    }

    /// Loads each session's chat so its replies show.
    func prepare() async {
        for id in batch?.sessionIDs ?? [] where chats[id] == nil {
            if let chat = try? await prepareChat(id) { chats[id] = chat }
        }
    }

    /// Sends `typed` where it routes, and returns once each session has it or refused it.
    @discardableResult
    func send(_ typed: String, fallback: [String]) async -> Bool {
        let outgoing = CodeBatchRouting.route(typed, members: members, pullRequests: pullRequests, fallback: fallback)
        guard !outgoing.text.isEmpty, !outgoing.sessionIDs.isEmpty else { return false }
        store.record(CodeBatchMessage(id: UUID(), text: typed, sessionIDs: outgoing.sessionIDs, sentAt: .now),
                     in: batchID)
        var refused: [String] = []
        for id in outgoing.sessionIDs {
            let name = members.first { $0.id == id }?.name ?? "A session"
            guard let chat = try? await prepareChat(id), chat.acceptsCardReply(outgoing.text) else {
                refused.append(name)
                continue
            }
            chats[id] = chat
            // A new turn's send lasts the whole turn, so each session's runs on its own.
            Task { await chat.sendCardReply(outgoing.text) }
        }
        errorMessage = refused.isEmpty ? nil
            : "\(refused.joined(separator: ", ")) couldn't take it right now. Open it to try again."
        return true
    }

    /// One session's answer under one message.
    struct Reply: Identifiable {
        let member: CodeBatchMember
        /// The session's last answer in this message's window.
        let text: String?
        let status: CodeSessionStatus
        /// The newest message this session got: status and questions show here only.
        let isLatest: Bool
        var id: String { member.id }
    }

    /// Answers under `message`, or under the batch's start when it's nil.
    func replies(to message: CodeBatchMessage?) -> [Reply] {
        guard let batch else { return [] }
        let targets = message?.sessionIDs ?? batch.sessionIDs
        return members.filter { targets.contains($0.id) }.map { member in
            let sent = batch.messages.filter { $0.sessionIDs.contains(member.id) }
            let start = message?.sentAt ?? .distantPast
            let next = sent.first { $0.sentAt > start }?.sentAt
            return Reply(member: member, text: lastAnswer(of: member.id, from: start, before: next),
                         status: status.status(of: member.id), isLatest: next == nil)
        }
    }

    /// A session's connect cards (Hermes' `manage_connections`), with the store that answers them.
    func connectorCards(of sessionID: String) -> (store: ConnectorCardStore, cards: [ConnectorCardStore.Card])? {
        guard let client = chats[sessionID]?.nativeConversationClient, let store = client.promptStore?.connectorCards
        else { return nil }
        let cards = client.connectorCards
        return cards.isEmpty ? nil : (store, cards)
    }

    /// The pending question or approval of a session, with its chat's client to answer it.
    func prompt(of sessionID: String) -> (client: DirectHermesConversationClient, prompt: DirectHermesPrompt)? {
        guard let client = chats[sessionID]?.nativeConversationClient, let prompt = client.prompts.first else { return nil }
        return (client, prompt)
    }

    private func lastAnswer(of sessionID: String, from start: Date, before end: Date?) -> String? {
        guard let items = chats[sessionID]?.items else { return nil }
        let answers = items.filter { item in
            guard item.role == .assistant, !item.metadata.isInterimReply, case .message = item.content else { return false }
            // Without a time, an answer counts toward the newest message.
            guard let time = item.metadata.timestamp else { return end == nil }
            return time >= start && end.map { time < $0 } ?? true
        }
        guard case .message(let text)? = answers.last?.content else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CodeBatchChatView: View {
    @State private var model: CodeBatchChatModel
    let onOpenSession: (CodeSessionRecord) -> Void
    @State private var message = ""
    @State private var isFocused = false
    /// The target chip: nil is every session.
    @State private var target: String?

    init(model: CodeBatchChatModel, onOpenSession: @escaping (CodeSessionRecord) -> Void) {
        _model = State(initialValue: model)
        self.onOpenSession = onOpenSession
    }

    var body: some View {
        Group {
            if let batch = model.batch {
                content(batch)
            } else {
                ContentUnavailableView("This batch isn't here anymore", systemImage: "square.stack.3d.up.slash")
            }
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(model.batch?.title ?? "Batch").font(.bighelp(.headline)).lineLimit(1)
                    Text(subtitle).font(.bighelp(.caption)).foregroundStyle(theme.secondaryText).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task { await model.prepare() }
        .task { await model.store.loadGit() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code.batch")
    }

    private var subtitle: String {
        let count = model.members.count
        let project = model.store.projects.first { $0.id == model.batch?.projectID }?.name
        return ([count == 1 ? "1 session" : "\(count) sessions", project].compactMap { $0 }).joined(separator: " · ")
    }

    private func content(_ batch: CodeBatch) -> some View {
        VStack(spacing: 0) {
            memberStrip
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: BighelpTokens.space12) {
                        startBlock(batch)
                        ForEach(batch.messages) { sent in
                            sentBubble(sent)
                            repliesBlock(model.replies(to: sent))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, BighelpTokens.space16)
                    .padding(.vertical, BighelpTokens.space8)
                    .frame(maxWidth: ChatCanvasLayout.regularLaneMaximumWidth)
                    .frame(maxWidth: .infinity)
                }
                .dismissesKeyboardOnScroll(true)
                .onChange(of: batch.messages.count) { _, _ in
                    withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CodeBatchComposer(model: model, message: $message, isFocused: $isFocused, target: $target)
        }
    }

    // MARK: Pills

    private var memberStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(model.members) { member in
                    let status = model.status.status(of: member.id)
                    Button {
                        if let session = model.store.sessions.first(where: { $0.id == member.id }) { onOpenSession(session) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(member.color).frame(width: 8, height: 8)
                            Text(member.name).font(.bighelp(.subheadline).weight(.semibold))
                            Text(status.shortTitle).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, BighelpTokens.space12)
                        .frame(minHeight: BighelpTokens.scaled(34))
                        .background(theme.surface, in: .capsule)
                        .overlay {
                            Capsule().stroke(status.filter == .needsYou ? theme.warning : member.color.opacity(0.4),
                                             lineWidth: status.filter == .needsYou ? 1.5 : 1)
                        }
                        .contentShape(.capsule)
                    }
                    .bighelpPlainButtonStyle(.capsule)
                    .accessibilityLabel("\(member.name), \(status.shortTitle). Opens its chat.")
                    .accessibilityIdentifier("code.batch.member.\(member.index)")
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space8)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Messages

    private func startBlock(_ batch: CodeBatch) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Label(batch.jobCount == 1 ? "Started 1 session" : "Started \(batch.jobCount) sessions",
                  systemImage: "square.stack.3d.up")
                .font(.bighelp(.footnote).weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            repliesBlock(model.replies(to: nil), showsTitles: true)
        }
    }

    private func sentBubble(_ sent: CodeBatchMessage) -> some View {
        let members = model.members
        let names = members.filter { sent.sessionIDs.contains($0.id) }.map(\.name)
        let everyone = sent.sessionIDs.count == members.count && members.count > 1
        return VStack(alignment: .trailing, spacing: BighelpTokens.space4) {
            Text(highlighted(sent.text, members: members))
                .font(.bighelp(.body))
                .foregroundStyle(theme.actionForeground)
                .padding(.horizontal, BighelpTokens.space12)
                .padding(.vertical, BighelpTokens.space8)
                .background(theme.action, in: .rect(cornerRadius: 18))
                .accessibilityIdentifier("code.batch.sent")
            Label(everyone ? "To all \(members.count)" : "To \(names.joined(separator: ", "))",
                  systemImage: everyone ? "person.2" : "number")
                .font(.bighelp(.caption).weight(.semibold))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Mentions in a sent message, bold on the bubble.
    private func highlighted(_ text: String, members: [CodeBatchMember]) -> AttributedString {
        var attributed = AttributedString(text)
        for member in members {
            var searchStart = attributed.startIndex
            while let range = attributed[searchStart...].range(of: "#" + member.name, options: .caseInsensitive) {
                attributed[range].inlinePresentationIntent = .stronglyEmphasized
                searchStart = range.upperBound
            }
        }
        return attributed
    }

    private func repliesBlock(_ replies: [CodeBatchChatModel.Reply], showsTitles: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
                if index > 0 { Divider().padding(.leading, BighelpTokens.space12) }
                replyRow(reply, showsTitle: showsTitles)
            }
        }
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay { RoundedRectangle(cornerRadius: BighelpTokens.radius16).stroke(theme.border, lineWidth: BighelpTokens.hairline) }
    }

    private func replyRow(_ reply: CodeBatchChatModel.Reply, showsTitle: Bool) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space8) {
            RoundedRectangle(cornerRadius: 1.5).fill(reply.member.color).frame(width: 3)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(reply.member.name)
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(reply.member.color)
                if showsTitle {
                    Text(reply.member.title).font(.bighelp(.caption)).foregroundStyle(theme.secondaryText).lineLimit(1)
                }
                if let text = reply.text {
                    Text(LocalizedStringKey(text))
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("code.batch.reply")
                }
                if reply.isLatest {
                    latestState(reply)
                    if let pending = model.connectorCards(of: reply.member.id) {
                        ForEach(pending.cards) { card in ConnectorInlineCard(store: pending.store, card: card) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(BighelpTokens.space12)
    }

    /// The newest message's row also says what the session is doing now.
    @ViewBuilder private func latestState(_ reply: CodeBatchChatModel.Reply) -> some View {
        switch reply.status {
        case .needsYou(let ask):
            if let pending = model.prompt(of: reply.member.id) {
                DirectHermesPromptResponseView(client: pending.client, prompt: pending.prompt, inline: true)
            } else {
                CodePill(text: ask, tint: theme.warning, systemImage: "hand.raised")
            }
        case .running(let step):
            Label(step.map { "Working · \($0)" } ?? "Working", systemImage: "gearshape.2")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
        case .starting(let step):
            Label(step, systemImage: "hourglass").font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
        case .ready:
            if reply.text == nil {
                Text("No answer yet.").font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme
}

/// The batch chat's message box: who it goes to, the text (mentions colored in place),
/// the target chip and Send. `#` opens the list of the batch's sessions and the project's
/// open pull requests.
struct CodeBatchComposer: View {
    let model: CodeBatchChatModel
    @Binding var message: String
    @Binding var isFocused: Bool
    @Binding var target: String?
    @State private var isSending = false

    var body: some View {
        let members = model.members
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if let query = CodeBatchRouting.mentionQuery(in: message) {
                mentionList(query: query, members: members)
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                if let goes = goesLine(members: members) {
                    Label { Text(goes) } icon: { Image(systemName: "number") }
                        .font(.bighelp(.caption).weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("code.batch.goes")
                }
                ZStack(alignment: .topLeading) {
                    if message.isEmpty {
                        Text(members.count > 1 ? "Message all \(members.count), or type # for one" : "Message the session")
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.secondaryText)
                            .allowsHitTesting(false)
                    }
                    CodeMentionTextView(text: $message, isFocused: $isFocused,
                                        mentions: members.map { ("#" + $0.name, UIColor($0.color)) }
                                            + model.pullRequests.map { ("#\($0.number)", UIColor(theme.action)) },
                                        textColor: UIColor(theme.primaryText))
                }
                HStack(spacing: BighelpTokens.space8) {
                    targetMenu(members: members)
                    Spacer(minLength: 0)
                    sendButton
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space12)
            .padding(.bottom, BighelpTokens.space8)
            .bighelpSurface(.composer)
        }
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.bottom, BighelpTokens.space8)
        .frame(maxWidth: ChatCanvasLayout.regularLaneMaximumWidth)
        .frame(maxWidth: .infinity)
    }

    private var routed: CodeBatchRouting.Outgoing {
        CodeBatchRouting.route(message, members: model.members, pullRequests: model.pullRequests, fallback: fallback)
    }

    private var fallback: [String] {
        target.map { [$0] } ?? model.members.map(\.id)
    }

    /// Shown when mentions decide who gets it.
    private func goesLine(members: [CodeBatchMember]) -> String? {
        let outgoing = routed
        guard !message.isEmpty, outgoing.sessionIDs != fallback || !outgoing.pullRequestOwners.isEmpty else { return nil }
        let names = members.filter { outgoing.sessionIDs.contains($0.id) }.map(\.name)
        let only = names.count == 1 ? " only" : ""
        let owned = outgoing.pullRequestOwners.first.flatMap { number, owner in
            members.first { $0.id == owner }.map { _ in " (it owns #\(number))" }
        } ?? ""
        return "Goes to \(names.joined(separator: ", "))\(only)\(owned)"
    }

    private func targetMenu(members: [CodeBatchMember]) -> some View {
        Menu {
            Button {
                target = nil
            } label: {
                Label("All \(members.count) sessions", systemImage: target == nil ? "checkmark" : "person.2")
            }
            ForEach(members) { member in
                Button {
                    target = member.id
                } label: {
                    Label(member.name, systemImage: target == member.id ? "checkmark" : "number")
                }
            }
        } label: {
            // Mentions decide while there are some; the chip says who gets it either way.
            let going = members.filter { routed.sessionIDs.contains($0.id) }
            let only = going.count == 1 && members.count > 1 ? going.first : nil
            HStack(spacing: BighelpTokens.space4) {
                if let only {
                    Circle().fill(only.color).frame(width: 8, height: 8)
                } else {
                    Image(systemName: "person.2")
                }
                Text(only.map { "To \($0.name)" }
                     ?? (going.count == members.count ? "To all \(members.count)" : "To \(going.count) sessions"))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.bighelp(.caption2).weight(.semibold))
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: BighelpTokens.scaled(32))
            .background(theme.raisedSurface, in: .capsule)
            .contentShape(.capsule)
        }
        .accessibilityLabel(targetDescription(members: members))
        .accessibilityIdentifier("code.batch.target")
    }

    private func targetDescription(members: [CodeBatchMember]) -> String {
        let count = routed.sessionIDs.count
        if count == members.count { return "Sends to every session" }
        return count == 1 ? "Sends to one session" : "Sends to \(count) sessions"
    }

    private var canSend: Bool { !routed.text.isEmpty && !isSending }

    private var sendButton: some View {
        Button {
            let typed = message
            isSending = true
            Task {
                if await model.send(typed, fallback: fallback) { message = "" }
                isSending = false
            }
        } label: {
            Image(systemName: "arrow.up")
                .font(.bighelp(.body).weight(.bold))
                .foregroundStyle(canSend ? theme.actionForeground : theme.secondaryText)
                .frame(width: BighelpTokens.scaled(36), height: BighelpTokens.scaled(36))
                .background(canSend ? theme.action : theme.surface, in: .circle)
                .contentShape(.circle)
        }
        .bighelpPlainButtonStyle(.circle)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .bighelpIconLabel("Send", shortcut: "⌘↩")
        .accessibilityIdentifier("code.batch.send")
    }

    // MARK: The # list

    private func mentionList(query: String, members: [CodeBatchMember]) -> some View {
        let term = query.trimmingCharacters(in: .whitespaces)
        let sessions = members.filter {
            term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || $0.title.localizedCaseInsensitiveContains(term)
        }
        let pulls = model.pullRequests.filter {
            term.isEmpty || "\($0.number)".hasPrefix(term) || $0.title.localizedCaseInsensitiveContains(term)
                || $0.branch.localizedCaseInsensitiveContains(term)
        }
        let suggestions = sessions.map { member -> BighelpSuggestion in
            let status = model.status.status(of: member.id)
            return BighelpSuggestion(id: "session.\(member.index)", icon: .number(member.index + 1, member.color),
                                     sigil: "#", name: member.name, detail: member.title, tag: status.shortTitle,
                                     tone: status.tone, section: "In this batch")
        } + pulls.map { pull in
            let owner = members.first { $0.branch == pull.branch }
            return BighelpSuggestion(id: "pr.\(pull.number)", icon: .symbol("arrow.triangle.pull"), sigil: "#",
                                     name: "\(pull.number) \(pull.title)",
                                     detail: pull.branch + " · " + (owner?.name ?? "not in this batch"),
                                     tag: pull.isDraft ? "Draft" : "Open", section: "Pull requests")
        }
        return BighelpSuggestionList(
            suggestions: suggestions, identifier: "code.batch.mentions",
            emptyText: "No sessions or open pull requests match.",
            onPick: { picked in
                if picked.id.hasPrefix("session."), let index = Int(picked.id.dropFirst(8)),
                   let member = members.first(where: { $0.index == index }) {
                    insertMention("#" + member.name, replacing: query)
                } else if picked.id.hasPrefix("pr."), let number = Int(picked.id.dropFirst(3)) {
                    insertMention("#\(number)", replacing: query)
                }
            }
        ) {
            BighelpSuggestionHeader(systemImage: "number", title: "Sessions and pull requests", count: suggestions.count)
        }
    }

    private func insertMention(_ mention: String, replacing query: String) {
        guard message.hasSuffix("#" + query) else { return }
        message = String(message.dropLast(query.count + 1)) + mention + " "
        isFocused = true
    }

    @BighelpThemeReader private var theme
}

extension CodeSessionStatus {
    /// One or two words for pills and tags.
    var shortTitle: String {
        switch self {
        case .starting: "Starting"
        case .running: "Working"
        case .needsYou: "Needs you"
        case .ready: "Ready"
        case .failed: "Stopped"
        }
    }

    var tone: BighelpSuggestion.Tone {
        switch self {
        case .starting, .running: .working
        case .needsYou: .needsYou
        case .ready: .ready
        case .failed: .plain
        }
    }
}
