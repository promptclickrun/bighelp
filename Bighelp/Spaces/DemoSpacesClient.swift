import Foundation

/// Demo mode's computer: three live spaces and one draft on the demo bots, answering the way the
/// plugin does (docs/SPACES.md › Routes), so UI tests and the demo need no host. Add needs the
/// draft's revision, a repeated `operationId` gets the first answer only for the same request (and
/// `invalid_request` for another), Update now is held to the plugin's minimum gap and runs nothing
/// for a paused AI routine, and a deleted space is gone. Made-up data only.
@MainActor
final class DemoSpacesClient: SpacesClient {
    static let shared = DemoSpacesClient()

    nonisolated static let commuteID = "s_c0e1a7e0c0e1a7e0c0e1a7e0c0e1a7e0"
    nonisolated static let gardenID = "s_6a7d6a7d6a7d6a7d6a7d6a7d6a7d6a7d"
    nonisolated static let workoutsID = "s_b0d1b0d1b0d1b0d1b0d1b0d1b0d1b0d1"
    /// A draft in the finance bot's chat, waiting for Add to Today.
    nonisolated static let spendingDraftID = "s_5e9d5e9d5e9d5e9d5e9d5e9d5e9d5e9d"
    /// Their pages, served by `DemoHTMLAppsClient`.
    nonisolated static let commutePageID = "a_c0e2c0e2c0e2c0e2c0e2c0e2c0e2c0e2"
    nonisolated static let gardenPageID = "a_6a7e6a7e6a7e6a7e6a7e6a7e6a7e6a7e"
    nonisolated static let workoutsPageID = "a_b0d2b0d2b0d2b0d2b0d2b0d2b0d2b0d2"
    nonisolated static let spendingPageID = "a_5e9e5e9e5e9e5e9e5e9e5e9e5e9e5e9e"
    /// The demo computer's bots (`AppFixtureClients`).
    nonisolated static let agentIDs: Set<String> = ["travel", "home", "finance"]

    private struct Record {
        let agentID: String
        let spaceID: String
        var state: SpaceState
        var title: String
        var description: String
        var size: SpaceSize
        var hidden: Bool
        var position: Double
        var revision: Int
        let pageID: String
        let usesAI: Bool
        let updates: String
        let cadenceMinutes: Int
        var routineState: SpaceRoutineState
        var problem: String?
        var updatedAt: Date
        var checkedAt: Date?
        var lastRefresh: Date?
        /// Deleted while Hermes still had its task: off Today, never run, gone for every route but delete.
        var isDeleting = false
        let cards: @MainActor (Date) -> (card: [String: BighelpJSONValue], sizes: [String: BighelpJSONValue])
    }

    private struct Outcome {
        /// The operation and its body, without the `operationId`.
        let request: String
        let answer: Result<[String: BighelpJSONValue], WorkspaceClientError>
    }

    private var records: [String: Record] = [:]
    /// Answers by `operationId`, refusals too: the same request again gets the first answer and
    /// changes nothing. A 503 isn't kept, so the same request tries again.
    private var operations: [String: Outcome] = [:]
    private let clock: @MainActor () -> Date
    /// Every call, for tests.
    private(set) var calls: [(operation: SpacesOperation, payload: [String: BighelpJSONValue])] = []
    /// Spaces whose script is gone or fails the check: Add is refused with `invalid_request`.
    var missingScripts: Set<String> = []
    /// Spaces whose Hermes task won't go yet: delete takes them off Today and answers
    /// `schedules_unavailable` until they leave this set.
    var stuckTasks: Set<String> = []

