import Foundation

/// What a group chat Hermes runs itself keeps for every member (`room.context_set`): its
/// purpose, shared notes and who answers a message that names nobody. `groups.state` returns
/// it as `context` (Hermes 0.23 `gateway/hosted_room_context.py`). A room whose state has no
/// `context` has none of these settings, and the app shows none of them.
struct HermesBotModeRoomContext: Equatable, Sendable {
    enum Routing: String, CaseIterable, Sendable {
        /// Every member gets a turn: Hermes' default.
        case everyone
        /// The lead picks who takes it (`room.assignment`).
        case lead
        /// One quick model call picks who it's for (`room.routed`).
        case auto
    }

    static let maximumPurposeCharacters = 500
    static let maximumNotesBytes = 4 * 1024

    var purpose: String
    var notes: String
    /// Nil when Hermes keeps no routing for the room, or one the app doesn't know. The app then
    /// never sends routing, so Hermes keeps what it has.
    var routing: Routing?
    /// The lead, only while `routing` is `lead`.
    var leadMemberID: String?

    init(purpose: String = "", notes: String = "", routing: Routing? = .everyone, leadMemberID: String? = nil) {
        self.purpose = purpose
        self.notes = notes
        self.routing = routing
        self.leadMemberID = routing == .lead ? leadMemberID : nil
    }

    /// `groups.state`'s `context`, read leniently: a missing or wrong-typed part is empty, and an
    /// unknown routing is left alone. Nil when there's no context object.
    init?(json: BighelpJSONValue?) {
        guard case .object(let object)? = json else { return nil }
        // Hermes keeps these within 500 characters and 4 KB; a host that sends more is cut off
        // well past that, never shown or saved whole.
        func text(_ key: String, limit: Int) -> String {
            String(String.UnicodeScalarView((object[key]?.string ?? "").unicodeScalars.prefix(limit)))
        }
        let routing = object["routing"]?.string.flatMap(Routing.init(rawValue:))
        let lead = object["lead_member_id"]?.string.flatMap { HermesBotModeWireCodec.identifier($0) ? $0 : nil }
        self.init(purpose: text("purpose", limit: Self.maximumPurposeCharacters * 4),
                  notes: text("notes", limit: Self.maximumNotesBytes * 4),
                  routing: routing, leadMemberID: lead)
    }

    /// The purpose as Hermes saves it: each run of whitespace becomes one space (Python's
    /// `" ".join(purpose.split())`).
    static func savedPurpose(_ value: String) -> String {
        var words: [String] = []
        var word = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if isHostWhitespace(scalar) {
                if !word.isEmpty { words.append(String(word)) }
                word = String.UnicodeScalarView()
            } else {
                word.append(scalar)
            }
        }
        if !word.isEmpty { words.append(String(word)) }
        return words.joined(separator: " ")
    }

    /// The notes as Hermes saves them: without leading and trailing whitespace.
    static func savedNotes(_ value: String) -> String { HermesBotModeWireCodec.canonicalUserText(value) }

    /// The bytes Hermes counts against `maximumNotesBytes`.
    static func notesBytes(_ value: String) -> Int { savedNotes(value).utf8.count }

    /// Hermes would take this as it is: purpose and notes within their limits, and a lead named
    /// for lead routing.
    var isSavable: Bool {
        Self.savedPurpose(purpose).unicodeScalars.count <= Self.maximumPurposeCharacters
            && Self.notesBytes(notes) <= Self.maximumNotesBytes
            && (routing != .lead || leadMemberID.map(HermesBotModeWireCodec.identifier) == true)
    }

    /// Python's `str.isspace()`: Unicode whitespace and the four separator controls.
    private static func isHostWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }
}

/// What `groups.state`'s `driver_status` says about routing: the modes the room's runtime runs
/// (`routing_modes`) and how many times one discussion may continue (`max_continues`).
struct HermesBotModeRoutingSupport: Equatable, Sendable {
    var modes: Set<HermesBotModeRoomContext.Routing>
    /// Nil when Hermes doesn't say.
    var maximumContinues: Int?

