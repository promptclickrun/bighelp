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
    /// row that swipes and took right-to-left drags first. On Today's root the rows own them.
    @Test func todaysRowsOwnSwipesFromTheTrailingEdge() {
        #expect(!WorkspaceEdgeSwipeResolver.trailingEdgeIsActive(tab: .today, pathIsEmpty: true))
        #expect(WorkspaceEdgeSwipeResolver.trailingEdgeIsActive(tab: .today, pathIsEmpty: false),
                "A chat pushed over Today keeps the edge")
        #expect(WorkspaceEdgeSwipeResolver.trailingEdgeIsActive(tab: .conversations, pathIsEmpty: true))
        #expect(WorkspaceEdgeSwipeResolver.trailingEdgeIsActive(tab: .work, pathIsEmpty: true))
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

    /// Each prompt says where the agent should put what it makes, so a Feed blueprint never
    /// ends up as a chat reply and a goal lands in its own category.
    @Test func everyBlueprintNamesWhereTheItemGoes() throws {
        let catalog = try BoardBlueprintCatalog.bundled()
        for blueprint in catalog.groups(for: .feed).flatMap(\.blueprints) {
            #expect(blueprint.text.contains("to my Feed"), "\(blueprint.id)")
        }
        for blueprint in catalog.groups(for: .idea).flatMap(\.blueprints) {
            #expect(blueprint.text.contains("to my Ideas"), "\(blueprint.id)")
        }
        for blueprint in catalog.groups(for: .goal).flatMap(\.blueprints) {
            let category = try #require(blueprint.goalCategory)
            let place = category == .other ? "to my Goals" : "to my Goals under \(category.groupTitle)"
            #expect(blueprint.text.contains(place), "\(blueprint.id)")
        }
    }

    /// Tapping a blueprint asks for each [blank] like an ad-lib before it's sent.
    @Test func blueprintBlanksBecomeFieldsAndFillTheSentence() {
        let adLib = BlueprintAdLib("Every Sunday, post five [videos / posts] about [my niche] to my Feed, under $[50] each, [20] of them.")
        #expect(adLib.blanks.map(\.hint) == ["videos / posts", "my niche", "50", "20"])
        #expect(adLib.blanks[0].isChoice && adLib.blanks[0].options == ["videos", "posts"])
        #expect(adLib.blanks[2].isNumber && adLib.blanks[3].isNumber && !adLib.blanks[1].isNumber)
        // Choices start on the first option and numbers on their example; text starts empty.
        #expect(adLib.initialValues == [0: "videos", 1: "", 2: "50", 3: "20"])
        #expect(!adLib.isComplete(adLib.initialValues), "Send waits for the typed blank")
        var values = adLib.initialValues
        values[1] = "  home baking \n"
        values[0] = "posts"
        #expect(adLib.isComplete(values))
        #expect(adLib.filled(values)
                == "Every Sunday, post five posts about home baking to my Feed, under $50 each, 20 of them.")
        values[1] = ""
        #expect(adLib.filled(values).contains("[my niche]"), "An empty blank keeps its brackets")
        let plain = BlueprintAdLib("Post a recap to my Feed.")
        #expect(plain.blanks.isEmpty && plain.isComplete([:]) && plain.filled([:]) == "Post a recap to my Feed.")
        #expect(BlueprintAdLib.value(String(repeating: "x", count: 500))?.count == 200, "Each answer is bounded")
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
        #expect(catalog.groups(for: .goal).map(\.id) == ["other"], "Empty groups don't show; an unknown topic is Other")
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
        #expect(try goal(nil).goalCategory == .health, "Older plugins send none; its words say")
        #expect(try goal(.string("")).goalCategory == .health)
        #expect(try goal(.string("Fitness")).goalCategory == .health, "A name off the list means one on it")
        #expect(try goal(.string("pets")).goalCategory == nil, "Unknown names are uncategorized")
        #expect(try goal(.string("other")).goalCategory == .other, "Filed under other stays there")
    }

    /// An agent that leaves the category out still has its goal shown where it belongs.
    @Test func goalsWithoutACategoryGoWhereTheirWordsPoint() {
        #expect(GoalCategory.inferred(from: "Health goal: sleep by 11") == .health)
        #expect(GoalCategory.inferred(from: "Pay off the credit card") == .finance)
        #expect(GoalCategory.inferred(from: "Get the promotion at work") == .career)
        #expect(GoalCategory.inferred(from: "Call mom every Sunday") == .relationships)
        #expect(GoalCategory.inferred(from: "Learn 20 songs on guitar") == .interests)
        #expect(GoalCategory.inferred(from: "Inbox under 20 every Friday") == .productivity)
        #expect(GoalCategory.inferred(from: "Something nice") == nil)
        #expect(GoalCategory.inferred(from: "Workout budget") == nil, "A tie is no category")
        let groups = GoalCategoryInfo.grouped([
            AgentBoardItem(id: "a", kind: .goal, title: "Health goal", body: "Walk 8,000 steps a day"),
            AgentBoardItem(id: "b", kind: .goal, title: "Something nice"),
        ], in: GoalCategoryInfo.builtIn)
        #expect(groups.map(\.category.id) == ["health", "other"])
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
        let groups = GoalCategoryInfo.grouped(goals, in: GoalCategoryInfo.builtIn)
        #expect(groups.map(\.category.id) == ["health", "finance", "other"])
        #expect(groups.map { $0.items.map(\.id) } == [["c", "e"], ["a"], ["b", "d", "f"]])
        #expect(GoalCategoryInfo.grouped([], in: GoalCategoryInfo.builtIn).isEmpty)
        // An older plugin: goals go where their words point, the rest under Other; nothing is lost.
        let legacy = GoalCategoryInfo.grouped([AgentBoardItem(id: "x", kind: .goal, title: "Sleep"),
                                               AgentBoardItem(id: "y", kind: .goal, title: "Old goal")],
                                              in: GoalCategoryInfo.builtIn)
        #expect(legacy.map(\.category.id) == ["health", "other"] && legacy.allSatisfy { $0.items.count == 1 })
    }

    // MARK: A computer's own categories

    private static let homeLab = GoalCategoryInfo(id: "home-lab", name: "Home lab", icon: "🖥️")

    @Test func aGoalShowsInItsComputersCategoryByItsNameAndEmoji() throws {
        let goal = try AgentBoardItem(json: .object([
            "id": .string("keys"), "kind": .string("goal"), "title": .string("Audit the SSH keys"),
            "category": .string("home-lab"), "categoryName": .string("Home lab"), "categoryIcon": .string("🖥️"),
        ]))
        #expect(goal.goalCategoryInfo == Self.homeLab)
        #expect(goal.goalCategoryInfo.pillTitle == "🖥️ Home lab" && goal.goalCategoryInfo.pillSystemImage == nil)
        #expect(goal.chatCard.detail == "Home lab")
        // A built-in category someone renamed keeps its symbol and takes the new name.
        let renamed = AgentBoardItem(id: "m", kind: .goal, title: "Save", category: "finance", categoryName: "Money")
        #expect(renamed.goalCategoryInfo.name == "Money" && renamed.goalCategoryInfo.systemImage == "dollarsign")
        #expect(renamed.goalCategoryInfo.prompt.contains("under Money"))
        #expect(GoalCategoryInfo(.finance).prompt == GoalCategory.finance.prompt)
        // A plugin from before the list sends only the built-in name.
        #expect(AgentBoardItem(id: "o", kind: .goal, title: "Save", category: "finance").goalCategoryInfo
            == GoalCategoryInfo(.finance))
    }

    @Test func goalsGroupInTheComputersOrderAndOnesOffTheListGoUnderOther() {
        let list = [GoalCategoryInfo(.health), Self.homeLab, .other]
        let goals = [
            AgentBoardItem(id: "a", kind: .goal, title: "Audit", category: "home-lab", categoryName: "Home lab"),
            AgentBoardItem(id: "b", kind: .goal, title: "Save", category: "finance", categoryName: "Finance"),
            AgentBoardItem(id: "c", kind: .goal, title: "Run", category: "health", categoryName: "Health"),
        ]
        let groups = GoalCategoryInfo.grouped(goals, in: list)
        #expect(groups.map(\.category.id) == ["health", "home-lab", "other"])
        #expect(groups.map { $0.items.map(\.id) } == [["c"], ["a"], ["b"]], "Finance left the list")
    }

    @Test func theComputersListIsReadLeniently() {
        let rows: [BighelpJSONValue] = [
            .object(["id": .string("health"), "name": .string("Health"), "icon": .string("")]),
            .object(["id": .string("home-lab"), "name": .string(" Home lab "), "icon": .string("🖥️"),
                     "later": .boolean(true)]),
            .object(["id": .string("home-lab"), "name": .string("Twice")]),
            .object(["name": .string("No ID")]),
            .string("nonsense"),
            .object(["id": .string("other"), "name": .string("Other")]),
        ]
        #expect(GoalCategoryInfo.list(json: .array(rows))?.map(\.id) == ["health", "home-lab", "other"])
        #expect(GoalCategoryInfo.list(json: .array(rows))?[1] == Self.homeLab)
        #expect(GoalCategoryInfo.list(json: nil) == nil, "A plugin from before the list")
        #expect(GoalCategoryInfo.list(json: .array([])) == nil)
    }

    @Test func theGoalsPageChangesTheComputersCategories() async throws {
        let client = DemoAgentBoardClient()
        let store = AgentBoardStore()
        store.configure(client: client)
        #expect(store.goalCategories == GoalCategoryInfo.builtIn && !store.canEditGoalCategories)
        await store.load(agentID: "nova")
        #expect(store.canEditGoalCategories)

        #expect(await store.changeGoalCategories(.add(name: "Home lab", icon: "🖥️")) == nil)
        #expect(store.goalCategories.map(\.id).suffix(2) == ["home-lab", "other"], "Other stays last")
        #expect(await store.changeGoalCategories(.add(name: "home LAB", icon: ""))
            == GoalCategoryChange.refusal("category_exists"))
        #expect(await store.changeGoalCategories(.update(id: "health", name: "Fitness", icon: "")) == nil)
        let health = try #require(store.goals.first { $0.category == "health" })
        #expect(health.goalCategoryInfo.name == "Fitness", "Its goals are read again under the new name")
        #expect(await store.changeGoalCategories(.delete(id: "health")) == nil)
        #expect(!store.goalCategories.contains { $0.id == "health" })
        #expect(store.goals.first { $0.id == health.id }?.goalCategoryInfo.isOther == true)
        #expect(await store.changeGoalCategories(.delete(id: "other")) == GoalCategoryChange.refusal("category_fixed"))
    }

    @Test func theComputerSendsItsCategoriesWithTheBoardAndTakesChanges() async throws {
        let owner = WorkspaceOwner(authority: try .fixture(id: "categories"), authenticationGeneration: UUID(),
                                   connectionGeneration: UUID())
        let performer = CategoryPerformer(owner: owner)
        let listed: BighelpJSONValue = .array([
            .object(["id": .string("home-lab"), "name": .string("Home lab"), "icon": .string("🖥️")]),
            .object(["id": .string("other"), "name": .string("Other"), "icon": .string("")]),
        ])
        let client = DirectHermesAgentBoardClient(workspace: performer, owner: owner, supportsFeedback: true,
                                                  supportsGoalCategories: true)
        // A plugin from before the list: nothing to edit.
        _ = try await client.items(agentID: "nova")
        #expect(client.goalCategories == nil)
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            _ = try await client.changeGoalCategories(agentID: "nova", .delete(id: "home-lab"))
        }
        performer.results[.boardList] = ["items": .array([]), "goalCategories": listed]
        performer.results[.boardCategories] = ["goalCategories": .array([
            .object(["id": .string("other"), "name": .string("Other"), "icon": .string("")]),
        ])]
        _ = try await client.items(agentID: "nova")
        #expect(client.goalCategories == [Self.homeLab, .other])
        let after = try await client.changeGoalCategories(agentID: "nova", .delete(id: "home-lab"))
        #expect(after == [.other])
        #expect(performer.calls.last?.operation == .boardCategories)
        #expect(performer.calls.last?.payload == ["agentId": .string("nova"), "action": .string("delete"),
                                                  "id": .string("home-lab")])
        #expect(DirectHermesNativePluginClient.supports(.boardCategories))
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

    var results: [WorkspaceOperation: [String: BighelpJSONValue]] = [:]
    private(set) var calls: [(operation: WorkspaceOperation, payload: [String: BighelpJSONValue])] = []

    init(owner: WorkspaceOwner) { self.owner = owner }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue], owner: WorkspaceOwner) async throws
        -> [String: BighelpJSONValue] {
        calls.append((operation, payload))
        return results[operation] ?? [:]
    }
}
