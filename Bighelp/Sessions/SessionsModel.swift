import Foundation
import Observation

enum SessionTypeFilter: Hashable, CaseIterable {
    case all
    case direct
    case botMode

    var title: String {
        switch self {
        case .all: "All"
        case .direct: "Direct"
        case .botMode: "Groups"
        }
    }

    fileprivate func includes(_ kind: SessionKind) -> Bool {
        switch self {
        case .all: true
        case .direct: kind == .direct
        case .botMode: kind == .botMode
        }
    }
}

/// Read-only Chats projection. Hosted rooms keep their authority and durable
/// payloads in BotModeRoomStore rather than becoming direct SessionCatalog rows.
enum HostedRoomSessionProjection {
    static let remoteSource = "hermes-room"
    private static let identityPrefix = "hermes-room:"

    static func summary(for room: HermesBotModeRoomSummary) -> SessionSummary {
        record(for: room).summary
    }

    static func records(
        catalogRecords: [SessionRecord],
        hostedRooms: [HermesBotModeRoomSummary]
    ) -> [SessionRecord] {
        var result = catalogRecords
        var indexByID: [String: Int] = [:]
        for (index, record) in result.enumerated() where indexByID[record.id] == nil {
            indexByID[record.id] = index
        }

        for room in hostedRooms where !room.isDisbanded {
            let projection = record(for: room)
            guard let index = indexByID[projection.id] else {
                indexByID[projection.id] = result.count
                result.append(projection)
                continue
            }
            guard result[index].remoteSource == remoteSource,
                  result[index].botModeRoomID == room.roomID else {
                continue
            }
            result[index].kind = .botMode
            result[index].agentIDs = projection.agentIDs
            result[index].title = room.name
            result[index].updatedAt = max(result[index].updatedAt, room.updatedAt)
            result[index].hasAcceptedMessage = true
        }
        return result
    }

    private static func record(for room: HermesBotModeRoomSummary) -> SessionRecord {
        SessionRecord(
            id: identityPrefix + room.roomID,
            kind: .botMode,
            agentIDs: uniqueProfiles(room.members.map(\.profile)),
            title: room.name,
            remoteSource: remoteSource,
            botModeRoomID: room.roomID,
            createdAt: room.updatedAt,
            updatedAt: room.updatedAt,
            hasAcceptedMessage: true
        )
    }

    private static func uniqueProfiles(_ profiles: [String]) -> [String] {
        var seen = Set<Data>()
        return profiles.filter { seen.insert(Data($0.utf8)).inserted }
    }
}

enum SessionSelectionTarget: Equatable {
    case session(String)
    case hostedRoom(String)
}

enum SessionSelectionRouting {
    static func target(for session: SessionSummary) -> SessionSelectionTarget {
        session.hostedRoomID.map(SessionSelectionTarget.hostedRoom)
            ?? .session(session.id)
    }
}

enum SessionAgentFilter: Hashable {
    case all
    case agent(String)
}

/// Started in: chats from one place (by `SessionOrigin` label), or all.
enum SessionOriginFilter: Hashable {
    case all
    case origin(String)

    var title: String {
        switch self {
        case .all: "Everywhere"
        case .origin(let label): label
        }
    }

    fileprivate func includes(_ record: SessionRecord) -> Bool {
        switch self {
        case .all: true
        case .origin(let label): SessionOrigin.label(record.remoteSource) == label
        }
    }
}

struct SessionProjectOption: Identifiable, Hashable {
    let projectID: String
    let name: String

    var id: String { "\(projectID)\u{1F}\(name)" }
}

enum SessionProjectFilter: Hashable {
    case all
    case project(SessionProjectOption)
    case unassigned

    fileprivate func includes(_ record: SessionRecord) -> Bool {
        switch self {
        case .all: true
        case .project(let project):
            record.workspaceID == project.projectID && record.workspaceName == project.name
        case .unassigned: record.workspaceID == nil
        }
    }
}

struct SessionDaySection: Identifiable, Equatable {
    enum Day: Hashable {
        case active
        case pinned
        case sessions
        case today
        case yesterday
        case earlier
        case project(SessionProjectOption)
        case unassigned

        var title: String {
            switch self {
            case .active: "Active Sessions"
            case .pinned: "Pinned"
            case .sessions: "Sessions"
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .earlier: "Earlier"
            case .project(let project): project.name
            case .unassigned: "Unassigned"
            }
        }
    }

    let day: Day
    let sessions: [SessionSummary]

    var id: Day { day }
    var title: String { day.title }

    var key: SessionSectionKey {
        switch day {
        case .pinned: .pinned
        case .active: .active
        case .sessions, .today, .yesterday, .earlier: .sessions
        case .project(let project): .project(project.projectID)
        case .unassigned: .unassigned
        }
    }

    var isReorderable: Bool { key.isReorderable }
}

