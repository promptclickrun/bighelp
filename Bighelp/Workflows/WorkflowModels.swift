import Foundation

// The plugin's `native-workflows-v1` shapes (docs/WORKFLOWS.md in bighelp-plugin,
// fixtures/contracts/workflows-v1). Hosts differ, so every part is lenient:
// unknown keys are ignored, a missing part hides one row, and an unknown state
// is kept as `.unknown` instead of failing the screen.

typealias WorkflowJSON = [String: BighelpJSONValue]

enum WorkflowDecode {
    static func string(_ value: BighelpJSONValue?, max: Int = 4_096) -> String? {
        guard let text = value?.string, text.utf8.count <= max else { return nil }
        return text
    }

    static func int(_ value: BighelpJSONValue?) -> Int? {
        switch value {
        case .integer(let number)?: number
        case .number(let number)? where number.isFinite && number.rounded() == number
            && abs(number) < 9.0e15: Int(number)
        default: nil
        }
    }

    static func bool(_ value: BighelpJSONValue?) -> Bool? { value?.boolean }

    static func strings(_ value: BighelpJSONValue?, max: Int = 200) -> [String] {
        (value?.array ?? []).prefix(max).compactMap { string($0, max: 512) }
    }

    static func objects(_ value: BighelpJSONValue?, max: Int = 500) -> [WorkflowJSON] {
        (value?.array ?? []).prefix(max).compactMap(\.object)
    }

    /// ISO 8601 (with or without fractions) or seconds since 1970 (milliseconds when huge).
    static func date(_ value: BighelpJSONValue?) -> Date? {
        switch value {
        case .string(let text)?:
            if let date = try? Date(text, strategy: .iso8601) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            if let seconds = Double(text) { return epoch(seconds) }
            return nil
        case .integer(let seconds)?: return epoch(Double(seconds))
        case .number(let seconds)?: return epoch(seconds)
        default: return nil
        }
    }

    private static func epoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1_000 : value)
    }
}

// MARK: - States

/// A run's (or a stage's) state. Apps parse unknown states leniently.
enum WorkflowRunState: Hashable, Sendable {
    case planned, launched, running, checkingOutput, accepted, waitingForYou, needsAttention
    case succeeded, failed, cancelled
    case unknown(String)

    init(_ raw: String?) {
        switch raw?.lowercased() {
        // Stages that haven't started are "pending" (contract vectors).
        case "planned", "pending": self = .planned
        case "launched": self = .launched
        case "running": self = .running
        case "checking_output": self = .checkingOutput
        case "accepted": self = .accepted
        case "waiting_for_you": self = .waitingForYou
        case "needs_attention": self = .needsAttention
        case "succeeded": self = .succeeded
        case "failed": self = .failed
        case "cancelled", "canceled": self = .cancelled
        default: self = .unknown(raw ?? "")
        }
    }

    var rawValue: String {
        switch self {
        case .planned: "planned"
        case .launched: "launched"
        case .running: "running"
        case .checkingOutput: "checking_output"
        case .accepted: "accepted"
        case .waitingForYou: "waiting_for_you"
        case .needsAttention: "needs_attention"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .unknown(let raw): raw
        }
    }

    /// Plain words for people.
    var title: String {
        switch self {
        case .planned: "Planned"
        case .launched: "Starting"
        case .running: "Running"
        case .checkingOutput: "Checking"
        case .accepted: "Done"
        case .waitingForYou: "Waiting for you"
        case .needsAttention: "Needs attention"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    /// An agent or the host is working on it now: worth watching closely.
    var isWorking: Bool { [.planned, .launched, .running, .checkingOutput, .accepted].contains(self) }
    /// Nothing more happens by itself.
    var isFinished: Bool { [.succeeded, .failed, .cancelled].contains(self) }
}

// MARK: - Host status

struct WorkflowStatus: Equatable, Sendable {
    enum Coordinator: String, Sendable { case online, starting, offline, unknown }
    var coordinator: Coordinator
    var heartbeatAt: Date?
    var epoch: Int?
    var slotsUsed: Int
    var slotsTotal: Int
    var survivesAppClose: Bool
    var runnerAvailable: Bool
    var runnerReason: String?
    var hostName: String?

    init(json: WorkflowJSON) {
        let coordinator = json["coordinator"]?.object ?? [:]
        self.coordinator = Coordinator(rawValue: WorkflowDecode.string(coordinator["state"]) ?? "") ?? .unknown
        heartbeatAt = WorkflowDecode.date(coordinator["heartbeatAt"])
        epoch = WorkflowDecode.int(coordinator["epoch"])
        let slots = json["slots"]?.object ?? [:]
        slotsUsed = max(0, WorkflowDecode.int(slots["used"]) ?? 0)
        slotsTotal = max(0, WorkflowDecode.int(slots["total"]) ?? 0)
        survivesAppClose = WorkflowDecode.bool(json["survivesAppClose"]) ?? true
        let runner = json["runner"]?.object ?? [:]
        runnerAvailable = WorkflowDecode.bool(runner["available"]) ?? true
        runnerReason = WorkflowDecode.string(runner["reason"], max: 500)
        hostName = WorkflowDecode.string(json["hostName"], max: 200)
    }

    init(coordinator: Coordinator, heartbeatAt: Date?, epoch: Int?, slotsUsed: Int, slotsTotal: Int,
         survivesAppClose: Bool = true, runnerAvailable: Bool = true, runnerReason: String? = nil, hostName: String?) {
        self.coordinator = coordinator
        self.heartbeatAt = heartbeatAt
        self.epoch = epoch
        self.slotsUsed = slotsUsed
        self.slotsTotal = slotsTotal
        self.survivesAppClose = survivesAppClose
        self.runnerAvailable = runnerAvailable
        self.runnerReason = runnerReason
        self.hostName = hostName
    }
}

// MARK: - Workflows

struct WorkflowSummary: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    /// The newest published revision; nil until the first publish.
    var revision: Int?
    var hasDraft: Bool
    var stageCount: Int
    var needsSetupRoles: [String]
    var valid: Bool
    var lastRunAt: Date?
    /// Stage kinds in order, when the host sends them (for the little rail).
    var stageKinds: [WorkflowStage.Kind]

    init?(json: WorkflowJSON) {
        guard let id = WorkflowDecode.string(json["id"], max: 128), !id.isEmpty else { return nil }
        self.id = id
        name = WorkflowDecode.string(json["name"], max: 200) ?? "Workflow"
        revision = WorkflowDecode.int(json["revision"])
        hasDraft = WorkflowDecode.bool(json["hasDraft"]) ?? false
        stageCount = max(0, WorkflowDecode.int(json["stageCount"]) ?? 0)
        needsSetupRoles = WorkflowDecode.strings(json["needsSetupRoles"], max: 20)
        valid = WorkflowDecode.bool(json["valid"]) ?? false
        lastRunAt = WorkflowDecode.date(json["lastRunAt"])
        stageKinds = WorkflowDecode.strings(json["stageKinds"], max: 20).map(WorkflowStage.Kind.init)
    }

    init(id: String, name: String, revision: Int?, hasDraft: Bool, stageCount: Int, needsSetupRoles: [String],
         valid: Bool, lastRunAt: Date?, stageKinds: [WorkflowStage.Kind] = []) {
        self.id = id
        self.name = name
        self.revision = revision
        self.hasDraft = hasDraft
        self.stageCount = stageCount
        self.needsSetupRoles = needsSetupRoles
        self.valid = valid
        self.lastRunAt = lastRunAt
        self.stageKinds = stageKinds
    }
}

struct WorkflowsList: Equatable, Sendable {
    var workflows: [WorkflowSummary]
    var waiting: [WorkflowRunSummary]
    var active: [WorkflowRunSummary]

