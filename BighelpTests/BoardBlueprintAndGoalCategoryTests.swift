import Foundation
import Testing
@testable import Bighelp

/// Swipe to dismiss on Feed, Ideas and Goals; the bundled Blueprints; goals by category.
@MainActor
struct BoardBlueprintAndGoalCategoryTests {
    // MARK: Swipe to dismiss

    /// Swipe left and the long-press menu say what hiding means for each kind, as the plugin
    /// records it: a Feed post is cleared, an idea is a "not now", a goal is removed.
    @Test func eachKindDismissesInItsOwnWords() {
        let feed = BoardDismissAction(kind: .feed)
        let idea = BoardDismissAction(kind: .idea)
        let goal = BoardDismissAction(kind: .goal)
        #expect([feed.title, idea.title, goal.title] == ["Clear", "Not now", "Remove"])
        #expect(Set([feed.systemImage, idea.systemImage, goal.systemImage]).count == 3)
        #expect(feed.undoMessage(for: "Fares dropped") == "Cleared “Fares dropped”")
        #expect(idea.undoMessage(for: "Plan dinner") == "Not now: “Plan dinner”")
        #expect(goal.undoMessage(for: "Sleep") == "Removed “Sleep”")
    }

    @Test func dismissingHidesEachKindWithUndo() async {
        let client = CategoryBoardClient(items: [
            AgentBoardItem(id: "f", kind: .feed, title: "Post"),
            AgentBoardItem(id: "i", kind: .idea, title: "Idea"),
            AgentBoardItem(id: "g", kind: .goal, title: "Goal", section: "goal", status: "active"),
        ])
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        for item in store.items {
            await store.dismiss(item)
            #expect(store.recentlyHidden?.id == item.id)
        }
        #expect(store.feed.isEmpty && store.ideas.isEmpty && store.goals.isEmpty)
        #expect(client.dismissed == ["f", "i", "g"])
        await store.undoHide()
        #expect(store.goals.map(\.id) == ["g"])
    }

