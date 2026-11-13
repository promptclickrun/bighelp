import SwiftUI

/// What the review needs from the shell: the computer in use, its agents and chats, and how to open one.
struct PendingShareReviewContext {
    let computerName: String?
    /// The computer in use (`WorkspaceOwner.cacheScopeID`); nil while none is.
    let scope: String?
    let agents: [AgentProfile]
    /// The agent's own chats on this computer, newest first.
    let chats: (String) -> [SessionSummary]
    /// Puts the share in that chat's message box.
    let open: (PendingShare, PendingShareDestination, String) -> Void
    /// Opens a chat as it is, to see whether a share reached it.
    let openChat: (String) -> Void
}

/// Offers a share another app saved for bighelp each time bighelp comes to the front, so the person
/// picks the agent and chat it goes to, and shows every waiting share when asked (Shared with
/// bighelp). It waits for whatever has to come first: the AI data agreement, first setup, adding a
/// computer, Settings, or, for a review on its own, no computer at all.
@MainActor
struct PendingShareReview: ViewModifier {
    let center: PendingShareCenter
    /// Something else is on screen that must finish first.
    let isBlocked: Bool
    let usesDemoData: Bool
    let context: PendingShareReviewContext
    @AppStorage(AIDataConsent.key) private var agreed = false
    @Environment(\.scenePhase) private var scenePhase

    private enum Sheet: Identifiable, Equatable {
        case review(PendingShareInbox.Entry)
        case list

        var id: String {
            switch self {
            case .review(let entry): "review-" + entry.id
            case .list: "list"
            }
        }
    }

    private var hasAgreed: Bool {
        !AIDataConsent.needsAsking(agreed: agreed || AIDataConsent.isAgreed(), inFirstSetup: false,
                                   usesDemoData: usesDemoData)
    }

    private var sheet: Sheet? {
        guard !isBlocked, hasAgreed else { return nil }
        if center.isListShown { return .list }
        guard context.scope != nil, let next = center.next() else { return nil }
        return .review(next)
    }

    func body(content: Content) -> some View {
        content
            .bighelpSheet(item: Binding(get: { sheet }, set: { if $0 == nil { center.isListShown = false } })) { sheet in
                NavigationStack {
                    switch sheet {
                    case .review(let entry):
                        PendingShareReviewView(entry: entry, center: center, context: reviewContext(for: entry),
                                               onLater: { center.later($0) })
                    case .list:
                        PendingShareListView(center: center, context: listContext,
                                             close: { center.isListShown = false })
                    }
                }
                // A review on its own closes only by its own buttons, so each way out means one thing.
                .interactiveDismissDisabled(sheet != .list)
                .bighelpSheetSize(.standard)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await center.refresh()
            }
    }

    /// Looking in a chat from a review on its own puts the share off, so the review doesn't stay over it.
    private func reviewContext(for entry: PendingShareInbox.Entry) -> PendingShareReviewContext {
        PendingShareReviewContext(
            computerName: context.computerName, scope: context.scope, agents: context.agents, chats: context.chats,
            open: context.open,
            openChat: { id in
                center.later(entry.id)
                context.openChat(id)
            })
    }

    /// From the list, opening a chat closes the list first.
    private var listContext: PendingShareReviewContext {
        PendingShareReviewContext(
            computerName: context.computerName, scope: context.scope, agents: context.agents, chats: context.chats,
            open: { share, destination, name in
                center.isListShown = false
                context.open(share, destination, name)
            },
            openChat: { id in
                center.isListShown = false
                context.openChat(id)
            })
    }
}

/// Every share waiting, put off ones too: open one to send it, or delete it. Reached from
/// Shared with bighelp, or Settings' first screen, while any wait.
struct PendingShareListView: View {
    let center: PendingShareCenter
    let context: PendingShareReviewContext
    /// Nil when pushed on another page's stack.
    var close: (() -> Void)?

    @State private var deleting: PendingShareInbox.Entry?
    @BighelpThemeReader private var theme

    var body: some View {
        List {
            if center.entries.isEmpty {
                Section {
                    Text("Nothing is waiting. Things you share with bighelp from other apps show up here until you send or delete them.")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .listRowBackground(theme.surface)
                }
            }
            Section {
                ForEach(center.entries) { entry in
                    NavigationLink {
                        PendingShareReviewView(entry: entry, center: center, context: context, onLater: nil)
                    } label: {
                        row(entry)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { deleting = entry }
                    }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }
                    }
                    .accessibilityIdentifier("pending-shares.row.\(entry.id)")
                    .listRowBackground(theme.surface)
                }
            } footer: {
                if !center.entries.isEmpty {
                    Text("Each stays on this device until Hermes takes the message it's in, or you delete it.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Shared with bighelp")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let close {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                        .accessibilityIdentifier("pending-shares.done")
                }
            }
        }
        .confirmationDialog("Delete this share? It hasn't been sent.",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { entry in
            Button("Delete", role: .destructive) {
                Task { try? await center.delete(entry.id) }
            }
        }
        .accessibilityIdentifier("pending-shares.list")
    }

