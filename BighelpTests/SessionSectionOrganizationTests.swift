import Foundation
import Testing
@testable import Bighelp

@MainActor
struct SessionSectionOrganizationTests {
    @Test func activeChatsMoveAheadOfPinsAndReturnWithoutLosingPlacement() {
        let ordinary = summary("ordinary", created: 30, project: "work")
        let pin = summary("pin", created: 10, project: "work", pinned: true)
        let working = summary("working", created: 20, project: "work", active: true)
        let runningPin = summary("pin", created: 10, project: "work", pinned: true, active: true)
        let running = SessionSectionOrganizer.sections(
            from: [ordinary, runningPin, working], organizeByProjects: false)
        #expect(running.map(\.key) == [.active, .sessions])
        #expect(running.first?.title == "Active Sessions")
        #expect(running.first?.sessions.map(\.id) == ["working", "pin"])
        #expect(running.last?.title == "Sessions")
        #expect(Set(running.flatMap(\.sessions).map(\.id)).count == 3)

        let settled = summary("working", created: 20, project: "work")
        let idle = SessionSectionOrganizer.sections(
            from: [ordinary, pin, settled], organizeByProjects: false)
        #expect(idle.map(\.key) == [.pinned, .sessions])
        #expect(idle.last?.sessions.map(\.id) == ["ordinary", "working"])
        let projects = SessionSectionOrganizer.sections(
            from: [ordinary, pin, settled], organizeByProjects: true)
        #expect(projects.map(\.key) == [.pinned, .project("work")])
        #expect(projects.last?.sessions.map(\.id) == ["ordinary", "working"])
    }

    @Test func recentActivityOutranksCreationAcrossBothSessionSurfaces() {
        let sessions = [
            summary("recent-created", created: 90, updated: 90),
            summary("old-used", created: 1, updated: 100),
            summary("pin", created: 2, updated: 2, pinned: true),
            summary("active", created: 3, updated: 3, active: true),
        ]
        let sections = SessionSectionOrganizer.sections(from: sessions, organizeByProjects: false)
        #expect(sections.map(\.key) == [.active, .pinned, .sessions])
        #expect(sections.flatMap(\.sessions).map(\.id) == ["active", "pin", "old-used", "recent-created"])
        let quick = QuickWorkspaceContent(recentSessions: sessions)
        #expect(quick.recentSessions.map(\.id) == sections.flatMap(\.sessions).map(\.id))
    }

    @Test func quickListBudgetsByRecentActivityBeforeProjectGrouping() {
        let ordinary = (0..<7).map {
            summary("new-\($0)", created: TimeInterval(20 + $0), updated: TimeInterval(200 - $0), project: "new")
        }
        let sessions = ordinary + [
            summary("old-used", created: 1, updated: 500, project: "old"),
            summary("pin", created: 2, updated: 2, pinned: true),
            summary("active", created: 3, updated: 3, active: true),
        ]
        let quick = QuickWorkspaceContent(recentSessions: sessions, organizeByProjects: true,
                                         projectOrder: [.project("new"), .project("old")])
        #expect(quick.sessionGroups.map(\.key) == [.active, .pinned, .project("new"), .project("old")])
        #expect(quick.recentSessions.map(\.id) == ["active", "pin", "new-0", "new-1", "new-2", "new-3", "old-used"])
    }

    @Test func projectRecencyUsesLatestActivityAndPreservesExplicitOrder() {
        let sessions = [
            summary("old-used", created: 1, updated: 100, project: "old"),
            summary("new-created", created: 50, updated: 50, project: "new"),
            summary("old-newer-created", created: 40, updated: 40, project: "old"),
        ]
        let automatic = SessionSectionOrganizer.sections(from: sessions, organizeByProjects: true)
        #expect(automatic.map(\.key) == [.project("old"), .project("new")])
        #expect(automatic.first?.sessions.map(\.id) == ["old-used", "old-newer-created"])
        let manual = SessionSectionOrganizer.sections(from: sessions, organizeByProjects: true,
                                                      projectOrder: [.project("new"), .project("old")])
        #expect(manual.map(\.key) == [.project("new"), .project("old")])
        #expect(manual.last?.sessions.map(\.id) == ["old-used", "old-newer-created"])
    }

    @Test func equalActivityUsesStableIdentityInsteadOfCreation() {
        let sections = SessionSectionOrganizer.sections(from: [
            summary("z", created: 90, updated: 100),
            summary("a", created: 1, updated: 100),
        ], organizeByProjects: false)
        #expect(sections.first?.sessions.map(\.id) == ["a", "z"])
    }

    @Test func sectionDragPayloadDoesNotAcceptUnrelatedPlainText() {
        let provider = SessionSectionDragPayload.provider(for: .project("a"))
        #expect(!provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text"))
        #expect(provider.hasItemConformingToTypeIdentifier("app.loopdy.session-section"))
    }

