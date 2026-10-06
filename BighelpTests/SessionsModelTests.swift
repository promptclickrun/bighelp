import Foundation
import Testing
@testable import Bighelp

@MainActor
struct SessionsModelTests {
    @Test func activeThenPinnedThenProjectsUseRecentActivityDescending() {
        func record(_ id: String, created: TimeInterval, updated: TimeInterval,
                    pinned: Bool = false, active: Bool = false) -> SessionRecord {
            SessionRecord(id: id, kind: .direct, agentIDs: ["juno"], title: id,
                          workspaceID: "project", workspaceName: "Project",
                          isActive: active, isPinned: pinned,
                          createdAt: Date(timeIntervalSince1970: created),
                          updatedAt: Date(timeIntervalSince1970: updated), hasAcceptedMessage: true)
        }
        let model = SessionsModel(fixtures: [
            record("pinned-old-active", created: 10, updated: 900, pinned: true, active: true),
            record("pinned-new", created: 20, updated: 20, pinned: true),
            record("active-old", created: 30, updated: 800, active: true),
            record("active-new", created: 40, updated: 40, active: true),
            record("project-old", created: 50, updated: 700),
            record("project-new", created: 60, updated: 60),
        ], calendar: Calendar(identifier: .gregorian))
        let sections = model.filteredSections(organizeByProjects: true)
        #expect(sections.map(\.day) == [.active, .pinned,
            .project(SessionProjectOption(projectID: "project", name: "Project"))])
        #expect(sections.map { $0.sessions.map(\.id) } == [
            ["pinned-old-active", "active-old", "active-new"],
            ["pinned-new"],
            ["project-old", "project-new"],
        ])
    }

    /// Each chat says where it started, and the list can show chats from one place.
    @Test func chatsTagAndFilterByWhereTheyStarted() {
        #expect(SessionOrigin.label("desktop") == "Hermes Desktop")
        #expect(SessionOrigin.label("claude-code") == "Claude Code")
        #expect(SessionOrigin.label("codex-cli") == "Codex")
        #expect(SessionOrigin.label("TELEGRAM") == "Telegram")
        #expect(SessionOrigin.label("some_new_place") == "Some New Place", "Unknown sources still read as words")
        #expect(SessionOrigin.label(nil) == nil && SessionOrigin.label("  ") == nil)

        let date = Date(timeIntervalSince1970: 100)
        let records = [("a", "desktop"), ("b", "telegram"), ("c", "hermes-desktop"), ("d", nil)].map { id, source in
            SessionRecord(id: id, kind: .direct, agentIDs: ["juno"], title: id, remoteSource: source,
                          createdAt: date, updatedAt: date, hasAcceptedMessage: true)
        }
        let model = SessionsModel(fixtures: records, calendar: Calendar(identifier: .gregorian))
        #expect(model.availableOrigins == ["Hermes Desktop", "Telegram"])
        #expect(model.filteredSections.flatMap(\.sessions).first { $0.id == "b" }?.origin == "telegram")
        model.originFilter = .origin("Hermes Desktop")
        #expect(Set(model.filteredSections.flatMap(\.sessions).map(\.id)) == ["a", "c"])
        model.originFilter = .all
        #expect(model.filteredSections.flatMap(\.sessions).count == 4)
    }

    @Test func activitySortIsStableAndFilteringPreservesSectionPriority() {
        let date = Date(timeIntervalSince1970: 100)
        let records = ["z", "a", "m"].map { id in
            SessionRecord(id: id, kind: .direct, agentIDs: ["juno"], title: "Find \(id)",
                          createdAt: date, updatedAt: date.addingTimeInterval(id == "z" ? 500 : 0),
                          hasAcceptedMessage: true)
        }
        let model = SessionsModel(fixtures: records, calendar: Calendar(identifier: .gregorian))
        #expect(model.filteredSections.map(\.title) == ["Sessions"])
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == ["z", "a", "m"])
        model.query = "Find m"
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == ["m"])
    }

    @Test func sectionsUseRecencyAndSectionPriorityRules() {
        func record(_ id: String, created: TimeInterval, updated: TimeInterval,
                    pinned: Bool = false, active: Bool = false) -> SessionRecord {
            SessionRecord(id: id, kind: .direct, agentIDs: ["juno"], title: id,
                          workspaceID: "p", workspaceName: "Project", isActive: active, isPinned: pinned,
                          createdAt: Date(timeIntervalSince1970: created),
                          updatedAt: Date(timeIntervalSince1970: updated), hasAcceptedMessage: true)
        }
        let records = [
            record("old-pin-active", created: 1, updated: 100, pinned: true, active: true),
            record("new-pin", created: 2, updated: 2, pinned: true),
            record("old-active", created: 3, updated: 90, active: true),
            record("new-active", created: 4, updated: 4, active: true),
            record("normal", created: 5, updated: 5),
        ]
        let sections = SessionSectionOrganizer.sections(from: records.map(\.summary), organizeByProjects: true)
        #expect(sections.map(\.title) == ["Active Sessions", "Pinned", "Project"])
        #expect(sections.map { $0.sessions.map(\.id) } == [
            ["old-pin-active", "old-active", "new-active"], ["new-pin"], ["normal"],
        ])
    }

    @Test func cachedSessionsStartRefreshableWithoutHidingRows() {
        let cached = session(id: "cached-session", title: "Cached session")
        let model = SessionsModel(
            catalog: SessionCatalogStore(
                client: DeferredSessionsModelCatalogClient(),
                records: [cached]
            ),
            agents: AgentDirectoryStore(
                client: EmptySessionsModelAgentDirectoryClient(),
                defaults: UserDefaults(suiteName: "SessionsModelTests.\(UUID().uuidString)")!
            )
        )

        #expect(model.loadState == .idle)
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == [cached.id])
    }

    @Test func uncachedIdleSessionsUseFullProgressBeforeTheViewTaskStarts() {
        #expect(SessionsPresentation.loadingMode(loadState: .idle, hasSessions: false) == .fullScreen)
    }

    @Test func sessionLoadingUsesInlineProgressWithCacheAndFullProgressWithoutCache() {
        #expect(SessionsPresentation.loadingMode(loadState: .loading, hasSessions: true) == .inline)
        #expect(SessionsPresentation.loadingMode(loadState: .loading, hasSessions: false) == .fullScreen)
    }

    @Test func workspaceRefreshSupersedingPullToRefreshKeepsExistingSessionsLoaded() async {
        let client = DeferredSessionsModelCatalogClient()
        let defaults = UserDefaults(
            suiteName: "SessionsModelTests.\(UUID().uuidString)"
        )!
        let catalog = SessionCatalogStore(
            client: client,
            records: [session(id: "cached-session", title: "Cached session")]
        )
        let model = SessionsModel(
            catalog: catalog,
            agents: AgentDirectoryStore(
                client: EmptySessionsModelAgentDirectoryClient(),
                defaults: defaults
            )
        )
        let pullToRefresh = Task { await model.load() }
        await client.waitUntilListStarts(count: 1)
        let workspaceRefresh = Task { try? await catalog.load() }
        await client.waitUntilListStarts(count: 2)

        client.resumeList(request: 2, with: [
            session(id: "refreshed-session", title: "Refreshed session"),
        ])
        await workspaceRefresh.value
        client.resumeList(request: 1, with: [
            session(id: "stale-session", title: "Stale session"),
        ])
        await pullToRefresh.value

        #expect(model.loadState == .loaded)
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == ["refreshed-session"])
    }

    @Test func externallyRefreshedHostedRoomsProjectAfterSessionsLoadIsSuperseded() async throws {
        let client = DeferredSessionsModelCatalogClient()
        let catalog = SessionCatalogStore(client: client)
        let rooms = BotModeRoomStore(
            client: BotModeFixtureClient(),
            executionEnabled: false,
            nativeClient: BotModeCatalogFixtureClient()
        )
        let defaults = try #require(UserDefaults(
            suiteName: "SessionsModelTests.\(UUID().uuidString)"
        ))
        let model = SessionsModel(
            catalog: catalog,
            agents: AgentDirectoryStore(
                client: EmptySessionsModelAgentDirectoryClient(),
                defaults: defaults
            ),
            hostedRooms: rooms
        )
        model.synchronizeHostedRooms()
        #expect(model.filteredSections.flatMap(\.sessions).isEmpty)

        let sessionsLoad = Task { await model.load() }
        await client.waitUntilListStarts(count: 1)
        let workspaceLoad = Task { try await catalog.load() }
        await client.waitUntilListStarts(count: 2)
        client.resumeList(request: 2, with: [])
        try await workspaceLoad.value

        await rooms.refreshNativeRoomCatalog()
        #expect(rooms.catalogRooms.map(\.roomID) == ["studio-pair", "research-circle"])
        client.resumeList(request: 1, with: [])
        await sessionsLoad.value

        model.typeFilter = .botMode
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == [
            "hermes-room:research-circle", "hermes-room:studio-pair",
        ])
    }

    @Test func olderSupersededLoadFailureCannotReplaceNewerSuccess() async {
        let client = DeferredSessionsModelCatalogClient()
        let model = makeModel(client: client)
        let first = Task { await model.load() }
        await client.waitUntilListStarts(count: 1)
        let second = Task { await model.load() }
        await client.waitUntilListStarts(count: 2)

        client.resumeList(request: 2, with: [
            session(id: "newer-session", title: "Newer session"),
        ])
        await second.value
        #expect(model.loadState == .loaded)

        client.failList(request: 1)
        await first.value

        #expect(model.loadState == .loaded)
    }

    @Test func accountResetInvalidatesAnInflightLoadFailure() async {
        let client = DeferredSessionsModelCatalogClient()
        let model = makeModel(client: client)
        let loading = Task { await model.load() }
        await client.waitUntilListStarts(count: 1)

        model.resetForAccountBoundary()
        client.failList(request: 1)
        await loading.value

        #expect(model.loadState == .idle)
    }

    @Test func searchAgentAndTypeFiltersCompose() {
        let calendar = Calendar(identifier: .gregorian)
        let model = SessionsModel(
            fixtures: [
                session(
                    id: "session-budget-room",
                    kind: .botMode,
                    agentIDs: ["finance", "travel"],
                    title: "Budget room",
                    transcript: "Review the quarterly budget"
                ),
                session(
                    id: "session-budget-direct",
                    kind: .direct,
                    agentIDs: ["finance"],
                    title: "Budget review",
                    transcript: "Review the quarterly budget"
                ),
                session(
                    id: "session-travel-room",
                    kind: .botMode,
                    agentIDs: ["travel"],
                    title: "Travel room",
                    transcript: "Plan a trip"
                )
            ],
            calendar: calendar,
            now: Self.fixtureDate,
            agentNamesByID: ["finance": "Avery Park", "travel": "Mina Shah"]
        )

        model.query = "budget quarterly"
        model.agentFilter = .agent("finance")
        model.typeFilter = .botMode

        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == ["session-budget-room"])
    }

    @Test func hostedRoomCatalogAppearsOnceInAllAndOnlyInBotMode() {
        let existingRoom = hostedRoom(id: "existing", name: "Existing room", updatedAt: 300)
        let catalogOnlyRoom = hostedRoom(id: "catalog-only", name: "Catalog room", updatedAt: 400)
        let persistedProjection = SessionRecord(
            id: "hermes-room:existing",
            kind: .botMode,
            agentIDs: ["finance", "travel"],
            title: "Stale room title",
            remoteSource: HostedRoomSessionProjection.remoteSource,
            botModeRoomID: "existing",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            hasAcceptedMessage: true
        )
        let direct = session(
            id: "direct-chat",
            kind: .direct,
            title: "Direct chat",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let removedRoom = SessionRecord(
            id: "hermes-room:removed",
            kind: .botMode,
            agentIDs: ["finance", "travel"],
            title: "Removed room",
            remoteSource: HostedRoomSessionProjection.remoteSource,
            botModeRoomID: "removed",
            createdAt: Date(timeIntervalSince1970: 500),
            hasAcceptedMessage: true
        )
        let now = Self.fixtureDate
        let model = SessionsModel(
            fixtures: [persistedProjection, direct, removedRoom],
            hostedRooms: [existingRoom, catalogOnlyRoom],
            calendar: Calendar(identifier: .gregorian),
            now: { now }
        )

        let all = model.filteredSections.flatMap(\.sessions)
        #expect(all.map(\.id) == ["hermes-room:catalog-only", "hermes-room:existing", "direct-chat"])
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.first { $0.id == "hermes-room:existing" }?.title == "Existing room")
        #expect(all.first { $0.id == "hermes-room:existing" }?.hostedRoomID == "existing")
        #expect(all.first { $0.id == "hermes-room:existing" }.map(model.canManageConversation) == false)
        #expect(all.first { $0.id == "direct-chat" }.map(model.canManageConversation) == true)

        model.typeFilter = .botMode
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == [
            "hermes-room:catalog-only", "hermes-room:existing",
        ])

        model.typeFilter = .direct
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == ["direct-chat"])
    }

    @Test func hostedRoomProjectionKeepsStableNavigationIdentity() {
        let room = hostedRoom(id: "release-room", name: "Release room", updatedAt: 500)
        let first = HostedRoomSessionProjection.summary(for: room)
        let second = HostedRoomSessionProjection.summary(for: room)

        #expect(first.id == "hermes-room:release-room")
        #expect(first == second)
        #expect(first.hostedRoomID == room.roomID)
        #expect(SessionSelectionRouting.target(for: first) == .hostedRoom("release-room"))
        #expect(SessionSelectionRouting.target(for: session(id: "direct").summary) == .session("direct"))
    }

    @Test func liveHostedRoomStoreProjectsWithoutPersistingIntoSessionCatalog() async throws {
        let direct = session(id: "direct", title: "Direct chat")
        let catalog = SessionCatalogStore(
            client: DemoSessionCatalogClient(records: [direct]),
            records: [direct]
        )
        let rooms = BotModeRoomStore(
            client: BotModeFixtureClient(),
            executionEnabled: false,
            nativeClient: BotModeCatalogFixtureClient()
        )
        let defaults = try #require(UserDefaults(suiteName: "SessionsModelTests.\(UUID().uuidString)"))
        let model = SessionsModel(
            catalog: catalog,
            agents: AgentDirectoryStore(
                client: EmptySessionsModelAgentDirectoryClient(),
                defaults: defaults
            ),
            hostedRooms: rooms
        )
        await model.load()

        model.typeFilter = .botMode
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == [
            "hermes-room:research-circle", "hermes-room:studio-pair",
        ])
        #expect(catalog.records.map(\.id) == ["direct"])

        model.resetForAccountBoundary()
        #expect(model.filteredSections.flatMap(\.sessions).isEmpty)
        #expect(catalog.records.map(\.id) == ["direct"])
    }

    @Test func leavingSessionsClearsSearchWithoutResettingFilters() {
        let model = SessionsModel(
            fixtures: [],
            calendar: Calendar(identifier: .gregorian),
            now: Self.fixtureDate
        )
        let project = SessionProjectOption(projectID: "project-loopdy", name: "bighelp")
        model.query = "release"
        model.agentFilter = .agent("juno")
        model.projectFilter = .project(project)
        model.typeFilter = .botMode

        model.didLeaveScreen()

        #expect(model.query.isEmpty)
        #expect(model.agentFilter == .agent("juno"))
        #expect(model.projectFilter == .project(project))
        #expect(model.typeFilter == .botMode)
    }

    @Test func projectFilterComposesWithSearchAgentAndTypeFilters() {
        let model = SessionsModel(
            fixtures: [
                session(
                    id: "loopdy-budget-room",
                    kind: .botMode,
                    agentIDs: ["finance"],
                    title: "Budget room",
                    transcript: "Quarterly budget",
                    workspaceID: "project-loopdy",
                    workspaceName: "bighelp"
                ),
                session(
                    id: "home-budget-room",
                    kind: .botMode,
                    agentIDs: ["finance"],
                    title: "Budget room",
                    transcript: "Quarterly budget",
                    workspaceID: "project-home",
                    workspaceName: "Home"
                ),
                session(
                    id: "unassigned-budget-room",
                    kind: .botMode,
                    agentIDs: ["finance"],
                    title: "Budget room",
                    transcript: "Quarterly budget"
                ),
            ],
            calendar: Calendar(identifier: .gregorian),
            now: Self.fixtureDate,
            agentNamesByID: ["finance": "Avery Park"]
        )

        model.query = "quarterly"
        model.agentFilter = .agent("finance")
        model.typeFilter = .botMode
        model.projectFilter = .project(
            SessionProjectOption(projectID: "project-loopdy", name: "bighelp")
        )

        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == ["loopdy-budget-room"])
        #expect(model.availableProjects.map(\.projectID) == ["project-loopdy", "project-home"])
        #expect(model.availableProjects.map(\.name) == ["bighelp", "Home"])

        model.projectFilter = .unassigned
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == ["unassigned-budget-room"])
    }

    @Test func projectFilterKeepsReusedIDsDistinctAndFallsBackWhenSelectionDisappears() {
        let model = SessionsModel(
            fixtures: [
                session(
                    id: "home-a",
                    title: "Home A",
                    workspaceID: "project-home",
                    workspaceName: "Home A"
                ),
                session(
                    id: "home-b",
                    title: "Home B",
                    workspaceID: "project-home",
                    workspaceName: "Home B"
                ),
            ],
            calendar: Calendar(identifier: .gregorian),
            now: Self.fixtureDate
        )

        #expect(model.availableProjects.map(\.name) == ["Home A", "Home B"])
        model.projectFilter = .project(
            SessionProjectOption(projectID: "project-home", name: "Home B")
        )
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == ["home-b"])

        model.projectFilter = .project(
            SessionProjectOption(projectID: "missing", name: "Missing")
        )
        #expect(model.effectiveProjectFilter == .all)
        #expect(Set(model.filteredSections.flatMap(\.sessions).map(\.id)) == ["home-a", "home-b"])
    }

    @Test func ungroupedResultsUseOneCreationOrderedSection() {
        let calendar = Calendar(identifier: .gregorian)
        let model = SessionsModel(
            fixtures: [
                session(id: "today", updatedAt: Self.fixtureDate),
                session(id: "yesterday", updatedAt: calendar.date(byAdding: .day, value: -1, to: Self.fixtureDate)!),
                session(id: "earlier", updatedAt: calendar.date(byAdding: .day, value: -2, to: Self.fixtureDate)!)
            ],
            calendar: calendar,
            now: Self.fixtureDate
        )

        #expect(model.filteredSections.map(\.title) == ["Sessions"])
        #expect(model.filteredSections.map { $0.sessions.map(\.id) } == [["today", "yesterday", "earlier"]])
    }

    @Test func activeSessionsLeadThenInactiveSessionsSortByCreation() {
        let model = SessionsModel(
            fixtures: [
                session(id: "inactive-newest", updatedAt: Self.fixtureDate),
                session(
                    id: "active-older",
                    updatedAt: Self.fixtureDate.addingTimeInterval(-7_200),
                    isActive: true
                ),
                session(
                    id: "active-newer",
                    updatedAt: Self.fixtureDate.addingTimeInterval(-3_600),
                    isActive: true
                ),
                session(
                    id: "inactive-older",
                    updatedAt: Self.fixtureDate.addingTimeInterval(-10_800)
                ),
            ],
            calendar: Calendar(identifier: .gregorian),
            now: Self.fixtureDate
        )

        #expect(model.filteredSections.map(\.title) == ["Active Sessions", "Sessions"])
        #expect(model.filteredSections.map { $0.sessions.map(\.id) } == [
            ["active-newer", "active-older"],
            ["inactive-newest", "inactive-older"],
        ])
        #expect(model.filteredSections.first?.sessions.allSatisfy(\.isActive) == true)
    }

    @Test func subagentChildSessionsNeverAppearAsTopLevelActiveSessions() {
        let parent = session(id: "parent", isActive: true)
        let child = session(
            id: "child",
            isActive: true,
            parentSessionID: parent.id
        )
        let model = SessionsModel(
            fixtures: [child, parent],
            calendar: Calendar(identifier: .gregorian),
            now: Self.fixtureDate
        )

        #expect(model.filteredSections.map(\.title) == ["Active Sessions"])
        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == [parent.id])
    }

    @Test func activePinsAppearOnlyInActiveChats() {
        let model = SessionsModel(
            fixtures: [
                session(id: "newer-unpinned", updatedAt: Self.fixtureDate),
                session(
                    id: "older-pinned",
                    updatedAt: Self.fixtureDate.addingTimeInterval(-3_600),
                    isPinned: true
                ),
                session(
                    id: "active-pinned",
                    updatedAt: Self.fixtureDate.addingTimeInterval(-7_200),
                    isActive: true,
                    isPinned: true
                ),
            ],
            calendar: Calendar(identifier: .gregorian),
            now: Self.fixtureDate
        )

        #expect(model.filteredSections.map(\.title) == ["Active Sessions", "Pinned", "Sessions"])
        #expect(model.filteredSections.map { $0.sessions.map(\.id) } == [
            ["active-pinned"],
            ["older-pinned"],
            ["newer-unpinned"],
        ])
        #expect(model.filteredSections.flatMap(\.sessions).map(\.isPinned) == [true, true, false])
    }

    @Test func projectOrganizationKeepsPrioritySectionsThenGroupsByRecentProject() {
        let model = SessionsModel(
            fixtures: [
                session(
                    id: "active",
                    isActive: true,
                    workspaceID: "project-loopdy",
                    workspaceName: "bighelp iOS"
                ),
                session(
                    id: "pinned",
                    updatedAt: Self.fixtureDate.addingTimeInterval(-10),
                    isPinned: true,
                    workspaceID: "project-infra",
                    workspaceName: "Hermes Infrastructure"
                ),
                session(
                    id: "loopdy-new",
                    updatedAt: Self.fixtureDate.addingTimeInterval(-20),
                    workspaceID: "project-loopdy",
                    workspaceName: "bighelp iOS"
                ),
                session(
                    id: "loopdy-old",
                    updatedAt: Self.fixtureDate.addingTimeInterval(-40),
                    workspaceID: "project-loopdy",
                    workspaceName: "bighelp iOS"
                ),
                session(
                    id: "infra",
                    updatedAt: Self.fixtureDate.addingTimeInterval(-30),
                    workspaceID: "project-infra",
                    workspaceName: "Hermes Infrastructure"
                ),
                session(
                    id: "unassigned",
                    updatedAt: Self.fixtureDate.addingTimeInterval(-5)
                ),
            ],
            calendar: Calendar(identifier: .gregorian),
            now: Self.fixtureDate
        )

        let sections = model.filteredSections(organizeByProjects: true)

        #expect(sections.map(\.title) == [
            "Active Sessions", "Pinned", "bighelp iOS", "Hermes Infrastructure", "Unassigned",
        ])
        #expect(sections.map { $0.sessions.map(\.id) } == [
            ["active"],
            ["pinned"],
            ["loopdy-new", "loopdy-old"],
            ["infra"],
            ["unassigned"],
        ])
        #expect(Set(sections.flatMap(\.sessions).map(\.id)).count == 6)
    }

    @Test func includesAnActiveHermesSessionBeforeItsFirstAcceptedMessage() {
        let activeHermesSession = SessionRecord(
            id: "visible-active-session",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Active Juno session",
            remoteStoredID: "stored-active-session",
            remoteSource: "loopdy",
            isActive: true,
            hasAcceptedMessage: false
        )
        let localEmptyDraft = SessionRecord(
            id: "local-empty-draft",
            kind: .direct,
            agentIDs: ["juno"],
            title: "New chat",
            hasAcceptedMessage: false
        )
        let model = SessionsModel(
            fixtures: [activeHermesSession, localEmptyDraft],
            calendar: Calendar(identifier: .gregorian),
            now: Self.fixtureDate
        )

        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == [activeHermesSession.id])
        #expect(model.hasLoadedSessions)
    }

    @Test func hidesCronSessionsByDefaultWhileRetainingActualChats() {
        let chat = SessionRecord(
            id: "actual-chat",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Actual chat",
            remoteSource: "loopdy",
            hasAcceptedMessage: true
        )
        let cron = SessionRecord(
            id: "scheduled-run",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Scheduled run",
            remoteSource: "cron",
            hasAcceptedMessage: true
        )
        let model = SessionsModel(
            fixtures: [cron, chat],
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(model.filteredSections.flatMap(\.sessions).map(\.id) == [chat.id])
    }

    private static let fixtureDate = Date(timeIntervalSinceReferenceDate: 777_600_000)

    private func makeModel(client: DeferredSessionsModelCatalogClient) -> SessionsModel {
        let defaults = UserDefaults(
            suiteName: "SessionsModelTests.\(UUID().uuidString)"
        )!
        return SessionsModel(
            catalog: SessionCatalogStore(client: client),
            agents: AgentDirectoryStore(
                client: EmptySessionsModelAgentDirectoryClient(),
                defaults: defaults
            )
        )
    }

    private func session(
        id: String,
        kind: SessionKind = .direct,
        agentIDs: [String] = ["finance"],
        title: String = "Session",
        transcript: String = "A saved message",
        updatedAt: Date? = nil,
        isActive: Bool = false,
        isPinned: Bool = false,
        workspaceID: String? = nil,
        workspaceName: String? = nil,
        parentSessionID: String? = nil
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            kind: kind,
            agentIDs: agentIDs,
            title: title,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            parentSessionID: parentSessionID,
            items: [
                TimelineItem(
                    id: "\(id)-message",
                    role: .human,
                    sender: .user(snapshot: .init(name: "You")),
                    content: .message(transcript),
                    metadata: TimelineMetadata(delivery: "Sent")
                )
            ],
            isActive: isActive,
            isPinned: isPinned,
            createdAt: updatedAt ?? Self.fixtureDate,
            updatedAt: updatedAt ?? Self.fixtureDate,
            hasAcceptedMessage: true
        )
    }

    private func hostedRoom(
        id: String,
        name: String,
        updatedAt: TimeInterval
    ) -> HermesBotModeRoomSummary {
        HermesBotModeRoomSummary(
            room: HermesBotModeRoomState(
                roomID: id,
                name: name,
                members: ["finance", "travel"].map { profile in
                    HermesBotModeRoomMember(
                        memberID: "member-\(profile)",
                        profile: profile,
                        handle: profile,
                        target: ["kind": .string("local"), "profile": .string(profile)]
                    )
                },
                authorityGatewayID: "fixture-gateway",
                authorityEpoch: 1,
                revision: 1,
                createdAt: updatedAt - 60,
                updatedAt: updatedAt,
                latestSequence: 0,
                disbandedAt: nil,
                driverStatus: nil
            ),
            capabilities: nil
        )
    }
}

private enum SessionsModelTestError: Error {
    case unavailable
}

@MainActor
private final class DeferredSessionsModelCatalogClient: SessionCatalogClient {
    private var continuations: [Int: CheckedContinuation<[SessionRecord], Error>] = [:]
    private var startedCount = 0

    func list() async throws -> [SessionRecord] {
        startedCount += 1
        let request = startedCount
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        throw SessionsModelTestError.unavailable
    }

    func waitUntilListStarts(count: Int) async {
        while startedCount < count { await Task.yield() }
    }

    func resumeList(request: Int, with records: [SessionRecord]) {
        continuations.removeValue(forKey: request)?.resume(returning: records)
    }

    func failList(request: Int) {
        continuations.removeValue(forKey: request)?.resume(
            throwing: SessionsModelTestError.unavailable
        )
    }
}

@MainActor
private final class EmptySessionsModelAgentDirectoryClient: AgentDirectoryClient {
    func list() async throws -> [AgentProfile] { [] }

    func create(_ draft: AgentDraft) async throws -> AgentProfile {
        throw SessionsModelTestError.unavailable
    }

    func update(id: String, draft: AgentDraft) async throws -> AgentProfile {
        throw SessionsModelTestError.unavailable
    }
}
