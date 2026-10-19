import SwiftUI

/// A bot profile's tabs, in order. Computer shows only when the bot has a screen.
enum SimpleBotProfileTab: String, CaseIterable, Identifiable {
    case info, computer, files, media

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "Info"
        case .computer: "Computer"
        case .files: "Files"
        case .media: "Media"
        }
    }

    static func available(showsComputer: Bool) -> [Self] {
        allCases.filter { $0 != .computer || showsComputer }
    }
}

/// A bot's Files tab: its folder on the computer, one folder at a time. Folders open in place
/// with Back above them; files open in the preview chats use, videos and songs stream.
@MainActor
struct SimpleBotFilesTab: View {
    @Bindable var model: SimpleBotFilesModel
    let botName: String
    /// The name of the bot whose folder the computer shares instead.
    let nameOfBot: (String) -> String

    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            switch model.phase {
            case .loading:
                SimpleBotsMessageCard(title: "Opening \(botName)'s files…", isLoading: true)
            case .needsPluginUpdate:
                SimpleBotsMessageCard(systemImage: "arrow.down.circle", title: "Update the bighelp plugin to see files",
                                      detail: "Update it on your computer in Settings, then come back here.")
            case .sharedByAnotherBot(let id):
                let other = nameOfBot(id)
                SimpleBotsMessageCard(systemImage: "folder", title: "\(botName)'s files aren't shared",
                                      detail: "Your computer shares one bot's folder with bighelp: \(other)'s. "
                                          + "Open \(other) to see those files.")
            case .failed(let message):
                SimpleBotsMessageCard(systemImage: "exclamationmark.triangle", title: "Files didn't load",
                                      detail: message, actionTitle: "Try Again") { Task { await model.refresh() } }
            case .loaded:
                folder
            }
        }
        .task { await model.refresh() }
        .bighelpSheet(item: $model.preview) { attachment in
            ChatAttachmentPreviewView(attachment: attachment).bighelpSheetSize(.large)
        }
        .bighelpSheet(item: $model.playback) { playback in
            WorkspaceManagedMediaView(playback: playback).bighelpSheetSize(.large)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.profile.files")
    }

    @ViewBuilder
    private var folder: some View {
        SimpleBotsSectionLabel(title: model.locationTitle)
            .accessibilityIdentifier("simple-bots.files.location")
        // Lazy: a folder can hold thousands of files.
        LazyVStack(spacing: 0) {
            if !model.isAtTop {
                Button { Task { await model.goUp() } } label: {
                    SimpleBotsRow(title: "Back to \(model.parentTitle)", leading: Image(systemName: "chevron.left")) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("simple-bots.files.up")
                if !model.entries.isEmpty { SimpleBotsDivider() }
            }
            if model.entries.isEmpty {
                Text(model.isAtTop ? "No files yet" : "This folder is empty")
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .padding(.horizontal, BighelpTokens.space20)
                    .accessibilityIdentifier("simple-bots.files.empty")
            }
            ForEach(model.entries) { file in
                if file.id != model.entries.first?.id { SimpleBotsDivider() }
                row(file)
            }
        }
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20, style: .continuous))
        if let notice = model.notice {
            Text(notice)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.danger)
                .padding(.horizontal, BighelpTokens.space20)
                .accessibilityIdentifier("simple-bots.files.notice")
        }
        Text(model.isAtTop && model.entries.isEmpty
             ? "Files \(botName) makes or saves on your computer show up here."
             : "The folder \(botName) works in on your computer.")
            .font(.bighelp(.subheadline))
            .foregroundStyle(theme.tertiaryText)
            .padding(.horizontal, BighelpTokens.space20)
    }

    private func row(_ file: HermesManagedFile) -> some View {
        Button { Task { await model.open(file) } } label: {
            SimpleBotsRow(title: file.name, detail: detail(file),
                          leading: Image(systemName: SimpleBotFilesModel.symbol(for: file))) {
                if model.openingPath == file.path {
                    BighelpSpinner(size: 18)
                } else {
                    SimpleBotsDisclosure()
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.openingPath != nil)
        .accessibilityHint(file.isDirectory ? "Opens this folder" : "Opens a preview")
        .accessibilityIdentifier("simple-bots.files.item")
    }

    private func detail(_ file: HermesManagedFile) -> String {
        let changed = file.modifiedAt.formatted(.relative(presentation: .named))
        guard !file.isDirectory, let size = file.byteCount else { return changed.capitalizedFirst }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " · " + changed
    }
}

/// A bot's Media tab: photos and videos from its chats, newest first, as in the full app's
/// Files › Media. Pictures load small copies as they scroll in; videos load when opened.
@MainActor
struct SimpleBotMediaTab: View {
    let agentID: String
    let botName: String
    let store: AgentMediaStore
    /// False while no computer is connected.
    let isConnected: Bool

    @State private var preview: ChatAttachment?
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if store.items.isEmpty {
                empty
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(store.items) { item in
                        AgentMediaTile(item: item, store: store) {
                            Task { preview = await store.attachment(for: item) }
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: BighelpTokens.radius20, style: .continuous))
                Text("Photos and videos from your chats with \(botName).")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.tertiaryText)
                    .padding(.horizontal, BighelpTokens.space20)
            }
        }
        .task(id: agentID) { await store.load(agentID: agentID) }
        .bighelpSheet(item: $preview) { attachment in
            ChatAttachmentPreviewView(attachment: attachment).bighelpSheetSize(.large)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.profile.media")
    }

    @ViewBuilder
    private var empty: some View {
        switch store.state {
        case .idle, .loading:
            SimpleBotsMessageCard(title: "Finding photos and videos…", isLoading: true)
        case .unavailable where !isConnected:
            SimpleBotsMessageCard(systemImage: "wifi.slash", title: "Your computer isn't connected",
                                  detail: "Photos and videos show up here once it's back.")
        case .unavailable:
            SimpleBotsMessageCard(systemImage: "arrow.down.circle", title: "Update the bighelp plugin to see media",
                                  detail: "Update it on your computer in Settings, then come back here.")
        case .failed(let message):
            SimpleBotsMessageCard(systemImage: "exclamationmark.triangle", title: "Media didn't load",
                                  detail: message, actionTitle: "Try Again") {
                Task { await store.load(agentID: agentID) }
            }
        case .loaded:
            SimpleBotsMessageCard(systemImage: "photo.on.rectangle", title: "No photos or videos yet",
                                  detail: "Pictures and videos \(botName) sends you or makes show up here.")
        }
    }
}

/// A card that says one thing: loading, empty, or what to do.
struct SimpleBotsMessageCard: View {
    var systemImage: String?
    let title: String
    var detail: String?
    var isLoading = false
    var actionTitle: String?
    var action: (() -> Void)?

    @BighelpThemeReader private var theme

    var body: some View {
        SimpleBotsCard {
            VStack(spacing: BighelpTokens.space12) {
                if isLoading {
                    BighelpSpinner(size: 24)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.bighelp(.title2))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                if let detail {
                    Text(detail)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.bighelp(.body, weight: .semibold))
                        .foregroundStyle(theme.information)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                        .buttonStyle(.plain)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(BighelpTokens.space24)
        }
        .accessibilityElement(children: .contain)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
