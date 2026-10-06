import CoreGraphics
import Foundation
import SwiftUI

/// How the canvas lines its nodes up. Only `saved` uses (and changes) the places people give
/// nodes; the straight lines are worked out each time, so switching never loses a place.
enum WorkflowArrangement: String, Sendable {
    /// Saved places (`layout`), the rest left to right: the canvas as people arranged it.
    case saved
    /// One column, top to bottom in reading order.
    case column
    /// One row, left to right in reading order: a phone's side-by-side view.
    case row

    var axis: Axis { self == .column ? .vertical : .horizontal }
}

/// Where the canvas draws each node. Saved places (`layout`) win; stages
/// without one are laid out left to right in reading order on a clean grid.
/// Compact widths ignore places and line the stages up top to bottom.
enum WorkflowCanvasLayout {
    static let inputsKey = "inputs"
    static let grid: CGFloat = 20
    static let nodeWidth: CGFloat = 220
    static let columnStep: CGFloat = 300
    static let rowStep: CGFloat = 160
    static let origin = CGPoint(x: 40, y: 60)
    /// The room kept clear around a new node.
    static let clearance: CGFloat = 20
    /// Between two nodes in a column: room for the wire, its label and the End marker.
    static let lineGap: CGFloat = 80

    static func size(_ kind: WorkflowStage.Kind?) -> CGSize {
        CGSize(width: nodeWidth, height: kind == .decision ? 132 : 76)
    }

    /// Compact widths: one line, in list order. Places are ignored there.
    static func compactOrder(_ definition: WorkflowDefinition) -> [String] {
        definition.stages.map(\.key)
    }

    /// Every node's top-left corner in an arrangement. Never changes the saved places.
    static func positions(_ definition: WorkflowDefinition, arrangement: WorkflowArrangement) -> [String: CGPoint] {
        switch arrangement {
        case .saved: positions(definition)
        case .column: lined(definition, axis: .vertical)
        case .row: lined(definition, axis: .horizontal)
        }
    }

    /// Inputs, then every stage in reading order, in one straight line; stages nothing reaches go last.
    static func lined(_ definition: WorkflowDefinition, axis: Axis) -> [String: CGPoint] {
        let graph = definition.graph
        let reached = graph.reachable(from: graph.start)
        let order = graph.readingOrder(start: graph.start)
        let kinds = Dictionary(definition.stages.map { ($0.key, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var result: [String: CGPoint] = [inputsKey: origin]
        var next = axis == .vertical ? origin.y + size(nil).height + lineGap : origin.x + columnStep
        for key in order.filter(reached.contains) + order.filter({ !reached.contains($0) }) {
            if axis == .vertical {
                result[key] = CGPoint(x: origin.x, y: next)
                next += size(kinds[key]).height + lineGap
            } else {
                result[key] = CGPoint(x: next, y: origin.y)
                next += columnStep
            }
        }
        return result
    }

    /// Every node's top-left corner (stages and `inputs`).
    static func positions(_ definition: WorkflowDefinition) -> [String: CGPoint] {
        var result = automatic(definition)
        if let layout = definition.layout {
            if let inputs = layout.inputs { result[inputsKey] = inputs }
            for stage in definition.stages {
                if let saved = layout.stages[stage.key] { result[stage.key] = saved }
            }
        }
        return result
    }

    /// Columns by how far each stage is from the start along the ways on;
    /// stages nothing reaches go in a row underneath.
    static func automatic(_ definition: WorkflowDefinition) -> [String: CGPoint] {
        let graph = definition.graph
        let order = graph.readingOrder(start: graph.start)
        let reached = graph.reachable(from: graph.start)
        var column: [String: Int] = [:]
        if let start = graph.start { column[start] = 1 }
        // A way on to a stage read later moves it right; one back (a loop) doesn't.
        for key in order where reached.contains(key) {
            guard let here = column[key], let next = graph.exits[key]?.primary,
                  let from = order.firstIndex(of: key), let to = order.firstIndex(of: next), to > from else { continue }
            column[next] = max(column[next] ?? 0, here + 1)
        }
        var rows: [Int: Int] = [:]
        var result: [String: CGPoint] = [inputsKey: origin]
        for key in order where reached.contains(key) {
            let col = column[key] ?? 1
            let row = rows[col, default: 0]
            rows[col] = row + 1
            result[key] = point(column: col, row: row)
        }
        let lowest = rows.values.max() ?? 1
        var spare = 1
        for key in order where !reached.contains(key) {
            result[key] = point(column: spare, row: lowest + 1)
            spare += 1
        }
        return result
    }

    /// A free place for a new node after another one: to its right if there's
    /// room, else the nearest free place in that column, on the grid.
    static func place(after anchor: String?, kind: WorkflowStage.Kind, in positions: [String: CGPoint],
                      kinds: [String: WorkflowStage.Kind]) -> CGPoint {
        let base = anchor.flatMap { positions[$0] } ?? positions[inputsKey] ?? origin
        let rects = positions.map { key, point in
            CGRect(origin: point, size: size(key == inputsKey ? nil : kinds[key]))
                .insetBy(dx: -clearance, dy: -clearance)
        }
        let size = size(kind)
        for offset in [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, 6, 7, 8] {
            let candidate = snap(CGPoint(x: base.x + columnStep, y: base.y + CGFloat(offset) * rowStep))
            if !rects.contains(where: { $0.intersects(CGRect(origin: candidate, size: size)) }) {
                return WorkflowLayout.clamped(candidate)
            }
        }
        // Everything near is taken: below everything.
        let bottom = rects.map(\.maxY).max() ?? origin.y
        return WorkflowLayout.clamped(snap(CGPoint(x: base.x + columnStep, y: bottom + clearance)))
    }

    static func snap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x / grid).rounded() * grid, y: (point.y / grid).rounded() * grid)
    }

    /// The rectangle around every node, for Fit.
    static func bounds(_ definition: WorkflowDefinition, arrangement: WorkflowArrangement = .saved) -> CGRect {
        let positions = positions(definition, arrangement: arrangement)
        let kinds = Dictionary(definition.stages.map { ($0.key, $0.kind) }, uniquingKeysWith: { first, _ in first })
        return positions.reduce(CGRect.null) { rect, entry in
            rect.union(CGRect(origin: entry.value, size: size(entry.key == inputsKey ? nil : kinds[entry.key])))
        }
    }

    private static func point(column: Int, row: Int) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(column) * columnStep, y: origin.y + CGFloat(row) * rowStep)
    }
}