    init(json: WorkflowJSON) {
        workflows = WorkflowDecode.objects(json["workflows"], max: 200).compactMap(WorkflowSummary.init(json:))
        waiting = WorkflowDecode.objects(json["waiting"], max: 200).compactMap(WorkflowRunSummary.init(json:))
        active = WorkflowDecode.objects(json["active"], max: 200).compactMap(WorkflowRunSummary.init(json:))
    }

    init(workflows: [WorkflowSummary], waiting: [WorkflowRunSummary], active: [WorkflowRunSummary]) {
        self.workflows = workflows
        self.waiting = waiting
        self.active = active
    }
}

struct WorkflowBinding: Equatable, Sendable {
    var role: String
    var agentID: String?
    var approvedAt: Date?

    init?(json: WorkflowJSON) {
        guard let role = WorkflowDecode.string(json["role"], max: 128) else { return nil }
        self.role = role
        agentID = WorkflowDecode.string(json["agentId"], max: 128)
        approvedAt = WorkflowDecode.date(json["approvedAt"])
    }

    init(role: String, agentID: String?, approvedAt: Date? = nil) {
        self.role = role
        self.agentID = agentID
        self.approvedAt = approvedAt
    }

    static func list(_ value: BighelpJSONValue?) -> [WorkflowBinding] {
        WorkflowDecode.objects(value, max: 50).compactMap(WorkflowBinding.init(json:))
    }
}

struct WorkflowValidation: Equatable, Sendable {
    struct Issue: Equatable, Sendable, Identifiable {
        var id: String { "\(stageKey ?? "-")/\(code)/\(message)" }
        var stageKey: String?
        var code: String
        var message: String
        var isError: Bool
    }

    var valid: Bool
    /// True when the computer itself checked it (its tools, agents and Hermes),
    /// not only the definition's shape.
    var checkedOnHost: Bool
    var issues: [Issue]

    init(json: WorkflowJSON?) {
        let json = json ?? [:]
        valid = WorkflowDecode.bool(json["valid"]) ?? false
        checkedOnHost = WorkflowDecode.bool(json["host"]) ?? false
        issues = WorkflowDecode.objects(json["issues"], max: 100).compactMap { issue in
            guard let code = WorkflowDecode.string(issue["code"], max: 128) else { return nil }
            return Issue(stageKey: WorkflowDecode.string(issue["stageKey"], max: 128), code: code,
                         message: WorkflowDecode.string(issue["message"], max: 1_000) ?? code,
                         isError: WorkflowDecode.string(issue["severity"]) != "warning")
        }
    }

    init(valid: Bool, checkedOnHost: Bool = true, issues: [Issue]) {
        self.valid = valid
        self.checkedOnHost = checkedOnHost
        self.issues = issues
    }

    var errors: [Issue] { issues.filter(\.isError) }
    var warnings: [Issue] { issues.filter { !$0.isError } }
}

struct WorkflowDetail: Equatable, Sendable {
    var id: String
    var name: String
    /// The revision shown; nil when this is the draft.
    var revision: Int?
    /// The newest published revision, which runs use.
    var latestRevision: Int?
    var draftVersion: Int
    var definition: WorkflowDefinition
    var bindings: [WorkflowBinding]
    var validation: WorkflowValidation

    init(json: WorkflowJSON) throws {
        guard let workflow = json["workflow"]?.object,
              let id = WorkflowDecode.string(workflow["id"], max: 128),
              let definition = workflow["definition"]?.object else {
            throw WorkspaceClientError.invalidResponse
        }
        self.id = id
        self.definition = WorkflowDefinition(json: definition)
        name = WorkflowDecode.string(workflow["name"], max: 200) ?? self.definition.name
        revision = WorkflowDecode.int(workflow["revision"])
        latestRevision = WorkflowDecode.int(workflow["latestRevision"]) ?? revision
        draftVersion = WorkflowDecode.int(workflow["draftVersion"]) ?? 0
        bindings = WorkflowBinding.list(workflow["bindings"])
        validation = WorkflowValidation(json: json["validation"]?.object)
    }

