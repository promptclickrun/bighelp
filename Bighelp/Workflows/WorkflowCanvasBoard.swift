import SwiftUI
import UniformTypeIdentifiers

/// Where ports and wires sit on a node, in canvas points.
enum WorkflowCanvasGeometry {
    /// A decision's title row, then one row for each way out.
    static let decisionHeader: CGFloat = 52
    static let decisionRow: CGFloat = 40

    static func outPort(_ port: WorkflowPort, origin: CGPoint, kind: WorkflowStage.Kind?) -> CGPoint {
        let size = WorkflowCanvasLayout.size(kind)
        guard kind == .decision else { return CGPoint(x: origin.x + size.width, y: origin.y + size.height / 2) }
        let row = port == .changes ? 1 : 0
        return CGPoint(x: origin.x + size.width,
                       y: origin.y + decisionHeader + decisionRow * CGFloat(row) + decisionRow / 2)
    }

    static func inPort(origin: CGPoint, kind: WorkflowStage.Kind?) -> CGPoint {
        let size = WorkflowCanvasLayout.size(kind)
        return CGPoint(x: origin.x, y: origin.y + (kind == .decision ? decisionHeader / 2 : size.height / 2))
    }

    /// A smooth curve from a way out to a way in. One that goes back swings
    /// under both nodes, so a loop reads as a loop.
    static func wire(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        if end.x >= start.x + 40 {
            let pull = max(60, (end.x - start.x) / 2)
            path.addCurve(to: end, control1: CGPoint(x: start.x + pull, y: start.y),
                          control2: CGPoint(x: end.x - pull, y: end.y))
        } else {
            let drop = max(start.y, end.y) + 110
            path.addCurve(to: end, control1: CGPoint(x: start.x + 140, y: drop),
                          control2: CGPoint(x: end.x - 140, y: drop))
        }
        return path
    }

    /// The middle of a wire, for its label.
    static func middle(from start: CGPoint, to end: CGPoint) -> CGPoint {
        if end.x >= start.x + 40 { return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
        return CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + 82)
    }
}

/// The free canvas at regular width (iPad, Mac, Vision Pro): a dotted grid
/// you pan and zoom, nodes where `layout` puts them, and curved wires from
/// each way out to the next stage's way in. With `native-workflows-edit-v1`:
/// touch and hold a node to move it (its menu goes away once it moves; on
/// the Mac just drag it), and drag a port or a wire's end to another node.
struct WorkflowCanvasBoard: View {
    @Bindable var model: WorkflowEditorModel
    let context: WorkflowsContext
    @Binding var selected: String?
    let edit: (WorkflowStage) -> Void
    let add: (WorkflowStage.Kind, String?) -> Void
    let editInputs: () -> Void

    @State private var scale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var zoomStart: (scale: CGFloat, pan: CGSize)?
    @State private var viewSize: CGSize = .zero
    @State private var didFit = false
    /// The node being dragged, the drag's grip on it, and where it is now.
    @State private var moving: Moving?
    @State private var draggingKey: String?
    @State private var wire: LiveWire?
    @BighelpThemeReader private var theme

    static let space = "workflows.canvas.space"
    private static let scales: ClosedRange<CGFloat> = 0.35...2

    private struct Moving: Equatable {
        var key: String
        var grip: CGSize
        var origin: CGPoint
    }

    private struct LiveWire: Equatable {
        var from: String
        var port: WorkflowPort
        var point: CGPoint
        /// Dragged from a wire's end: what happens to it if dropped on nothing.
        var detaches: Bool
    }

    private struct Handle: Identifiable {
        enum Kind: Equatable { case out(WorkflowPort), into }
        var id: String { kind == .into ? "in.\(key)" : "out.\(key).\(port.rawValue)" }
        var key: String
        var kind: Kind
        var port: WorkflowPort { if case .out(let port) = kind { port } else { .next } }
        var point: CGPoint
        var target: String?
    }

