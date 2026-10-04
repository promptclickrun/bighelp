import Foundation
import Observation
import UIKit

// MARK: - What the agent is doing

/// What an agent is doing right now, from the tool it is running. Drives the
/// live avatar's reaction and the Activity list's icons. Mirrors the plugin's
/// `agent_board.tool_category` names.
enum AgentActivityKind: String, CaseIterable, Sendable {
    case idle, thinking, replying, coding, web, images, seeing, memory, scheduling
    case delegating, files, messaging, publishing, tools, waiting, done, failed

    /// Same rules as the Dynamic Island (`BighelpActivityPose`), one source.
    init(toolName: String) {
        self = AgentActivityKind(rawValue: BighelpActivityPose(tool: toolName).rawValue) ?? .tools
    }

    var pose: BighelpActivityPose { BighelpActivityPose(rawValue: rawValue) ?? .tools }

    /// The plugin's stored category names.
    init(category: String) {
        self = AgentActivityKind(rawValue: category) ?? .tools
    }

    var label: String {
        switch self {
        case .idle: "Here for you"
        case .thinking: "Thinking"
        case .replying: "Replying"
        case .coding: "Writing code"
        case .web: "Browsing the web"
        case .images: "Making images"
        case .seeing: "Taking a look"
        case .memory: "Remembering"
        case .scheduling: "Scheduling"
        case .delegating: "Working with helpers"
        case .files: "Working with files"
        case .messaging: "Sending a message"
        case .publishing: "Posting an update"
        case .tools: "Using tools"
        case .waiting: "Needs you"
        case .done: "All done"
        case .failed: "Hit a snag"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle"
        case .thinking: "sparkles"
        case .replying: "text.bubble"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .web: "globe"
        case .images: "paintbrush.pointed"
        case .seeing: "eye"
        case .memory: "brain"
        case .scheduling: "calendar.badge.clock"
        case .delegating: "person.2"
        case .files: "doc.text"
        case .messaging: "paperplane"
        case .publishing: "pin"
        case .tools: "wrench.and.screwdriver"
        case .waiting: "hand.raised"
        case .done: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// The character mood for this activity.
    var moodID: String? {
        switch self {
        case .idle: nil
        case .thinking: "thinking"
        case .replying: "bounce"
        case .coding: "scan"
        case .web: "lookAround"
        case .images: "excited"
        case .seeing: "curious"
        case .memory: "nod"
        case .scheduling: "alert"
        case .delegating: "dance"
        case .files: "peek"
        case .messaging: "bounce"
        case .publishing: "happy"
        case .tools: "squint"
        case .waiting: "alert"
        case .done: "happy"
        case .failed: "sad"
        }
    }

    var isWorking: Bool { ![.idle, .done, .failed].contains(self) }
}

// MARK: - Board items

struct AgentBoardItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case feed, idea, goal }
    enum Picture: Equatable, Sendable {
        case remote(URL)
        case stored(index: Int)
    }
    struct Link: Equatable, Sendable {
        let url: URL
        let title: String
    }
    /// A file the agent attached to a Feed post (plugin `native-agent-board-files-v1`). The host
    /// keeps the path; the app knows the file by its place in the post.
    struct File: Identifiable, Equatable, Sendable {
        static let maximumCount = 10

        let index: Int
        let fileName: String
        let mimeType: String
        let byteCount: Int
        /// When the agent attached it; attaching the same path again is a new version.
        var addedAt: Date?

        var id: Int { index }
        var isImage: Bool { mimeType.hasPrefix("image/") }

        var systemImage: String {
            let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
            if isImage { return "photo" }
            if mimeType.hasPrefix("video/") { return "film" }
            if mimeType.hasPrefix("audio/") { return "waveform" }
            if mimeType == "application/pdf" { return "doc.richtext" }
            if ["xls", "xlsx", "csv", "tsv", "numbers", "ods"].contains(ext) { return "tablecells" }
            if ["zip", "gz", "tar"].contains(ext) { return "doc.zipper" }
            return "doc.text"
        }

        var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }

        init(index: Int, fileName: String, mimeType: String, byteCount: Int, addedAt: Date? = nil) {
            self.index = index; self.fileName = fileName; self.mimeType = mimeType
            self.byteCount = byteCount; self.addedAt = addedAt
        }