    init(id: String, name: String, revision: Int?, draftVersion: Int, definition: WorkflowDefinition,
         bindings: [WorkflowBinding], validation: WorkflowValidation) {
        self.id = id
        self.name = name
        self.revision = revision
        latestRevision = revision
        self.draftVersion = draftVersion
        self.definition = definition
        self.bindings = bindings
        self.validation = validation
    }

    func agentID(for role: String) -> String? { bindings.first { $0.role == role }?.agentID }
}

// MARK: - Definition (schemaVersion 1)

/// A workflow's definition. Fields the app doesn't know are kept and sent back
/// unchanged, so saving a draft never drops what a newer plugin added.
struct WorkflowDefinition: Equatable, Sendable {
    struct Role: Equatable, Sendable, Identifiable {
        var id: String { key }
        var key: String
        var label: String
    }

    struct Input: Equatable, Sendable, Identifiable {
        enum Kind: String, Sendable { case text, longText = "long_text", number, choice }
        var id: String { key }
        var key: String
        var label: String
        var type: String
        var required: Bool
        var choices: [String]
        /// Kept as sent, so a saved draft gives it back unchanged.
        var sampleValue: BighelpJSONValue?
        var sample: String? { sampleValue?.displayText }
        var kind: Kind { Kind(rawValue: type) ?? .text }
    }

    var schemaVersion: Int
    var name: String
    var description: String
    var roles: [Role]
    var inputs: [Input]
    var stageMinutes: Int
    var maxRevisions: Int
    var stages: [WorkflowStage]
    private var extra: WorkflowJSON
    private var limitsExtra: WorkflowJSON

    init(json: WorkflowJSON) {
        schemaVersion = WorkflowDecode.int(json["schemaVersion"]) ?? 1
        name = WorkflowDecode.string(json["name"], max: 200) ?? ""
        description = WorkflowDecode.string(json["description"], max: 2_000) ?? ""
        roles = WorkflowDecode.objects(json["roles"], max: 20).compactMap { role in
            guard let key = WorkflowDecode.string(role["key"], max: 64) else { return nil }
            return Role(key: key, label: WorkflowDecode.string(role["label"], max: 200) ?? key)
        }
        inputs = WorkflowDecode.objects(json["inputs"], max: 20).compactMap { input in
            guard let key = WorkflowDecode.string(input["key"], max: 64) else { return nil }
            return Input(key: key, label: WorkflowDecode.string(input["label"], max: 200) ?? key,
                         type: WorkflowDecode.string(input["type"], max: 32) ?? "text",
                         required: WorkflowDecode.bool(input["required"]) ?? false,
                         choices: WorkflowDecode.strings(input["choices"], max: 50),
                         sampleValue: input["sample"].flatMap { $0 == .null ? nil : $0 })
        }
        let limits = json["limits"]?.object ?? [:]
        stageMinutes = WorkflowDecode.int(limits["stageMinutes"]) ?? 20
        maxRevisions = WorkflowDecode.int(limits["maxRevisions"]) ?? 2
        stages = WorkflowDecode.objects(json["stages"], max: 20).compactMap(WorkflowStage.init(json:))
        let known: Set<String> = ["schemaVersion", "name", "description", "roles", "inputs", "limits", "stages"]
        extra = json.filter { !known.contains($0.key) }
        limitsExtra = limits.filter { !["stageMinutes", "maxRevisions"].contains($0.key) }
    }

    var json: WorkflowJSON {
        var value = extra
        value["schemaVersion"] = .integer(schemaVersion)
        value["name"] = .string(name)
        value["description"] = .string(description)
        value["roles"] = .array(roles.map { .object(["key": .string($0.key), "label": .string($0.label)]) })
        value["inputs"] = .array(inputs.map { input in
            var object: WorkflowJSON = ["key": .string(input.key), "label": .string(input.label),
                                        "type": .string(input.type), "required": .boolean(input.required)]
            if !input.choices.isEmpty { object["choices"] = .array(input.choices.map(BighelpJSONValue.string)) }
            if let sample = input.sampleValue { object["sample"] = sample }
            return .object(object)
        })
        var limits = limitsExtra
        limits["stageMinutes"] = .integer(stageMinutes)
        limits["maxRevisions"] = .integer(maxRevisions)
        value["limits"] = .object(limits)
        value["stages"] = .array(stages.map { .object($0.json) })
        return value
    }

    func role(_ key: String?) -> Role? { roles.first { $0.key == key } }
    func stage(_ key: String?) -> WorkflowStage? { stages.first { $0.key == key } }
}

struct WorkflowStage: Equatable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case agent, check, decision, signoff
        case unknown(String)

        init(_ raw: String) {
            switch raw {
            case "agent": self = .agent
            case "check": self = .check
            case "decision": self = .decision
            case "signoff": self = .signoff
            default: self = .unknown(raw)
            }
        }

        var rawValue: String {
            switch self {
            case .agent: "agent"
            case .check: "check"
            case .decision: "decision"
            case .signoff: "signoff"
            case .unknown(let raw): raw
            }
        }

        var title: String {
            switch self {
            case .agent: "Agent stage"
            case .check: "Check"
            case .decision: "Decision"
            case .signoff: "Sign-off"
            case .unknown: "Stage"
            }
        }

