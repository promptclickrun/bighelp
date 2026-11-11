import SwiftUI

/// Chats someone archived on this computer, every agent's, newest first, each with the app or channel it
/// came from (iMessage, Telegram…). Restore brings one back to the lists; opening one restores it first.
/// Delete removes one for good, from the row's ••• or its long-press menu: the lists have no Delete of their own.
@MainActor
struct ArchivedChatsView: View {
    let catalog: SessionCatalogStore
    let agentName: (String) -> String
    let onOpen: (SessionSummary) -> Void

    @State private var chats: [SessionArchivedChat]?
    /// The list couldn't load. What a row's own action says stays on that row (`failure`).
    @State private var errorMessage: String?
    /// The one chat being restored or deleted: one at a time, so the two can't race on a chat.
    @State private var working: String?
    @State private var failure: RowFailure?
    /// The row waiting on the Delete alert's confirmation.
    @State private var pendingDelete: SessionArchivedChat?
    @BighelpThemeReader private var theme

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.warning)
                    .accessibilityIdentifier("archived-chats.error")
            }
            if let chats {
                if chats.isEmpty {
                    ContentUnavailableView("No Archived Chats", systemImage: "archivebox",
                                           description: Text("Chats you archive show here, ready to restore."))
                        .listRowBackground(Color.clear)
                }
                ForEach(chats) { chat in row(chat) }
            } else if errorMessage == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Archived Chats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("Delete chat?", isPresented: Binding(get: { pendingDelete != nil },
                                                   set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { chat in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await delete(chat) } }
                .accessibilityIdentifier("archived-chats.delete-confirm")
        } message: { _ in
            Text("It and its history are removed from this computer. This can't be undone.")
        }
        .accessibilityIdentifier("archived-chats")
    }

    private var isWorking: Bool { working != nil }

    private func row(_ chat: SessionArchivedChat) -> some View {
        HStack(spacing: BighelpTokens.space4) {
            Button {
                Task { await restore(chat, opens: true) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Text(detail(chat))
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                    if let failure, failure.chatID == chat.id {
                        // Not a Label: a List lines its row separators up with a Label's text.
                        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space4) {
                            Image(systemName: "exclamationmark.circle")
                                .accessibilityHidden(true)
                            Text(failure.message)
                        }
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.warning)
                        .padding(.top, BighelpTokens.space4)
                        .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("archived-chats.failure.\(chat.id)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityIdentifier("archived-chats.chat.\(chat.id)")

            if working == chat.id {
                ProgressView()
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
            } else {
                Menu {
                    actions(chat)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                        .bighelpPointer()
                }
                .menuOrder(.fixed)
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityLabel("More actions")
                .accessibilityIdentifier("archived-chats.more.\(chat.id)")
            }
        }
        // The ••• button's own margin lines its dots up with the row's edge.
        .padding(.trailing, -BighelpTokens.space8)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Restore", systemImage: "tray.and.arrow.up") { Task { await restore(chat, opens: false) } }
                .tint(.indigo)
                .disabled(isWorking)
        }
        .contextMenu { actions(chat) }
    }

    /// The row's ••• and its long-press menu. `.disabled` on the row doesn't reach inside a menu.
    @ViewBuilder
    private func actions(_ chat: SessionArchivedChat) -> some View {
        Button("Restore", systemImage: "tray.and.arrow.up") { Task { await restore(chat, opens: false) } }
            .disabled(isWorking)
        if catalog.canDeleteArchivedChats {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = chat }
                .disabled(isWorking)
        }
    }

    private func detail(_ chat: SessionArchivedChat) -> String {
        [agentName(chat.profileID), SessionOrigin.label(chat.source),
         chat.lastActive?.formatted(.relative(presentation: .named))]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func load() async {
        do {
            chats = try await catalog.archivedChats()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = "Archived chats couldn't be loaded. "
                + (HermesRefusalMessage.sentence(in: error) ?? "Pull down to try again.")
        }
    }

    private func delete(_ chat: SessionArchivedChat) async {
        guard working == nil else { return }
        working = chat.id
        failure = nil
        defer { working = nil }
        do {
            try await catalog.deleteArchivedChat(chat)
            chats?.removeAll { $0.id == chat.id }
        } catch is CancellationError {
        } catch {
            failure = RowFailure(chatID: chat.id,
                                 message: ArchivedChatDeleteRefusal.message(for: error, source: chat.source))
        }
    }

    private func restore(_ chat: SessionArchivedChat, opens: Bool) async {
        guard working == nil else { return }
        working = chat.id
        failure = nil
        defer { working = nil }
        do {
            let record = try await catalog.restoreArchivedChat(chat)
            chats?.removeAll { $0.id == chat.id }
            if opens, let record { onOpen(record.summary) }
        } catch is CancellationError {
        } catch {
            failure = RowFailure(chatID: chat.id, message: "Couldn't restore this chat. "
                + (HermesRefusalMessage.sentence(in: error) ?? "Try again."))
        }
    }

    private struct RowFailure {
        let chatID: String
        let message: String
    }
}

/// What a row says when its Delete doesn't go through. Hermes refuses a chat that's still open
/// somewhere ("cannot delete an active session"), which needs words a person can act on.
enum ArchivedChatDeleteRefusal {
    static func message(for error: any Error, source: String?) -> String {
        guard let refusal = HermesRefusalMessage.refusal(in: error),
              refusal.text?.localizedCaseInsensitiveContains("active session") == true else {
            return "Couldn't delete this chat. " + (HermesRefusalMessage.sentence(in: error) ?? "Try again.")
        }
        // bighelp's own chats let go shortly after the app does; there's nowhere for the person to close them.
        guard let app = SessionOrigin.label(source), app != "bighelp" else {
            return "Still open. Try again in a moment."
        }
        return "Still open in \(app). Close it there, then try again."
    }
}
