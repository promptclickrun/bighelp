import Foundation
import SwiftUI

/// One chat in the Chats view: a chat on the computer in use (live, from its catalog), or one on
/// another computer as its all-hosts copy last read it. One-to-one chats, group chats and coding
/// sessions are all rows of the same list.
struct ChatsInboxRow: Identifiable, Equatable {
    enum Source: Equatable {
        /// The computer in use: a catalog row, or a group chat with no message yet.
        case session(SessionSummary)
        /// Another computer's chat, from its all-hosts copy.
        case fleetChat(FleetChat)
        /// Another computer's group chat, from its all-hosts copy.
        case fleetGroup(FleetGroup)
    }

    let id: String
    let source: Source
    /// The computer it lives on; nil when no computer list is kept (one computer).
    let hostID: UUID?
    let isOnComputerInUse: Bool
    let title: String
    /// Hermes' preview as it came (Markdown and all); the row makes it plain as it draws.
    let preview: String
    let updatedAt: Date
    /// Only the computer in use keeps pins and read state the list can see (`FleetChat` has neither).
    let isPinned: Bool
    let isUnread: Bool
    let tracksUnread: Bool
    let hasDraft: Bool
    let isActive: Bool
    let isGroup: Bool
    /// A coding session started from Work. Only known for the computer in use.
    let isCode: Bool
    /// Who it's with, by profile ID on its own computer.
    let memberIDs: [String]
    let origin: String?
    /// The computer's name for the row's tag; nil when the tag doesn't show.
    let computerTag: String?
    /// Its bot's Bot Chat state in `BotChatActivityStore`; nil for any other chat, whose state the
    /// store doesn't know.
    let activityKey: String?

    /// Pin, Mark read and Rename work through the computer in use's catalog; group chats are
    /// managed in their own settings, as on the Sessions list.
    private var isManagedHere: Bool {
        if case .session(let summary) = source { return summary.hostedRoomID == nil }
        return false
    }

    private var isFleetChat: Bool {
        if case .fleetChat = source { return true }
        return false
    }

    var canPin: Bool { isManagedHere }
    var canMarkUnread: Bool { isManagedHere && tracksUnread }
    /// Another computer's chat goes through the fleet's update call, which renames and archives.
    var canRename: Bool { isManagedHere || isFleetChat }
    var canArchive: Bool { isManagedHere || isFleetChat }
    var isBotChat: Bool { !isGroup && title == "Bot Chat" }

    var target: ChatsInboxTarget {
        switch source {
        case .session(let summary): .session(summary)
        case .fleetChat(let chat): .fleetChat(chat)
        case .fleetGroup(let group): .group(group)
        }
    }
}

extension ChatsInboxRow {
    init(session: SessionSummary, hostID: UUID?, isCode: Bool) {
        let isGroup = session.kind == .botMode || session.hostedRoomID != nil
        let isBotChat = !isGroup && session.isBotChat
        self.init(
            id: "here/" + session.id, source: .session(session), hostID: hostID, isOnComputerInUse: true,
            title: session.title, preview: session.preview, updatedAt: session.updatedAt,
            isPinned: session.isPinned, isUnread: session.isUnread, tracksUnread: session.tracksUnread,
            hasDraft: session.hasDraft, isActive: session.isActive, isGroup: isGroup, isCode: isCode,
            memberIDs: session.agentIDs, origin: session.origin, computerTag: nil,
            activityKey: isBotChat ? session.agentIDs.first.map(BotChatActivityStore.liveKey) : nil
        )
    }

    init(fleetChat chat: FleetChat, computerTag: String?) {
        self.init(
            id: chat.id, source: .fleetChat(chat), hostID: chat.hostID, isOnComputerInUse: false,
            title: chat.title.isEmpty ? String(localized: "New chat") : chat.title, preview: chat.preview,
            updatedAt: chat.updatedAt, isPinned: chat.isPinned ?? false, isUnread: false, tracksUnread: false, hasDraft: false,
            isActive: chat.isActive, isGroup: false, isCode: false, memberIDs: [chat.profileID], origin: chat.origin,
            computerTag: computerTag,
            activityKey: chat.title == "Bot Chat" ? FleetID.make(chat.hostID, chat.profileID) : nil
        )
    }

    init(fleetGroup group: FleetGroup, computerTag: String?) {
        self.init(
            id: group.id, source: .fleetGroup(group), hostID: group.hostID, isOnComputerInUse: false,
            title: group.name, preview: group.memberNames.joined(separator: ", "), updatedAt: group.updatedAt,
            isPinned: false, isUnread: false, tracksUnread: false, hasDraft: false, isActive: group.isWorking,
            isGroup: true, isCode: false, memberIDs: group.memberIDs ?? [], origin: nil, computerTag: computerTag,
            activityKey: nil
        )
    }
}

/// What a tap on a row opens. The shell routes each the way it already does: a session through
/// `SessionSelectionRouting` (a group chat by its room), another computer's through `openFleet`.
enum ChatsInboxTarget: Equatable {
    case session(SessionSummary)
    case fleetChat(FleetChat)
    case group(FleetGroup)
}