    init(clock: @escaping @MainActor () -> Date = { Date() }) {
        self.clock = clock
        let now = clock()
        for record in [
            Record(agentID: "travel", spaceID: Self.commuteID, state: .live, title: "Commute",
                   description: "Drive time to work, from live traffic.", size: .small, hidden: false, position: 1_024,
                   revision: 1, pageID: Self.commutePageID, usesAI: false, updates: "Every 15 minutes",
                   cadenceMinutes: 15, routineState: .running, updatedAt: now.addingTimeInterval(-4 * 60),
                   checkedAt: now.addingTimeInterval(-4 * 60), cards: DemoSpaceCards.commute),
            // Stopped: nothing ran its routine for hours, so the panel offers Try again.
            Record(agentID: "home", spaceID: Self.gardenID, state: .live, title: "Garden",
                   description: "Soil, temperature and the last watering.", size: .wide, hidden: false, position: 2_048,
                   revision: 1, pageID: Self.gardenPageID, usesAI: false, updates: "Every 30 minutes",
                   cadenceMinutes: 30, routineState: .late, updatedAt: now.addingTimeInterval(-3 * 3_600),
                   checkedAt: now.addingTimeInterval(-3 * 3_600), cards: DemoSpaceCards.garden),
            Record(agentID: "home", spaceID: Self.workoutsID, state: .live, title: "Workouts",
                   description: "This week's training, read from the log each evening.", size: .tall, hidden: false,
                   position: 3_072, revision: 2, pageID: Self.workoutsPageID, usesAI: true, updates: "Every day at 20:00",
                   cadenceMinutes: 1_440, routineState: .running, updatedAt: now.addingTimeInterval(-40 * 60),
                   checkedAt: now.addingTimeInterval(-40 * 60), cards: DemoSpaceCards.workouts),
            Record(agentID: "finance", spaceID: Self.spendingDraftID, state: .draft, title: "Spending",
                   description: "This month's spending against the budget.", size: .wide, hidden: false,
                   position: 4_096, revision: 1, pageID: Self.spendingPageID, usesAI: false,
                   updates: "Every 2 hours", cadenceMinutes: 120, routineState: .draft,
                   updatedAt: now.addingTimeInterval(-60), cards: DemoSpaceCards.spending),
        ] {
            records[Space.key(agentID: record.agentID, spaceID: record.spaceID)] = record
        }
    }

    func perform(_ operation: SpacesOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        calls.append((operation, payload))
        guard operation.isMutation else { return try read(operation, payload) }
        guard let operationID = payload["operationId"]?.string, operationID == operationID.lowercased(),
              UUID(uuidString: operationID) != nil else { throw Self.refusal("invalid_request") }
        let request = Self.request(operation, payload)
        if let outcome = operations[operationID] {
            // Another operation, space or body under a used `operationId` is refused, and nothing is done.
            guard outcome.request == request else { throw Self.refusal("invalid_request") }
            return try current(outcome.answer.get())
        }
        let answer: Result<[String: BighelpJSONValue], WorkspaceClientError>
        do {
            answer = .success(try mutate(operation, payload))
        } catch let error as WorkspaceClientError {
            answer = .failure(error)
        }
        if case .failure(.rejected(let code, _)) = answer, code == "schedules_unavailable" {
            // Not kept: the same request tries again.
        } else {
            operations[operationID] = Outcome(request: request, answer: answer)
        }
        return try answer.get()
    }

    /// A repeated request's answer, with its space as it is now (as the plugin reads it again).
    private func current(_ answer: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] {
        guard let space = answer["space"]?.object, let agentID = space["agentId"]?.string,
              let spaceID = space["spaceId"]?.string,
              let record = records[Space.key(agentID: agentID, spaceID: spaceID)] else { return answer }
        var answer = answer
        answer["space"] = .object(json(record, cards: true))
        return answer
    }