        var symbol: String {
            switch self {
            case .agent: "cpu"
            case .check: "checkmark.shield"
            case .decision: "arrow.triangle.branch"
            case .signoff: "person.badge.shield.checkmark"
            case .unknown: "square.dashed"
            }
        }
    }

    struct Output: Equatable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        var type: String
        var values: [String]

        var typeTitle: String {
            switch type {
            case "markdown_file": "Markdown file"
            case "text": "Text"
            case "number": "Number"
            case "decision": "Decision"
            case "notes": "Notes"
            default: type
            }
        }
    }

    /// A check stage's rule: word_range, has_title, not_empty, number_range.
    struct Rule: Equatable, Sendable, Identifiable {
        var id: String { "\(kind)/\(of)" }
        var kind: String
        var of: String
        var min: Double?
        var max: Double?
        fileprivate var raw: WorkflowJSON

        /// `{"rule": "word_range", "of": …}` (or `type`/`kind`), or `{"word_range": {"of": …}}`.
        init(json: WorkflowJSON) {
            raw = json
            var body = json
            if let named = WorkflowDecode.string(json["rule"] ?? json["type"] ?? json["kind"], max: 64) {
                kind = named
            } else if json.count == 1, let first = json.first, let nested = first.value.object {
                kind = first.key
                body = nested
            } else {
                kind = "rule"
            }
            of = WorkflowDecode.string(body["of"], max: 128) ?? ""
            min = body["min"]?.number
            max = body["max"]?.number
        }

        var summary: String {
            func number(_ value: Double?) -> String { value.map { Int($0).formatted() } ?? "…" }
            switch kind {
            case "word_range": return "\(number(min))-\(number(max)) words"
            case "has_title": return "has title"
            case "not_empty": return "not empty"
            case "number_range": return "\(of) \(number(min))-\(number(max))"
            default: return kind.replacingOccurrences(of: "_", with: " ")
            }
        }
    }

    var id: String { key }
    var key: String
    var kind: Kind
    var title: String
    var role: String?
    var instructions: String
    var tools: [String]
    var uses: [String]
    var outputs: [Output]
    var minutes: Int?
    var rules: [Rule]
    /// Decision: the output it reads (`review.decision`), where pass goes, where changes go.
    var on: String?
    var pass: String?
    var changesGoTo: String?
    var changesMaxRevisions: Int?
    /// Sign-off: the file you approve (`draft.draft`).
    var file: String?
    private var extra: WorkflowJSON
    private var changesExtra: WorkflowJSON

    init?(json: WorkflowJSON) {
        guard let key = WorkflowDecode.string(json["key"], max: 64), !key.isEmpty else { return nil }
        self.key = key
        kind = Kind(WorkflowDecode.string(json["kind"], max: 32) ?? "")
        title = WorkflowDecode.string(json["title"], max: 200) ?? key
        role = WorkflowDecode.string(json["role"], max: 64)
        instructions = WorkflowDecode.string(json["instructions"], max: 8_000) ?? ""
        tools = WorkflowDecode.strings(json["tools"], max: 40)
        uses = WorkflowDecode.strings(json["uses"], max: 40)
        outputs = WorkflowDecode.objects(json["outputs"], max: 20).compactMap { output in
            guard let name = WorkflowDecode.string(output["name"], max: 64) else { return nil }
            return Output(name: name, type: WorkflowDecode.string(output["type"], max: 32) ?? "text",
                          values: WorkflowDecode.strings(output["values"], max: 20))
        }
        minutes = WorkflowDecode.int(json["minutes"])
        rules = WorkflowDecode.objects(json["rules"], max: 20).map(Rule.init(json:))
        on = WorkflowDecode.string(json["on"], max: 128)
        pass = WorkflowDecode.string(json["pass"], max: 64)
        let changes = json["changes"]?.object ?? [:]
        changesGoTo = WorkflowDecode.string(changes["goTo"], max: 64)
        changesMaxRevisions = WorkflowDecode.int(changes["maxRevisions"])
        changesExtra = changes.filter { !["goTo", "maxRevisions"].contains($0.key) }
        file = WorkflowDecode.string(json["file"], max: 128)
        let known: Set<String> = ["key", "kind", "title", "role", "instructions", "tools", "uses", "outputs",
                                  "minutes", "rules", "on", "pass", "changes", "file"]
        extra = json.filter { !known.contains($0.key) }
    }

    /// A new agent stage for the editor.
    init(newAgentStageAfter existing: [WorkflowStage], role: String?) {
        var number = existing.count + 1
        while existing.contains(where: { $0.key == "stage\(number)" }) { number += 1 }
        key = "stage\(number)"
        kind = .agent
        title = "New stage"
        self.role = role
        instructions = ""
        tools = []
        uses = []
        outputs = [Output(name: "result", type: "text", values: [])]
        minutes = nil
        rules = []
        extra = [:]
        changesExtra = [:]
    }

    var json: WorkflowJSON {
        var value = extra
        value["key"] = .string(key)
        value["kind"] = .string(kind.rawValue)
        value["title"] = .string(title)
        switch kind {
        case .agent:
            if let role { value["role"] = .string(role) }
            value["instructions"] = .string(instructions)
            value["tools"] = .array(tools.map(BighelpJSONValue.string))
            value["uses"] = .array(uses.map(BighelpJSONValue.string))
            value["outputs"] = .array(outputs.map { output in
                var object: WorkflowJSON = ["name": .string(output.name), "type": .string(output.type)]
                if !output.values.isEmpty { object["values"] = .array(output.values.map(BighelpJSONValue.string)) }
                return .object(object)
            })
            if let minutes { value["minutes"] = .integer(minutes) }
        case .check:
            // The editor shows rules but doesn't change them: each goes back as it came.
            value["rules"] = .array(rules.map { .object($0.raw) })
        case .decision:
            if let on { value["on"] = .string(on) }
            if let pass { value["pass"] = .string(pass) }
            var changes = changesExtra
            if let changesGoTo { changes["goTo"] = .string(changesGoTo) }
            if let changesMaxRevisions { changes["maxRevisions"] = .integer(changesMaxRevisions) }
            if !changes.isEmpty { value["changes"] = .object(changes) }
        case .signoff:
            if let file { value["file"] = .string(file) }
        case .unknown:
            break
        }
        return value
    }

    /// One line under the stage's title: "writer → quill", "700-1,100 words · has title".
    func subtitle(agentName: (String?) -> String?) -> String {
        switch kind {
        case .agent:
            let agent = agentName(role) ?? "no agent yet"
            return [role, agent].compactMap { $0 }.joined(separator: " → ")
        case .check: return rules.map(\.summary).joined(separator: " · ")
        case .decision: return on ?? ""
        case .signoff: return "approval → you"
        case .unknown: return ""
        }
    }

    /// Tools that can change anything on the computer; the stage editor warns about them.
    static let broadToolsets: Set<String> = ["terminal", "code_execution", "file"]
    var hasBroadTools: Bool { tools.contains { Self.broadToolsets.contains($0) } }
}