/// A row's long-press actions. The shell makes them: the catalog for the computer in use,
/// `FleetStore.updateChat` (rename, archive) for another computer.
enum ChatsInboxChange: Equatable, Sendable {
    case pin(Bool)
    case unread(Bool)
    case rename(String)
    case archive
}

/// A Chats row: the face (a group's faces together), the title with its tags, the time and the
/// unread dot; under them the draft mark and the preview. While a Bot Chat works or needs you,
/// that takes the preview's line, as on the Bots view.
struct ChatsInboxRowLabel: View {
    let row: ChatsInboxRow
    let face: AnyView
    let activity: BotChatActivityStore?
    @Environment(\.dynamicTypeSize) private var typeSize
    @BighelpThemeReader private var theme

    static let faceSize: CGFloat = 56

    /// Read here, so only this row redraws when its bot's state changes.
    private var busy: BotChatActivity? {
        guard let key = row.activityKey, let value = activity?.activity(key), value.isBusy else { return nil }
        return value
    }

    var body: some View {
        HStack(spacing: BighelpTokens.space16) {
            face.frame(width: Self.faceSize, height: Self.faceSize)
            VStack(alignment: .leading, spacing: 3) {
                if typeSize.isAccessibilitySize {
                    // The largest text sizes: each part on a line of its own, so none is cut off.
                    HStack(spacing: BighelpTokens.space8) {
                        titleText.lineLimit(3)
                        pin
                        Spacer(minLength: BighelpTokens.space8)
                        unreadDot
                    }
                    tags
                    dateText
                } else {
                    HStack(spacing: BighelpTokens.space8) {
                        titleText
                            .lineLimit(1)
                            .layoutPriority(1)
                        pin
                        tags
                        Spacer(minLength: BighelpTokens.space8)
                        // The title is cut, never the time.
                        dateText.fixedSize()
                        unreadDot
                    }
                }
                secondLine
            }
        }
        .padding(.vertical, BighelpTokens.space8)
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(row.title)
            .font(.bighelp(.title3, weight: row.isUnread ? .semibold : .medium))
            .foregroundStyle(theme.primaryText)
    }

    @ViewBuilder
    private var tags: some View {
        if row.isCode || row.computerTag != nil {
            HStack(spacing: 4) {
                if row.isCode { ChatsInboxCodeTag() }
                if let name = row.computerTag { FleetHostTag(name: name) }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var secondLine: some View {
        if let busy, let line = busy.line {
            Text(line)
                .font(.bighelp(.body, weight: .medium))
                .foregroundStyle(lineColor(busy))
                .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                if row.isActive {
                    Circle()
                        .fill(AgentLiveState.thinking.dotColor)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Working")
                }
                SessionOriginTag(source: row.origin, size: 12)
                if row.hasDraft {
                    HStack(spacing: 2) {
                        Image(systemName: "pencil").accessibilityHidden(true)
                        Text("Draft")
                    }
                    .font(.bighelp(.footnote, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                }
                let preview = SessionPreviewText.plain(row.preview)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// Needing you in ember, a turn in the action color, work in the background in plain ink.
    private func lineColor(_ activity: BotChatActivity) -> Color {
        switch activity {
        case .waiting: BighelpBrand.ember
        case .background: theme.primaryText
        case .idle, .working: theme.action
        }
    }

    @ViewBuilder
    private var pin: some View {
        if row.isPinned {
            Image(systemName: "pin.fill")
                .font(.bighelp(.caption2))
                .foregroundStyle(theme.tertiaryText)
                .accessibilityLabel("Pinned")
        }
    }

    private var dateText: some View {
        Text(SessionRow.compactTimestamp(row.updatedAt))
            .font(.bighelp(.subheadline))
            .monospacedDigit()
            .foregroundStyle(theme.tertiaryText)
            .lineLimit(1)
    }

    @ViewBuilder
    private var unreadDot: some View {
        if row.isUnread {
            Circle().fill(theme.information).frame(width: 9, height: 9).accessibilityLabel("Unread")
        }
    }
}

/// "Code" on a coding session's row, drawn as the computer tag is.
struct ChatsInboxCodeTag: View {
    @BighelpThemeReader private var theme

    var body: some View {
        Text("Code")
            .font(.bighelp(.caption2).weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(theme.secondaryText.opacity(0.12), in: .capsule)
            .accessibilityLabel("Coding session")
    }
}

/// A still stand-in for a row while the first chats load: no pulse, which would repaint every frame.
struct ChatsInboxPlaceholderRow: View {
    let index: Int
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space16) {
            Circle()
                .fill(theme.incomingMessageBackground)
                .frame(width: ChatsInboxRowLabel.faceSize, height: ChatsInboxRowLabel.faceSize)
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                bar(width: index.isMultiple(of: 2) ? 140 : 100, height: 14)
                bar(width: index.isMultiple(of: 3) ? 160 : 220, height: 12)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, BighelpTokens.space8)
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(theme.incomingMessageBackground)
            .frame(width: width, height: height)
    }
}