    private static func request(_ operation: SpacesOperation, _ payload: [String: BighelpJSONValue]) -> String {
        var body = payload
        body["operationId"] = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(BighelpJSONValue.object(body))) ?? Data()
        return operation.rawValue + " " + String(decoding: data, as: UTF8.self)
    }

    private func read(_ operation: SpacesOperation,
                      _ payload: [String: BighelpJSONValue]) throws -> [String: BighelpJSONValue] {
        if operation == .get {
            let record = try stored(payload)
            return ["space": .object(json(record, cards: true))]
        }
        guard let agents = payload["agentIds"]?.array?.compactMap(\.string), (1...64).contains(agents.count),
              agents.allSatisfy(SpacesWire.isAgentID) else { throw Self.refusal("invalid_request") }
        let known = payload["known"]?.object ?? [:]
        let spaces = records.values
            .filter { $0.state == .live && !$0.isDeleting && agents.contains($0.agentID) }
            .sorted { $0.position < $1.position }
            .map { record in
                let key = Space.key(agentID: record.agentID, spaceID: record.spaceID)
                return BighelpJSONValue.object(json(record, cards: known[key]?.string != cardsHash(record)))
            }
        let statuses = Dictionary(uniqueKeysWithValues: agents.map { agent in
            (agent, BighelpJSONValue.string(Self.agentIDs.contains(agent) ? "ok" : "profile_not_found"))
        })
        return ["spaces": .array(spaces), "agents": .object(statuses)]
    }

    private func mutate(_ operation: SpacesOperation,
                        _ payload: [String: BighelpJSONValue]) throws -> [String: BighelpJSONValue] {
        let now = clock()
        if operation == .delete {
            let key = try spaceKey(payload)
            guard let record = records[key] else {
                return ["spaceId": payload["spaceId"] ?? .null, "deleted": .boolean(true), "existed": .boolean(false)]
            }
            if stuckTasks.contains(record.spaceID) {
                // Off Today at once; the delete finishes on a later try.
                records[key]?.isDeleting = true
                throw Self.refusal("schedules_unavailable")
            }
            records[key] = nil
            return ["spaceId": payload["spaceId"] ?? .null, "deleted": .boolean(true), "existed": .boolean(true)]
        }
        var record = try stored(payload)
        let key = Space.key(agentID: record.agentID, spaceID: record.spaceID)
        var answer: [String: BighelpJSONValue] = [:]
        switch operation {
        case .add:
            guard let revision = payload["draftRevision"]?.integer else { throw Self.refusal("invalid_request") }
            guard revision == record.revision else { throw Self.refusal("draft_changed") }
            if record.state == .draft {
                guard !missingScripts.contains(record.spaceID) else { throw Self.refusal("invalid_request") }
                let live = records.values.filter { $0.agentID == record.agentID && $0.state == .live }
                guard live.count < SpacesWire.maximumLiveSpacesPerBot else { throw Self.refusal("spaces_full") }
                record.state = .live
                record.routineState = .running
                record.checkedAt = now
                if let size = payload["size"]?.string { record.size = SpaceSize(wire: .string(size)) }
                record.position = payload["position"]?.number
                    ?? (live.map(\.position).max() ?? 0) + SpacesWire.positionStep
            }
        case .update:
            guard let changes = payload["changes"]?.object, !changes.isEmpty else { throw Self.refusal("invalid_request") }
            for (name, value) in changes {
                switch (name, value) {
                case ("size", .string(let size)) where SpaceSize(rawValue: size) != nil:
                    record.size = SpaceSize(wire: value)
                case ("hidden", .boolean(let hidden)):
                    record.hidden = hidden
                case ("position", _) where value.number.map({ $0.isFinite && abs($0) <= SpacesWire.maximumPositionMagnitude }) == true:
                    record.position = value.number ?? record.position
                case ("title", .string(let title)) where (1...SpacesWire.maximumTitleLength).contains(title.unicodeScalars.count):
                    record.title = title
                default:
                    throw Self.refusal("invalid_request")
                }
            }
        case .refresh:
            guard record.state == .live else { throw Self.refusal("invalid_request") }
            let gap: TimeInterval = record.usesAI ? 600 : 60
            if let last = record.lastRefresh, now.timeIntervalSince(last) < gap { throw Self.refusal("refresh_too_soon") }
            let paused = record.routineState == .paused
            if record.usesAI {
                // A paused AI routine runs nothing, and the next Update now stays free: only the
                // person resumes it, in Scheduled tasks.
                guard !paused else {
                    answer["ran"] = .string(SpaceRefreshRun.paused.rawValue)
                    break
                }
                // It runs on the computer's next tick.
                record.lastRefresh = now
                record.routineState = .running
                record.problem = nil
                answer["ran"] = .string(SpaceRefreshRun.queued.rawValue)
            } else {
                // A script that changed since Add doesn't run (the plugin's 502 `routine_failed`).
                guard record.problem != SpacesWire.scriptChangedProblem else { throw Self.refusal("routine_failed") }
                // A script runs at once, paused or not; a pause stays.
                record.lastRefresh = now
                if !paused { record.routineState = .running }
                record.problem = nil
                record.updatedAt = now
                record.checkedAt = now
                answer["ran"] = .string(SpaceRefreshRun.now.rawValue)
            }
        case .list, .get, .delete:
            throw Self.refusal("invalid_request")
        }
        records[key] = record
        answer["space"] = .object(json(record, cards: true))
        return answer
    }

    private func spaceKey(_ payload: [String: BighelpJSONValue]) throws -> String {
        guard let agentID = payload["agentId"]?.string, SpacesWire.isAgentID(agentID),
              let spaceID = payload["spaceId"]?.string, SpacesWire.isSpaceID(spaceID) else {
            throw Self.refusal("invalid_request")
        }
        guard Self.agentIDs.contains(agentID) else { throw Self.refusal("profile_not_found") }
        return Space.key(agentID: agentID, spaceID: spaceID)
    }

    private func stored(_ payload: [String: BighelpJSONValue]) throws -> Record {
        guard let record = records[try spaceKey(payload)], !record.isDeleting else { throw Self.refusal("space_not_found") }
        return record
    }

    private static func refusal(_ code: String) -> WorkspaceClientError { .rejected(code: code) }

    private func cardsHash(_ record: Record) -> String {
        let cards = record.cards(record.updatedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(BighelpJSONValue.object(["card": .object(cards.card), "sizes": .object(cards.sizes)]))) ?? Data()
        return SpacesWire.sha256(String(decoding: data, as: UTF8.self))
    }

    /// The route's space object; cards left out when the phone has them.
    private func json(_ record: Record, cards withCards: Bool) -> [String: BighelpJSONValue] {
        let now = clock()
        let cadence = TimeInterval(record.cadenceMinutes * 60)
        let status: SpaceStatus = if record.state == .draft {
            .draft
        } else if record.routineState != .running {
            .stopped
        } else if now.timeIntervalSince(record.updatedAt) > 3 * cadence {
            .stale
        } else {
            .fresh
        }
        let checkedAt: BighelpJSONValue = record.checkedAt.map { .string(SpacesWire.text($0)) } ?? .null
        var routine: [String: BighelpJSONValue] = [
            "kind": .string(record.usesAI ? "ai" : "script"), "usesAI": .boolean(record.usesAI),
            "updates": .string(record.updates), "cadenceMinutes": .integer(record.cadenceMinutes),
            "state": .string(record.routineState.rawValue), "pendingChange": .boolean(false),
        ]
        routine["problem"] = record.problem.map(BighelpJSONValue.string) ?? .null
        if record.state == .live {
            let next = (record.checkedAt ?? record.updatedAt).addingTimeInterval(cadence)
            routine["nextRunAt"] = .string(SpacesWire.text(next))
            routine["lastRunAt"] = checkedAt
        }
        let page: [String: BighelpJSONValue] = ["appId": .string(record.pageID), "htmlSha256": .null, "live": .boolean(true)]
        var space: [String: BighelpJSONValue] = [
            "spaceId": .string(record.spaceID), "agentId": .string(record.agentID), "state": .string(record.state.rawValue),
            "title": .string(record.title), "description": .string(record.description),
            "size": .string(record.size.rawValue), "hidden": .boolean(record.hidden), "position": .number(record.position),
            "revision": .integer(record.revision), "cardOmitted": .boolean(false), "status": .string(status.rawValue),
        ]
        space["cardsSha256"] = .string(cardsHash(record))
        space["updatedAt"] = .string(SpacesWire.text(record.updatedAt))
        space["checkedAt"] = checkedAt
        space["page"] = .object(page)
        space["routine"] = .object(routine)
        if withCards {
            let cards = record.cards(record.updatedAt)
            space["card"] = .object(cards.card)
            if !cards.sizes.isEmpty { space["sizes"] = .object(cards.sizes) }
        }
        return space
    }

    // MARK: For tests

    /// The bot changes its draft (`bighelp_draft_space` again): Add with the old revision is refused.
    func reviseDraft(_ spaceID: String, agentID: String) {
        records[Space.key(agentID: agentID, spaceID: spaceID)]?.revision += 1
    }

    /// The person pauses a routine in Scheduled tasks, or a run reports a problem
    /// (`script_changed` once the bot changed the script after Add).
    func setRoutine(_ spaceID: String, agentID: String, state: SpaceRoutineState, problem: String? = nil) {
        let key = Space.key(agentID: agentID, spaceID: spaceID)
        records[key]?.routineState = state
        records[key]?.problem = problem
    }
}

