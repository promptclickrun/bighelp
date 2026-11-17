import Foundation

/// One of a computer's goal categories (plugin `native-goal-categories-v1`). Each computer keeps its
/// own list for every bot on it: the built-in seven until someone changes it in Goals › Categories or
/// asks a bot to. Its `id` never changes, so a renamed category keeps its goals. Other is always
/// there and last; goals whose category left the list show under it.
struct GoalCategoryInfo: Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    /// One emoji, or empty: then the built-in category's symbol, else a tag.
    var icon: String

    static let maximumNameLength = 40
    static let maximumIconLength = 16
    static let maximumCount = 24
    /// What a computer has until its list changes, and what a plugin without the feature has.
    static let builtIn = GoalCategory.allCases.map { GoalCategoryInfo($0) }
    static let other = GoalCategoryInfo(.other)

    init(id: String, name: String, icon: String = "") {
        self.id = id
        self.name = name
        self.icon = icon
    }

    init(_ category: GoalCategory) {
        self.init(id: category.rawValue, name: category.groupTitle)
    }

    /// Lenient, bounded: a row without an ID or a name is skipped by `list(json:)`.
    init?(json value: BighelpJSONValue) {
        guard let object = value.object,
              let id = object["id"]?.string, !id.isEmpty, id.count <= 64,
              let name = object["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        self.init(id: id, name: String(name.prefix(Self.maximumNameLength)),
                  icon: String((object["icon"]?.string ?? "").prefix(Self.maximumIconLength)))
    }

    /// The computer's list as `board/list` and `board/categories` send it; nil when the plugin sends none.
    static func list(json value: BighelpJSONValue?) -> [GoalCategoryInfo]? {
        guard let rows = value?.array else { return nil }
        var seen: Set<String> = []
        let categories = rows.prefix(maximumCount).compactMap(GoalCategoryInfo.init(json:)).filter { seen.insert($0.id).inserted }
        return categories.isEmpty ? nil : categories
    }

    /// The built-in category with this ID, for its symbol, blueprints and wording.
    var builtInCategory: GoalCategory? { GoalCategory(rawValue: id) }
    var isOther: Bool { id == GoalCategory.other.rawValue }
    /// In the Create a goal list.
    var title: String { isOther ? GoalCategory.other.title : name }
    var systemImage: String { builtInCategory?.systemImage ?? "tag" }
    /// A pill's words: the emoji leads when there is one.
    var pillTitle: String { icon.isEmpty ? name : "\(icon) \(name)" }
    var pillSystemImage: String? { icon.isEmpty ? systemImage : nil }

    /// What Create a goal puts in the message box. It names the category so the bot files the goal there.
    var prompt: String {
        if let builtInCategory, name == builtInCategory.groupTitle { return builtInCategory.prompt }
        return "I'd like to set a goal. Ask me a few quick questions about what I'm after, then make a plan "
            + "and add it to my Goals under \(name)."
    }

    /// Goals by category in the computer's order, keeping their order within each. A goal whose
    /// category isn't on the list goes under Other.
    static func grouped(_ goals: [AgentBoardItem], in list: [GoalCategoryInfo])
        -> [(category: GoalCategoryInfo, items: [AgentBoardItem])] {
        let listed = Set(list.map(\.id))
        let byCategory = Dictionary(grouping: goals) { goal -> String in
            let id = goal.goalCategoryInfo.id
            return listed.contains(id) ? id : GoalCategory.other.rawValue
        }
        let order = list.contains(where: \.isOther) ? list : list + [.other]
        return order.compactMap { category in byCategory[category.id].map { (category, $0) } }
    }
}

/// One change to a computer's goal categories, from Goals › Categories.
enum GoalCategoryChange: Equatable, Sendable {
    case add(name: String, icon: String)
    case update(id: String, name: String, icon: String)
    case delete(id: String)

    var payload: [String: BighelpJSONValue] {
        switch self {
        case let .add(name, icon):
            ["action": .string("add"), "name": .string(name), "icon": .string(icon)]
        case let .update(id, name, icon):
            ["action": .string("update"), "id": .string(id), "name": .string(name), "icon": .string(icon)]
        case let .delete(id):
            ["action": .string("delete"), "id": .string(id)]
        }
    }

    /// Why the computer didn't take a change, by the plugin's code.
    static func refusal(_ code: String?) -> String {
        switch code {
        case "category_exists": String(localized: "There's already a category with that name.")
        case "too_many_categories":
            String(localized: "This computer has as many categories as it can keep. Delete one first.")
        case "invalid_category": String(localized: "Use a short name, and one emoji for the icon.")
        case "category_fixed": String(localized: "Other can't be renamed or deleted.")
        case "category_not_found": String(localized: "That category isn't on this computer any more.")
        default: String(localized: "The computer didn't save that. Try again.")
        }
    }
}

extension AgentBoardItem {
    /// Where a goal shows. The computer says (`categoryName`); a plugin from before that sends only a
    /// built-in name, and a goal without one goes where its words point.
    var goalCategoryInfo: GoalCategoryInfo {
        if !categoryName.isEmpty, !category.isEmpty {
            return GoalCategoryInfo(id: category, name: categoryName, icon: categoryIcon)
        }
        return GoalCategoryInfo(goalCategory ?? .other)
    }
}

extension BighelpBlockColor {
    /// A category keeps its color through a rename: it goes by the ID.
    static func goal(_ category: GoalCategoryInfo) -> BighelpBlockColor { pastel(for: category.id) }
}