@MainActor
@Observable
final class SessionsModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var query = ""
    var agentFilter: SessionAgentFilter = .all
    var originFilter: SessionOriginFilter = .all
    var typeFilter: SessionTypeFilter = .all
    var projectFilter: SessionProjectFilter = .all
    var showsCronSessions = false
    private(set) var loadState: LoadState

    private let catalog: SessionCatalogStore?
    private let agents: AgentDirectoryStore?
    private let hostedRoomStore: BotModeRoomStore?
    private let fixtureRecords: [SessionRecord]
    private var hostedRoomSnapshot: [HermesBotModeRoomSummary]
    private let fixtureHostedCatalogIsAuthoritative: Bool
    private let fixtureAgentNamesByID: [String: String]
    private let calendar: Calendar
    private let now: () -> Date
    private var liveHostedRoomProjectionEnabled = true
    private var accountGeneration: UInt64 = 0
    private var latestLoadGeneration: UInt64 = 0

    init(
        catalog: SessionCatalogStore,
        agents: AgentDirectoryStore,
        hostedRooms: BotModeRoomStore? = nil
    ) {
        self.catalog = catalog
        self.agents = agents
        hostedRoomStore = hostedRooms
        fixtureRecords = []
        hostedRoomSnapshot = hostedRooms?.catalogRooms ?? []
        fixtureHostedCatalogIsAuthoritative = false
        fixtureAgentNamesByID = [:]
        calendar = .autoupdatingCurrent
        now = { Date.now }
        loadState = .idle
    }

    init(
        fixtures: [SessionRecord],
        hostedRooms: [HermesBotModeRoomSummary]? = nil,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date = { Date.now },
        agentNamesByID: [String: String] = [:]
    ) {
        catalog = nil
        agents = nil
        hostedRoomStore = nil
        fixtureRecords = fixtures
        hostedRoomSnapshot = hostedRooms ?? []
        fixtureHostedCatalogIsAuthoritative = hostedRooms != nil
        fixtureAgentNamesByID = agentNamesByID
        self.calendar = calendar
        self.now = now
        loadState = .loaded
    }

    convenience init(
        fixtures: [SessionRecord],
        calendar: Calendar,
        now: Date,
        agentNamesByID: [String: String] = [:]
    ) {
        self.init(
            fixtures: fixtures,
            calendar: calendar,
            now: { now },
            agentNamesByID: agentNamesByID
        )
    }

    var availableAgents: [(id: String, name: String)] {
        agentNamesByID
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var availableProjects: [SessionProjectOption] {
        var projects: Set<SessionProjectOption> = []
        for record in sourceRecords where
            isVisible(record) && !record.isSubagentSession && (record.hasAcceptedMessage || record.hasActiveWork) {
            guard let id = record.workspaceID, let name = record.workspaceName else { continue }
            projects.insert(SessionProjectOption(projectID: id, name: name))
        }
        return projects.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.projectID < $1.projectID : order == .orderedAscending
        }
    }

    /// The places chats on this list started, by name, for the Started in filter.
    var availableOrigins: [String] {
        var labels: Set<String> = []
        for record in sourceRecords where
            isVisible(record) && !record.isSubagentSession && (record.hasAcceptedMessage || record.hasActiveWork) {
            if let label = SessionOrigin.label(record.remoteSource) { labels.insert(label) }
        }
        return labels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var effectiveProjectFilter: SessionProjectFilter {
        guard case .project(let project) = projectFilter else { return projectFilter }
        return availableProjects.contains(project) ? projectFilter : .all
    }

    var filteredSections: [SessionDaySection] {
        filteredSections(organizeByProjects: false)
    }

    func filteredSections(
        organizeByProjects: Bool,
        projectOrder: [SessionSectionKey] = []
    ) -> [SessionDaySection] {
        // Retain and present by recent activity. The shared organizer preserves
        // active/pinned priority and any explicit project ordering.
        let matching = sourceRecords
            .filter { isVisible($0) && !$0.isSubagentSession && ($0.hasAcceptedMessage || $0.hasActiveWork) }
            .sorted(by: activitySort)
            .prefix(SessionCatalogStore.summaryRetentionLimit)
            .filter(matches)
            .map(\.summary)

        return SessionSectionOrganizer.sections(
            from: matching,
            organizeByProjects: organizeByProjects,
            projectOrder: projectOrder
        )
    }

    var hasLoadedSessions: Bool {
        sourceRecords.contains {
            isVisible($0) && !$0.isSubagentSession && ($0.hasAcceptedMessage || $0.hasActiveWork)
        }
    }

    func didLeaveScreen() {
        query = ""
    }

    func load() async {
        guard let catalog else { return }
        let generation = accountGeneration
        latestLoadGeneration &+= 1
        let loadGeneration = latestLoadGeneration
        loadState = .loading
        do {
            try await catalog.load()
            await hostedRoomStore?.refreshNativeRoomCatalog()
            guard
                generation == accountGeneration,
                loadGeneration == latestLoadGeneration
            else { return }
            synchronizeHostedRooms()
            loadState = .loaded
        } catch is SessionCatalogLoadOwnershipError {
            guard
                generation == accountGeneration,
                loadGeneration == latestLoadGeneration
            else { return }
            loadState = catalog.hasLoadedState ? .loaded : .idle
        } catch is CancellationError {
            guard
                generation == accountGeneration,
                loadGeneration == latestLoadGeneration
            else { return }
            loadState = catalog.hasLoadedState ? .loaded : .idle
        } catch {
            guard
                generation == accountGeneration,
                loadGeneration == latestLoadGeneration
            else { return }
            loadState = .failed("We couldn’t load your sessions. Try again.")
        }
    }

    func resetForAccountBoundary() {
        accountGeneration &+= 1
        latestLoadGeneration &+= 1
        liveHostedRoomProjectionEnabled = false
        hostedRoomSnapshot = []
        loadState = .idle
    }

    func synchronizeHostedRooms() {
        guard hostedRoomStore != nil else { return }
        liveHostedRoomProjectionEnabled = true
    }

    func renameSession(id: String, title: String) async throws {
        guard let catalog, canManageConversation(id: id) else {
            throw SessionCatalogError.invalidSession
        }
        try await catalog.renameSession(id: id, title: title)
    }

    func setSessionPinned(id: String, pinned: Bool) async throws {
        guard let catalog, canManageConversation(id: id) else {
            throw SessionCatalogError.invalidSession
        }
        try await catalog.setSessionPinned(id: id, pinned: pinned)
    }

    func archiveSession(id: String) async throws {
        guard let catalog, canManageConversation(id: id) else {
            throw SessionCatalogError.invalidSession
        }
        try await catalog.archiveSession(id: id)
    }

    func deleteSession(id: String) async throws {
        guard let catalog, canManageConversation(id: id) else {
            throw SessionCatalogError.invalidSession
        }
        try await catalog.deleteSession(id: id)
    }

    var canDeleteConversation: Bool { catalog?.canDeleteConversation ?? true }

    func canManageConversation(_ session: SessionSummary) -> Bool {
        session.hostedRoomID == nil
    }

    private var sourceRecords: [SessionRecord] {
        let catalogRecords = catalog?.presentedRecords ?? fixtureRecords
        // Read the observable store directly so a room catalog loaded by the
        // workspace refresh invalidates Chats even when its own sessions load
        // was superseded before it could take another snapshot.
        let hostedRooms = hostedRoomStore.map {
            liveHostedRoomProjectionEnabled ? $0.catalogRooms : []
        } ?? hostedRoomSnapshot
        let catalogIsAuthoritative = fixtureHostedCatalogIsAuthoritative
            || hostedRoomStore.map { $0.catalogState == .loaded && !$0.isCatalogStale } == true
        let activeRoomIDs = Set(hostedRooms.map { Data($0.roomID.utf8) })
        let currentRecords = catalogIsAuthoritative ? catalogRecords.filter { record in
            guard record.remoteSource == HostedRoomSessionProjection.remoteSource else { return true }
            guard let roomID = record.botModeRoomID else { return false }
            return activeRoomIDs.contains(Data(roomID.utf8))
        } : catalogRecords

        return HostedRoomSessionProjection.records(
            catalogRecords: currentRecords,
            hostedRooms: hostedRooms
        )
    }

    private func canManageConversation(id: String) -> Bool {
        guard let record = sourceRecords.first(where: { $0.id == id }) else {
            return false
        }
        return record.summary.hostedRoomID == nil
    }

    private func isVisible(_ record: SessionRecord) -> Bool {
        !record.isWorkflowSession && (showsCronSessions || !record.isCronSession)
    }

    private var agentNamesByID: [String: String] {
        if let agents {
            Dictionary(uniqueKeysWithValues: agents.profiles.map { ($0.id, $0.name) })
        } else {
            fixtureAgentNamesByID
        }
    }

    private func matches(_ record: SessionRecord) -> Bool {
        guard typeFilter.includes(record.kind) else { return false }
        guard effectiveProjectFilter.includes(record) else { return false }
        guard originFilter.includes(record) else { return false }
        if case .agent(let agentID) = agentFilter, !record.agentIDs.contains(agentID) {
            return false
        }
        let queryTokens = normalized(query)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !queryTokens.isEmpty else { return true }
        let searchableTokens = searchTokens(for: record)
        return queryTokens.allSatisfy { queryToken in
            searchableTokens.contains { $0.contains(queryToken) }
        }
    }

    private func searchTokens(for record: SessionRecord) -> [String] {
        let transcript = record.items.compactMap { item -> String? in
            guard case .message(let text) = item.content else { return nil }
            return text
        }
        let agentNames = record.agentIDs.compactMap { agentNamesByID[$0] }
        return ([record.title, record.summary.preview] + transcript + agentNames)
            .map(normalized)
            .filter { !$0.isEmpty }
    }

    private func sectionDay(for date: Date) -> SessionDaySection.Day {
        let currentDate = now()
        if calendar.isDate(date, inSameDayAs: currentDate) {
            return .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: currentDate),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .earlier
    }

    private func activitySort(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        if lhs.hasActiveWork != rhs.hasActiveWork {
            return lhs.hasActiveWork
        }
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id < rhs.id
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private extension SessionDaySection.Day {
    static let inactiveCases: [Self] = [.today, .yesterday, .earlier]
}