        /// Lenient: hosts differ, so a file this build can't show safely is left out, not the post.
        init?(json value: BighelpJSONValue) {
            guard let object = value.object, let index = object["index"]?.integer, (0..<Self.maximumCount).contains(index),
                  let name = object["fileName"]?.string, (1...180).contains(name.count),
                  name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                  name == URL(fileURLWithPath: name).lastPathComponent, !name.hasPrefix("."),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let mime = object["mimeType"]?.string?.lowercased(), (3...120).contains(mime.count),
                  mime.contains("/"), mime.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0)) }),
                  let size = object["byteCount"]?.integer, (1...ChatAttachment.maximumAgentBytes).contains(size)
            else { return nil }
            let added = object["addedAt"]?.integer.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
            self.init(index: index, fileName: name, mimeType: mime, byteCount: size, addedAt: added)
        }
    }

    let id: String
    let kind: Kind
    var title: String
    var body: String
    var icon: String
    var section: String
    var status: String
    var note: String
    var links: [Link]
    var pictures: [Picture]
    var files: [File]
    var source: String
    /// Thumbs up or down. It tells the agent what's worth posting.
    var rating: Rating
    /// Why a thumbs down ("Not relevant"); empty otherwise.
    var reason: String
    var read: Bool
    var dismissed: Bool
    /// A goal's category as the plugin stored it; empty for none (plugins before 3.5).
    var category: String
    var createdAt: Date
    var updatedAt: Date

    enum Rating: String, Sendable { case up, down, none }

    /// Nil for goals without one, or with a name this build doesn't know: they show under Other.
    /// A goal's category. One saved without one (older plugins, or an agent that left it out)
    /// goes where its words point, so a "Health goal" shows under Health, not Other.
    var goalCategory: GoalCategory? {
        GoalCategory(stored: category) ?? (category.isEmpty ? GoalCategory.inferred(from: title, body, note) : nil)
    }

    var liked: Bool { rating == .up }
    var isDone: Bool { status == "done" }
    var isTracking: Bool { section == "tracking" }
    /// Title and text, for Copy and Share.
    var shareText: String { body.isEmpty ? title : "\(title)\n\n\(body)" }

    init(id: String, kind: Kind, title: String, body: String = "", icon: String = "", section: String = "",
         status: String = "", note: String = "", links: [Link] = [], pictures: [Picture] = [],
         files: [File] = [], source: String = "", rating: Rating = .none, reason: String = "", read: Bool = true,
         dismissed: Bool = false, category: String = "", createdAt: Date = .now, updatedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.icon = icon
        self.section = section; self.status = status; self.note = note; self.links = links
        self.pictures = pictures; self.files = files; self.source = source; self.rating = rating; self.reason = reason
        self.read = read; self.dismissed = dismissed; self.category = category
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    init(json value: BighelpJSONValue) throws {
        guard let object = value.object, let id = object["id"]?.string, !id.isEmpty,
              let kind = object["kind"]?.string.flatMap(Kind.init(rawValue:)),
              let title = object["title"]?.string else { throw WorkspaceClientError.invalidResponse }
        let links: [Link] = (object["links"]?.array ?? []).compactMap { link in
            guard let url = link.object?["url"]?.string.flatMap(URL.init(string:)),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return Link(url: url, title: link.object?["title"]?.string ?? "")
        }
        let pictures: [Picture] = (object["images"]?.array ?? []).compactMap { image in
            if let url = image.object?["url"]?.string.flatMap(URL.init(string:)), url.scheme?.lowercased() == "https" {
                return .remote(url)
            }
            if let index = image.object?["index"]?.integer, (0..<6).contains(index) { return .stored(index: index) }
            return nil
        }
        var files: [File] = []
        for file in (object["files"]?.array ?? []).compactMap(File.init(json:))
        where files.count < File.maximumCount && !files.contains(where: { $0.index == file.index }) {
            files.append(file)
        }
        func date(_ key: String) -> Date {
            Date(timeIntervalSince1970: TimeInterval(object[key]?.integer ?? 0))
        }
        self.init(id: id, kind: kind, title: title, body: object["body"]?.string ?? "",
                  icon: object["icon"]?.string ?? "", section: object["section"]?.string ?? "",
                  status: object["status"]?.string ?? "", note: object["note"]?.string ?? "",
                  links: links, pictures: pictures, files: files, source: object["source"]?.string ?? "",
                  // Plugins before 2.19.0 only know a heart, and have no read state.
                  rating: object["rating"]?.string.flatMap(Rating.init(rawValue:))
                      ?? (object["liked"]?.boolean == true ? .up : .none),
                  reason: object["reason"]?.string ?? "", read: object["read"]?.boolean ?? true,
                  dismissed: object["dismissed"]?.boolean ?? false,
                  category: object["category"]?.string ?? "",
                  createdAt: date("createdAt"), updatedAt: date("updatedAt"))
    }
}

/// What a goal is about. The plugin keeps the same fixed list
/// (`native-agent-board-goal-categories-v1`); "Something else" is stored as `other`.
enum GoalCategory: String, CaseIterable, Identifiable, Sendable {
    case health, relationships, finance, career, interests, productivity, other

    var id: String { rawValue }

    /// Lenient: hosts differ, so an empty name is no category, and one off the list ("Fitness")
    /// is the category it means.
    init?(stored: String) {
        let name = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let category = GoalCategory(rawValue: name) ?? (name.isEmpty ? nil : Self.inferred(from: name))
        else { return nil }
        self = category
    }