// MARK: - Runs

struct WorkflowRunSummary: Identifiable, Equatable, Hashable, Sendable {
    struct Problem: Equatable, Hashable, Sendable {
        var stageKey: String?
        var code: String
        var message: String
    }

    struct Waiting: Equatable, Hashable, Sendable {
        var kind: String
        var stageKey: String?
        var since: Date?
    }

    let id: String
    var number: Int
    var workflowID: String
    var workflowName: String
    var revision: Int?
    var state: WorkflowRunState
    var stageKey: String?
    var stageTitle: String?
    var stageState: WorkflowRunState?
    var stagesDone: Int
    var stageCount: Int
    var startedAt: Date?
    var updatedAt: Date?
    var attention: Problem?
    var failure: Problem?
    var waiting: Waiting?
    var version: Int
    var sample: Bool
    var iteration: Int = 1
    var endedAt: Date?
    var paused = false
    /// Present on hosts that echo it; used to find a run whose start wasn't confirmed.
    var clientRunToken: String?

    init?(json: WorkflowJSON) {
        guard let id = WorkflowDecode.string(json["id"], max: 128), !id.isEmpty else { return nil }
        self.id = id
        number = WorkflowDecode.int(json["number"]) ?? 0
        workflowID = WorkflowDecode.string(json["workflowId"], max: 128) ?? ""
        workflowName = WorkflowDecode.string(json["workflowName"], max: 200) ?? "Workflow"
        revision = WorkflowDecode.int(json["revision"])
        state = WorkflowRunState(WorkflowDecode.string(json["state"], max: 64))
        stageKey = WorkflowDecode.string(json["stageKey"], max: 64)
        stageTitle = WorkflowDecode.string(json["stageTitle"], max: 200)
        stageState = WorkflowDecode.string(json["stageState"], max: 64).map { WorkflowRunState($0) }
        stagesDone = max(0, WorkflowDecode.int(json["stagesDone"]) ?? 0)
        stageCount = max(0, WorkflowDecode.int(json["stageCount"]) ?? 0)
        startedAt = WorkflowDecode.date(json["startedAt"])
        updatedAt = WorkflowDecode.date(json["updatedAt"])
        attention = Self.problem(json["attention"])
        failure = Self.problem(json["failure"])
        waiting = json["waiting"]?.object.map { waiting in
            Waiting(kind: WorkflowDecode.string(waiting["kind"], max: 32) ?? "signoff",
                    stageKey: WorkflowDecode.string(waiting["stageKey"], max: 64),
                    since: WorkflowDecode.date(waiting["since"]))
        }
        version = WorkflowDecode.int(json["version"]) ?? 0
        sample = WorkflowDecode.bool(json["sample"]) ?? false
        iteration = WorkflowDecode.int(json["iteration"]) ?? 1
        endedAt = WorkflowDecode.date(json["endedAt"])
        paused = WorkflowDecode.bool(json["paused"]) ?? false
        clientRunToken = WorkflowDecode.string(json["clientRunToken"], max: 128)
    }

    init(id: String, number: Int, workflowID: String, workflowName: String, revision: Int?, state: WorkflowRunState,
         stageKey: String?, stageTitle: String?, stageState: WorkflowRunState?, stagesDone: Int, stageCount: Int,
         startedAt: Date?, updatedAt: Date?, attention: Problem? = nil, failure: Problem? = nil,
         waiting: Waiting? = nil, version: Int, sample: Bool = false, clientRunToken: String? = nil) {
        self.id = id
        self.number = number
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.revision = revision
        self.state = state
        self.stageKey = stageKey
        self.stageTitle = stageTitle
        self.stageState = stageState
        self.stagesDone = stagesDone
        self.stageCount = stageCount
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.attention = attention
        self.failure = failure
        self.waiting = waiting
        self.version = version
        self.sample = sample
        self.clientRunToken = clientRunToken
    }

    private static func problem(_ value: BighelpJSONValue?) -> Problem? {
        guard let object = value?.object else { return nil }
        let code = WorkflowDecode.string(object["code"], max: 128) ?? "unknown"
        return Problem(stageKey: WorkflowDecode.string(object["stageKey"], max: 64), code: code,
                       message: WorkflowDecode.string(object["message"], max: 1_000) ?? WorkflowWords.problem(code))
    }

    /// "Running Draft", "Needs attention", "Failed at Check draft".
    var stateLine: String {
        switch state {
        case .running, .launched, .checkingOutput, .accepted:
            return [state == .checkingOutput ? "Checking" : "Running", stageTitle].compactMap { $0 }.joined(separator: " ")
        case .failed:
            if let stageTitle { return "Failed at \(stageTitle)" }
            return state.title
        default:
            return state.title
        }
    }
}

struct WorkflowRunPage: Equatable, Sendable {
    var runs: [WorkflowRunSummary]
    var hasMore: Bool

    init(json: WorkflowJSON) {
        runs = WorkflowDecode.objects(json["runs"], max: 200).compactMap(WorkflowRunSummary.init(json:))
        hasMore = WorkflowDecode.bool(json["hasMore"]) ?? false
    }

    init(runs: [WorkflowRunSummary], hasMore: Bool) {
        self.runs = runs
        self.hasMore = hasMore
    }
}

enum WorkflowRunFilter: String, CaseIterable, Identifiable, Sendable {
    case all, active, forYou = "for_you", attention
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        case .forYou: "For you"
        case .attention: "Attention"
        }
    }
}

