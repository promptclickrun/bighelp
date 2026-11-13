import Foundation

/// Another computer as the Chats view lists it: its chats and group chats from its all-hosts copy.
struct ChatsInboxComputer: Identifiable, Equatable {
    let id: UUID
    let name: String
    let chats: [FleetChat]
    let groups: [FleetGroup]
}

/// Everything the Chats list is made from.
struct ChatsInboxInput: Equatable {
    /// The computer in use's chats (`SessionCatalogStore.recentSummaries`).
    var sessions: [SessionSummary] = []
    /// The computer in use's group chats, with or without messages: one with none yet isn't in the catalog.
    var rooms: [HermesBotModeRoomSummary] = []
    /// Coding sessions started from Work on the computer in use, by app session ID.
    var codeSessionIDs: Set<String> = []
    var selectedHostID: UUID? = nil
    /// Every computer's all-hosts copy; the one in use's is dropped, since its catalog is live.
    var computers: [ChatsInboxComputer] = []
    /// Two or more computers show: chats on another computer carry its name.
    var showsComputerTags = false
}

/// The chip row's one choice: every chat, one computer's, or the unread ones.
enum ChatsInboxFilter: Hashable {
    case all
    case computer(UUID)
    case unread
}

/// A run of rows under one header: Pinned, then by day.
struct ChatsInboxSection: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case pinned, today, yesterday, earlier
    }

    let kind: Kind
    let rows: [ChatsInboxRow]

    var id: Kind { kind }
}

/// The Chats list as a pure function of what the stores hold: merged, the computer in use's copies
/// dropped, Pinned first, then newest first. The view keeps the result until an input changes
/// (`ChatsInboxCache`), so nothing here runs for each event a computer sends.
enum ChatsInboxProjection {
    static func rows(_ input: ChatsInboxInput) -> [ChatsInboxRow] {
        var rows: [ChatsInboxRow] = []
        var listedRooms = Set<String>()
        var listedIDs = Set<String>()
        for session in input.sessions where listedIDs.insert(session.id).inserted {
            if let roomID = session.hostedRoomID { listedRooms.insert(roomID) }
            rows.append(ChatsInboxRow(session: session, hostID: input.selectedHostID,
                                      isCode: input.codeSessionIDs.contains(session.id)))
        }
        // A group chat with no message yet: Hermes' rooms list it, named as its catalog row will be.
        for room in input.rooms where !room.isDisbanded && listedRooms.insert(room.roomID).inserted {
            let summary = HostedRoomSessionProjection.summary(for: room)
            guard listedIDs.insert(summary.id).inserted else { continue }
            rows.append(ChatsInboxRow(session: summary, hostID: input.selectedHostID, isCode: false))
        }
        for computer in input.computers where computer.id != input.selectedHostID {
            let tag = input.showsComputerTags ? computer.name : nil
            rows += computer.chats.map { ChatsInboxRow(fleetChat: $0, computerTag: tag) }
            rows += computer.groups.map { ChatsInboxRow(fleetGroup: $0, computerTag: tag) }
        }
        return rows.sorted(by: inOrder)
    }

    /// Pinned first, then the newest; the ID keeps equal times in one order.
    static func inOrder(_ lhs: ChatsInboxRow, _ rhs: ChatsInboxRow) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    /// The chip and the search text on top of the merged rows. Search looks at titles and previews.
    static func filter(_ rows: [ChatsInboxRow], by filter: ChatsInboxFilter, matching query: String) -> [ChatsInboxRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            switch filter {
            case .all: break
            case .computer(let id): guard row.hostID == id else { return false }
            case .unread: guard row.isUnread else { return false }
            }
            return query.isEmpty
                || row.title.localizedCaseInsensitiveContains(query)
                || row.preview.localizedCaseInsensitiveContains(query)
        }
    }

    /// Pinned on top, then Today, Yesterday and Earlier, each keeping the rows' order.
    static func sections(_ rows: [ChatsInboxRow], now: Date, calendar: Calendar = .current) -> [ChatsInboxSection] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        var byKind: [ChatsInboxSection.Kind: [ChatsInboxRow]] = [:]
        for row in rows {
            let kind: ChatsInboxSection.Kind = if row.isPinned {
                .pinned
            } else if row.updatedAt >= startOfToday {
                // A clock a little ahead on the computer still reads as today.
                .today
            } else if row.updatedAt >= startOfYesterday {
                .yesterday
            } else {
                .earlier
            }
            byKind[kind, default: []].append(row)
        }
        return [ChatsInboxSection.Kind.pinned, .today, .yesterday, .earlier].compactMap { kind in
            byKind[kind].map { ChatsInboxSection(kind: kind, rows: $0) }
        }
    }
}
