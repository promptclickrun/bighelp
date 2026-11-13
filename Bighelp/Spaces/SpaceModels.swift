import Foundation

/// How much of Today a space takes: half a row, the whole row, or the whole row and twice the height.
enum SpaceSize: String, CaseIterable, Codable, Sendable {
    case small, wide, tall

    /// A size this app doesn't know is drawn Wide.
    init(wire value: BighelpJSONValue?) {
        self = value?.string.flatMap(Self.init(rawValue:)) ?? .wide
    }
}

/// A draft waits in the chat for Add to Today; a live space is on Today and its routine runs.
enum SpaceState: String, Sendable {
    case draft, live
}

/// What the computer says about a space's routine (`routine.state`).
enum SpaceRoutineState: String, Sendable {
    case running
    /// Paused on the computer, for example in Scheduled tasks.
    case paused
    /// Its scheduled task was removed.
    case missing
    case failed
    /// It should have run by now: nothing runs this computer's scheduled tasks.
    case late
    case draft
    /// A state this app doesn't know. Drawn as stopped.
    case unknown
}

/// How current a space's panel is (`status`).
enum SpaceStatus: String, Sendable {
    case draft, fresh
    /// Not updated for three of its intervals while its routine runs.
    case stale
    /// Its routine isn't running.
    case stopped
    case unknown
}

/// What updates a space, and whether that spends AI.
struct SpaceRoutine: Equatable, Sendable {
    enum Kind: String, Sendable {
        case script, ai, unknown
    }

    var kind: Kind
    /// Each update is a model turn. Unknown counts as yes: the person is never told "no AI" by guess.
    var usesAI: Bool
    /// The plugin's words for how often: "Every 15 minutes", "Weekdays at 7:00".
    var updates: String
    var cadenceMinutes: Int?
    var state: SpaceRoutineState
    var nextRunAt: Date?
    var lastRunAt: Date?
    /// A fixed code (`script_failed`, `no_update`, …), never the script's own output.
    var problem: String?
    /// A changed routine waits for Add again; the old one keeps running until then.
    var pendingChange: Bool

    init(json: [String: BighelpJSONValue]?) {
        let json = json ?? [:]
        let kind = json["kind"]?.string.flatMap(Kind.init(rawValue:)) ?? .unknown
        self.kind = kind
        usesAI = json["usesAI"]?.boolean ?? (kind != .script)
        updates = String((json["updates"]?.string ?? "").prefix(SpacesWire.maximumUpdatesLength))
        cadenceMinutes = json["cadenceMinutes"]?.integer.flatMap { $0 > 0 ? $0 : nil }
        state = json["state"]?.string.flatMap(SpaceRoutineState.init(rawValue:)) ?? .unknown
        nextRunAt = SpacesWire.date(json["nextRunAt"])
        lastRunAt = SpacesWire.date(json["lastRunAt"])
        problem = json["problem"]?.string.flatMap(Self.code)
        pendingChange = json["pendingChange"]?.boolean ?? false
    }

    var json: [String: BighelpJSONValue] {
        var json: [String: BighelpJSONValue] = [
            "kind": .string(kind.rawValue), "usesAI": .boolean(usesAI), "updates": .string(updates),
            "state": .string(state.rawValue), "pendingChange": .boolean(pendingChange),
        ]
        json["cadenceMinutes"] = cadenceMinutes.map(BighelpJSONValue.integer)
        json["nextRunAt"] = nextRunAt.map { .string(SpacesWire.text($0)) }
        json["lastRunAt"] = lastRunAt.map { .string(SpacesWire.text($0)) }
        json["problem"] = problem.map(BighelpJSONValue.string)
        return json
    }

    /// Letters, digits and `_`, at most 64: the plugin's codes, nothing else.
    private static func code(_ value: String) -> String? {
        guard (1...64).contains(value.utf8.count),
              value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
        return value
    }
}

/// The HTML app a space's panel opens (`html-apps/get` and `html-apps/data` with its `appId`).
struct SpacePage: Equatable, Sendable {
    let appID: String
    let htmlSHA256: String?
    let isLive: Bool

    /// The card the page screen opens with. A space's page never sends a message.
    func card(title: String, description: String) -> HTMLAppCard {
        HTMLAppCard(appID: appID, title: title, description: description, sendsAnswers: false, isLive: isLive)
    }
}