/// The demo spaces' cards, as a bot's routine would write them: basic components, real-looking
/// numbers that move with the time of the update.
enum DemoSpaceCards {
    static func commute(_ at: Date) -> (card: [String: BighelpJSONValue], sizes: [String: BighelpJSONValue]) {
        let minutes = 24 + Calendar.current.component(.minute, from: at) % 9
        return (document("Commute", summary: "\(minutes) minutes to work.", at: at, elements: [
            "root": node("card", ["title": .string("Commute"), "subtitle": .string("To work")], ["time", "note"]),
            "time": node("text", ["value": literal(.string("\(minutes) min")), "typography": .string("title")]),
            "note": node("text", ["value": literal(.string("Leave by 8:05 · light traffic")),
                                  "typography": .string("caption"), "color": .string("secondary"), "line_limit": .integer(2)]),
        ]), [:])
    }

    static func garden(_ at: Date) -> (card: [String: BighelpJSONValue], sizes: [String: BighelpJSONValue]) {
        let moisture = 38 + Calendar.current.component(.minute, from: at) % 6
        return (document("Garden", summary: "Soil moisture \(moisture) percent.", at: at, elements: [
            "root": node("card", ["title": .string("Garden"), "subtitle": .string("Back beds")], ["grid", "watered"]),
            "grid": node("grid", ["columns": .integer(2), "spacing": .string("small")], ["moisture", "temperature"]),
            "moisture": node("metric", ["label": .string("Soil moisture"), "value": literal(.integer(moisture)),
                                        "format": .object(["style": .string("percent")]), "semantic": .string("accent")]),
            "temperature": node("metric", ["label": .string("Temperature"), "value": literal(.string("18.4°C"))]),
            "watered": node("text", ["value": literal(.string("Last watered Tuesday, 7:10 AM")),
                                     "typography": .string("caption"), "color": .string("secondary")]),
        ]), [:])
    }