    private var definition: WorkflowDefinition? { model.definition }
    private var editable: Bool { model.canEditFlow }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                WorkflowDotGrid(scale: scale, pan: pan)
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture { selected = nil }
                    .accessibilityHidden(true)
                if let definition {
                    let positions = positions(definition)
                    nodesLayer(definition, positions: positions)
                        .scaleEffect(scale, anchor: .topLeading)
                        .offset(pan)
                    if editable { handlesLayer(definition, positions: positions) }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(zoomGesture)
            .onDrop(of: [UTType.utf8PlainText], delegate: WorkflowNodeDrop(
                isActive: { draggingKey != nil && editable },
                update: { dragUpdate($0) }, drop: { dragDrop($0) }, exit: { moving = nil }))
            .onAppear {
                viewSize = proxy.size
                fitOnce()
            }
            .onChange(of: proxy.size) { _, size in
                viewSize = size
                fitOnce()
            }
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .bottomLeading) { zoomControls.padding(BighelpTokens.space16) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflows.canvas.board")
    }

    // MARK: Nodes and wires

    private func positions(_ definition: WorkflowDefinition) -> [String: CGPoint] {
        var positions = WorkflowCanvasLayout.positions(definition)
        if let moving { positions[moving.key] = moving.origin }
        return positions
    }

    private func kind(_ key: String) -> WorkflowStage.Kind? {
        key == WorkflowCanvasLayout.inputsKey ? nil : definition?.stage(key)?.kind
    }

    private func nodesLayer(_ definition: WorkflowDefinition, positions: [String: CGPoint]) -> some View {
        let graph = definition.graph
        let issues = Set(model.issues.filter(\.isError).compactMap(\.stageKey))
        return ZStack(alignment: .topLeading) {
            wires(definition, graph: graph, positions: positions)
            inputsNode(definition)
                .offset(x: positions[WorkflowCanvasLayout.inputsKey]?.x ?? 0,
                        y: positions[WorkflowCanvasLayout.inputsKey]?.y ?? 0)
            ForEach(definition.stages) { stage in
                let origin = positions[stage.key] ?? .zero
                node(stage, graph: graph, hasIssue: issues.contains(stage.key), origin: origin)
                    .offset(x: origin.x, y: origin.y)
                    .zIndex(moving?.key == stage.key ? 2 : selected == stage.key ? 1 : 0)
            }
            if let wire, let origin = positions[wire.from] {
                WorkflowCanvasGeometry.wire(
                    from: WorkflowCanvasGeometry.outPort(wire.port, origin: origin, kind: kind(wire.from)), to: wire.point)
                .stroke(theme.action, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func wires(_ definition: WorkflowDefinition, graph: WorkflowFlowGraph,
                       positions: [String: CGPoint]) -> some View {
        let edges = [WorkflowEdge(from: WorkflowCanvasLayout.inputsKey, port: .next, to: graph.start)] + graph.edges
        ForEach(edges, id: \.self) { edge in
            if let to = edge.to, let fromOrigin = positions[edge.from], let toOrigin = positions[to],
               !(wire?.from == edge.from && wire?.port == edge.port && wire?.detaches == true) {
                let start = WorkflowCanvasGeometry.outPort(edge.port, origin: fromOrigin, kind: kind(edge.from))
                let end = WorkflowCanvasGeometry.inPort(origin: toOrigin, kind: kind(to))
                let lit = selected != nil && (selected == edge.from || selected == to)
                let color = edge.port == .changes ? BighelpTokens.Palette.gold : lit ? theme.action : theme.secondaryText
                WorkflowCanvasGeometry.wire(from: start, to: end)
                    .stroke(color.opacity(lit || edge.port == .changes ? 1 : 0.7),
                            style: StrokeStyle(lineWidth: lit ? 2.5 : 1.75, lineCap: .round,
                                               dash: edge.port == .changes ? [6, 5] : []))
                    .allowsHitTesting(false)
                arrow(at: end, color: color)
                if edge.port != .next {
                    wireLabel(edge, definition: definition)
                        .position(WorkflowCanvasGeometry.middle(from: start, to: end))
                }
            }
        }
        // Where the flow ends.
        ForEach(graph.keys.filter { graph.exits[$0]?.primary == nil }, id: \.self) { key in
            if let origin = positions[key] {
                let port = WorkflowCanvasGeometry.outPort(kind(key) == .decision ? .pass : .next, origin: origin,
                                                          kind: kind(key))
                Text("End")
                    .font(.bighelp(.caption2).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, BighelpTokens.space8)
                    .padding(.vertical, 3)
                    .background(theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.border))
                    .fixedSize()
                    .position(x: port.x + 36, y: port.y)
                    .allowsHitTesting(false)
            }
        }
    }

    private func arrow(at point: CGPoint, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: point.x - 1, y: point.y))
            path.addLine(to: CGPoint(x: point.x - 9, y: point.y - 5))
            path.addLine(to: CGPoint(x: point.x - 9, y: point.y + 5))
            path.closeSubpath()
        }
        .fill(color)
        .allowsHitTesting(false)
    }