    /// Words people and agents use for each category; the plugin files new goals with the same
    /// list (`_CATEGORY_WORDS`). Whole words; the most matches wins, and a tie is no category.
    static func inferred(from texts: String...) -> GoalCategory? {
        let text = texts.joined(separator: " ").lowercased()
        let words = Set(text.split { !($0.isLetter || $0.isNumber || $0 == "-") }.map(String.init))
        let scores = allCases.map { category in
            (category, category.words.filter { $0.contains(" ") ? text.contains($0) : words.contains($0) }.count)
        }
        guard let best = scores.map(\.1).max(), best > 0 else { return nil }
        let leaders = scores.filter { $0.1 == best }
        return leaders.count == 1 ? leaders[0].0 : nil
    }

    private var words: [String] {
        switch self {
        case .health:
            ["health", "healthy", "fitness", "fit", "exercise", "workout", "workouts", "running", "run",
             "marathon", "5k", "10k", "weight", "diet", "nutrition", "sleep", "wellness", "wellbeing",
             "meditation", "meditate", "mental", "steps", "gym", "yoga", "medical", "doctor", "sober",
             "drinking", "smoking", "calories", "protein", "walk", "walking", "swim", "cycling"]
        case .relationships:
            ["relationship", "relationships", "family", "friend", "friends", "friendship", "partner", "dating",
             "date", "marriage", "wife", "husband", "kids", "children", "parents", "mom", "dad", "social",
             "community"]
        case .finance:
            ["finance", "finances", "financial", "money", "budget", "budgeting", "save", "saving", "savings",
             "debt", "invest", "investing", "investment", "retirement", "spending", "income", "mortgage", "loan",
             "credit", "taxes", "emergency fund"]
        case .career:
            ["career", "job", "work", "promotion", "raise", "interview", "resume", "business", "salary",
             "startup", "client", "clients", "certification", "networking", "portfolio"]
        case .interests:
            ["interest", "interests", "hobby", "hobbies", "learn", "learning", "read", "reading", "books",
             "music", "guitar", "piano", "art", "draw", "drawing", "paint", "painting", "language", "spanish",
             "french", "japanese", "travel", "trip", "cooking", "cook", "garden", "gardening", "photography",
             "writing", "novel", "game", "games", "craft"]
        case .productivity:
            ["productivity", "productive", "habit", "habits", "routine", "routines", "focus", "organize",
             "organized", "organizing", "declutter", "inbox", "time", "schedule", "procrastination", "planning",
             "todo", "to-do", "chores"]
        case .other: []
        }
    }

    /// In the Create a goal list.
    var title: String { self == .other ? "Something else" : groupTitle }

    /// Over the goals in it.
    var groupTitle: String {
        switch self {
        case .health: "Health"
        case .relationships: "Relationships"
        case .finance: "Finance"
        case .career: "Career"
        case .interests: "Interests"
        case .productivity: "Productivity"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .health: "heart"
        case .relationships: "person.2"
        case .finance: "dollarsign"
        case .career: "building.2"
        case .interests: "paintpalette"
        case .productivity: "laptopcomputer"
        case .other: "circle"
        }
    }

    /// What Create a goal puts in the message box. It names the category so the agent files the goal there.
    var prompt: String {
        let ask = "Ask me a few quick questions about what I'm after, then make a plan"
        let goal = switch self {
        case .health: "a health goal"
        case .relationships: "a relationship goal"
        case .finance: "a money goal"
        case .career: "a career goal"
        case .interests: "a goal for one of my interests"
        case .productivity: "a productivity goal"
        case .other: "a goal"
        }
        let place = self == .other ? "my Goals" : "my Goals under \(groupTitle)"
        return "I'd like to set \(goal). \(ask) and add it to \(place)."
    }

    /// Goals by category in the list's order, keeping their order within each. Goals without a
    /// category (or with one this build doesn't know) go under Other.
    static func grouped(_ goals: [AgentBoardItem]) -> [(category: GoalCategory, items: [AgentBoardItem])] {
        let byCategory = Dictionary(grouping: goals) { $0.goalCategory ?? .other }
        return allCases.compactMap { category in
            byCategory[category].map { (category, $0) }
        }
    }
}

/// Swipe left on a Feed, Ideas or Goals item, and the last action in its long-press menu.
/// Each hides the item with Undo; the words follow what the plugin records for each kind.
struct BoardDismissAction: Equatable {
    let kind: AgentBoardItem.Kind

    init(kind: AgentBoardItem.Kind) { self.kind = kind }

    var title: String {
        switch kind {
        // Clearing a read post isn't a thumbs down.
        case .feed: "Clear"
        // The plugin remembers a "not now" so the agent doesn't offer it again for a while.
        case .idea: "Not now"
        case .goal: "Remove"
        }
    }

    var systemImage: String {
        switch kind {
        case .feed: "xmark"
        case .idea: "clock.arrow.circlepath"
        case .goal: "minus.circle"
        }
    }

    var isDestructive: Bool { kind == .goal }

    func undoMessage(for title: String) -> String {
        switch kind {
        case .feed: "Cleared “\(title)”"
        case .idea: "Not now: “\(title)”"
        case .goal: "Removed “\(title)”"
        }
    }
}

