import SwiftUI

/// Offers a share another app saved for bighelp each time bighelp comes to the front, so the person
/// picks the agent and chat it goes to. It waits for whatever has to come first: the AI data
/// agreement, first setup, adding a computer, Settings, or no computer at all.
@MainActor
struct PendingShareReview: ViewModifier {
    let center: PendingShareCenter
    /// Something else is on screen that must finish first.
    let isBlocked: Bool
    let usesDemoData: Bool
    let computerName: String?
    /// The computer in use (`WorkspaceOwner.cacheScopeID`); nil while none is.
    let scope: String?
    let agents: [AgentProfile]
    /// The agent's own chats on this computer, newest first.
    let chats: (String) -> [SessionSummary]
    let open: (PendingShare, PendingShareDestination, String) -> Void
    @AppStorage(AIDataConsent.key) private var agreed = false
    @Environment(\.scenePhase) private var scenePhase

    private var isActive: Bool {
        !isBlocked && scope != nil
            && !AIDataConsent.needsAsking(agreed: agreed || AIDataConsent.isAgreed(), inFirstSetup: false,
                                          usesDemoData: usesDemoData)
    }

    func body(content: Content) -> some View {
        content
            // Closed only by its own buttons, so each way out means one thing.
            .bighelpSheet(item: Binding(get: { isActive ? center.next() : nil }, set: { _ in })) { entry in
                PendingShareReviewView(
                    entry: entry, waiting: center.waitingCount, computerName: computerName, scope: scope,
                    agents: agents, chats: chats,
                    onOpen: open,
                    onLater: { center.later($0) },
                    onDelete: { try await center.delete($0) })
                    .interactiveDismissDisabled()
                    .bighelpSheetSize(.standard)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await center.refresh()
            }
    }
}

/// One share: what it holds, where it goes, and Open, Not now or Delete.
struct PendingShareReviewView: View {
    let entry: PendingShareInbox.Entry
    let waiting: Int
    let computerName: String?
    let scope: String?
    let agents: [AgentProfile]
    let chats: (String) -> [SessionSummary]
    let onOpen: (PendingShare, PendingShareDestination, String) -> Void
    let onLater: (String) -> Void
    let onDelete: (String) async throws -> Void

    @State private var agentID: String?
    /// Nil is a new chat.
    @State private var sessionID: String?
    /// The computer the agent and chat were picked on.
    @State private var pickedScope: String?
    @State private var notice: String?
    @State private var confirmsDelete = false
    @State private var isDeleting = false
    @BighelpThemeReader private var theme

    private static let shownChats = 6

    var body: some View {
        NavigationStack {
            List {
                switch entry {
                case .share(let share, let placement):
                    contents(share, placement: placement)
                    destination
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
            .navigationTitle(waiting > 1 ? "Shared with bighelp (\(waiting))" : "Shared with bighelp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { onLater(entry.id) }
                        .accessibilityIdentifier("pending-share.later")
                }
                if case .share(let share, _) = entry {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Open") { openChat(share) }
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
        } header: {
            Text("From another app")
        } footer: {
            if let placement {
                Text("You put this in a chat with \(placement.agentName) before, and it wasn't sent.")
            }
        }
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
            Text(computerName.map { String(localized: "Agent on \($0)") } ?? String(localized: "Agent"))
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
                ForEach(chats(agentID).prefix(Self.shownChats)) { chat in
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
        guard agentID == nil, let scope, case .share(_, let placement) = entry else { return }
        if let destination = placement?.destination,
           destination.problem(currentScope: scope, agentIDs: Set(agents.map(\.id)),
                               sessionIDs: Set(chats(destination.agentID).map(\.id))) == nil {
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
                                   sessionIDs: Set(chats(agentID).map(\.id))) {
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
            onOpen(share, destination, name)
        }
    }

    private func delete() {
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do { try await onDelete(entry.id) }
            catch { notice = String(localized: "bighelp couldn't delete this share. Try again.") }
        }
    }
}