    init(modes: Set<HermesBotModeRoomContext.Routing> = [], maximumContinues: Int? = nil) {
        self.modes = modes
        self.maximumContinues = maximumContinues
    }

    init(driverStatus: [String: BighelpJSONValue]?) {
        let modes = driverStatus?["routing_modes"]?.array?.prefix(16)
            .compactMap { $0.string.flatMap(HermesBotModeRoomContext.Routing.init(rawValue:)) } ?? []
        let maximum = driverStatus?["max_continues"]?.integer.flatMap { (0...1_000).contains($0) ? $0 : nil }
        self.init(modes: Set(modes), maximumContinues: maximum)
    }
}

/// A room's settings as this connection last read them.
struct HermesBotModeRoomSettings: Equatable, Sendable {
    var context: HermesBotModeRoomContext
    var support: HermesBotModeRoutingSupport

    /// "Pick who answers" shows where the room's runtime runs it, or where the room already uses it.
    var offersAutomaticRouting: Bool { support.modes.contains(.auto) || context.routing == .auto }
}

/// One save of a room's settings. It is kept with the room until Hermes answers, so a retry
/// sends the same `event_id` (Hermes returns the first save for it), and an edit that wasn't
/// saved stays for the person to try again, also after a relaunch.
struct HermesBotModeContextIntent: Codable, Equatable, Sendable {
    let eventID: String
    let purpose: String
    let notes: String
    /// Nil: Hermes keeps the routing it has.
    let routing: String?
    let leadMemberID: String?
    /// Why the last try didn't save, in plain words; nil while it's on its way.
    var problem: String?

    init(eventID: String, context: HermesBotModeRoomContext, problem: String? = nil) {
        self.eventID = eventID
        // Kept as Hermes saves them, so a retry under this `event_id` matches its first save.
        purpose = HermesBotModeRoomContext.savedPurpose(context.purpose)
        notes = HermesBotModeRoomContext.savedNotes(context.notes)
        routing = context.routing?.rawValue
        leadMemberID = context.routing == .lead ? context.leadMemberID : nil
        self.problem = problem
    }

    var context: HermesBotModeRoomContext {
        HermesBotModeRoomContext(purpose: purpose, notes: notes,
                                 routing: routing.flatMap(HermesBotModeRoomContext.Routing.init(rawValue:)),
                                 leadMemberID: leadMemberID)
    }

    /// The same edit, so a retry may reuse this save's `event_id`.
    func isSameEdit(as context: HermesBotModeRoomContext) -> Bool {
        let other = HermesBotModeContextIntent(eventID: eventID, context: context)
        return purpose == other.purpose && notes == other.notes
            && routing == other.routing && leadMemberID == other.leadMemberID
    }

    /// The `groups.context` request. Routing goes only when there is one to set, and the lead only
    /// with lead routing: an omitted field keeps Hermes' value.
    func request(roomID: String) -> [String: BighelpJSONValue] {
        var request: [String: BighelpJSONValue] = [
            "room_id": .string(roomID), "event_id": .string(eventID),
            "purpose": .string(purpose), "notes": .string(notes),
        ]
        if let routing {
            request["routing"] = .string(routing)
            if routing == HermesBotModeRoomContext.Routing.lead.rawValue, let leadMemberID {
                request["lead_member_id"] = .string(leadMemberID)
            }
        }
        return request
    }
}

@MainActor
protocol HermesBotModeRoomSettingsClient: AnyObject {
    func groupsContext(roomID: String, intent: HermesBotModeContextIntent) async throws -> HermesBotModeRoomContext
    /// Gives a discussion Hermes paused at its cap one more budget of rounds and messages.
    func groupsContinue(roomID: String, discussionEventID: String) async throws -> HermesBotModeEvent
}

extension BighelpLinkHermesBotModeClient: HermesBotModeRoomSettingsClient {}