struct AgentActivityEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let sessionID: String
    let title: String
    let request: String
    let summary: String
    let kind: AgentActivityKind
    let outcome: String
    let createdAt: Date

    /// Hermes' session title reads best; the request is the fallback.
    var headline: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (request.isEmpty ? kind.label : request) : trimmed
    }

    init(id: Int, sessionID: String, title: String, request: String, summary: String,
         kind: AgentActivityKind, outcome: String, createdAt: Date) {
        self.id = id; self.sessionID = sessionID; self.title = title; self.request = request
        self.summary = summary; self.kind = kind; self.outcome = outcome; self.createdAt = createdAt
    }

    init(json value: BighelpJSONValue) throws {
        guard let object = value.object, let id = object["id"]?.integer else { throw WorkspaceClientError.invalidResponse }
        self.init(id: id, sessionID: object["sessionId"]?.string ?? "", title: object["title"]?.string ?? "",
                  request: object["request"]?.string ?? "", summary: object["summary"]?.string ?? "",
                  kind: AgentActivityKind(category: object["category"]?.string ?? ""),
                  outcome: object["outcome"]?.string ?? "done",
                  createdAt: Date(timeIntervalSince1970: TimeInterval(object["createdAt"]?.integer ?? 0)))
    }
}

struct AgentApprovalEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let sessionTitle: String
    let description: String
    let command: String
    let choice: String
    let createdAt: Date

    var decisionLabel: String {
        switch choice {
        case "always": "Always allowed"
        case "session": "Allowed for this chat"
        case "once": "Allowed once"
        case "deny": "Denied"
        case "timeout", "transport_timeout": "Timed out"
        default: choice.hasPrefix("transport_") ? "Not answered" : "Answered"
        }
    }

    var wasAllowed: Bool { ["always", "session", "once"].contains(choice) }

    init(id: Int, sessionTitle: String, description: String, command: String, choice: String, createdAt: Date) {
        self.id = id; self.sessionTitle = sessionTitle; self.description = description
        self.command = command; self.choice = choice; self.createdAt = createdAt
    }

    init(json value: BighelpJSONValue) throws {
        guard let object = value.object, let id = object["id"]?.integer else { throw WorkspaceClientError.invalidResponse }
        self.init(id: id, sessionTitle: object["sessionTitle"]?.string ?? "",
                  description: object["description"]?.string ?? "", command: object["command"]?.string ?? "",
                  choice: object["choice"]?.string ?? "",
                  createdAt: Date(timeIntervalSince1970: TimeInterval(object["createdAt"]?.integer ?? 0)))
    }
}

/// SOUL and memory text for the Identity tab's cards.
struct AgentIdentityDocuments: Equatable, Sendable {
    struct Document: Equatable, Sendable {
        var text: String
        var updatedAt: Date?
        var truncated: Bool

        init(text: String = "", updatedAt: Date? = nil, truncated: Bool = false) {
            self.text = text; self.updatedAt = updatedAt; self.truncated = truncated
        }

        init(json value: BighelpJSONValue?) {
            let object = value?.object ?? [:]
            let seconds = object["updatedAt"]?.integer ?? 0
            self.init(text: object["text"]?.string ?? "",
                      updatedAt: seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil,
                      truncated: object["truncated"]?.boolean ?? false)
        }
    }

    var soul: Document
    var memory: Document
    var user: Document
}

extension AgentBoardItem {
    /// What Let's do it puts in the chat: the idea's title only. The host learns which idea from
    /// `AgentBoardStore.accept`, so its ID never shows in the message box, the sent message or
    /// the chat's history. Older plugins match this exact text to record the yes.
    var letsDoItMessage: String { "Yes, go ahead with this idea: “\(title)”." }
}

// MARK: - Clients

/// What the person did to one item. Nil fields stay as they are.
struct AgentBoardChange: Equatable, Sendable {
    var rating: AgentBoardItem.Rating?
    var reason: String?
    var read: Bool?
    var dismissed: Bool?
    var status: String?
}

@MainActor
protocol AgentBoardClient: AnyObject {
    /// Thumbs down, reasons, read state and idea → goal (plugin 2.19.0).
    var supportsFeedback: Bool { get }
    /// Goals carry a category (`native-agent-board-goal-categories-v1`).
    var supportsGoalCategories: Bool { get }
    func items(agentID: String) async throws -> [AgentBoardItem]
    func update(agentID: String, itemID: String, change: AgentBoardChange) async throws -> AgentBoardItem
    func markRead(agentID: String, itemIDs: [String]) async throws
    func promote(agentID: String, itemID: String) async throws -> AgentBoardItem
    /// Let's do it records exactly this idea (`native-agent-board-answers-v1`).
    var supportsAnswers: Bool { get }
    func accept(agentID: String, itemID: String) async throws
    func picture(agentID: String, itemID: String, index: Int) async throws -> Data
    func activity(agentID: String) async throws -> [AgentActivityEntry]
    func approvals(agentID: String) async throws -> [AgentApprovalEntry]
    func identity(agentID: String) async throws -> AgentIdentityDocuments
    /// Feed posts carry files (`native-agent-board-files-v1`).
    var supportsFiles: Bool { get }
    /// One of a post's files, through the attachment routes and this phone's attachment cache.
    func file(agentID: String, itemID: String, file: AgentBoardItem.File) async throws -> ChatAttachment
}