struct WorkflowTokens: Equatable, Sendable {
    var input: Int
    var output: Int
    var total: Int { input + output }

    init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }

    init(json: BighelpJSONValue?) {
        let object = json?.object ?? [:]
        input = max(0, WorkflowDecode.int(object["in"]) ?? 0)
        output = max(0, WorkflowDecode.int(object["out"]) ?? 0)
    }
}

struct WorkflowAttempt: Equatable, Sendable, Identifiable {
    var id: String
    var number: Int
    var iteration: Int = 1
    var state: WorkflowRunState
    var agentID: String?
    var launchedAt: Date?
    var endedAt: Date?
    var durationMs: Int?
    var tokens: WorkflowTokens
    var outcomeCode: String?

    init?(json: WorkflowJSON) {
        guard let id = WorkflowDecode.string(json["id"], max: 128) ?? WorkflowDecode.int(json["id"]).map(String.init)
        else { return nil }
        self.id = id
        number = WorkflowDecode.int(json["number"]) ?? 1
        iteration = WorkflowDecode.int(json["iteration"]) ?? 1
        state = WorkflowRunState(WorkflowDecode.string(json["state"], max: 64))
        agentID = WorkflowDecode.string(json["agentId"], max: 128)
        launchedAt = WorkflowDecode.date(json["launchedAt"])
        endedAt = WorkflowDecode.date(json["endedAt"])
        durationMs = WorkflowDecode.int(json["durationMs"])
        tokens = WorkflowTokens(json: json["tokens"])
        outcomeCode = WorkflowDecode.string(json["outcomeCode"], max: 128)
    }

    init(id: String, number: Int, state: WorkflowRunState, agentID: String?, launchedAt: Date?, endedAt: Date?,
         durationMs: Int?, tokens: WorkflowTokens, outcomeCode: String? = nil) {
        self.id = id
        self.number = number
        self.state = state
        self.agentID = agentID
        self.launchedAt = launchedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.tokens = tokens
        self.outcomeCode = outcomeCode
    }
}

struct WorkflowRunStage: Equatable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var kind: WorkflowStage.Kind
    var title: String
    var role: String?
    var agentID: String?
    var iteration: Int
    var state: WorkflowRunState
    var minutes: Double?
    var startedAt: Date?
    var endedAt: Date?
    var attempts: [WorkflowAttempt]

    init?(json: WorkflowJSON) {
        guard let key = WorkflowDecode.string(json["key"], max: 64) else { return nil }
        self.key = key
        kind = WorkflowStage.Kind(WorkflowDecode.string(json["kind"], max: 32) ?? "")
        title = WorkflowDecode.string(json["title"], max: 200) ?? key
        role = WorkflowDecode.string(json["role"], max: 64)
        agentID = WorkflowDecode.string(json["agentId"], max: 128)
        iteration = WorkflowDecode.int(json["iteration"]) ?? 1
        state = WorkflowRunState(WorkflowDecode.string(json["state"], max: 64))
        minutes = json["minutes"]?.number
        startedAt = WorkflowDecode.date(json["startedAt"])
        endedAt = WorkflowDecode.date(json["endedAt"])
        attempts = WorkflowDecode.objects(json["attempts"], max: 50).compactMap(WorkflowAttempt.init(json:))
    }

    init(key: String, kind: WorkflowStage.Kind, title: String, role: String?, agentID: String?, iteration: Int,
         state: WorkflowRunState, minutes: Double?, attempts: [WorkflowAttempt]) {
        self.key = key
        self.kind = kind
        self.title = title
        self.role = role
        self.agentID = agentID
        self.iteration = iteration
        self.state = state
        self.minutes = minutes
        self.attempts = attempts
    }
}

struct WorkflowOutput: Equatable, Sendable, Identifiable {
    var id: String { "\(stageKey)/\(iteration)/\(name)" }
    var stageKey: String
    var iteration: Int
    var name: String
    var type: String
    var sha256: String?
    var bytes: Int?
    var wordCount: Int?
    var value: BighelpJSONValue?

    init?(json: WorkflowJSON) {
        guard let name = WorkflowDecode.string(json["name"], max: 128) else { return nil }
        self.name = name
        stageKey = WorkflowDecode.string(json["stageKey"], max: 64) ?? ""
        iteration = WorkflowDecode.int(json["iteration"]) ?? 1
        type = WorkflowDecode.string(json["type"], max: 32) ?? "text"
        sha256 = WorkflowSHA.valid(WorkflowDecode.string(json["sha256"], max: 64))
        bytes = WorkflowDecode.int(json["bytes"])
        wordCount = WorkflowDecode.int(json["wordCount"])
        value = json["value"]
    }

    init(stageKey: String, iteration: Int, name: String, type: String, sha256: String?, bytes: Int?,
         wordCount: Int?, value: BighelpJSONValue? = nil) {
        self.stageKey = stageKey
        self.iteration = iteration
        self.name = name
        self.type = type
        self.sha256 = sha256
        self.bytes = bytes
        self.wordCount = wordCount
        self.value = value
    }

    var isFile: Bool { type == "markdown_file" && sha256 != nil }
}

/// What a sign-off stage is waiting on: one exact file, the same file one
/// revision earlier, the reviewer's notes and how the run got here.
struct WorkflowSignoff: Equatable, Sendable {
    struct Note: Equatable, Sendable, Identifiable {
        var id: String { "\(severity)/\(text)" }
        var severity: String
        var text: String
        var isMajor: Bool { severity == "major" }
    }

    struct Step: Equatable, Sendable, Identifiable {
        var id: String { "\(stageKey)/\(iteration)/\(index)" }
        var index: Int
        var stageKey: String
        var title: String
        var iteration: Int
        var outcome: String
        var agentID: String?
        var durationMs: Int?
        var notes: [Note]
        var asksForChanges: Bool { ["changes", "changes_requested"].contains(outcome) }
    }

