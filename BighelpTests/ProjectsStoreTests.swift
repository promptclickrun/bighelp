import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ProjectsStoreTests {
    @Test func chatsAreNewestFirstAndListedOnce() async {
        let source = StubProjectsSource()
        let store = ProjectsStore(source: source, profileID: "default")
        await store.loadChats(projectID: "garden")
        #expect(store.chats["garden"]?.map(\.id) == ["new", "old"], "A chat in two lanes shows once")
        await store.refresh()
        #expect(store.details["garden"]?.chatCount == 2)
        #expect(store.errorMessage == nil)
        source.fails = true
        await store.loadChats(projectID: "garden")
        #expect(store.errorMessage != nil)
        #expect(store.chats["garden"]?.count == 2, "A failed reload keeps what's shown")
    }

    @Test func projectsSortByNameAndByRecentUseKeepsTheCurrentProjectFirst() {
        let projects = [
            project(id: "z", name: "Zebra"),
            project(id: "a", name: "apricot"),
            project(id: "m", name: "Mint"),
            project(id: "c", name: "Current", active: true),
        ]

        let byName = ProjectsSort.name.ordered(projects) { _ in nil }
        #expect(byName.map(\.id) == ["c", "a", "m", "z"])

        let byUse = ProjectsSort.recent.ordered(projects) { id in id == "z" ? .now : nil }
        #expect(byUse.map(\.id) == ["c", "z", "a", "m"], "Used last month beats never used; a tie breaks by name")
    }

    private func project(id: String, name: String, active: Bool = false) -> HermesWorkspaceSummary {
        HermesWorkspaceSummary(id: id, name: name, description: "", folderCount: 1, isActive: active)
    }
}

@MainActor
private final class StubProjectsSource: ProjectsSource {
    var fails = false

    func details(profileID: String) async throws -> [String: ProjectsStore.Details] {
        ["garden": .init(icon: "🌱", color: "#2FA37A", folders: ["/srv/garden"], chatCount: 2, lastActive: .now)]
    }

    func chats(projectID: String, profileID: String) async throws -> [ProjectsStore.Chat] {
        if fails { throw WorkspaceClientError.invalidResponse }
        let old = ProjectsStore.Chat(id: "old", profileID: profileID, title: "Old", preview: "",
                                     lastActive: Date(timeIntervalSince1970: 1_000))
        let new = ProjectsStore.Chat(id: "new", profileID: profileID, title: "New", preview: "",
                                     lastActive: Date(timeIntervalSince1970: 2_000))
        return [old, new, new]
    }
}