    private func wireLabel(_ edge: WorkflowEdge, definition: WorkflowDefinition) -> some View {
        let changes = edge.port == .changes
        let rounds = definition.stage(edge.from)?.changesMaxRevisions ?? definition.maxRevisions
        return Text(changes ? "changes · max \(rounds)" : "pass")
            .font(.bighelp(.caption2).monospaced())
            .foregroundStyle(changes ? BighelpTokens.Palette.gold : theme.secondaryText)
            .padding(.horizontal, BighelpTokens.space8)
            .padding(.vertical, 2)
            .background(theme.canvas, in: Capsule())
            .overlay(Capsule().strokeBorder(changes ? BighelpTokens.Palette.gold.opacity(0.5) : theme.border))
            .fixedSize()
            .allowsHitTesting(false)
    }

    private func inputsNode(_ definition: WorkflowDefinition) -> some View {
        let size = WorkflowCanvasLayout.size(nil)
        let fields = definition.inputs.count == 1 ? "1 field" : "\(definition.inputs.count) fields"
        return WorkflowCanvasCard(title: "Inputs", detail: definition.inputs.isEmpty ? "No fields yet" : fields,
                                  kind: nil, isSelected: false, hasIssue: false, isDashed: false)
            .frame(width: size.width, height: size.height)
            .contentShape(RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .onTapGesture { editInputs() }
            .modifier(WorkflowNodeDragSource(key: WorkflowCanvasLayout.inputsKey, enabled: editable) {
                draggingKey = WorkflowCanvasLayout.inputsKey
            })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Inputs, \(fields)")
            .accessibilityValue(positionValue(WorkflowCanvasLayout.inputsKey))
            .accessibilityIdentifier("workflows.canvas.node.inputs")
    }

    private func node(_ stage: WorkflowStage, graph: WorkflowFlowGraph, hasIssue: Bool, origin: CGPoint) -> some View {
        let size = WorkflowCanvasLayout.size(stage.kind)
        return WorkflowCanvasCard(title: stage.title, detail: detail(stage), kind: stage.kind,
                                  isSelected: selected == stage.key, hasIssue: hasIssue,
                                  isDashed: needsAgent(stage),
                                  rounds: stage.changesMaxRevisions ?? definition?.maxRevisions)
            .frame(width: size.width, height: size.height)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .onTapGesture { selected = stage.key }
            .contextMenu { nodeMenu(stage, graph: graph) }
            .modifier(WorkflowNodeDragSource(key: stage.key, enabled: editable) { draggingKey = stage.key })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(stage.title), \(stage.kind.title)\(hasIssue ? ", needs fixing" : "")")
            .accessibilityValue(positionValue(stage.key))
            .accessibilityIdentifier("workflows.canvas.node.\(stage.key)")
    }

    /// An agent stage, or an agent of a parallel block, that no agent does yet.
    private func needsAgent(_ stage: WorkflowStage) -> Bool {
        ([stage] + stage.branches).contains { $0.kind == .agent && model.agentID(for: $0.role) == nil }
    }

    /// "x,y": the node's saved place, so tests and VoiceOver can tell it moved.
    private func positionValue(_ key: String) -> String {
        guard let definition, let point = WorkflowCanvasLayout.positions(definition)[key] else { return "" }
        return "\(Int(point.x)),\(Int(point.y))"
    }

    private func detail(_ stage: WorkflowStage) -> String {
        switch stage.kind {
        case .agent: context.agentName(model.agentID(for: stage.role)) ?? definition?.role(stage.role)?.label ?? "No agent yet"
        case .check: stage.rules.count == 1 ? "1 rule" : "\(stage.rules.count) rules"
        case .decision: stage.sources.count > 1 ? "\(stage.sources.count) verdicts" : stage.on ?? ""
        case .signoff: "You approve the file"
        case .parallel: stage.subtitle { context.agentName(model.agentID(for: $0)) }
        case .unknown: ""
        }
    }

    @ViewBuilder
    private func nodeMenu(_ stage: WorkflowStage, graph: WorkflowFlowGraph) -> some View {
        Button("Edit", systemImage: "pencil") { edit(stage) }
        Menu("Add a stage after", systemImage: "plus") {
            WorkflowAddStageButtons(parallel: model.canParallel) { add($0, stage.key) }
        }
        if editable, stage.kind != .decision, graph.exits[stage.key]?.primary != nil {
            Button("End the flow here", systemImage: "stop.circle") { model.connect(stage.key, .next, to: nil) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
            if selected == stage.key { selected = nil }
            model.deleteStage(stage.key)
            Task { await model.save() }
        }
    }

    // MARK: Ports (drawn at screen size, so they stay easy to grab at any zoom)

    private func handles(_ definition: WorkflowDefinition, positions: [String: CGPoint]) -> [Handle] {
        let graph = definition.graph
        func screen(_ point: CGPoint) -> CGPoint {
            CGPoint(x: pan.width + point.x * scale, y: pan.height + point.y * scale)
        }
        var handles: [Handle] = []
        if let origin = positions[WorkflowCanvasLayout.inputsKey] {
            handles.append(Handle(key: WorkflowCanvasLayout.inputsKey, kind: .out(.next),
                                  point: screen(WorkflowCanvasGeometry.outPort(.next, origin: origin, kind: nil)),
                                  target: graph.start))
        }
        for stage in definition.stages {
            guard let origin = positions[stage.key] else { continue }
            let ports: [WorkflowPort] = stage.kind == .decision ? [.pass, .changes] : [.next]
            for port in ports {
                handles.append(Handle(key: stage.key, kind: .out(port),
                                      point: screen(WorkflowCanvasGeometry.outPort(port, origin: origin, kind: stage.kind)),
                                      target: graph.target(stage.key, port)))
            }
            handles.append(Handle(key: stage.key, kind: .into,
                                  point: screen(WorkflowCanvasGeometry.inPort(origin: origin, kind: stage.kind)),
                                  target: nil))
        }
        return handles
    }

    private func handlesLayer(_ definition: WorkflowDefinition, positions: [String: CGPoint]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(handles(definition, positions: positions)) { handle in
                portDot(handle)
                    .position(handle.point)
            }
        }
    }

    private func portDot(_ handle: Handle) -> some View {
        let tint = handle.port == .changes ? BighelpTokens.Palette.gold : theme.primaryText
        let isOut = handle.kind != .into
        return Circle()
            .fill(isOut ? tint : theme.surface)
            .overlay(Circle().strokeBorder(isOut ? theme.surface : tint.opacity(0.8), lineWidth: 2))
            .frame(width: 12, height: 12)
            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
            .contentShape(Circle())
            .bighelpPointer()
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                .onChanged { value in dragWire(handle, to: value.location) }
                .onEnded { value in finishWire(at: contentPoint(value.location)) })
            .accessibilityElement()
            .accessibilityLabel(portLabel(handle))
            .accessibilityValue(handle.kind == .into ? "" : handle.target ?? "end")
            .accessibilityIdentifier(handle.kind == .into ? "workflows.canvas.in.\(handle.key)"
                                     : "workflows.canvas.port.\(handle.key).\(handle.port.rawValue)")
    }

