import Foundation

// Dev Factory: coding workflows (schemaVersion 3, `native-workflows-code-v1`). A recipe
// lists git projects; starting it makes one run per project, grouped, and each run works
// in its own worktree (or the project folder), runs commands, waits for your sign-off on
// the changes and opens a pull request. The plugin's contract is its docs/DEV_FACTORY.md.

/// A project a recipe works in: a git repository's top folder on the computer.
struct WorkflowCodeProject: Equatable, Hashable, Sendable, Identifiable {
    var key: String
    var label: String
    /// Absent in the workflow list, which sends only key and label.
    var path: String?
    var id: String { key }

    init(key: String, label: String, path: String?) {
        self.key = key
        self.label = label
        self.path = path
    }

    init?(json: WorkflowJSON) {
        guard let key = WorkflowDecode.string(json["key"], max: 40), !key.isEmpty else { return nil }
        self.key = key
        label = WorkflowDecode.string(json["label"], max: 80) ?? key
        path = WorkflowDecode.string(json["path"], max: 1_024)
    }

    var json: BighelpJSONValue {
        var object: WorkflowJSON = ["key": .string(key), "label": .string(label)]
        if let path { object["path"] = .string(path) }
        return .object(object)
    }

    /// A project key from a name: lowercase letters, digits, `-` and `_`, starting with a letter or digit.
    static func key(for name: String, taken: Set<String>) -> String {
        var key = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        while key.contains("--") { key = key.replacingOccurrences(of: "--", with: "-") }
        key = String(key.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).prefix(36))
        if key.isEmpty { key = "project" }
        var candidate = key
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(key)-\(number)"
            number += 1
        }
        return candidate
    }
}

/// A Dev Factory run's own part of a run summary: its project, its folder, its pull
/// request and, while it waits or stops, why, in one sentence from the computer.
struct WorkflowCodeRun: Equatable, Hashable, Sendable {
    struct Workspace: Equatable, Hashable, Sendable {
        var placement: String
        var path: String
        var branch: String?
        var base: String?
        var isWorktree: Bool { placement == "worktree" }
    }

    struct PullRequest: Equatable, Hashable, Sendable {
        var url: URL
        var number: Int
    }

    var groupID: String
    var project: WorkflowCodeProject
    /// Nil until the run's folder is ready.
    var workspace: Workspace?
    var pullRequest: PullRequest?
    var reason: String?

    init?(json: WorkflowJSON) {
        guard let project = json["project"]?.object.flatMap(WorkflowCodeProject.init(json:)) else { return nil }
        self.project = project
        groupID = WorkflowDecode.string(json["group_id"], max: 64) ?? ""
        workspace = json["workspace"]?.object.flatMap { object in
            guard let path = WorkflowDecode.string(object["path"], max: 1_024) else { return nil }
            return Workspace(placement: WorkflowDecode.string(object["placement"], max: 16) ?? "worktree", path: path,
                             branch: WorkflowDecode.string(object["branch"], max: 256),
                             base: WorkflowDecode.string(object["base"], max: 256))
        }
        pullRequest = json["pull_request"]?.object.flatMap { object in
            guard let raw = WorkflowDecode.string(object["url"], max: 2_048), let url = URL(string: raw),
                  url.scheme == "https", let number = WorkflowDecode.int(object["number"]) else { return nil }
            return PullRequest(url: url, number: number)
        }
        reason = WorkflowDecode.string(json["reason"], max: 1_000)
    }

    init(groupID: String, project: WorkflowCodeProject, workspace: Workspace? = nil, pullRequest: PullRequest? = nil,
         reason: String? = nil) {
        self.groupID = groupID
        self.project = project
        self.workspace = workspace
        self.pullRequest = pullRequest
        self.reason = reason
    }
}

/// A sign-off on a run's changes: what changed since it left its base branch, and the
/// hash of the folder as it is now. Approval binds to that hash, so a folder that
/// changed after you looked is refused and you look again.
struct WorkflowChangesSignoff: Equatable, Sendable {
    var stageKey: String
    var sha256: String
    var files: Int
    var additions: Int
    var deletions: Int
    var branch: String?
    var base: String?
    var reviewNotes: [WorkflowSignoff.Note]

