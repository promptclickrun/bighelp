import SwiftUI

/// Chats from Codex and Claude Code on the computer. Hermes reads them where those apps
/// keep them and can bring one in as its own chat (Hermes' `session.foreign.*`).
@MainActor
protocol OtherAppChatsSource: AnyObject {
    func list(offset: Int) async throws -> HermesForeignSessionPage
    func preview(_ item: HermesForeignSessionItem) async throws -> HermesForeignSessionPreview
    /// Brings the previewed chat into Hermes; its Hermes session ID. A chat brought in
    /// before opens the copy Hermes already has.
    func bringIn(_ preview: HermesForeignSessionPreview) async throws -> String
}

@MainActor
final class LiveOtherAppChats: OtherAppChatsSource {
    private let client: any HermesSessionMaintenanceManaging
    private let profileID: String

    init(client: any HermesSessionMaintenanceManaging, profileID: String) {
        self.client = client
        self.profileID = profileID
    }

    func list(offset: Int) async throws -> HermesForeignSessionPage {
        try await client.foreignSessions(profileID: profileID, source: nil, offset: offset, limit: 10)
    }

    func preview(_ item: HermesForeignSessionItem) async throws -> HermesForeignSessionPreview {
        try await client.foreignPreview(profileID: profileID, item: item)
    }

    func bringIn(_ preview: HermesForeignSessionPreview) async throws -> String {
        if let imported = preview.alreadyImportedSessionID { return imported }
        return try await client.importForeign(reviewed: preview).sessionID
    }
}

/// The list's state: a page of chats, the one being previewed, and whether Hermes can do this.
@MainActor
@Observable
final class OtherAppChatsStore {
    private(set) var items: [HermesForeignSessionItem] = []
    private(set) var nextOffset: Int?
    private(set) var preview: HermesForeignSessionPreview?
    private(set) var isWorking = false
    var errorMessage: String?
    @ObservationIgnored private let source: any OtherAppChatsSource

    init(source: any OtherAppChatsSource) { self.source = source }

    /// The newest chats. A computer whose Hermes can't list them shows nothing.
    func load() async {
        do {
            let page = try await source.list(offset: 0)
            items = page.sessions
            nextOffset = page.nextOffset
        } catch is CancellationError {
        } catch {
            items = []
            nextOffset = nil
        }
    }

    func loadMore() async {
        guard let offset = nextOffset, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let page = try await source.list(offset: offset)
            let known = Set(items.map(\.id))
            items += page.sessions.filter { !known.contains($0.id) }
            nextOffset = page.nextOffset
        } catch is CancellationError {
        } catch {
            errorMessage = "More chats couldn't be loaded. Try again."
        }
    }

    func showPreview(_ item: HermesForeignSessionItem) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            preview = try await source.preview(item)
        } catch is CancellationError {
        } catch {
            errorMessage = "This chat couldn't be read. Try again."
        }
    }

    func closePreview() { preview = nil }

    /// Brings the previewed chat in; its Hermes session ID, or nil when that failed.
    func bringIn() async -> String? {
        guard let preview, !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let id = try await source.bringIn(preview)
            self.preview = nil
            return id
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = "This chat couldn't be opened in bighelp. Check that the computer is connected, then try again."
            return nil
        }
    }
}

/// A chat from another app, as a row: its app, title, last change and how it starts.
struct OtherAppChatRow: View {
    let item: HermesForeignSessionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                Text(item.title)
                    .font(.bighelp(.callout).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: BighelpTokens.space4)
                if let modified = item.modifiedAt {
                    Text(SessionRow.compactTimestamp(modified))
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                SessionOriginTag(source: item.source, size: 11)
                Text(item.excerpt.isEmpty ? "\(item.turnCount) messages" : item.excerpt)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// What a chat from another app says before it comes into bighelp.
struct OtherAppChatPreviewSheet: View {
    let preview: HermesForeignSessionPreview
    let isWorking: Bool
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("From", value: SessionOrigin.label(preview.source) ?? preview.source)
                    if let cwd = preview.cwd { LabeledContent("Folder", value: cwd) }
                    LabeledContent("Messages", value: "\(preview.totalMessages)")
                } footer: {
                    Text(preview.alreadyImportedSessionID == nil
                         ? "Opening it copies the chat into Hermes, so you can keep going here. The original stays where it is."
                         : "This chat is already in Hermes.")
                }
                Section("Start of the chat") {
                    ForEach(preview.messages.prefix(6)) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.role == "user" ? "You" : "Assistant")
                                .font(.bighelp(.footnote).weight(.semibold))
                                .foregroundStyle(theme.secondaryText)
                            Text(message.content)
                                .font(.bighelp(.subheadline))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(4)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle(preview.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .bighelpToolbarText()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open", action: onOpen)
                        .fontWeight(.semibold)
                        .disabled(isWorking)
                        .bighelpDefaultAction()
                        .accessibilityIdentifier("sessions.other-apps.open")
                        .bighelpToolbarText()
                }
            }
        }
        .presentationDragIndicator(.visible)
        .bighelpSheetSize(.standard)
        .accessibilityIdentifier("sessions.other-apps.preview")
    }

    @BighelpThemeReader private var theme
}

/// Demo mode's Codex and Claude Code chats.
@MainActor
final class DemoOtherAppChats: OtherAppChatsSource {
    private static let items = [
        HermesForeignSessionItem(id: String(repeating: "a", count: 64), source: "codex", sourceLabel: "Codex CLI",
                                 title: "Polish the Mac menus", cwd: "~/Projects/bighelp",
                                 modifiedAt: Date.now.addingTimeInterval(-3_600), turnCount: 12,
                                 excerpt: "Make the sidebar easier to read"),
        HermesForeignSessionItem(id: String(repeating: "b", count: 64), source: "claude", sourceLabel: "Claude Code",
                                 title: "Trip budget script", cwd: "~/Projects/travel",
                                 modifiedAt: Date.now.addingTimeInterval(-86_400), turnCount: 6,
                                 excerpt: "Add up the hotel quotes"),
    ]
    /// The demo chat a brought-in one opens as.
    let openedSessionID: String

    init(openedSessionID: String) { self.openedSessionID = openedSessionID }

    func list(offset: Int) async throws -> HermesForeignSessionPage {
        HermesForeignSessionPage(profileID: "default", host: "Demo Mac", sessions: offset == 0 ? Self.items : [],
                                 nextOffset: nil, unreadable: 0)
    }

    func preview(_ item: HermesForeignSessionItem) async throws -> HermesForeignSessionPreview {
        HermesForeignSessionPreview(demoTitle: item.title, source: item.source, cwd: item.cwd)
    }

    func bringIn(_ preview: HermesForeignSessionPreview) async throws -> String { openedSessionID }
}