    @Test func targetAwareMovesCrossMultipleSectionsInEitherDirection() {
        let order: [SessionSectionKey] = [.project("a"), .project("b"), .project("c"), .unassigned]
        #expect(SessionSectionLayout.moving(.project("a"), to: .unassigned, in: order)
                == [.project("b"), .project("c"), .unassigned, .project("a")])
        #expect(SessionSectionLayout.moving(.unassigned, to: .project("a"), in: order)
                == [.unassigned, .project("a"), .project("b"), .project("c")])
        #expect(SessionSectionLayout.moving(.pinned, to: .project("a"), in: order) == order)
        #expect(SessionSectionLayout.moving(.project("a"), to: .project("missing"), in: order) == order)
        #expect(SessionSectionLayout.moving(.project("a"), to: .project("a"), in: order) == order)
    }

    @Test func newerPreferenceSchemaIsPreservedOnMutation() throws {
        let suite = "session-section-future-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "loopdy.sessions.section-preferences.v1"
        let future = Data(#"{"schemaVersion":2,"preferencesByAccount":{},"future":"preserve me"}"#.utf8)
        defaults.set(future, forKey: key)
        let settings = SettingsStore(defaults: defaults)
        settings.setSessionSectionCollapsed(true, sectionKey: .project("a"), accountID: "a", hostID: "h")
        #expect(defaults.data(forKey: key) == future)
    }

    @Test func sidebarKeepsFiveNewestOrdinaryChatsWhenPrioritySectionsAreFull() {
        let pins = (0..<6).map { summary("pin-\($0)", created: TimeInterval($0), pinned: true) }
        let ordinary = (0..<7).map { summary("normal-\($0)", created: TimeInterval(100 + $0), project: "p") }
        let content = QuickWorkspaceContent(recentSessions: pins + ordinary, organizeByProjects: true)
        #expect(content.sessionGroups.last?.sessions.map(\.id) == ["normal-6", "normal-5", "normal-4", "normal-3", "normal-2"])
        #expect(content.sessionGroups.first?.sessions.count == pins.count)
    }

    @Test func layoutPersistsAndIsolatesAccountsAndHosts() {
        let suite = "session-sections-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let order: [SessionSectionKey] = [.project("b"), .unassigned, .project("a")]
        settings.setSessionSectionOrder(order, accountID: "account-a", hostID: "host-a")
        settings.setSessionSectionCollapsed(true, sectionKey: .project("a"), accountID: "account-a", hostID: "host-a")
        let restored = SettingsStore(defaults: defaults)
        let value = restored.sessionSectionPreferences(accountID: "account-a", hostID: "host-a")
        #expect(value.projectOrder == order)
        #expect(value.isCollapsed(.project("a")))
        #expect(restored.sessionSectionPreferences(accountID: "account-b", hostID: "host-a") == SessionSectionPreferences())
        #expect(restored.sessionSectionPreferences(accountID: "account-a", hostID: "host-b") == SessionSectionPreferences())
        #expect(restored.sessionSectionPreferences(accountID: nil, hostID: "host-a") == SessionSectionPreferences())
        SettingsStore.eraseSessionSectionPreferences(defaults: defaults)
        #expect(restored.sessionSectionPreferences(accountID: "account-a", hostID: "host-a") == SessionSectionPreferences())
    }

    @Test func movesPreserveHiddenKeysAndPrioritySectionsCannotCollapse() {
        let suite = "session-section-moves-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setSessionSectionOrder([.project("a"), .project("hidden"), .project("b")], accountID: "a", hostID: "h")
        settings.moveSessionSection(.project("b"), direction: .up,
            availableProjectKeys: [.project("a"), .project("b")], accountID: "a", hostID: "h")
        let layout = settings.sessionSectionLayout(accountID: "a", hostID: "h",
            availableProjectKeys: [.project("a"), .project("b")])
        #expect(layout.projectOrder == [.project("b"), .project("a")])
        #expect(settings.sessionSectionPreferences(accountID: "a", hostID: "h").projectOrder.contains(.project("hidden")))
        settings.setSessionSectionCollapsed(true, sectionKey: .pinned, accountID: "a", hostID: "h")
        settings.setSessionSectionCollapsed(true, sectionKey: .active, accountID: "a", hostID: "h")
        #expect(settings.sessionSectionPreferences(accountID: "a", hostID: "h").collapsedSectionKeys.isEmpty)
        settings.moveSessionSection(.project("b"), direction: .up,
            availableProjectKeys: [.project("a"), .project("b")], accountID: "a", hostID: "h")
        #expect(settings.sessionSectionLayout(accountID: "a", hostID: "h",
            availableProjectKeys: [.project("a"), .project("b")]).projectOrder == layout.projectOrder)
    }

    @Test func savedOrderIsAnOverlayAndNeverMovesPrioritySections() {
        let sessions = [
            summary("pin", created: 1, pinned: true),
            summary("active", created: 2, active: true),
            summary("a-chat", created: 30, project: "a"),
            summary("b-chat", created: 20, project: "b"),
            summary("c-chat", created: 10, project: "c"),
        ]
        let sections = SessionSectionOrganizer.sections(from: sessions, organizeByProjects: true,
            projectOrder: [.active, .project("b"), .pinned, .project("b"), .project("absent")])
        #expect(sections.map(\.key) == [.active, .pinned, .project("b"), .project("a"), .project("c")])
        #expect(sections.flatMap(\.sessions).count == sessions.count)
    }

    @Test func partialCatalogOrderPreservesAbsentProjects() {
        let saved: [SessionSectionKey] = [.project("a"), .project("b"), .project("c")]
        let visible = SessionSectionLayout.orderedProjectKeys(savedOrder: saved,
            availableKeys: [.project("c"), .project("a")])
        #expect(visible == [.project("a"), .project("c")])
        let persisted = SessionSectionLayout.preservingSavedKeys(
            reorderedKeys: [.project("c"), .project("a")], savedOrder: saved)
        #expect(persisted == [.project("c"), .project("b"), .project("a")])
        #expect(Set(persisted) == Set(saved))
        #expect(persisted.first == .project("c"))
        #expect(persisted.filter { $0 == .project("a") }.count == 1)
    }

    @Test func projectRenameKeepsStableSectionIdentityAndRecentActivityOrder() {
        let sections = SessionSectionOrganizer.sections(from: [
            summary("old", created: 1, project: "stable", projectName: "Old name"),
            summary("new", created: 2, project: "stable", projectName: "Renamed"),
        ], organizeByProjects: true, projectOrder: [.project("stable")])
        #expect(sections.count == 1)
        #expect(sections.first?.key == .project("stable"))
        #expect(sections.first?.title == "Renamed")
        #expect(sections.first?.sessions.map(\.id) == ["new", "old"])
    }

    @Test func unassignedAndSystemNamesCannotCollideWithProjects() {
        let sections = SessionSectionOrganizer.sections(from: [
            summary("p", created: 1, project: "pinned"),
            summary("u", created: 2, project: "unassigned"),
            summary("none", created: 3),
        ], organizeByProjects: true)
        #expect(Set(sections.map(\.key)) == [.project("pinned"), .project("unassigned"), .unassigned])
        #expect(!SessionSectionKey.pinned.isReorderable)
        #expect(!SessionSectionKey.active.isReorderable)
        #expect(SessionSectionKey.unassigned.isReorderable)
    }

    @Test func priorityChatsRemainInSidebarEvenBehindRecentOrdinaryChats() {
        let ordinary = (0..<8).map { summary("normal-\($0)", created: TimeInterval(100 - $0), project: "p") }
        let sessions = ordinary + [summary("pin", created: 1, pinned: true), summary("active", created: 2, active: true)]
        let content = QuickWorkspaceContent(recentSessions: sessions, organizeByProjects: true)
        #expect(content.sessionGroups.prefix(2).map(\.title) == ["Active Sessions", "Pinned"])
        #expect(content.recentSessions.contains { $0.id == "pin" })
        #expect(content.recentSessions.contains { $0.id == "active" })
        #expect(Set(content.recentSessions.map(\.id)).count == content.recentSessions.count)
    }

    @Test func sidebarDoesNotTruncatePinnedOrActiveSectionsToFiveChats() {
        let pins = (0..<7).map { summary("pin-\($0)", created: TimeInterval($0), pinned: true) }
        let active = (0..<6).map { summary("active-\($0)", created: TimeInterval($0), active: true) }
        let content = QuickWorkspaceContent(recentSessions: pins + active, organizeByProjects: false)
        #expect(Set(content.recentSessions.map(\.id)) == Set((pins + active).map(\.id)))
        #expect(content.sessionGroups.first?.sessions.count == active.count)
        #expect(content.sessionGroups.dropFirst().first?.sessions.count == pins.count)
    }

    private func summary(_ id: String, created: TimeInterval, updated: TimeInterval? = nil, project: String? = nil,
                         projectName: String? = nil, pinned: Bool = false, active: Bool = false) -> SessionSummary {
        SessionRecord(id: id, kind: .direct, agentIDs: ["juno"], title: id,
                      workspaceID: project, workspaceName: projectName ?? project,
                      isActive: active, isPinned: pinned,
                      createdAt: Date(timeIntervalSince1970: created),
                      updatedAt: Date(timeIntervalSince1970: updated ?? created),
                      hasAcceptedMessage: true).summary
    }
}