extension AgentBoardClient {
    var supportsGoalCategories: Bool { false }
    var supportsFiles: Bool { false }
    var supportsAnswers: Bool { false }

    func accept(agentID: String, itemID: String) async throws {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }

    func file(agentID: String, itemID: String, file: AgentBoardItem.File) async throws -> ChatAttachment {
        throw WorkspaceClientError.unavailable(.unsupportedOperation)
    }
}

/// The bighelp plugin's `native-agent-board-v1` routes.
@MainActor
final class DirectHermesAgentBoardClient: AgentBoardClient {
    private let workspace: any WorkspaceOperationPerforming
    private let owner: WorkspaceOwner
    let supportsFeedback: Bool
    let supportsGoalCategories: Bool
    let supportsAnswers: Bool
    /// Chat's attachment client: the same chunked download, checks and cache. Only
    /// given when the plugin serves posts' files.
    private let files: DirectHermesGeneratedMediaClient?

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner, supportsFeedback: Bool,
         supportsGoalCategories: Bool = false, supportsAnswers: Bool = false,
         files: DirectHermesGeneratedMediaClient? = nil) {
        self.workspace = workspace
        self.owner = owner
        self.supportsFeedback = supportsFeedback
        self.supportsGoalCategories = supportsGoalCategories
        self.supportsAnswers = supportsAnswers
        self.files = files
    }

    var supportsFiles: Bool { files != nil }

    func file(agentID: String, itemID: String, file: AgentBoardItem.File) async throws -> ChatAttachment {
        guard let files else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
        guard workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
        return try await files.boardFile(agentID: agentID, itemID: itemID, file: file)
    }

    private func perform(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue]) async throws
        -> [String: BighelpJSONValue] {
        guard workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
        return try await workspace.perform(operation, payload: payload, owner: owner)
    }

    func items(agentID: String) async throws -> [AgentBoardItem] {
        let result = try await perform(.boardList, ["agentId": .string(agentID), "limit": .integer(200)])
        return try (result["items"]?.array ?? []).map(AgentBoardItem.init(json:))
    }

    func update(agentID: String, itemID: String, change: AgentBoardChange) async throws -> AgentBoardItem {
        var payload: [String: BighelpJSONValue] = ["agentId": .string(agentID), "itemId": .string(itemID)]
        if let rating = change.rating {
            if supportsFeedback {
                payload["rating"] = .string(rating.rawValue)
            } else {
                // An older plugin only has the heart.
                guard rating != .down else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
                payload["liked"] = .boolean(rating == .up)
            }
        }
        if supportsFeedback, let reason = change.reason { payload["reason"] = .string(String(reason.prefix(120))) }
        if supportsFeedback, let read = change.read { payload["read"] = .boolean(read) }
        if let dismissed = change.dismissed { payload["dismissed"] = .boolean(dismissed) }
        if let status = change.status { payload["status"] = .string(status) }
        let result = try await perform(.boardUpdate, payload)
        guard let item = result["item"] else { throw WorkspaceClientError.invalidResponse }
        return try AgentBoardItem(json: item)
    }

    func markRead(agentID: String, itemIDs: [String]) async throws {
        guard supportsFeedback, !itemIDs.isEmpty else { return }
        for batch in stride(from: 0, to: itemIDs.count, by: 200).map({ Array(itemIDs[$0..<min($0 + 200, itemIDs.count)]) }) {
            _ = try await perform(.boardRead, ["agentId": .string(agentID),
                                               "itemIds": .array(batch.map(BighelpJSONValue.string)),
                                               "read": .boolean(true)])
        }
    }

    func promote(agentID: String, itemID: String) async throws -> AgentBoardItem {
        guard supportsFeedback else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
        let result = try await perform(.boardPromote, ["agentId": .string(agentID), "itemId": .string(itemID)])
        guard let item = result["item"] else { throw WorkspaceClientError.invalidResponse }
        return try AgentBoardItem(json: item)
    }

    func accept(agentID: String, itemID: String) async throws {
        guard supportsAnswers else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
        _ = try await perform(.boardAccept, ["agentId": .string(agentID), "itemId": .string(itemID)])
    }

    func picture(agentID: String, itemID: String, index: Int) async throws -> Data {
        let result = try await perform(.boardMedia, ["agentId": .string(agentID), "itemId": .string(itemID),
                                                     "index": .integer(index)])
        guard let encoded = result["data"]?.string, let data = Data(base64Encoded: encoded) else {
            throw WorkspaceClientError.invalidResponse
        }
        return data
    }

    func activity(agentID: String) async throws -> [AgentActivityEntry] {
        let result = try await perform(.boardActivity, ["agentId": .string(agentID), "limit": .integer(100)])
        return try (result["activity"]?.array ?? []).map(AgentActivityEntry.init(json:))
    }

    func approvals(agentID: String) async throws -> [AgentApprovalEntry] {
        let result = try await perform(.boardApprovals, ["agentId": .string(agentID), "limit": .integer(100)])
        return try (result["approvals"]?.array ?? []).map(AgentApprovalEntry.init(json:))
    }

    func identity(agentID: String) async throws -> AgentIdentityDocuments {
        let result = try await perform(.boardIdentity, ["agentId": .string(agentID)])
        return AgentIdentityDocuments(soul: .init(json: result["soul"]), memory: .init(json: result["memory"]),
                                      user: .init(json: result["user"]))
    }
}