    static func workouts(_ at: Date) -> (card: [String: BighelpJSONValue], sizes: [String: BighelpJSONValue]) {
        let days: [(String, Int)] = [("Mon", 35), ("Tue", 0), ("Wed", 50), ("Thu", 20), ("Fri", 45), ("Sat", 60), ("Sun", 0)]
        let points = BighelpJSONValue.array(days.map { day in
            BighelpJSONValue.object(["x": .string(day.0), "y": literal(.integer(day.1))])
        })
        let card = document("Workouts", summary: "210 minutes of training this week.", at: at, elements: [
            "root": node("card", ["title": .string("Workouts"), "subtitle": .string("This week")], ["totals", "chart", "next"]),
            "totals": node("hstack", ["spacing": .string("medium")], ["minutes", "sessions"]),
            "minutes": node("metric", ["label": .string("Minutes"), "value": literal(.integer(210)),
                                       "format": .object(["style": .string("integer")]), "semantic": .string("positive")]),
            "sessions": node("metric", ["label": .string("Sessions"), "value": literal(.integer(5)),
                                        "format": .object(["style": .string("integer")])]),
            "chart": node("chart", ["kind": .string("bar"), "description": .string("Minutes each day this week"),
                                    "series": .array([.object(["name": .string("Minutes"), "points": points])])]),
            "next": node("text", ["value": literal(.string("Next: easy run, 30 minutes")),
                                  "typography": .string("caption"), "color": .string("secondary")]),
        ])
        // Small has room for the week's total only.
        let small = document("Workouts", summary: "210 minutes of training this week.", at: at, elements: [
            "root": node("card", ["title": .string("Workouts")], ["minutes"]),
            "minutes": node("metric", ["label": .string("This week"), "value": literal(.string("210 min")),
                                       "semantic": .string("positive")]),
        ])
        return (card, ["small": .object(small)])
    }