/// One space as the computer describes it (`spaces/list`, `get`, and every mutation's answer).
/// Read leniently: unknown keys are ignored, unknown values fall back, and only a space without
/// its ids is left out, never the list it came in.
struct Space: Identifiable, Equatable, Sendable {
    let spaceID: String
    let agentID: String
    var state: SpaceState
    var title: String
    var description: String
    var size: SpaceSize
    var hidden: Bool
    var position: Double
    var revision: Int
    /// The hash of the card and the size cards together; `list` leaves out cards the phone has.
    var cardsSHA256: String?
    /// The panel for every size that has no card of its own. Nil until it's read, or when unreadable.
    var card: BighelpCardDocument?
    var sizes: [SpaceSize: BighelpCardDocument]
    /// The list left the cards out to keep its answer small: `get` reads them.
    var cardOmitted: Bool
    /// The computer sent a card this app can't draw: its panel says so, the rest of Today draws.
    var cardUnreadable: Bool
    /// When the bot or its routine last changed what the panel shows. Never the phone's own time.
    var updatedAt: Date?
    /// When the routine last finished, also a run that had nothing new.
    var checkedAt: Date?
    var page: SpacePage?
    var routine: SpaceRoutine
    var status: SpaceStatus

    /// `agentId/spaceId`: unique on one computer, and the key `list`'s `known` uses.
    var id: String { key }
    var key: String { Self.key(agentID: agentID, spaceID: spaceID) }

    static func key(agentID: String, spaceID: String) -> String { agentID + "/" + spaceID }

    /// The card drawn at a size: the one made for it, else the space's own.
    func card(for size: SpaceSize) -> BighelpCardDocument? { sizes[size] ?? card }

    /// The phone has every card the computer sent (drawable or not), so `list` may leave them out.
    var holdsCards: Bool { card != nil || !sizes.isEmpty || cardUnreadable }

    /// The person paused its routine in Scheduled tasks; only they resume it there.
    var isPaused: Bool { routine.state == .paused }

    /// The bot changed its script after the person added the space: it stays stopped until the bot
    /// drafts it again and the person adds it again. Update now can't fix that.
    var isScriptChanged: Bool { routine.problem == SpacesWire.scriptChangedProblem }

    /// Its panel says Stopped updating, with Try again. An unknown state counts as stopped.
    var isStopped: Bool {
        guard state == .live else { return false }
        if status == .stopped { return true }
        switch routine.state {
        case .running, .draft: return false
        case .paused, .missing, .failed, .late, .unknown: return true
        }
    }