// MARK: - Store

/// What Feed, Ideas and Goals do with the connection as it stands.
enum AgentBoardConnectionStep: Equatable {
    /// Reconnecting, or the plugin's features aren't known for this connection yet.
    case wait
    case connect
    /// The host answered without the board: its plugin needs an update.
    case pluginMissing
    /// No computer to reconnect to.
    case disconnected

    static func decide(isConnected: Bool, board: WorkspaceAvailability, reconnects: Bool) -> Self {
        guard isConnected else { return reconnects ? .wait : .disconnected }
        switch board {
        case .available: return .connect
        // Right after a reconnect the features still belong to the old connection.
        case .unknown, .unavailable(.notConnected): return .wait
        case .unavailable: return .pluginMissing
        }
    }
}

@MainActor
@Observable
final class AgentBoardStore {
    enum LoadState: Equatable { case idle, loading, loaded, unavailable, failed(String) }

    private(set) var agentID: String?
    private(set) var items: [AgentBoardItem] = []
    private(set) var activity: [AgentActivityEntry] = []
    private(set) var approvals: [AgentApprovalEntry] = []
    private(set) var identity: AgentIdentityDocuments?
    private(set) var state: LoadState = .idle
    private(set) var logState: LoadState = .idle
    /// Why there is no board: no host yet, or the host's plugin predates it.
    private(set) var isDisconnected = false
    private var client: (any AgentBoardClient)?
    private var pictures: [String: Data] = [:]
    private var generation = 0
    /// The computer the board is for (its cache scope); a new connection to the
    /// same one keeps what's shown.
    private var scope: String?
    /// Reconnecting, or the plugin's features aren't known yet: neither "update
    /// the plugin" nor an empty board, just a short wait.
    private var isWaiting = false
    /// The agent a page asked for while waiting, loaded once connected.
    private var pendingAgentID: String?

    /// A post's file on this phone: not here yet, here, or the host no longer serves it.
    enum FileState: Equatable { case loading, ready, unavailable }
    private(set) var fileStates: [String: FileState] = [:]
    /// Small copies of posts' pictures for the Feed and the post; the full files stay in
    /// the attachment cache on disk.
    private(set) var fileThumbnails: [String: UIImage] = [:]
    /// The file being fetched to open, for its spinner.
    private(set) var openingFile: String?
    @ObservationIgnored private var pendingThumbnails: Set<String> = []

    var isAvailable: Bool { client != nil }
    var supportsFeedback: Bool { client?.supportsFeedback ?? false }
    /// Without it (older plugins) posts have no files and Feed works as before.
    var supportsFiles: Bool { client?.supportsFiles ?? false }
    /// Without it goals have no category and the page says to update the plugin.
    var supportsGoalCategories: Bool { client?.supportsGoalCategories ?? false }
    /// Just deleted, for Undo.
    private(set) var recentlyHidden: AgentBoardItem?
    var feed: [AgentBoardItem] { items.filter { $0.kind == .feed && !$0.dismissed } }
    var ideas: [AgentBoardItem] { items.filter { $0.kind == .idea && !$0.dismissed } }
    var goals: [AgentBoardItem] { items.filter { $0.kind == .goal && !$0.dismissed } }

    /// A new client (host, account or plugin change) drops everything shown so far.
    func configure(client: (any AgentBoardClient)?, isDisconnected: Bool = false) {
        self.isDisconnected = client == nil && isDisconnected
        guard client !== self.client || isWaiting else { return }
        isWaiting = false; pendingAgentID = nil; scope = nil
        self.client = client
        generation &+= 1
        items = []; activity = []; approvals = []; pictures = [:]; identity = nil; recentlyHidden = nil
        fileStates = [:]; fileThumbnails = [:]; pendingThumbnails = []; openingFile = nil
        state = client == nil ? .unavailable : .idle
        logState = state
        agentID = nil
    }

    /// The app came back or the features are still being learned: drop the old
    /// connection but keep what's on screen until `connect` brings a new one.
    func waitForConnection() {
        client = nil
        generation &+= 1
        isWaiting = true
        isDisconnected = false
        if state != .loaded { state = .loading }
    }

    /// A ready connection. The same computer again (coming back to the app) keeps
    /// what's shown and reloads it; another computer starts fresh.
    func connect(client: any AgentBoardClient, scope: String) async {
        guard client !== self.client else { return }
        let sameComputer = scope == self.scope
        let pending = pendingAgentID
        if sameComputer {
            self.client = client
            generation &+= 1
            isWaiting = false; isDisconnected = false; pendingAgentID = nil
            if state == .loading, agentID == nil { state = .idle }
        } else {
            configure(client: client)
            self.scope = scope
        }
        if let reload = pending ?? (sameComputer ? agentID : nil) { await load(agentID: reload) }
    }