    private func row(_ entry: PendingShareInbox.Entry) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text(Self.title(entry))
                .font(.bighelp(.body))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Text(status(entry))
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
        }
    }

    /// Its note, else its first words, link or file.
    static func title(_ entry: PendingShareInbox.Entry) -> String {
        guard case .share(let share, _) = entry else { return String(localized: "A share that couldn't be read") }
        for words in [share.note, share.text] where PendingShare.hasWords(words) {
            return words.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? words
        }
        return share.links.first ?? share.files.first?.name ?? String(localized: "Shared item")
    }

    private func status(_ entry: PendingShareInbox.Entry) -> String {
        guard case .share(let share, let placement) = entry else { return String(localized: "It can be deleted.") }
        if center.isHeld(share.id) { return String(localized: "In a chat's message box now") }
        let saved = share.createdAt.formatted(.relative(presentation: .named))
        guard let placement else { return String(localized: "Saved \(saved). Not sent.") }
        switch placement.recovery {
        case .notSent:
            return String(localized: "Saved \(saved). Put in a chat with \(placement.agentName), not sent.")
        case .maybeSent:
            return String(localized: "Saved \(saved). May have reached \(placement.agentName).")
        }
    }
}

/// One share: what it holds, where it goes, and Open, Not now or Delete.
struct PendingShareReviewView: View {
    let entry: PendingShareInbox.Entry
    let center: PendingShareCenter
    let context: PendingShareReviewContext
    /// Not now, for the review that opens on its own; nil when reached from the list.
    let onLater: ((String) -> Void)?

    @State private var agentID: String?
    /// Nil is a new chat.
    @State private var sessionID: String?
    /// The computer the agent and chat were picked on.
    @State private var pickedScope: String?
    @State private var notice: String?
    @State private var confirmsDelete = false
    @State private var confirmsAgain = false
    @State private var isDeleting = false
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private static let shownChats = 6

    private var scope: String? { context.scope }
    private var agents: [AgentProfile] { context.agents }

    private var placement: PendingSharePlacement? {
        guard case .share(_, let placement) = entry else { return nil }
        return placement
    }