    /// The root's right-edge strip (New chat by default) sat over the trailing edge of every
    /// board row and took right-to-left drags first. On Feed, Ideas and Goals the rows own them.
    @Test func boardRowsOwnSwipesFromTheTrailingEdge() {
        for tab in [AppTab.feed, .ideas, .goals] {
            #expect(!WorkspaceEdgeSwipeResolver.trailingEdgeIsActive(tab: tab, pathIsEmpty: true), "\(tab)")
            #expect(WorkspaceEdgeSwipeResolver.trailingEdgeIsActive(tab: tab, pathIsEmpty: false),
                    "A chat pushed over \(tab) keeps the edge")
        }
        #expect(WorkspaceEdgeSwipeResolver.trailingEdgeIsActive(tab: .apps, pathIsEmpty: true))
        #expect(WorkspaceEdgeSwipeResolver.trailingEdgeIsActive(tab: .sessions, pathIsEmpty: true))
    }

    // MARK: Blueprints

    /// The 45 starter prompts from bighelp.app/quick-start ship in the app.
    @Test func bundledBlueprintsMatchTheQuickStartPage() throws {
        let catalog = try BoardBlueprintCatalog.bundled()
        #expect(catalog.count == 45)
        let titles = ["Productivity", "Marketing", "Content creation", "Personal life", "Research"]
        for kind in [AgentBoardItem.Kind.feed, .idea, .goal] {
            let groups = catalog.groups(for: kind)
            #expect(groups.map(\.title) == titles, "\(kind)")
            #expect(groups.flatMap(\.blueprints).count == 15, "\(kind)")
            #expect(groups.allSatisfy { $0.blueprints.count == 3 })
        }
        let all = [AgentBoardItem.Kind.feed, .idea, .goal].flatMap { catalog.groups(for: $0).flatMap(\.blueprints) }
        #expect(Set(all.map(\.id)).count == 45, "Every blueprint has its own id")
        #expect(all.allSatisfy { !$0.text.isEmpty && !$0.text.contains("&") && !$0.text.contains("<") })
        #expect(catalog.groups(for: .goal).flatMap(\.blueprints).allSatisfy { $0.goalCategory != nil })
        #expect(catalog.groups(for: .feed).flatMap(\.blueprints).allSatisfy { $0.goalCategory == nil })
        #expect(catalog.groups(for: .feed)[0].blueprints[0].text.hasPrefix("Every weekday at 7am, post a morning brief"))
        #expect(catalog.blueprints(for: .health).map(\.text).contains { $0.contains("lose [20] lbs") })
        #expect(catalog.blueprints(for: .relationships).isEmpty)
    }

    @Test func blueprintsDecodeLeniently() throws {
        let json = """
        {"source": "x", "pages": [
          {"page": "feed", "groups": [{"id": "a", "title": "A", "prompts": [
            {"id": "one", "text": "Post the news."}, {"id": "blank", "text": "  "}, {"text": "No id"}]}]},
          {"page": "posters", "groups": [{"id": "b", "title": "B", "prompts": [{"id": "p", "text": "Hi"}]}]},
          {"page": "goals", "groups": [
            {"id": "c", "title": "C", "prompts": [{"id": "g", "text": "Run more.", "goalCategory": "pets"}]},
            {"id": "empty", "title": "Empty", "prompts": []}]},
          {"page": "ideas", "extra": true}
        ], "future": 1}
        """
        let catalog = try BoardBlueprintCatalog(data: Data(json.utf8))
        #expect(catalog.count == 2)
        #expect(catalog.groups(for: .feed).flatMap(\.blueprints).map(\.id) == ["one"])
        #expect(catalog.groups(for: .goal).map(\.id) == ["c"], "Empty groups don't show")
        #expect(catalog.groups(for: .goal)[0].blueprints[0].goalCategory == nil)
        #expect(catalog.groups(for: .idea).isEmpty)
        #expect(throws: (any Error).self) { try BoardBlueprintCatalog(data: Data("[]".utf8)) }
    }

    // MARK: Goal categories

    @Test func goalsDecodeTheirCategoryAndOlderOnesHaveNone() throws {
        func goal(_ category: BighelpJSONValue?) throws -> AgentBoardItem {
            var object: [String: BighelpJSONValue] = ["id": .string("g"), "kind": .string("goal"),
                                                      "title": .string("Run a 10K")]
            object["category"] = category
            return try AgentBoardItem(json: .object(object))
        }
        #expect(try goal(.string("health")).goalCategory == .health)
        #expect(try goal(.string(" Finance ")).goalCategory == .finance)
        #expect(try goal(nil).goalCategory == nil, "Older plugins send no category")
        #expect(try goal(.string("")).goalCategory == nil)
        #expect(try goal(.string("pets")).goalCategory == nil, "Unknown names are uncategorized")
        #expect(try goal(.integer(3)).goalCategory == nil)
    }

    @Test func goalsGroupByCategoryInTheListsOrderWithUncategorizedUnderOther() {
        let goals = [
            AgentBoardItem(id: "a", kind: .goal, title: "Save", category: "finance"),
            AgentBoardItem(id: "b", kind: .goal, title: "Old goal"),
            AgentBoardItem(id: "c", kind: .goal, title: "Run", category: "health"),
            AgentBoardItem(id: "d", kind: .goal, title: "Odd", category: "pets"),
            AgentBoardItem(id: "e", kind: .goal, title: "Walk", category: "health"),
            AgentBoardItem(id: "f", kind: .goal, title: "Else", category: "other"),
        ]
        let groups = GoalCategory.grouped(goals)
        #expect(groups.map(\.category) == [.health, .finance, .other])
        #expect(groups.map { $0.items.map(\.id) } == [["c", "e"], ["a"], ["b", "d", "f"]])
        #expect(GoalCategory.grouped([]).isEmpty)
        // An older plugin: everything is under Other, nothing is lost.
        let legacy = GoalCategory.grouped([AgentBoardItem(id: "x", kind: .goal, title: "Sleep")])
        #expect(legacy.map(\.category) == [.other] && legacy[0].items.count == 1)
    }

    @Test func everyCategoryStartsAChatThatNamesIt() {
        #expect(GoalCategory.allCases.map(\.title)
            == ["Health", "Relationships", "Finance", "Career", "Interests", "Productivity", "Something else"])
        #expect(GoalCategory.other.groupTitle == "Other" && GoalCategory.health.groupTitle == "Health")
        #expect(GoalCategory.allCases.map(\.systemImage)
            == ["heart", "person.2", "dollarsign", "building.2", "paintpalette", "laptopcomputer", "circle"])
        for category in GoalCategory.allCases {
            #expect(category.prompt.hasPrefix("I'd like to set a"), "\(category)")
            if category != .other { #expect(category.prompt.contains("under \(category.groupTitle)")) }
        }
    }

    @Test func theClientSaysWhetherThePluginKnowsCategories() throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "categories"), authenticationGeneration: UUID(),
                                   connectionGeneration: UUID())
        let performer = CategoryPerformer(owner: owner)
        #expect(!DirectHermesAgentBoardClient(workspace: performer, owner: owner, supportsFeedback: true)
            .supportsGoalCategories)
        let current = DirectHermesAgentBoardClient(workspace: performer, owner: owner, supportsFeedback: true,
                                                   supportsGoalCategories: true)
        let store = AgentBoardStore()
        store.configure(client: current)
        #expect(store.supportsGoalCategories)
        #expect(DemoAgentBoardClient().supportsGoalCategories)
    }
}

@MainActor
private final class CategoryBoardClient: AgentBoardClient {
    var items: [AgentBoardItem]
    let supportsFeedback = true
    private(set) var dismissed: [String] = []

    init(items: [AgentBoardItem]) { self.items = items }

    func items(agentID: String) async throws -> [AgentBoardItem] { items }

    func update(agentID: String, itemID: String, change: AgentBoardChange) async throws -> AgentBoardItem {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw WorkspaceClientError.invalidRequest }
        if let value = change.dismissed {
            items[index].dismissed = value
            if value { dismissed.append(itemID) }
        }
        return items[index]
    }

    func markRead(agentID: String, itemIDs: [String]) async throws {}
    func promote(agentID: String, itemID: String) async throws -> AgentBoardItem { throw WorkspaceClientError.invalidRequest }
    func picture(agentID: String, itemID: String, index: Int) async throws -> Data { Data() }
    func activity(agentID: String) async throws -> [AgentActivityEntry] { [] }
    func approvals(agentID: String) async throws -> [AgentApprovalEntry] { [] }
    func identity(agentID: String) async throws -> AgentIdentityDocuments {
        AgentIdentityDocuments(soul: .init(), memory: .init(), user: .init())
    }
}

@MainActor
private final class CategoryPerformer: WorkspaceOperationPerforming {
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner) }

    init(owner: WorkspaceOwner) { self.owner = owner }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue], owner: WorkspaceOwner) async throws
        -> [String: BighelpJSONValue] { [:] }
}