    var stageKey: String
    var artifact: WorkflowOutput
    var previous: WorkflowOutput?
    var reviewDecision: String?
    var reviewNotes: [Note]
    var history: [Step]

    var artifactSHA256: String { artifact.sha256 ?? "" }
    var artifactIteration: Int { artifact.iteration }
    var artifactWords: Int? { artifact.wordCount }
    /// "draft-v2.md": the output's name, its version and a file extension.
    var artifactName: String { Self.fileName(artifact) }

    static func fileName(_ output: WorkflowOutput) -> String {
        if output.name.contains(".") { return output.name }
        return output.iteration > 1 ? "\(output.name)-v\(output.iteration).md" : "\(output.name).md"
    }

    init?(json: WorkflowJSON) {
        guard let artifactJSON = json["artifact"]?.object,
              let artifact = WorkflowOutput(json: artifactJSON.merging(["type": .string("markdown_file")]) { old, _ in old }),
              artifact.sha256 != nil else { return nil }
        stageKey = WorkflowDecode.string(json["stageKey"], max: 64) ?? "signoff"
        self.artifact = artifact
        previous = json["previous"]?.object.flatMap(WorkflowOutput.init(json:)).flatMap { $0.sha256 == nil ? nil : $0 }
        // Either a list of notes, or {decision, notes:[…]}.
        let review = json["reviewNotes"]
        reviewDecision = WorkflowDecode.string(review?.object?["decision"], max: 32)
        reviewNotes = Self.notes(review?.object?["notes"] ?? review)
        history = WorkflowDecode.objects(json["history"], max: 100).enumerated().compactMap { index, step in
            guard let key = WorkflowDecode.string(step["stageKey"], max: 64) else { return nil }
            return Step(index: index, stageKey: key, title: WorkflowDecode.string(step["title"], max: 200) ?? key,
                        iteration: WorkflowDecode.int(step["iteration"]) ?? 1,
                        outcome: WorkflowDecode.string(step["outcome"] ?? step["state"] ?? step["decision"], max: 64) ?? "",
                        agentID: WorkflowDecode.string(step["agentId"], max: 128),
                        durationMs: WorkflowDecode.int(step["durationMs"]),
                        notes: Self.notes(step["notes"]))
        }
    }

    init(stageKey: String, artifact: WorkflowOutput, previous: WorkflowOutput?, reviewDecision: String?,
         reviewNotes: [Note], history: [Step]) {
        self.stageKey = stageKey
        self.artifact = artifact
        self.previous = previous
        self.reviewDecision = reviewDecision
        self.reviewNotes = reviewNotes
        self.history = history
    }

    static func notes(_ value: BighelpJSONValue?) -> [Note] {
        WorkflowDecode.objects(value, max: 20).compactMap { note in
            guard let text = WorkflowDecode.string(note["text"], max: 2_000) else { return nil }
            return Note(severity: WorkflowDecode.string(note["severity"], max: 16) ?? "minor", text: text)
        }
    }
}

struct WorkflowRunDetail: Equatable, Sendable {
    var summary: WorkflowRunSummary
    var inputs: WorkflowJSON
    var stages: [WorkflowRunStage]
    var outputs: [WorkflowOutput]
    var signoff: WorkflowSignoff?
    var tokens: WorkflowTokens
    var allowedActions: Set<String>

    init(json: WorkflowJSON) throws {
        guard let run = json["run"]?.object, let summary = WorkflowRunSummary(json: run) else {
            throw WorkspaceClientError.invalidResponse
        }
        self.summary = summary
        inputs = run["inputs"]?.object ?? [:]
        stages = WorkflowDecode.objects(run["stages"], max: 40).compactMap(WorkflowRunStage.init(json:))
        outputs = WorkflowDecode.objects(run["outputs"], max: 200).compactMap(WorkflowOutput.init(json:))
        signoff = run["signoff"]?.object.flatMap(WorkflowSignoff.init(json:))
        tokens = WorkflowTokens(json: run["tokens"])
        allowedActions = Set(WorkflowDecode.strings(run["allowedActions"], max: 10))
    }

    init(summary: WorkflowRunSummary, inputs: WorkflowJSON, stages: [WorkflowRunStage], outputs: [WorkflowOutput],
         signoff: WorkflowSignoff?, tokens: WorkflowTokens, allowedActions: Set<String>) {
        self.summary = summary
        self.inputs = inputs
        self.stages = stages
        self.outputs = outputs
        self.signoff = signoff
        self.tokens = tokens
        self.allowedActions = allowedActions
    }

    /// The same file one revision earlier, for "Changes from v1".
    func previousVersion(of signoff: WorkflowSignoff) -> WorkflowOutput? {
        if let previous = signoff.previous { return previous }
        let current = signoff.artifact
        return outputs
            .filter { $0.stageKey == current.stageKey && $0.name == current.name && $0.iteration < current.iteration && $0.isFile }
            .max { $0.iteration < $1.iteration }
    }

    /// The reviewer's decision on the file being signed off.
    func reviewDecision(for signoff: WorkflowSignoff) -> String? {
        signoff.reviewDecision ?? outputs.last {
            $0.type == "decision" && $0.iteration == signoff.artifactIteration
        }?.value?.string
    }