    init?(json: WorkflowJSON) {
        guard let changes = json["changes"]?.object,
              let sha256 = WorkflowSHA.valid(WorkflowDecode.string(json["sha256"], max: 64)) else { return nil }
        stageKey = WorkflowDecode.string(json["stageKey"], max: 64) ?? "review"
        self.sha256 = sha256
        files = max(0, WorkflowDecode.int(changes["files"]) ?? 0)
        additions = max(0, WorkflowDecode.int(changes["additions"]) ?? 0)
        deletions = max(0, WorkflowDecode.int(changes["deletions"]) ?? 0)
        branch = WorkflowDecode.string(changes["branch"], max: 256)
        base = WorkflowDecode.string(changes["base"], max: 256)
        let review = json["reviewNotes"]
        reviewNotes = WorkflowSignoff.notes(review?.object?["notes"] ?? review)
    }

    init(stageKey: String, sha256: String, files: Int, additions: Int, deletions: Int, branch: String?, base: String?) {
        self.stageKey = stageKey
        self.sha256 = sha256
        self.files = files
        self.additions = additions
        self.deletions = deletions
        self.branch = branch
        self.base = base
        reviewNotes = []
    }

    /// "3 files · +21 −18".
    var summary: String {
        "\(files == 1 ? "1 file" : "\(files) files") · +\(additions) −\(deletions)"
    }
}

/// A started recipe: one run per project, under one group.
struct WorkflowCodeStart: Equatable, Sendable {
    var groupID: String
    /// Run IDs with their project keys, in the recipe's project order.
    var runs: [(runID: String, project: String)]
    /// The first run, as `runs/start` always returns.
    var first: WorkflowRunSummary

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.groupID == rhs.groupID && lhs.first == rhs.first
            && lhs.runs.map(\.runID) == rhs.runs.map(\.runID) && lhs.runs.map(\.project) == rhs.runs.map(\.project)
    }

    init(groupID: String, runs: [(runID: String, project: String)], first: WorkflowRunSummary) {
        self.groupID = groupID
        self.runs = runs
        self.first = first
    }

    init(json: WorkflowJSON) throws {
        guard let run = json["run"]?.object, let first = WorkflowRunSummary(json: run) else {
            throw WorkspaceClientError.invalidResponse
        }
        self.first = first
        groupID = WorkflowDecode.string(json["group_id"], max: 64) ?? first.code?.groupID ?? ""
        runs = WorkflowDecode.objects(json["runs"], max: 10).compactMap { item in
            guard let id = WorkflowDecode.string(item["run_id"], max: 128),
                  let project = WorkflowDecode.string(item["project"], max: 40) else { return nil }
            return (id, project)
        }
        if runs.isEmpty { runs = [(first.id, first.code?.project.key ?? "")] }
    }
}

/// One start of a recipe as Dev Factory shows it: its runs, one per project.
struct WorkflowCodeGroup: Identifiable, Equatable {
    var id: String
    var workflowID: String
    var name: String
    var runs: [WorkflowRunSummary]

    var startedAt: Date? { runs.compactMap(\.startedAt).min() }
    var needsYou: Int { runs.filter { $0.state == .waitingForYou || $0.state == .needsAttention }.count }
    var isWorking: Bool { runs.contains { $0.state.isWorking } }

    /// Runs grouped by the start they came from, newest first; each group keeps its project order.
    static func groups(_ runs: [WorkflowRunSummary]) -> [WorkflowCodeGroup] {
        var order: [String] = []
        var byGroup: [String: [WorkflowRunSummary]] = [:]
        for run in runs {
            guard let code = run.code else { continue }
            let key = code.groupID.isEmpty ? run.id : code.groupID
            if byGroup[key] == nil { order.append(key) }
            if byGroup[key]?.contains(where: { $0.id == run.id }) != true { byGroup[key, default: []].append(run) }
        }
        return order.compactMap { key in
            guard let members = byGroup[key], let first = members.first else { return nil }
            return WorkflowCodeGroup(id: key, workflowID: first.workflowID, name: first.workflowName,
                                     runs: members.sorted { $0.number < $1.number })
        }
        .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }
}