    init?(json: [String: BighelpJSONValue]) {
        guard let spaceID = json["spaceId"]?.string, SpacesWire.isSpaceID(spaceID),
              let agentID = json["agentId"]?.string, SpacesWire.isAgentID(agentID) else { return nil }
        self.spaceID = spaceID
        self.agentID = agentID
        state = json["state"]?.string.flatMap(SpaceState.init(rawValue:)) ?? .live
        // A bot wrote this text: no longer than the plugin accepts, whatever the answer holds.
        description = String((json["description"]?.string ?? "").prefix(SpacesWire.maximumDescriptionLength))
        size = SpaceSize(wire: json["size"])
        hidden = json["hidden"]?.boolean ?? false
        position = json["position"]?.number.flatMap {
            $0.isFinite && abs($0) <= SpacesWire.maximumPositionMagnitude ? $0 : nil
        } ?? SpacesWire.maximumPositionMagnitude
        revision = json["revision"]?.integer.flatMap { $0 >= 1 ? $0 : nil } ?? 1
        cardsSHA256 = json["cardsSha256"]?.string.flatMap { $0.utf8.count == 64 ? $0 : nil }
        let card: BighelpCardDocument?
        switch json["card"] {
        case nil, .null?:
            card = nil
            // Only the phone's own copy writes this mark: the computer sends the card or nothing.
            cardUnreadable = json["cardUnreadable"]?.boolean ?? false
        case let value?:
            card = Self.drawable(value)
            cardUnreadable = card == nil
        }
        self.card = card
        var sizes: [SpaceSize: BighelpCardDocument] = [:]
        for (name, value) in json["sizes"]?.object ?? [:] {
            // A size card that can't be drawn falls back to the space's own card.
            guard let size = SpaceSize(rawValue: name), let card = Self.drawable(value) else { continue }
            sizes[size] = card
        }
        self.sizes = sizes
        cardOmitted = json["cardOmitted"]?.boolean ?? false
        updatedAt = SpacesWire.date(json["updatedAt"])
        checkedAt = SpacesWire.date(json["checkedAt"])
        page = json["page"]?.object.flatMap { page in
            guard let appID = page["appId"]?.string, HTMLAppCard.isAppID(appID) else { return nil }
            return SpacePage(appID: appID, htmlSHA256: page["htmlSha256"]?.string, isLive: page["live"]?.boolean ?? true)
        }
        routine = SpaceRoutine(json: json["routine"]?.object)
        status = json["status"]?.string.flatMap(SpaceStatus.init(rawValue:)) ?? .unknown
        let title = (json["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = String((title.isEmpty ? (card?.title ?? "") : title).prefix(SpacesWire.maximumTitleLength))
    }

    /// The route's shape again, for the phone's copy on disk; read back by `init(json:)`.
    var json: [String: BighelpJSONValue] {
        var json: [String: BighelpJSONValue] = [
            "spaceId": .string(spaceID), "agentId": .string(agentID), "state": .string(state.rawValue),
            "title": .string(title), "description": .string(description), "size": .string(size.rawValue),
            "hidden": .boolean(hidden), "position": .number(position), "revision": .integer(revision),
            "cardOmitted": .boolean(cardOmitted), "routine": .object(routine.json), "status": .string(status.rawValue),
        ]
        json["cardsSha256"] = cardsSHA256.map(BighelpJSONValue.string)
        json["card"] = card.map { .object($0.document) }
        if card == nil, cardUnreadable { json["cardUnreadable"] = .boolean(true) }
        if !sizes.isEmpty {
            json["sizes"] = .object(Dictionary(uniqueKeysWithValues: sizes.map { size, card in
                (size.rawValue, BighelpJSONValue.object(card.document))
            }))
        }
        json["updatedAt"] = updatedAt.map { .string(SpacesWire.text($0)) }
        json["checkedAt"] = checkedAt.map { .string(SpacesWire.text($0)) }
        json["page"] = page.map { page in
            var object: [String: BighelpJSONValue] = ["appId": .string(page.appID), "live": .boolean(page.isLive)]
            object["htmlSha256"] = page.htmlSHA256.map(BighelpJSONValue.string)
            return .object(object)
        }
        return json
    }

    /// The same space with the cards the phone has, when the computer left them out and they
    /// haven't changed.
    func takingCards(from cached: Space?) -> Space {
        guard !holdsCards, let cached, cached.holdsCards, cached.cardsSHA256 != nil,
              cached.cardsSHA256 == cardsSHA256 else { return self }
        var space = self
        space.card = cached.card
        space.sizes = cached.sizes
        space.cardUnreadable = cached.cardUnreadable
        space.cardOmitted = false
        return space
    }

    /// The cards still have to be read with `get`.
    var needsCards: Bool { !holdsCards && (cardOmitted || cardsSHA256 != nil) }

    /// A card the app can draw: a valid `loopdy.card` with no live data sources.
    private static func drawable(_ value: BighelpJSONValue) -> BighelpCardDocument? {
        guard let document = value.object, let card = try? BighelpCardDocument(document: document) else { return nil }
        return try? BighelpCardValidator.validateForStaticRelease(card)
    }
}

/// What a bot's spaces read as, per bot in a `list` answer.
enum SpacesAgentStatus: Equatable, Sendable {
    case ok
    /// The bot isn't on the computer anymore: its spaces go.
    case notFound
    /// Anything else: its spaces stay as last read.
    case other(String)

    init(_ value: String) {
        switch value {
        case "ok": self = .ok
        case "profile_not_found": self = .notFound
        default: self = .other(value)
        }
    }

    /// A bot the computer couldn't read just now keeps the spaces last read for it.
    var keepsSpaces: Bool {
        if case .other = self { return true }
        return false
    }
}

/// One `spaces/list` answer.
struct SpacesList: Equatable, Sendable {
    var spaces: [Space]
    var agents: [String: SpacesAgentStatus]

    init(spaces: [Space] = [], agents: [String: SpacesAgentStatus] = [:]) {
        self.spaces = spaces
        self.agents = agents
    }

    /// A space that doesn't read is left out; the first of two with one key wins.
    init(json: [String: BighelpJSONValue]) {
        var seen = Set<String>()
        spaces = (json["spaces"]?.array ?? []).prefix(SpacesWire.maximumSpacesPerAnswer).compactMap { value in
            guard let object = value.object, let space = Space(json: object), seen.insert(space.key).inserted else { return nil }
            return space
        }
        var agents: [String: SpacesAgentStatus] = [:]
        for (agentID, status) in json["agents"]?.object ?? [:] {
            guard SpacesWire.isAgentID(agentID), let text = status.string else { continue }
            agents[agentID] = SpacesAgentStatus(text)
        }
        self.agents = agents
    }
}

/// What `spaces/update` changes. The phone keeps these until the computer says they're done.
struct SpaceChanges: Codable, Equatable, Sendable {
    var size: SpaceSize?
    var hidden: Bool?
    var position: Double?
    var title: String?

    init(size: SpaceSize? = nil, hidden: Bool? = nil, position: Double? = nil, title: String? = nil) {
        self.size = size
        self.hidden = hidden
        self.position = position
        self.title = title
    }

    var isEmpty: Bool { size == nil && hidden == nil && position == nil && title == nil }

    var payload: [String: BighelpJSONValue] {
        var changes: [String: BighelpJSONValue] = [:]
        changes["size"] = size.map { .string($0.rawValue) }
        changes["hidden"] = hidden.map(BighelpJSONValue.boolean)
        changes["position"] = position.map(BighelpJSONValue.number)
        changes["title"] = title.map(BighelpJSONValue.string)
        return changes
    }

    /// A later change on top of this one: its fields win.
    func merging(_ newer: SpaceChanges) -> SpaceChanges {
        SpaceChanges(size: newer.size ?? size, hidden: newer.hidden ?? hidden,
                     position: newer.position ?? position, title: newer.title ?? title)
    }

    /// Without the fields `other` sets: what's left after those were refused.
    func removing(_ other: SpaceChanges) -> SpaceChanges {
        SpaceChanges(size: other.size == nil ? size : nil, hidden: other.hidden == nil ? hidden : nil,
                     position: other.position == nil ? position : nil, title: other.title == nil ? title : nil)
    }

    func applied(to space: Space) -> Space {
        var space = space
        if let size { space.size = size }
        if let hidden { space.hidden = hidden }
        if let position { space.position = position }
        if let title { space.title = title }
        return space
    }

    /// The computer's own value has caught up with every field.
    func isSatisfied(by space: Space) -> Bool {
        (size == nil || space.size == size) && (hidden == nil || space.hidden == hidden)
            && (position == nil || space.position == position) && (title == nil || space.title == title)
    }
}

/// How `spaces/refresh` ran the routine: a script at once, an AI routine on the computer's next tick,
/// or nothing, for an AI routine the person paused in Scheduled tasks.
enum SpaceRefreshRun: String, Sendable {
    case now, queued, paused
}

/// A chat card's one `space_draft` element (the plugin's `space_draft_props`): which draft, what it
/// shows, how often it updates and whether that uses AI. Read exactly, as `HTMLAppCard` is.
struct SpaceDraftCard: Equatable, Sendable {
    let spaceID: String
    let title: String
    let description: String
    /// "Every 15 minutes": the plugin's words.
    let updates: String
    let usesAI: Bool
    /// Add to Today sends it back (`draftRevision`); a bot that changed the draft since gets `draft_changed`.
    let revision: Int

    init(spaceID: String, title: String, description: String, updates: String, usesAI: Bool, revision: Int) {
        self.spaceID = spaceID
        self.title = title
        self.description = description
        self.updates = updates
        self.usesAI = usesAI
        self.revision = revision
    }

    init(props: [String: BighelpJSONValue], title: String) throws {
        let keys: Set<String> = ["space_id", "description", "updates", "uses_ai", "revision"]
        guard Set(props.keys) == keys,
              let spaceID = props["space_id"]?.string, SpacesWire.isSpaceID(spaceID),
              case .string(let description)? = props["description"],
              // Counted as the plugin counts them (Unicode scalars, Python's `len`).
              description.unicodeScalars.count <= SpacesWire.maximumDescriptionLength,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .string(let updates)? = props["updates"],
              updates.unicodeScalars.count <= SpacesWire.maximumUpdatesLength,
              !updates.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .boolean(let usesAI)? = props["uses_ai"],
              case .integer(let revision)? = props["revision"], revision >= 1 else {
            throw BighelpCardValidationError.invalid
        }
        self.init(spaceID: spaceID, title: title, description: description, updates: updates,
                  usesAI: usesAI, revision: revision)
    }

    static func draft(in card: BighelpCardDocument) -> SpaceDraftCard? {
        guard let elements = card.document["elements"]?.object else { return nil }
        for element in elements.values {
            guard let object = element.object, object["type"]?.string == SpacesWire.type,
                  let props = object["props"]?.object else { continue }
            return try? SpaceDraftCard(props: props, title: card.title)
        }
        return nil
    }

    /// The validator's composition rule: a draft is its card's only element.
    static func validateComposition(_ elements: [String: BighelpJSONValue]) throws {
        let drafts = elements.values.filter { $0.object?["type"]?.string == SpacesWire.type }.count
        guard drafts == 0 || elements.count == 1 else { throw BighelpCardValidationError.invalid }
    }
}