    func load(agentID: String) async {
        guard let client else {
            if isWaiting {
                pendingAgentID = agentID
                if self.agentID != agentID { state = .loading }
            } else {
                state = .unavailable
            }
            return
        }
        let generation = generation
        // Reloading what's already shown keeps it on screen, without a spinner.
        let isRefresh = state == .loaded && self.agentID == agentID
        if self.agentID != agentID {
            self.agentID = agentID
            items = []; activity = []; approvals = []; identity = nil
        }
        if !isRefresh { state = .loading }
        do {
            let loaded = try await client.items(agentID: agentID)
            guard generation == self.generation, self.agentID == agentID else { return }
            items = loaded
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard generation == self.generation, self.agentID == agentID else { return }
            state = .failed((error as? WorkspaceClientError)?.localizedDescription ?? "Couldn't load this right now.")
        }
    }

    func loadLogs(agentID: String) async {
        guard let client else { logState = .unavailable; return }
        let generation = generation
        logState = .loading
        do {
            let nextActivity = try await client.activity(agentID: agentID)
            let nextApprovals = try await client.approvals(agentID: agentID)
            let nextIdentity = try? await client.identity(agentID: agentID)
            guard generation == self.generation else { return }
            activity = nextActivity
            approvals = nextApprovals
            identity = nextIdentity
            logState = .loaded
        } catch is CancellationError {
        } catch {
            guard generation == self.generation else { return }
            logState = .failed("Couldn't load this agent's history.")
        }
    }

    /// Thumbs up, down, or neither; a thumbs down may say why.
    func rate(_ item: AgentBoardItem, _ rating: AgentBoardItem.Rating, reason: String? = nil) async {
        let reason = rating == .down ? (reason ?? "") : ""
        await mutate(item) { $0.rating = rating; $0.reason = reason } send: { client, agent in
            try await client.update(agentID: agent, itemID: item.id,
                                    change: .init(rating: rating, reason: rating == .down ? reason : nil))
        }
    }

    func setRead(_ item: AgentBoardItem, _ read: Bool) async {
        guard supportsFeedback else { return }
        await mutate(item) { $0.read = read } send: { client, agent in
            try await client.update(agentID: agent, itemID: item.id, change: .init(read: read))
        }
    }

    /// Items on screen count as read. Quietly retried on the next load if it fails.
    func markSeen(_ seen: [AgentBoardItem]) async {
        guard supportsFeedback, let client, let agentID else { return }
        let ids = Set(seen.filter { !$0.read }.map(\.id))
        guard !ids.isEmpty else { return }
        for index in items.indices where ids.contains(items[index].id) { items[index].read = true }
        try? await client.markRead(agentID: agentID, itemIDs: Array(ids).sorted())
    }

    func unreadCount(_ kind: AgentBoardItem.Kind) -> Int {
        guard supportsFeedback else { return 0 }
        return items.filter { $0.kind == kind && !$0.dismissed && !$0.read }.count
    }

    /// Delete hides the item (the agent stops seeing it too) and can be undone.
    func hide(_ item: AgentBoardItem) async {
        recentlyHidden = item
        await mutate(item) { $0.dismissed = true } send: { client, agent in
            try await client.update(agentID: agent, itemID: item.id, change: .init(dismissed: true))
        }
    }

    /// Swipe left, or the long-press menu's Clear, Not now or Remove (`BoardDismissAction`).
    func dismiss(_ item: AgentBoardItem) async {
        await hide(item)
    }

    func undoHide() async {
        guard let item = recentlyHidden else { return }
        recentlyHidden = nil
        await mutate(item) { $0.dismissed = false } send: { client, agent in
            try await client.update(agentID: agent, itemID: item.id, change: .init(dismissed: false))
        }
    }

    func clearUndo(_ item: AgentBoardItem) {
        if recentlyHidden?.id == item.id { recentlyHidden = nil }
    }

    /// An idea the person wants to pursue moves to Goals.
    @discardableResult
    func promote(_ idea: AgentBoardItem) async -> Bool {
        guard supportsFeedback, let client, let agentID,
              let index = items.firstIndex(where: { $0.id == idea.id }) else { return false }
        let generation = generation
        items[index].dismissed = true
        do {
            let goal = try await client.promote(agentID: agentID, itemID: idea.id)
            guard generation == self.generation else { return false }
            items.removeAll { $0.id == goal.id }
            items.insert(goal, at: 0)
            return true
        } catch {
            guard generation == self.generation, let current = items.firstIndex(where: { $0.id == idea.id }) else { return false }
            items[current].dismissed = false
            return false
        }
    }

    /// What Let's do it managed on this connection.
    enum AcceptOutcome: Equatable {
        /// The host recorded the yes for exactly this idea.
        case recorded
        /// An older plugin: the chat message alone carries the yes, as before.
        case notSupported
        /// The host didn't confirm it; the person can try again.
        case failed
    }