    private func portLabel(_ handle: Handle) -> String {
        let name = handle.key == WorkflowCanvasLayout.inputsKey ? "Inputs" : definition?.stage(handle.key)?.title ?? handle.key
        switch handle.kind {
        case .into: return "Way into \(name)"
        case .out(.pass): return "\(name), pass"
        case .out(.changes): return "\(name), changes"
        case .out: return "Way out of \(name)"
        }
    }

    private func dragWire(_ handle: Handle, to location: CGPoint) {
        let point = contentPoint(location)
        if wire != nil {
            wire?.point = point
            return
        }
        switch handle.kind {
        case .out(let port):
            wire = LiveWire(from: handle.key, port: port, point: point, detaches: false)
        case .into:
            // A wire's end: pick up the one coming in (the selected node's, if it has one).
            guard let graph = definition?.graph else { return }
            var incoming = graph.edges.filter { $0.to == handle.key }
            if graph.start == handle.key {
                incoming.append(WorkflowEdge(from: WorkflowCanvasLayout.inputsKey, port: .next, to: handle.key))
            }
            guard let edge = incoming.first(where: { $0.from == selected }) ?? incoming.first else { return }
            wire = LiveWire(from: edge.from, port: edge.port, point: point, detaches: true)
        }
    }

    private func finishWire(at point: CGPoint) {
        defer { wire = nil }
        guard let wire, let definition else { return }
        let positions = positions(definition)
        let target = definition.stages.last { stage in
            guard stage.key != wire.from || wire.port == .changes, let origin = positions[stage.key] else { return false }
            return CGRect(origin: origin, size: WorkflowCanvasLayout.size(stage.kind)).insetBy(dx: -12, dy: -12)
                .contains(point)
        }
        if let target {
            model.connect(wire.from, wire.port, to: target.key)
        } else if wire.detaches, wire.port == .next, wire.from != WorkflowCanvasLayout.inputsKey {
            // A wire's end let go over nothing: the flow ends there.
            model.connect(wire.from, .next, to: nil)
        }
    }

