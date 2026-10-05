import Foundation

// How a definition's stages connect (schemaVersion 2): each stage goes to its
// `next` (absent: the following stage, null: the end), a decision to its
// `pass` and back to `changes.goTo`. The start is the first stage. Editing
// works on these connections; the stored definition keeps them in as few
// explicit `next`s as it can, in reading order.

/// One way out of a stage.
enum WorkflowPort: String, Hashable, Sendable {
    /// Every stage but a decision.
    case next
    /// A decision's way on.
    case pass
    /// A decision's way back for changes.
    case changes
}

struct WorkflowEdge: Hashable, Sendable {
    var from: String
    var port: WorkflowPort
    /// Nil: the flow ends here.
    var to: String?
}

/// Where each stage leads, read from a definition.
struct WorkflowFlowGraph: Equatable, Sendable {
    struct Exits: Equatable, Sendable {
        /// `next` for most stages, `pass` for a decision. Nil ends the flow.
        var primary: String?
        /// A decision's `changes.goTo`.
        var changes: String?
    }

    let keys: [String]
    let kinds: [String: WorkflowStage.Kind]
    var exits: [String: Exits]

    init(_ definition: WorkflowDefinition) {
        let stages = definition.stages
        keys = stages.map(\.key)
        kinds = Dictionary(stages.map { ($0.key, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var exits: [String: Exits] = [:]
        for (index, stage) in stages.enumerated() {
            let following = stages.indices.contains(index + 1) ? stages[index + 1].key : nil
            if stage.kind == .decision {
                let pass = stage.pass == nil || stage.pass == "next" ? following : stage.pass
                exits[stage.key] = Exits(primary: pass, changes: stage.changesGoTo)
            } else {
                switch stage.next {
                case .following: exits[stage.key] = Exits(primary: following)
                case .end: exits[stage.key] = Exits(primary: nil)
                case .stage(let target): exits[stage.key] = Exits(primary: target)
                }
            }
        }
        self.exits = exits
    }

    var start: String? { keys.first }

    func target(_ key: String, _ port: WorkflowPort) -> String? {
        port == .changes ? exits[key]?.changes : exits[key]?.primary
    }

    /// Every connection, in stage order.
    var edges: [WorkflowEdge] {
        keys.flatMap { key -> [WorkflowEdge] in
            guard let exit = exits[key] else { return [] }
            if kinds[key] == .decision {
                return [WorkflowEdge(from: key, port: .pass, to: exit.primary),
                        WorkflowEdge(from: key, port: .changes, to: exit.changes)]
            }
            return [WorkflowEdge(from: key, port: .next, to: exit.primary)]
        }
    }

    /// Stages from the start, following each stage's way on before its way
    /// back; stages nothing reaches come last, in list order.
    func readingOrder(start: String?) -> [String] {
        var order: [String] = []
        var seen = Set<String>()
        func visit(_ key: String) {
            guard keys.contains(key), seen.insert(key).inserted else { return }
            order.append(key)
            if let primary = exits[key]?.primary { visit(primary) }
            if let changes = exits[key]?.changes { visit(changes) }
        }
        if let start { visit(start) }
        for key in keys { visit(key) }
        return order
    }

    /// Stages the start reaches by any connection; with `waysOnOnly`, as the
    /// host checks a flow, going back (a decision's changes) doesn't count.
    func reachable(from start: String?, avoiding avoided: String? = nil, waysOnOnly: Bool = false) -> Set<String> {
        var seen = Set<String>()
        var stack = [start].compactMap { $0 }.filter { $0 != avoided }
        while let key = stack.popLast() {
            guard keys.contains(key), seen.insert(key).inserted else { continue }
            let ways = waysOnOnly ? [exits[key]?.primary] : [exits[key]?.primary, exits[key]?.changes]
            for next in ways.compactMap({ $0 }) where next != avoided {
                stack.append(next)
            }
        }
        return seen
    }

    /// Stages on a loop made only of ways on (a decision's changes may loop; nothing else may).
    var stagesOnCycles: Set<String> {
        var onCycle = Set<String>()
        for key in keys {
            var seen = Set<String>()
            var current = exits[key]?.primary
            while let step = current, keys.contains(step), seen.insert(step).inserted {
                if step == key {
                    onCycle.formUnion(seen)
                    break
                }
                current = exits[step]?.primary
            }
        }
        return onCycle
    }

    // MARK: Problems the canvas shows before the host answers

    /// The graph's own problems, with the host's codes. The host checks the
    /// rest (roles, instructions, outputs) and has the last word when it answers.
    func issues(_ definition: WorkflowDefinition) -> [WorkflowValidation.Issue] {
        guard !keys.isEmpty else {
            return [.init(stageKey: nil, code: "no_stages", message: WorkflowWords.issue("no_stages"), isError: true)]
        }
        func title(_ key: String) -> String { definition.stage(key)?.title ?? key }
        func issue(_ code: String, _ key: String?) -> WorkflowValidation.Issue {
            .init(stageKey: key, code: code, message: WorkflowWords.issue(code, stage: key.map(title)), isError: true)
        }
        var issues: [WorkflowValidation.Issue] = []
        let known = Set(keys)
        for edge in edges {
            if let to = edge.to, !known.contains(to) {
                issues.append(issue("next_unknown", edge.from))
            }
        }
        // Like the host: only ways on reach a stage; going back for changes doesn't.
        let reached = reachable(from: start, waysOnOnly: true)
        for key in keys where !reached.contains(key) {
            issues.append(issue("unreachable_stage", key))
        }
        let cycles = stagesOnCycles
        for key in keys where cycles.contains(key) {
            issues.append(issue("cycle", key))
        }
        // "Earlier" goes by the flow, not the list: the stage changes go back to must lead to the decision again.
        for key in keys where kinds[key] == .decision {
            guard let goTo = exits[key]?.changes else {
                issues.append(issue("goto_not_earlier", key))
                continue
            }
            if known.contains(goTo), goTo == key || !reachable(from: goTo, waysOnOnly: true).contains(key) {
                issues.append(issue("goto_not_earlier", key))
            }
        }
        if !reached.contains(where: { exits[$0]?.primary == nil }) {
            issues.append(issue("no_end", nil))
        }
        // What a stage reads (its uses, a check's rules, a decision's result,
        // a sign-off's file) must be made on every way to it.
        for stage in definition.stages where reached.contains(stage.key) {
            let reads = stage.uses + stage.rules.map(\.of) + [stage.on, stage.file].compactMap { $0 }
            let sources = Set(reads.compactMap { read -> String? in
                let head = read.split(separator: ".", maxSplits: 1).first.map(String.init)
                return head == "inputs" ? nil : head
            })
            for source in sources where source != stage.key {
                if !known.contains(source)
                    || reachable(from: start, avoiding: source, waysOnOnly: true).contains(stage.key) {
                    issues.append(issue("uses_not_before", stage.key))
                    break
                }
            }
        }
        return issues
    }

    /// Codes this graph decides; the host's answer for them is replaced by the canvas's own while editing.
    static let graphCodes: Set<String> = ["unreachable_stage", "cycle", "goto_not_earlier", "next_unknown",
                                          "uses_not_before", "no_end", "no_stages"]
}

// MARK: - Editing the connections

extension WorkflowDefinition {
    var graph: WorkflowFlowGraph { WorkflowFlowGraph(self) }

    /// Points one way out of a stage at another stage (nil: the flow ends; only `next`).
    mutating func connect(_ from: String, _ port: WorkflowPort, to target: String?) {
        var graph = graph
        guard graph.exits[from] != nil, target != from || port == .changes else { return }
        if port == .changes {
            graph.exits[from]?.changes = target
        } else {
            graph.exits[from]?.primary = target
        }
        apply(graph, start: graph.start)
    }

    /// Makes a stage the first one: Inputs lead to it.
    mutating func makeStart(_ key: String) {
        let graph = graph
        guard graph.keys.contains(key) else { return }
        apply(graph, start: key)
    }

    /// Adds a stage after another one, on its way on (nil: at the end of the flow).
    mutating func insert(_ stage: WorkflowStage, after key: String?) {
        var graph = graph
        let anchor = key.flatMap { graph.keys.contains($0) ? $0 : nil } ?? lastEnd(graph)
        stages.append(stage)
        graph = WorkflowFlowGraph.adding(stage, to: graph)
        if let anchor {
            let onward = graph.exits[anchor]?.primary
            graph.exits[stage.key]?.primary = onward
            graph.exits[anchor]?.primary = stage.key
        } else {
            graph.exits[stage.key]?.primary = nil
        }
        apply(graph, start: anchor == nil && graph.keys.count == 1 ? stage.key : graph.start)
    }

    /// Adds a stage before the first one: Inputs lead to it, and it goes on to the old first.
    mutating func insertFirst(_ stage: WorkflowStage) {
        var graph = graph
        let oldStart = graph.start
        stages.append(stage)
        graph = WorkflowFlowGraph.adding(stage, to: graph)
        graph.exits[stage.key]?.primary = oldStart
        apply(graph, start: stage.key)
    }

    /// Takes a stage out and joins the stages around it. Changes that went back to it go nowhere until changed.
    mutating func remove(_ key: String) {
        var graph = graph
        guard graph.keys.contains(key) else { return }
        let onward = graph.exits[key]?.primary
        splice(out: key, onward: onward, in: &graph)
        let start = graph.start == key ? onward ?? graph.keys.first { $0 != key } : graph.start
        stages.removeAll { $0.key == key }
        graph.exits[key] = nil
        for other in graph.keys where graph.exits[other]?.changes == key { graph.exits[other]?.changes = nil }
        apply(graph, start: start)
    }

    /// Moves a stage to another place in the list: the stages around its old
    /// place join up, and it goes on from the stage now above it.
    mutating func move(_ key: String, toIndex index: Int) {
        var graph = graph
        guard let from = graph.keys.firstIndex(of: key) else { return }
        var order = graph.keys
        order.remove(at: from)
        let index = min(max(index, 0), order.count)
        guard index != from else { return }
        let onward = graph.exits[key]?.primary
        let oldStart = graph.start
        splice(out: key, onward: onward, in: &graph)
        let start: String?
        if index == 0 {
            graph.exits[key]?.primary = order.first
            start = key
        } else {
            let above = order[index - 1]
            let aboveOnward = graph.exits[above]?.primary
            graph.exits[key]?.primary = aboveOnward
            graph.exits[above]?.primary = key
            start = oldStart == key ? order.first : oldStart
        }
        apply(graph, start: start, preferredOrder: order.inserting(key, at: index))
    }

    /// The last stage in reading order whose flow ends, else the last stage.
    private func lastEnd(_ graph: WorkflowFlowGraph) -> String? {
        let order = graph.readingOrder(start: graph.start)
        return order.last { graph.exits[$0]?.primary == nil } ?? order.last
    }

    private func splice(out key: String, onward: String?, in graph: inout WorkflowFlowGraph) {
        for other in graph.keys where other != key && graph.exits[other]?.primary == key {
            graph.exits[other]?.primary = onward == other ? nil : onward
        }
    }

    /// Writes the connections back: stages in reading order, then each `next`
    /// or `pass` only where it isn't simply the following stage.
    private mutating func apply(_ graph: WorkflowFlowGraph, start: String?, preferredOrder: [String]? = nil) {
        var reading = graph
        if let preferredOrder { reading = WorkflowFlowGraph.reordered(graph, preferredOrder) }
        let order = reading.readingOrder(start: start)
        let byKey = Dictionary(stages.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [WorkflowStage] = []
        for (index, key) in order.enumerated() {
            guard var stage = byKey[key], let exit = graph.exits[key] else { continue }
            let following = order.indices.contains(index + 1) ? order[index + 1] : nil
            if stage.kind == .decision {
                stage.pass = exit.primary == nil || exit.primary == following ? "next" : exit.primary
                stage.changesGoTo = exit.changes
            } else if exit.primary == following {
                stage.next = .following
            } else if let target = exit.primary {
                stage.next = .stage(target)
            } else {
                stage.next = .end
            }
            result.append(stage)
        }
        stages = result
        if result.contains(where: { $0.next != .following || ($0.kind == .decision && $0.pass != "next") }) {
            schemaVersion = max(schemaVersion, 2)
        }
    }
}

private extension WorkflowFlowGraph {
    static func adding(_ stage: WorkflowStage, to graph: WorkflowFlowGraph) -> WorkflowFlowGraph {
        var value = graph
        value = WorkflowFlowGraph(keys: graph.keys + [stage.key],
                                  kinds: graph.kinds.merging([stage.key: stage.kind]) { $1 },
                                  exits: graph.exits.merging([stage.key: Exits(primary: nil, changes: stage.changesGoTo)]) { $1 })
        return value
    }

    /// The same connections, with stages nothing reaches kept in the order given.
    static func reordered(_ graph: WorkflowFlowGraph, _ order: [String]) -> WorkflowFlowGraph {
        WorkflowFlowGraph(keys: order.filter(graph.keys.contains), kinds: graph.kinds, exits: graph.exits)
    }

    init(keys: [String], kinds: [String: WorkflowStage.Kind], exits: [String: Exits]) {
        self.keys = keys
        self.kinds = kinds
        self.exits = exits
    }
}

private extension Array {
    func inserting(_ element: Element, at index: Int) -> [Element] {
        var copy = self
        copy.insert(element, at: index)
        return copy
    }
}