    var body: some View {
        List {
            switch entry {
            case .share(let share, let placement):
                contents(share, placement: placement)
                if center.isHeld(share.id) {
                    Section {
                        Text("It's in a chat's message box now. Send it there, or take it out of the message box first.")
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.secondaryText)
                            .listRowBackground(theme.surface)
                    }
                } else if scope == nil {
                    Section {
                        Text("Connect a computer to send it.")
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.secondaryText)
                            .listRowBackground(theme.surface)
                    }
                } else {
                    destination
                }
            case .unreadable:
                Section {
                    Text("This share couldn't be read, so it can't be sent. You can delete it.")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .listRowBackground(theme.surface)
                }
            }
            Section {
                Button("Delete", role: .destructive) { confirmsDelete = true }
                    .font(.bighelp(.body))
                    .disabled(isDeleting)
                    .accessibilityIdentifier("pending-share.delete")
                    .listRowBackground(theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle(onLater != nil && center.waitingCount > 1
                         ? "Shared with bighelp (\(center.waitingCount))" : "Shared with bighelp")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onLater {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { onLater(entry.id) }
                        .accessibilityIdentifier("pending-share.later")
                }
            }
            if case .share(let share, _) = entry, !center.isHeld(share.id), scope != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        if placement?.recovery == .maybeSent { confirmsAgain = true } else { openChat(share) }
                    }
                    .bold()
                    .disabled(agentID == nil)
                    .accessibilityIdentifier("pending-share.open")
                }
            }
        }
        .confirmationDialog("Delete this share? It hasn't been sent.", isPresented: $confirmsDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        }
        .confirmationDialog(againTitle, isPresented: $confirmsAgain, titleVisibility: .visible) {
            if case .share(let share, _) = entry {
                Button("Put it in the message box again") { openChat(share) }
            }
        }
        .onAppear(perform: preselect)
        .onChange(of: scope) { _, current in
            // Never carried to another computer: the person picks again there.
            guard pickedScope != nil, current != pickedScope else { return }
            agentID = nil
            sessionID = nil
            pickedScope = nil
            notice = String(localized: "You switched computers. Pick the agent again.")
        }
        .accessibilityIdentifier("pending-share.review")
    }

    private var againTitle: String {
        String(localized: "This may have reached \(placement?.agentName ?? String(localized: "the agent")) already. Look in that chat first.")
    }

    // MARK: - What it holds

    @ViewBuilder
    private func contents(_ share: PendingShare, placement: PendingSharePlacement?) -> some View {
        Section {
            if PendingShare.hasWords(share.note) {
                Text(share.note)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .listRowBackground(theme.surface)
            }
            if PendingShare.hasWords(share.text) {
                Text(share.text)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(4)
                    .listRowBackground(theme.surface)
            }
            ForEach(share.links, id: \.self) { link in
                Label(link, systemImage: "link")
                    .font(.bighelp(.body))
                    .lineLimit(2)
                    .listRowBackground(theme.surface)
            }
            ForEach(share.files, id: \.storedName) { file in
                HStack {
                    Label(file.name, systemImage: file.kind == .image ? "photo" : "doc")
                        .lineLimit(1)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                        .foregroundStyle(theme.secondaryText)
                }
                .font(.bighelp(.body))
                .listRowBackground(theme.surface)
            }
            if let placement, placement.recovery == .maybeSent,
               let chat = placement.submission?.conversationID, isChatHere(chat, placement: placement) {
                Button("Look in that chat") { context.openChat(chat) }
                    .font(.bighelp(.body))
                    .accessibilityIdentifier("pending-share.look")
                    .listRowBackground(theme.surface)
            }
        } header: {
            Text("From another app")
        } footer: {
            if let placement {
                switch placement.recovery {
                case .notSent:
                    Text("You put this in a chat with \(placement.agentName) before, and it wasn't sent.")
                case .maybeSent:
                    Text("bighelp can't tell whether this reached \(placement.agentName). Look in that chat before you send it again.")
                }
            }
        }
    }

    private func isChatHere(_ chat: String, placement: PendingSharePlacement) -> Bool {
        placement.destination.scope == scope
            && context.chats(placement.destination.agentID).contains { $0.id == chat }
    }

    // MARK: - Where it goes

    @ViewBuilder
    private var destination: some View {
        Section {
            if agents.isEmpty {
                Text("No agents to send it to yet.")
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                    .listRowBackground(theme.surface)
            }
            ForEach(agents) { agent in
                choice(agent.name, isOn: agentID == agent.id, id: "pending-share.agent.\(agent.id)") {
                    agentID = agent.id
                    sessionID = nil
                    pickedScope = scope
                    notice = nil
                }
            }
        } header: {
            Text(context.computerName.map { String(localized: "Agent on \($0)") } ?? String(localized: "Agent"))
        } footer: {
            if let notice {
                Text(notice).foregroundStyle(theme.danger)
            }
        }
        if let agentID {
            Section {
                choice(String(localized: "New chat"), isOn: sessionID == nil, id: "pending-share.chat.new") {
                    sessionID = nil
                }
                ForEach(context.chats(agentID).prefix(Self.shownChats)) { chat in
                    choice(chat.title.isEmpty ? String(localized: "Untitled chat") : chat.title,
                           isOn: sessionID == chat.id, id: "pending-share.chat.\(chat.id)") {
                        sessionID = chat.id
                    }
                }
            } header: {
                Text("Chat")
            } footer: {
                Text("It goes into the message box. Nothing is sent until you tap Send there.")
            }
        }
    }

    private func choice(_ title: String, isOn: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.action)
                        .accessibilityHidden(true)
                }
            }
            .font(.bighelp(.body))
            .contentShape(.rect)
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
        .listRowBackground(theme.surface)
    }

    // MARK: - Actions

    /// The chat it was put in before, while that's still here; otherwise the only agent.
    private func preselect() {
        guard agentID == nil, let scope, case .share = entry else { return }
        if let destination = placement?.destination,
           destination.problem(currentScope: scope, agentIDs: Set(agents.map(\.id)),
                               sessionIDs: Set(context.chats(destination.agentID).map(\.id))) == nil {
            agentID = destination.agentID
            sessionID = destination.sessionID
            pickedScope = scope
        } else if agents.count == 1 {
            agentID = agents[0].id
            pickedScope = scope
        }
    }

    private func openChat(_ share: PendingShare) {
        guard let agentID, let pickedScope else { return }
        let destination = PendingShareDestination(scope: pickedScope, agentID: agentID, sessionID: sessionID)
        switch destination.problem(currentScope: scope, agentIDs: Set(agents.map(\.id)),
                                   sessionIDs: Set(context.chats(agentID).map(\.id))) {
        case .computerChanged?:
            self.agentID = nil
            sessionID = nil
            self.pickedScope = nil
            notice = String(localized: "You switched computers. Pick the agent again.")
        case .agentGone?:
            self.agentID = nil
            sessionID = nil
            notice = String(localized: "That agent isn't on this computer anymore. Pick another.")
        case .chatGone?:
            sessionID = nil
            notice = String(localized: "That chat isn't here anymore. Pick another, or a new chat.")
        case nil:
            let name = agents.first { $0.id == agentID }?.name ?? agentID
            context.open(share, destination, name)
        }
    }

    private func delete() {
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await center.delete(entry.id)
                // Back to the list it came from; a review on its own moves on by itself.
                if onLater == nil { dismiss() }
            } catch {
                notice = String(localized: "bighelp couldn't delete this share. Try again.")
            }
        }
    }
}