    /// Let's do it: tells the host which idea by its ID, before the chat opens. The ID goes
    /// only here, never into the chat (`letsDoItMessage`). The idea stays on the board.
    func accept(_ idea: AgentBoardItem) async -> AcceptOutcome {
        guard let client, client.supportsAnswers else { return .notSupported }
        guard idea.kind == .idea, let agentID, items.contains(where: { $0.id == idea.id && $0.kind == .idea }) else {
            return .failed
        }
        let generation = generation
        do {
            try await client.accept(agentID: agentID, itemID: idea.id)
            // A yes recorded by a connection that's gone may belong to another computer.
            return generation == self.generation ? .recorded : .failed
        } catch WorkspaceClientError.unavailable(.unsupportedOperation) {
            return .notSupported
        } catch {
            return .failed
        }
    }

    func setDone(_ item: AgentBoardItem, _ done: Bool) async {
        await mutate(item) { $0.status = done ? "done" : "active" } send: { client, agent in
            try await client.update(agentID: agent, itemID: item.id, change: .init(status: done ? "done" : "active"))
        }
    }

    func picture(for item: AgentBoardItem, index: Int) async -> Data? {
        let key = "\(item.id)#\(index)"
        if let cached = pictures[key] { return cached }
        guard let client, let agentID else { return nil }
        guard let data = try? await client.picture(agentID: agentID, itemID: item.id, index: index) else { return nil }
        if pictures.count > 60 { pictures.removeAll() }
        pictures[key] = data
        return data
    }

    // MARK: Files on posts

    /// The post's files this connection can show; none on an older plugin.
    func visibleFiles(of item: AgentBoardItem) -> [AgentBoardItem.File] {
        supportsFiles && item.kind == .feed ? item.files : []
    }

    func fileState(_ item: AgentBoardItem, _ file: AgentBoardItem.File) -> FileState {
        fileStates[fileKey(item, file)] ?? .loading
    }

    func thumbnail(_ item: AgentBoardItem, _ file: AgentBoardItem.File) -> UIImage? {
        fileThumbnails[fileKey(item, file)]
    }

    func isOpening(_ item: AgentBoardItem, _ file: AgentBoardItem.File) -> Bool {
        openingFile == fileKey(item, file)
    }

    /// A picture's small copy, as it scrolls into view. A file the host refused waits
    /// for a tap to try again.
    func loadThumbnail(for item: AgentBoardItem, file: AgentBoardItem.File) async {
        let key = fileKey(item, file)
        guard file.isImage, supportsFiles, let client, let agentID, fileThumbnails[key] == nil,
              fileStates[key] != .unavailable, pendingThumbnails.insert(key).inserted else { return }
        defer { pendingThumbnails.remove(key) }
        let generation = generation
        do {
            let attachment = try await client.file(agentID: agentID, itemID: item.id, file: file)
            guard generation == self.generation else { return }
            keep(attachment, key: key)
        } catch is CancellationError {
        } catch {
            guard generation == self.generation else { return }
            fileStates[key] = .unavailable
        }
    }

    /// The whole file, ready for the preview, Save and Share. Opening a file that
    /// failed before asks the host again.
    func attachment(for item: AgentBoardItem, file: AgentBoardItem.File) async -> ChatAttachment? {
        guard supportsFiles, let client, let agentID, item.files.contains(file) else { return nil }
        let key = fileKey(item, file)
        let generation = generation
        openingFile = key
        defer { if openingFile == key { openingFile = nil } }
        do {
            let attachment = try await client.file(agentID: agentID, itemID: item.id, file: file)
            guard generation == self.generation else { return nil }
            keep(attachment, key: key)
            return attachment
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return nil }
            fileStates[key] = .unavailable
            return nil
        }
    }

    private func keep(_ attachment: ChatAttachment, key: String) {
        fileStates[key] = .ready
        guard attachment.mimeType.hasPrefix("image/"), fileThumbnails[key] == nil else { return }
        guard let image = AgentMediaStore.thumbnail(attachment.data, side: 480) else {
            fileStates[key] = .unavailable
            return
        }
        if fileThumbnails.count > 60 { fileThumbnails.removeAll() }
        fileThumbnails[key] = image
    }

    private func fileKey(_ item: AgentBoardItem, _ file: AgentBoardItem.File) -> String {
        [agentID ?? "", item.id, String(file.index), file.fileName,
         String(Int(file.addedAt?.timeIntervalSince1970 ?? 0))].joined(separator: "\u{0}")
    }

    /// Optimistic: the change shows at once and rolls back if Hermes refuses it.
    private func mutate(
        _ item: AgentBoardItem,
        apply: (inout AgentBoardItem) -> Void,
        send: @MainActor (any AgentBoardClient, String) async throws -> AgentBoardItem
    ) async {
        guard let client, let agentID, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let before = items[index]
        apply(&items[index])
        let generation = generation
        do {
            let confirmed = try await send(client, agentID)
            guard generation == self.generation, let current = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[current] = confirmed
        } catch {
            guard generation == self.generation, let current = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[current] = before
        }
    }
}