    /// How the run got here. The host's own history when it sends one;
    /// otherwise each finished attempt in order. A review before the last
    /// revision asked for changes: that is what started the next one.
    func signoffHistory(for signoff: WorkflowSignoff) -> [WorkflowSignoff.Step] {
        if !signoff.history.isEmpty { return signoff.history }
        // The loop goes back to the stage that writes the file, so a stage after
        // it that ran on an earlier version is the review that sent it back.
        let writer = stages.firstIndex { $0.key == signoff.artifact.stageKey } ?? stages.count
        var steps: [(Date, WorkflowSignoff.Step)] = []
        for (position, stage) in stages.enumerated() where stage.kind == .agent {
            for attempt in stage.attempts where attempt.state == .accepted {
                let sentBack = position > writer && attempt.iteration < signoff.artifactIteration
                let versioned = position >= writer && signoff.artifactIteration > 1
                let title = versioned ? "\(stage.title) v\(attempt.iteration)" : stage.title
                steps.append((attempt.launchedAt ?? .distantPast, WorkflowSignoff.Step(
                    index: 0, stageKey: stage.key, title: sentBack ? "\(title) asked for changes" : title,
                    iteration: attempt.iteration, outcome: sentBack ? "changes" : "passed",
                    agentID: attempt.agentID ?? stage.agentID, durationMs: attempt.durationMs, notes: [])))
            }
        }
        return steps.sorted { $0.0 < $1.0 }.enumerated().map { index, step in
            var value = step.1
            value.index = index
            return value
        }
    }

    /// The approved file of a finished run, for Share and Save to Files.
    var approvedFile: WorkflowOutput? {
        guard summary.state == .succeeded else { return nil }
        if let artifact = signoff?.artifact { return artifact }
        return outputs.filter(\.isFile).max { $0.iteration < $1.iteration }
    }
}

struct WorkflowEvent: Equatable, Sendable, Identifiable {
    var id: Int { seq }
    var seq: Int
    var at: Date?
    var kind: String
    var stageKey: String?
    var attempt: Int?
    var text: String

    init?(json: WorkflowJSON) {
        guard let seq = WorkflowDecode.int(json["seq"]) else { return nil }
        self.seq = seq
        at = WorkflowDecode.date(json["at"])
        kind = WorkflowDecode.string(json["kind"], max: 64) ?? ""
        stageKey = WorkflowDecode.string(json["stageKey"], max: 64)
        attempt = WorkflowDecode.int(json["attempt"])
        text = WorkflowDecode.string(json["text"], max: 300) ?? ""
    }

    init(seq: Int, at: Date?, kind: String, stageKey: String?, attempt: Int?, text: String) {
        self.seq = seq
        self.at = at
        self.kind = kind
        self.stageKey = stageKey
        self.attempt = attempt
        self.text = text
    }
}

struct WorkflowEventPage: Equatable, Sendable {
    var events: [WorkflowEvent]
    var cursor: Int
    var hasMore: Bool

    init(json: WorkflowJSON, after: Int) {
        events = WorkflowDecode.objects(json["events"], max: 200).compactMap(WorkflowEvent.init(json:))
        cursor = WorkflowDecode.int(json["cursor"]) ?? events.map(\.seq).max() ?? after
        hasMore = WorkflowDecode.bool(json["hasMore"]) ?? false
    }

    init(events: [WorkflowEvent], cursor: Int, hasMore: Bool) {
        self.events = events
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

struct WorkflowArtifactChunk: Equatable, Sendable {
    var sha256: String
    var offset: Int
    var total: Int
    var data: Data
    var done: Bool

    init(json: WorkflowJSON) throws {
        guard let sha = WorkflowSHA.valid(WorkflowDecode.string(json["sha256"], max: 64)),
              let offset = WorkflowDecode.int(json["offset"]), offset >= 0,
              let total = WorkflowDecode.int(json["total"]), total >= 0,
              let encoded = WorkflowDecode.string(json["data"], max: 200_000),
              let data = Data(base64Encoded: encoded) else {
            throw WorkspaceClientError.invalidResponse
        }
        sha256 = sha
        self.offset = offset
        self.total = total
        self.data = data
        done = WorkflowDecode.bool(json["done"]) ?? (offset + data.count >= total)
    }

    init(sha256: String, offset: Int, total: Int, data: Data, done: Bool) {
        self.sha256 = sha256
        self.offset = offset
        self.total = total
        self.data = data
        self.done = done
    }
}

struct WorkflowTemplate: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var description: String
    var stageCount: Int

    init?(json: WorkflowJSON) {
        guard let id = WorkflowDecode.string(json["id"] ?? json["templateId"], max: 128) else { return nil }
        self.id = id
        name = WorkflowDecode.string(json["name"], max: 200) ?? id
        description = WorkflowDecode.string(json["description"], max: 1_000) ?? ""
        stageCount = WorkflowDecode.int(json["stageCount"]) ?? 0
    }

    init(id: String, name: String, description: String, stageCount: Int) {
        self.id = id
        self.name = name
        self.description = description
        self.stageCount = stageCount
    }
}

enum WorkflowSHA {
    /// A full lowercase sha256, or nil.
    static func valid(_ value: String?) -> String? {
        guard let value, value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }

    /// "4f1c…9a2e": enough to tell two files apart at a glance.
    static func short(_ value: String) -> String {
        guard value.count > 8 else { return value }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }
}

/// Plain words for the host's codes.
enum WorkflowWords {
    static func problem(_ code: String) -> String {
        switch code {
        case "host_restarted": "The computer restarted during this stage."
        case "coordinator_restarted": "The workflow service restarted during this stage."
        case "revision_limit": "The review asked for more changes than this workflow allows."
        case "timed_out": "The stage ran out of time."
        case "approval_stale": "The file changed after you opened it. Look at it again before you approve."
        case "workflow_archived": "This workflow is archived."
        case "check_failed": "The result didn't pass this workflow's checks."
        case "storage_full": "Your computer is out of room for workflow files."
        case "storage_unavailable", "store_unavailable": "Your computer can't open its workflow files right now."
        case "workflow_not_found", "run_not_found": "This isn't on your computer any more."
        case "queue_full": "Too many runs are waiting to start. Try again when some have finished."
        case "inputs_invalid": "Some of the details for this run aren't right. Check them and try again."
        case "invalid_definition": "Your computer can't use this workflow as it is. Check each stage."
        default: code.hasPrefix("contract_")
            ? "The stage's result didn't match what the next stage needs."
            : code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "2m 41s", "38 min", "1h".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return total % 60 == 0 || total >= 600 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h"
    }

    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 86_400 { return duration(seconds) }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}