    // MARK: Moving a node (drag and drop, so the long-press menu hands over to it)

    private func contentPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: (location.x - pan.width) / scale, y: (location.y - pan.height) / scale)
    }

    private func dragUpdate(_ location: CGPoint) {
        guard let key = draggingKey, let definition else { return }
        let point = contentPoint(location)
        if moving?.key == key, let grip = moving?.grip {
            moving?.origin = CGPoint(x: point.x - grip.width, y: point.y - grip.height)
            return
        }
        let origin = WorkflowCanvasLayout.positions(definition)[key] ?? point
        let size = WorkflowCanvasLayout.size(kind(key))
        let grip = CGSize(width: min(max(point.x - origin.x, 0), size.width),
                          height: min(max(point.y - origin.y, 0), size.height))
        moving = Moving(key: key, grip: grip, origin: CGPoint(x: point.x - grip.width, y: point.y - grip.height))
    }

    private func dragDrop(_ location: CGPoint) -> Bool {
        dragUpdate(location)
        defer {
            moving = nil
            draggingKey = nil
        }
        guard let moving else { return false }
        model.place(moving.key, at: moving.origin)
        return true
    }

    // MARK: Pan and zoom

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = panStart ?? pan
                panStart = start
                pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? (scale, pan)
                zoomStart = start
                zoom(to: start.scale * value.magnification, around: value.startLocation, from: start)
            }
            .onEnded { _ in zoomStart = nil }
    }

    /// Zooms keeping the point under the fingers (or the middle) where it is.
    private func zoom(to target: CGFloat, around anchor: CGPoint, from start: (scale: CGFloat, pan: CGSize)) {
        let next = min(max(target, Self.scales.lowerBound), Self.scales.upperBound)
        let content = CGPoint(x: (anchor.x - start.pan.width) / start.scale, y: (anchor.y - start.pan.height) / start.scale)
        scale = next
        pan = CGSize(width: anchor.x - content.x * next, height: anchor.y - content.y * next)
    }

    private func step(_ factor: CGFloat) {
        withAnimation(.snappy) {
            zoom(to: scale * factor, around: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2), from: (scale, pan))
        }
    }

    private func fitOnce() {
        guard !didFit, definition != nil, viewSize.width > 0 else { return }
        didFit = true
        fit()
    }

    /// Shows every node, at most a little bigger than life.
    private func fit() {
        guard let definition, viewSize.width > 0, viewSize.height > 0 else { return }
        // Room on the sides for the End marker after the last node.
        let bounds = WorkflowCanvasLayout.bounds(definition).insetBy(dx: -72, dy: -72)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
        let next = min(max(min(viewSize.width / bounds.width, viewSize.height / bounds.height), Self.scales.lowerBound), 1.2)
        scale = next
        pan = CGSize(width: (viewSize.width - bounds.width * next) / 2 - bounds.minX * next,
                     height: (viewSize.height - bounds.height * next) / 2 - bounds.minY * next)
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            zoomButton("plus.magnifyingglass", "Zoom in", "workflows.canvas.zoom-in") { step(1.25) }
            zoomButton("minus.magnifyingglass", "Zoom out", "workflows.canvas.zoom-out") { step(0.8) }
            zoomButton("arrow.up.left.and.down.right.magnifyingglass", "Fit", "workflows.canvas.fit") {
                withAnimation(.snappy) { fit() }
            }
        }
        .padding(.horizontal, BighelpTokens.space4)
        .bighelpNavigationGlass(in: Capsule())
    }

    private func zoomButton(_ symbol: String, _ label: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(Rectangle())
        }
        .bighelpPlainButtonStyle()
        .bighelpIconLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// One node: a rounded card with the stage's icon, title and one line under it.
