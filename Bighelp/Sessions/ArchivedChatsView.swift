import SwiftUI

/// Chats someone archived on this computer, every agent's, newest first, each with the app or channel it
/// came from (iMessage, Telegram…). Restore brings one back to the lists; opening one restores it first.
/// Delete removes one for good — the lists have no Delete of their own.
@MainActor
struct ArchivedChatsView: View {
    let catalog: SessionCatalogStore
    let agentName: (String) -> String
    let onOpen: (SessionSummary) -> Void

    @State private var chats: [SessionArchivedChat]?
    @State private var errorMessage: String?
    @State private var restoring: String?
    @State private var deleting: String?
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
        } message: { chat in
            Text("Delete “\(chat.title)” permanently? This cannot be undone.")
        }
        .accessibilityIdentifier("archived-chats")
    }

    private func row(_ chat: SessionArchivedChat) -> some View {
        Button {
            Task { await restore(chat, opens: true) }
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Text(detail(chat))
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: BighelpTokens.space8)
                if restoring == chat.id || deleting == chat.id { ProgressView() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(restoring != nil || deleting != nil)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Restore", systemImage: "tray.and.arrow.up") { Task { await restore(chat, opens: false) } }
                .tint(.indigo)
            if catalog.canDeleteArchivedChats {
                Button(role: .destructive) {
                    pendingDelete = chat
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("archived-chats.swipe.delete.\(chat.id)")
            }
        }
        .contextMenu {
            Button("Restore", systemImage: "tray.and.arrow.up") { Task { await restore(chat, opens: false) } }
            if catalog.canDeleteArchivedChats {
                Divider()
                Button(role: .destructive) {
                    pendingDelete = chat
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("archived-chats.action.delete.\(chat.id)")
            }
        }
        .accessibilityIdentifier("archived-chats.chat.\(chat.id)")
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
        guard deleting == nil else { return }
        deleting = chat.id
        defer { deleting = nil }
        do {
            try await catalog.deleteArchivedChat(chat)
            chats?.removeAll { $0.id == chat.id }
        } catch is CancellationError {
        } catch {
            errorMessage = "\(chat.title) couldn't be deleted. "
                + (HermesRefusalMessage.sentence(in: error) ?? "Try again.")
        }
    }

    private func restore(_ chat: SessionArchivedChat, opens: Bool) async {
        guard restoring == nil else { return }
        restoring = chat.id
        defer { restoring = nil }
        do {
            let record = try await catalog.restoreArchivedChat(chat)
            chats?.removeAll { $0.id == chat.id }
            if opens, let record { onOpen(record.summary) }
        } catch is CancellationError {
        } catch {
            errorMessage = "\(chat.title) couldn't be restored. "
                + (HermesRefusalMessage.sentence(in: error) ?? "Try again.")
        }
    }
}