    static func spending(_ at: Date) -> (card: [String: BighelpJSONValue], sizes: [String: BighelpJSONValue]) {
        (document("Spending", summary: "1,240 dollars spent of a 2,000 dollar budget.", at: at, elements: [
            "root": node("card", ["title": .string("Spending"), "subtitle": .string("This month")], ["spent", "groceries"]),
            "spent": node("progress", ["label": .string("Spent"), "value": literal(.integer(1_240)),
                                       "maximum": literal(.integer(2_000)),
                                       "format": .object(["style": .string("currency"), "currency": .string("USD")]),
                                       "semantic": .string("accent")]),
            "groceries": node("text", ["value": literal(.string("Groceries $312 of $450")),
                                       "typography": .string("caption"), "color": .string("secondary")]),
        ]), [:])
    }

    /// A card as the plugin's `render_card` leaves it.
    private static func document(_ title: String, summary: String, at: Date,
                                 elements: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] {
        let hash = SpacesWire.sha256(title + summary + SpacesWire.text(at))
        return [
            "schema": .string("loopdy.card"), "version": .integer(1), "title": .string(title),
            "spoken_summary": .string(summary), "data_sources": .array([]), "root": .string("root"),
            "elements": .object(elements), "content_hash": .string(hash), "card_id": .string(String(hash.prefix(32))),
            // The card validator reads `created_at` without fractions of a second.
            "origin": .string("live"), "created_at": .string(ISO8601DateFormatter().string(from: at)),
        ]
    }

    private static func node(_ type: String, _ props: [String: BighelpJSONValue], _ children: [String] = []) -> BighelpJSONValue {
        .object(["type": .string(type), "props": .object(props), "children": .array(children.map(BighelpJSONValue.string))])
    }

    private static func literal(_ value: BighelpJSONValue) -> BighelpJSONValue {
        .object(["literal": value])
    }
}

/// The demo spaces' pages, as a bot might write them: one small self-contained page each that
/// follows the phone's light or dark look and draws what `window.bighelp.onData` gives it.
enum DemoSpacePages {
    static func commuteData(_ now: Date) -> BighelpJSONValue {
        let minute = Calendar.current.component(.minute, from: now)
        return .object(["minutes": .integer(24 + minute % 9), "leaveBy": .string("8:05"),
                        "route": .string("Ring road, then Harbor Street"), "traffic": .string("Light")])
    }

    static func gardenData(_ now: Date) -> BighelpJSONValue {
        let tick = Int(now.timeIntervalSince1970 / 5)
        return .object(["moisture": .integer(38 + tick % 6), "temperature": .number(18 + Double(tick % 5) / 10),
                        "lastWatered": .string("Tuesday, 7:10 AM")])
    }

    static func workoutsData(_ now: Date) -> BighelpJSONValue {
        .object(["days": .array([35, 0, 50, 20, 45, 60, 0].map { BighelpJSONValue.integer($0) }),
                 "next": .string("Easy run, 30 minutes")])
    }

    static func spendingData(_ now: Date) -> BighelpJSONValue {
        .object(["spent": .integer(1_240), "budget": .integer(2_000),
                 "parts": .array([
                     .object(["name": .string("Groceries"), "spent": .integer(312)]),
                     .object(["name": .string("Eating out"), "spent": .integer(186)]),
                     .object(["name": .string("Transport"), "spent": .integer(142)]),
                 ])])
    }