/// A decision lists its two ways out (pass, changes) as rows, each with its port.
struct WorkflowCanvasCard: View {
    let title: String
    let detail: String
    let kind: WorkflowStage.Kind?
    let isSelected: Bool
    let hasIssue: Bool
    let isDashed: Bool
    var rounds: Int?
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: BighelpTokens.space12) {
                if let kind {
                    WorkflowStageIcon(kind: kind, size: 36, isDashed: isDashed)
                } else {
                    WorkflowInputsIcon(size: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.bighelp(.caption).monospaced())
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if hasIssue {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.danger)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, BighelpTokens.space12)
            .frame(height: kind == .decision ? WorkflowCanvasGeometry.decisionHeader : nil, alignment: .leading)
            .frame(maxHeight: kind == .decision ? nil : .infinity)
            if kind == .decision {
                branch("Pass", tint: theme.secondaryText)
                branch(rounds.map { "Changes · max \($0)" } ?? "Changes", tint: BighelpTokens.Palette.gold)
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                .strokeBorder(isSelected ? theme.action : hasIssue ? theme.danger : theme.border,
                              lineWidth: isSelected || hasIssue ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    private func branch(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.bighelp(.caption).weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: WorkflowCanvasGeometry.decisionRow - 8)
            .background(theme.raisedSurface, in: Capsule())
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, 4)
    }
}

/// The dotted grid under the canvas; it pans and zooms with the nodes.
struct WorkflowDotGrid: View {
    let scale: CGFloat
    let pan: CGSize
    @BighelpThemeReader private var theme

    var body: some View {
        Canvas { context, size in
            var spacing = WorkflowCanvasLayout.grid * scale
            while spacing < 10 { spacing *= 2 }
            let dot = max(1, 1.6 * min(scale, 1.2))
            let color = theme.secondaryText.opacity(0.28)
            var x = pan.width.truncatingRemainder(dividingBy: spacing)
            if x < 0 { x += spacing }
            while x < size.width {
                var y = pan.height.truncatingRemainder(dividingBy: spacing)
                if y < 0 { y += spacing }
                while y < size.height {
                    context.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                                 with: .color(color))
                    y += spacing
                }
                x += spacing
            }
        }
        .background(theme.canvas)
    }
}

/// The four kinds of stage, for Add menus.
struct WorkflowAddStageButtons: View {
    /// The computer's plugin runs parallel blocks.
    var parallel = false
    let add: (WorkflowStage.Kind) -> Void

    var body: some View {
        ForEach([WorkflowStage.Kind.agent] + (parallel ? [.parallel] : []) + [.check, .decision, .signoff],
                id: \.self) { kind in
            Button(kind.title, systemImage: kind.symbol) { add(kind) }
                .accessibilityIdentifier("workflows.add.\(kind.rawValue)")
        }
    }
}

/// Lets a node be picked up: on touch after a long press (which first shows
/// its menu; moving hands over to the drag and the menu goes away), on the Mac
/// with a plain drag. The item never leaves bighelp.
struct WorkflowNodeDragSource: ViewModifier {
    let key: String
    let enabled: Bool
    let began: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag({
                began()
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier,
                                                    visibility: .ownProcess) { completion in
                    completion(Data("bighelp-workflow-node:\(key)".utf8), nil)
                    return nil
                }
                return provider
            }, preview: {
                // The node itself follows the finger; the system's copy stays out of the way.
                Color.clear.frame(width: 1, height: 1)
            })
        } else {
            content
        }
    }
}

/// Follows a node being dragged over the canvas and puts it down where it's dropped.
struct WorkflowNodeDrop: DropDelegate {
    let isActive: () -> Bool
    let update: (CGPoint) -> Void
    let drop: (CGPoint) -> Bool
    let exit: () -> Void

    func validateDrop(info: DropInfo) -> Bool { isActive() }
    func dropEntered(info: DropInfo) { if isActive() { update(info.location) } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isActive() else { return nil }
        update(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { exit() }
    func performDrop(info: DropInfo) -> Bool { isActive() && drop(info.location) }
}