    private static let style = """
    <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      :root { color-scheme: light dark; --page: #F5F5F7; --card: #FFFFFF; --ink: #1D1D24; --muted: #5A5A66; --accent: #3F6FD8; }
      @media (prefers-color-scheme: dark) { :root { --page: #121216; --card: #1E1E25; --ink: #F2F2F7; --muted: #B4B4C0; --accent: #8EA8FF; } }
      body { margin: 0; padding: 20px 16px; background: var(--page); color: var(--ink); font: 16px -apple-system, system-ui, sans-serif; }
      .card { background: var(--card); border-radius: 16px; padding: 16px; margin-bottom: 12px; }
      .big { font-size: 40px; font-weight: 700; }
      .muted { color: var(--muted); font-size: 14px; }
      .row { display: flex; justify-content: space-between; padding: 6px 0; }
      .bars { display: flex; align-items: flex-end; gap: 8px; height: 120px; }
      .bars span { flex: 1; background: var(--accent); border-radius: 4px; }
    </style>
    """

    static let commute = """
    <!doctype html><html lang="en"><head>\(style)<title>Commute</title></head><body>
    <div class="card"><div class="muted">Drive to work</div><div class="big" id="minutes">–</div><div class="muted" id="leave"></div></div>
    <div class="card"><div class="row"><span>Route</span><span id="route"></span></div><div class="row"><span>Traffic</span><span id="traffic"></span></div></div>
    <script>
      window.bighelp.onData((d) => { if (!d) return;
        document.getElementById("minutes").textContent = d.minutes + " min";
        document.getElementById("leave").textContent = "Leave by " + d.leaveBy;
        document.getElementById("route").textContent = d.route;
        document.getElementById("traffic").textContent = d.traffic; });
    </script></body></html>
    """

    static let garden = """
    <!doctype html><html lang="en"><head>\(style)<title>Garden</title></head><body>
    <div class="card"><div class="muted">Soil moisture</div><div class="big" id="moisture">–</div></div>
    <div class="card"><div class="row"><span>Temperature</span><span id="temperature"></span></div><div class="row"><span>Last watered</span><span id="watered"></span></div></div>
    <script>
      window.bighelp.onData((d) => { if (!d) return;
        document.getElementById("moisture").textContent = d.moisture + "%";
        document.getElementById("temperature").textContent = d.temperature.toFixed(1) + "°C";
        document.getElementById("watered").textContent = d.lastWatered; });
    </script></body></html>
    """

    static let workouts = """
    <!doctype html><html lang="en"><head>\(style)<title>Workouts</title></head><body>
    <div class="card"><div class="muted">Minutes each day</div><div class="bars" id="bars"></div><div class="row muted"><span>Mon</span><span>Sun</span></div></div>
    <div class="card"><div class="muted">Next</div><div id="next"></div></div>
    <script>
      window.bighelp.onData((d) => { if (!d) return;
        const most = Math.max(1, ...d.days);
        document.getElementById("bars").innerHTML = d.days.map((m) => `<span style="height:${Math.max(2, m / most * 100)}%"></span>`).join("");
        document.getElementById("next").textContent = d.next; });
    </script></body></html>
    """

    static let spending = """
    <!doctype html><html lang="en"><head>\(style)<title>Spending</title></head><body>
    <div class="card"><div class="muted">Spent this month</div><div class="big" id="spent">–</div><div class="muted" id="budget"></div></div>
    <div class="card" id="parts"></div>
    <script>
      const money = (n) => "$" + n.toLocaleString("en-US");
      window.bighelp.onData((d) => { if (!d) return;
        document.getElementById("spent").textContent = money(d.spent);
        document.getElementById("budget").textContent = "of " + money(d.budget);
        document.getElementById("parts").innerHTML = d.parts.map((p) => `<div class="row"><span>${p.name}</span><span>${money(p.spent)}</span></div>`).join(""); });
    </script></body></html>
    """
}
