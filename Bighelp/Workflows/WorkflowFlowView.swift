import SwiftUI
import UniformTypeIdentifiers

/// Opens one workflow: the vertical flow at compact width, the canvas at regular width. Each has a
/// switch: a phone can show the stages side by side in one row, and a wider screen top to bottom in one
/// column. The choice is remembered; the canvas places people set are never changed by it.
struct WorkflowScreen: View {
    let context: WorkflowsContext
    let startsRun: Bool
    @State private var model: WorkflowEditorModel
    /// A layout switch shows the other view; it doesn't offer the run again.
    @State private var switched = false
    @AppStorage("bighelp.workflows.compact-row") private var compactRow = false
    @AppStorage("bighelp.workflows.regular-column") private var regularColumn = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(context: WorkflowsContext, workflowID: String, startsRun: Bool) {
        self.context = context
        self.startsRun = startsRun
        let hasDraft = context.store.workflows.first { $0.id == workflowID }?.hasDraft ?? false
        _model = State(initialValue: WorkflowEditorModel(workflowID: workflowID, client: context.client, hasDraft: hasDraft,
                                                         canEditFlow: context.canEdit,
                                                         features: context.store.features))
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                WorkflowCanvasView(model: model, context: context, startsRun: startsRun && !switched,
                                   arrangement: regularColumn ? .column : .saved,
                                   switchLayout: { switchLayout { regularColumn.toggle() } })
            } else if compactRow {
                WorkflowCanvasView(model: model, context: context, startsRun: startsRun && !switched,
                                   arrangement: .row, switchLayout: { switchLayout { compactRow = false } })
            } else {
                WorkflowFlowView(model: model, context: context, startsRun: startsRun && !switched,
                                 switchLayout: { switchLayout { compactRow = true } })
            }
        }
        .task { if model.detail == nil { await model.load() } }
    }

    private func switchLayout(_ change: () -> Void) {
        switched = true
        withAnimation(.snappy) { change() }
    }
}

/// The switch between a workflow's two layouts, in the toolbar. It names where it goes.
struct WorkflowLayoutButton: View {
    /// The layout a tap shows: one column, one row, or the canvas as you arranged it.
    let next: WorkflowArrangement
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: next == .column ? "rectangle.split.1x2" : "rectangle.split.3x1")
                .bighelpToolbarIcon()
        }
        .bighelpIconLabel(label)
        .accessibilityIdentifier("workflows.layout")
    }

    private var label: String {
        switch next {
        case .column: "Show top to bottom"
        case .row: "Show side by side"
        case .saved: "Show your layout"
        }
    }
}

/// Where each card of the vertical flow is, in the flow's own space.
private struct WorkflowFlowRects: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Build the flow at compact width (iPhone, and any narrow window): inputs,
/// then every stage in one line top to bottom so nothing is lost off screen
/// (saved places on the canvas don't apply here). Tap a stage to change it.
/// With `native-workflows-edit-v1`: touch and hold a stage, then drag it up
/// or down to reorder; drag a stage's port to another stage to rewire.
struct WorkflowFlowView: View {
    @Bindable var model: WorkflowEditorModel
    let context: WorkflowsContext
    let startsRun: Bool
    /// Shows the stages side by side in one row instead.
    var switchLayout: (() -> Void)?
    @State private var editing: WorkflowStage?
    @State private var isRunSheetPresented = false
    @State private var isInputsPresented = false
    @State private var isRolesPresented = false
    @State private var isTriggerPresented = false
    @State private var templateSource: WorkflowSummary?
    @State private var didOfferRun = false
    @State private var rects: [String: CGRect] = [:]
    @State private var draggingKey: String?
    @State private var dropGap: Int?
    @State private var wire: (from: String, port: WorkflowPort, point: CGPoint)?
    @BighelpThemeReader private var theme

    private static let space = "workflows.flow.space"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                if model.definition == nil {
                    WorkflowLoadStateView(state: model.state) { Task { await model.load() } }
                } else {
                    if model.trigger != nil {
                        WorkflowTriggerCard(trigger: model.trigger) { isTriggerPresented = true }
                    }
                    BighelpDeferredSection { flow }
                    BighelpDeferredSection { issues }
                }
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.top, BighelpTokens.space8)
            .padding(.bottom, 120)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workflows.flow")
        }
        .scrollIndicators(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { if model.definition != nil { bottomBar } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { WorkflowTitle(model: model) }
            if let switchLayout {
                ToolbarItem(placement: .topBarTrailing) {
                    WorkflowLayoutButton(next: .row, action: switchLayout)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                WorkflowMoreMenu(model: model, context: context, templateSource: $templateSource,
                                 editInputs: { isInputsPresented = true }, editRoles: { isRolesPresented = true },
                                 editTrigger: { isTriggerPresented = true })
            }
        }
        .sheet(isPresented: $isRolesPresented) {
            WorkflowRolesEditor(model: model, context: context)
                .bighelpSheetSize(.standard)
        }
        .sheet(isPresented: $isTriggerPresented) {
            WorkflowTriggerSheet(model: model, context: context)
                .bighelpSheetSize(.large)
        }
        .sheet(item: $editing) { stage in
            WorkflowStageEditor(model: model, context: context, stage: stage)
                .bighelpSheetSize(.large)
        }
        .sheet(isPresented: $isRunSheetPresented) {
            WorkflowRunSheet(model: model, context: context)
                .bighelpSheetSize(.standard)
        }
        .sheet(isPresented: $isInputsPresented) {
            WorkflowInputsEditor(model: model)
                .bighelpSheetSize(.large)
        }
        // Its own view: two alerts on one view and only one of them shows.
        .background {
            Color.clear
                .modifier(WorkflowSaveTemplatePrompt(store: context.store, source: $templateSource,
                                                     prepare: { await model.flushSave() }) { saved in
                    model.message = saved ? WorkflowWords.templateSaved : context.store.message
                    context.store.message = nil
                })
                .allowsHitTesting(false)
        }
        .alert("Workflow", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
        .onChange(of: model.definition != nil, initial: true) { _, loaded in
            guard loaded, startsRun, !didOfferRun else { return }
            didOfferRun = true
            if model.canRun { isRunSheetPresented = true }
        }
        .onDisappear { Task { await model.flushSave() } }
    }

    // MARK: Flow

    private var stages: [WorkflowStage] { model.definition?.stages ?? [] }
    private var graph: WorkflowFlowGraph? { model.definition?.graph }
    private var editable: Bool { model.canEditFlow }

    private var flow: some View {
        let graph = graph
        let order = model.definition.map(WorkflowCanvasLayout.compactOrder) ?? []
        let byKey = Dictionary(stages.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let lanes = sideLanes(graph, order: order)
        return VStack(spacing: 0) {
            inputsNode
            ForEach(Array(order.enumerated()), id: \.element) { index, key in
                if let stage = byKey[key] {
                    let previous = index == 0 ? WorkflowCanvasLayout.inputsKey : order[index - 1]
                    connector(from: previous, to: stage, graph: graph)
                    if dropGap == index { insertionLine }
                    stageNode(stage, graph: graph)
                }
            }
            if dropGap == order.count { insertionLine }
            Rectangle().fill(theme.border).frame(width: 1, height: 16)
            Menu {
                WorkflowAddStageButtons(features: model.features) { addStage($0, after: nil) }
            } label: {
                Image(systemName: "plus")
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .overlay {
                        RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                            .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .contentShape(Rectangle())
            }
            .bighelpIconLabel("Add a stage at the end")
            .accessibilityIdentifier("workflows.flow.add-end")
        }
        .padding(.trailing, lanes.isEmpty ? 0 : CGFloat(min(lanes.count, 4)) * 12 + 28)
        .overlay { sideWires(lanes) }
        .overlay { liveWire }
        .onPreferenceChange(WorkflowFlowRects.self) { rects = $0 }
        .coordinateSpace(.named(Self.space))
        .onDrop(of: [UTType.utf8PlainText], delegate: WorkflowNodeDrop(
            isActive: { draggingKey != nil && editable },
            update: { dropGap = gap(at: $0) },
            drop: { location in
                defer { draggingKey = nil; dropGap = nil }
                guard let key = draggingKey, let gap = gap(at: location) else { return false }
                withAnimation(.snappy) { model.move(key, toGap: gap) }
                return true
            },
            exit: { dropGap = nil }))
        .frame(maxWidth: .infinity)
    }

    /// Which gap between cards a drag is over: 0 is above the first stage.
    private func gap(at location: CGPoint) -> Int? {
        let order = model.definition.map(WorkflowCanvasLayout.compactOrder) ?? []
        guard !order.isEmpty else { return nil }
        for (index, key) in order.enumerated() {
            if let rect = rects[key], location.y < rect.midY { return index }
        }
        return order.count
    }

    private var insertionLine: some View {
        Capsule()
            .fill(theme.action)
            .frame(height: 3)
            .padding(.vertical, BighelpTokens.space4)
            .accessibilityHidden(true)
    }

    private var inputsNode: some View {
        Button { isInputsPresented = true } label: {
            HStack(spacing: BighelpTokens.space12) {
                WorkflowInputsIcon()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inputs")
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.primaryText)
                    Text((model.definition?.inputs ?? []).isEmpty ? "No fields yet"
                         : (model.definition?.inputs ?? []).map(\.key).joined(separator: " · "))
                        .font(.bighelp(.caption).monospaced())
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
            }
            .workflowCard(theme, padding: BighelpTokens.space12)
            .contentShape(Rectangle())
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("workflows.flow.inputs")
        .background(rectReader(WorkflowCanvasLayout.inputsKey))
        .overlay(alignment: .bottom) { if editable { port(WorkflowCanvasLayout.inputsKey, .next) } }
    }

    @ViewBuilder
    private func connector(from previous: String, to stage: WorkflowStage, graph: WorkflowFlowGraph?) -> some View {
        let leadsHere = previous == WorkflowCanvasLayout.inputsKey ? graph?.start == stage.key
            : graph?.exits[previous]?.primary == stage.key
        let fromDecision = graph?.kinds[previous] == .decision
        VStack(spacing: 0) {
            line(leadsHere, height: 8)
            HStack(spacing: BighelpTokens.space8) {
                if previous != WorkflowCanvasLayout.inputsKey, graph?.exits[previous]?.primary == nil {
                    Text(model.definition?.stage(previous)?.passEnd.map { "Ends: \($0.outcome.title.lowercased())" }
                         ?? "Flow ends")
                        .font(.bighelp(.caption).weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                Menu {
                    WorkflowAddStageButtons(features: model.features) { addStage($0, after: previous) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(theme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(theme.border))
                        .frame(width: BighelpTokens.hitTarget, height: 28)
                        .contentShape(Rectangle())
                }
                .bighelpIconLabel("Add a stage before \(stage.title)")
                if fromDecision, leadsHere {
                    Text("pass")
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            line(leadsHere, height: 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func line(_ solid: Bool, height: CGFloat) -> some View {
        Rectangle()
            .fill(solid ? theme.border : .clear)
            .frame(width: 1, height: height)
    }

    private func stageNode(_ stage: WorkflowStage, graph: WorkflowFlowGraph?) -> some View {
        let isDecision = stage.kind == .decision
        return Button { editing = stage } label: {
            HStack(spacing: BighelpTokens.space12) {
                WorkflowStageIcon(kind: stage.kind, size: isDecision ? 30 : 36,
                                  isDashed: ([stage] + stage.branches).contains {
                                      $0.kind == .agent && model.agentID(for: $0.role) == nil
                                  })
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.title)
                        .font(.bighelp(isDecision ? .subheadline : .headline))
                        .foregroundStyle(theme.primaryText)
                    Text(stage.subtitle { context.agentName(model.agentID(for: $0)) })
                        .font(.bighelp(.caption).monospaced())
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if issueColor(stage) != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.bighelp(.caption))
                        .foregroundStyle(theme.danger)
                        .accessibilityHidden(true)
                } else if !isDecision {
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.footnote).weight(.semibold))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            .padding(isDecision ? BighelpTokens.space8 : BighelpTokens.space12)
            // Room for the port on the bottom edge, clear of the text.
            .padding(.bottom, isDecision ? BighelpTokens.space8 : 0)
            .frame(maxWidth: isDecision ? 240 : .infinity, alignment: .leading)
            .background(isDecision ? BighelpTokens.Palette.gold.opacity(0.1) : theme.surface,
                        in: RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                    .strokeBorder(issueColor(stage) ?? (isDecision ? BighelpTokens.Palette.gold.opacity(0.4) : theme.border),
                                  lineWidth: 1)
            }
            .opacity(draggingKey == stage.key && dropGap != nil ? 0.4 : 1)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .contentShape(Rectangle())
        }
        .bighelpPlainButtonStyle()
        .contextMenu { stageMenu(stage, graph: graph) }
        .modifier(WorkflowNodeDragSource(key: stage.key, enabled: editable) { draggingKey = stage.key })
        // Before the ports: an identifier on the card would hide theirs.
        .accessibilityIdentifier("workflows.flow.stage.\(stage.key)")
        .background(rectReader(stage.key))
        .overlay(alignment: .bottom) {
            if editable { port(stage.key, isDecision ? .pass : .next) }
        }
        .overlay(alignment: .trailing) {
            if editable, isDecision { port(stage.key, .changes).offset(x: BighelpTokens.hitTarget / 2 - 6) }
        }
    }

    @ViewBuilder
    private func stageMenu(_ stage: WorkflowStage, graph: WorkflowFlowGraph?) -> some View {
        Button("Edit", systemImage: "pencil") { editing = stage }
        Menu("Add a stage after", systemImage: "plus") {
            WorkflowAddStageButtons(features: model.features) { addStage($0, after: stage.key) }
        }
        // Dragging toward an open menu picks from it, so moving is in the menu too.
        if editable, let index = stages.firstIndex(where: { $0.key == stage.key }) {
            if index > 0 {
                Button("Move up", systemImage: "arrow.up") { model.move(stage.key, toGap: index - 1) }
            }
            if index < stages.count - 1 {
                Button("Move down", systemImage: "arrow.down") { model.move(stage.key, toGap: index + 2) }
            }
        }
        if editable, stage.kind != .decision, graph?.exits[stage.key]?.primary != nil {
            Button("End the flow here", systemImage: "stop.circle") { model.connect(stage.key, .next, to: nil) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
            model.deleteStage(stage.key)
            Task { await model.save() }
        }
    }

    private func rectReader(_ key: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: WorkflowFlowRects.self, value: [key: proxy.frame(in: .named(Self.space))])
        }
    }

    private func issueColor(_ stage: WorkflowStage) -> Color? {
        model.issues.contains { $0.stageKey == stage.key && $0.isError } ? theme.danger : nil
    }

    // MARK: Ports and wires

    /// A port: drag it to another stage to send this way out there.
    private func port(_ key: String, _ port: WorkflowPort) -> some View {
        let tint = port == .changes ? BighelpTokens.Palette.gold : theme.primaryText
        return Circle()
            .fill(tint)
            .overlay(Circle().strokeBorder(theme.surface, lineWidth: 2))
            .frame(width: 12, height: 12)
            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
            .contentShape(Circle())
            .offset(y: port == .changes ? 0 : BighelpTokens.hitTarget / 2 - 6)
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                .onChanged { value in wire = (key, port, value.location) }
                .onEnded { value in finishWire(at: value.location) })
            .accessibilityElement()
            .accessibilityLabel(port == .changes ? "Changes go back" : "Way out")
            .accessibilityValue(target(key, port) ?? "end")
            .accessibilityIdentifier("workflows.flow.port.\(key).\(port.rawValue)")
    }

    private func target(_ key: String, _ port: WorkflowPort) -> String? {
        key == WorkflowCanvasLayout.inputsKey ? graph?.start : graph?.target(key, port)
    }

    private func finishWire(at point: CGPoint) {
        defer { wire = nil }
        guard let wire else { return }
        let target = stages.first { stage in
            (stage.key != wire.from || wire.port == .changes) && (rects[stage.key]?.insetBy(dx: 0, dy: -6).contains(point) ?? false)
        }
        guard let target else { return }
        withAnimation(.snappy) { model.connect(wire.from, wire.port, to: target.key) }
    }

    @ViewBuilder
    private var liveWire: some View {
        if let wire, let rect = rects[wire.from] {
            let start = wire.port == .changes ? CGPoint(x: rect.maxX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.maxY)
            Path { path in
                path.move(to: start)
                path.addCurve(to: wire.point, control1: CGPoint(x: start.x, y: start.y + 40),
                              control2: CGPoint(x: wire.point.x, y: wire.point.y - 40))
            }
            .stroke(theme.action, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
            .allowsHitTesting(false)
        }
    }

    /// Ways out that don't go to the card right below: drawn beside the cards,
    /// each in its own lane. A decision's changes are gold and dashed.
    private struct Lane: Identifiable {
        var id: String { "\(from).\(port.rawValue)" }
        var from: String
        var to: String
        var port: WorkflowPort
        var label: String?
    }

    private func sideLanes(_ graph: WorkflowFlowGraph?, order: [String]) -> [Lane] {
        guard let graph else { return [] }
        var lanes: [Lane] = []
        for (index, key) in order.enumerated() {
            let below = order.indices.contains(index + 1) ? order[index + 1] : nil
            if let to = graph.exits[key]?.primary, to != below, order.contains(to) {
                lanes.append(Lane(from: key, to: to, port: graph.kinds[key] == .decision ? .pass : .next, label: nil))
            }
            if let to = graph.exits[key]?.changes, order.contains(to) {
                let rounds = model.definition?.stage(key)?.changesMaxRevisions ?? model.definition?.maxRevisions ?? 2
                lanes.append(Lane(from: key, to: to, port: .changes, label: "max \(rounds)"))
            }
        }
        if let start = graph.start, order.first != start {
            lanes.append(Lane(from: WorkflowCanvasLayout.inputsKey, to: start, port: .next, label: nil))
        }
        return lanes
    }

    private func sideWires(_ lanes: [Lane]) -> some View {
        GeometryReader { proxy in
            ForEach(Array(lanes.prefix(4).enumerated()), id: \.element.id) { index, lane in
                if let from = rects[lane.from], let to = rects[lane.to] {
                    let x = proxy.size.width - 14 - CGFloat(index) * 12
                    let changes = lane.port == .changes
                    let color = changes ? BighelpTokens.Palette.gold : theme.secondaryText
                    Path { path in
                        path.move(to: CGPoint(x: from.maxX, y: from.midY))
                        path.addQuadCurve(to: CGPoint(x: x, y: from.midY + (to.midY > from.midY ? 12 : -12)),
                                          control: CGPoint(x: x, y: from.midY))
                        path.addLine(to: CGPoint(x: x, y: to.midY + (to.midY > from.midY ? -12 : 12)))
                        path.addQuadCurve(to: CGPoint(x: to.maxX + 6, y: to.midY), control: CGPoint(x: x, y: to.midY))
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: changes ? [5, 4] : []))
                    if let label = lane.label {
                        Text(label)
                            .font(.bighelp(.caption2).monospaced())
                            .foregroundStyle(color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.canvas, in: Capsule())
                            .overlay(Capsule().strokeBorder(color.opacity(0.5)))
                            .fixedSize()
                            // Along the lane, so it stays inside the screen's edge.
                            .rotationEffect(.degrees(-90))
                            .position(x: x, y: (from.midY + to.midY) / 2)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Issues and Run

    @ViewBuilder
    private var issues: some View {
        let issues = model.issues
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                ForEach(issues) { issue in
                    WorkflowIssueRow(issue: issue, editRoles: { isRolesPresented = true })
                }
            }
            .workflowCard(theme, padding: BighelpTokens.space12)
            .accessibilityIdentifier("workflows.flow.issues")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: BighelpTokens.space8) {
            Menu {
                WorkflowAddStageButtons(features: model.features) { addStage($0, after: nil) }
                Divider()
                Button("Inputs", systemImage: "arrow.right.to.line") { isInputsPresented = true }
            } label: {
                Image(systemName: "plus")
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(Rectangle())
            }
            .bighelpIconLabel("Add a stage")
            .accessibilityIdentifier("workflows.flow.add")
            Text("Nothing runs until you tap Run.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { isRunSheetPresented = true } label: {
                Label("Run", systemImage: "play.fill")
                    .font(.bighelp(.body).weight(.semibold))
                    .frame(minWidth: 96, minHeight: BighelpTokens.hitTarget - 8)
            }
            .workflowProminent(theme)
            .disabled(!model.canRun)
            .accessibilityIdentifier("workflows.flow.run")
        }
        .padding(BighelpTokens.space8)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius20, style: .continuous).strokeBorder(theme.border)
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.bottom, BighelpTokens.space8)
        .frame(maxWidth: 680)
    }

    private func addStage(_ kind: WorkflowStage.Kind, after key: String?) {
        if let stage = model.addStage(kind, after: key) { editing = stage }
    }
}

/// The workflow's name, with whether it can run under it.
struct WorkflowTitle: View {
    let model: WorkflowEditorModel
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: 0) {
            Text(model.name)
                .font(.bighelp(.headline))
                .lineLimit(1)
            if let line = validityLine {
                // A Label in the toolbar shows only its icon; spell it out.
                HStack(spacing: BighelpTokens.space4) {
                    Image(systemName: line.valid ? "checkmark" : "exclamationmark.triangle")
                    Text(line.text)
                }
                .font(.bighelp(.caption))
                .foregroundStyle(line.valid ? theme.success : theme.warning)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("workflows.flow.validity")
            }
        }
    }

    private var validityLine: (text: String, valid: Bool)? {
        guard let validation = model.validation, let definition = model.definition else { return nil }
        var parts = [validation.valid ? "Valid" : "Needs fixing",
                     definition.stages.count == 1 ? "1 stage" : "\(definition.stages.count) stages"]
        if let revision = model.detail?.latestRevision {
            parts.append(model.hasUnpublishedDraft || model.isDirty ? "draft of rev \(revision)" : "rev \(revision)")
        } else {
            parts.append("draft")
        }
        return (parts.joined(separator: " · "), validation.valid && model.unboundRoles.isEmpty)
    }
}

/// ⋯ on a workflow: runs, inputs, save as template, check again, archive.
struct WorkflowMoreMenu: View {
    let model: WorkflowEditorModel
    let context: WorkflowsContext
    @Binding var templateSource: WorkflowSummary?
    var editInputs: (() -> Void)?
    var editRoles: (() -> Void)?
    var editTrigger: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Menu {
            Button("Runs of this workflow", systemImage: "list.bullet") { context.open(.workflowRuns(selected: nil)) }
            if let editInputs {
                Button("Inputs", systemImage: "arrow.right.to.line") { editInputs() }
            }
            if let editRoles {
                Button("Agent roles", systemImage: "person.2") { editRoles() }
                    .accessibilityIdentifier("workflows.more.roles")
            }
            if let editTrigger, model.trigger != nil {
                Button("Trigger", systemImage: "clock.arrow.circlepath") { editTrigger() }
                    .accessibilityIdentifier("workflows.more.trigger")
            }
            if context.canEdit {
                Button("Save as template", systemImage: "square.on.square") {
                    templateSource = WorkflowSummary(id: model.workflowID, name: model.name, revision: nil, hasDraft: true,
                                                     stageCount: model.definition?.stages.count ?? 0,
                                                     needsSetupRoles: [], valid: false, lastRunAt: nil)
                }
                .accessibilityIdentifier("workflows.more.save-template")
            }
            if context.isNerdMode {
                Button("Check again", systemImage: "checkmark.seal") { Task { await model.save() } }
            }
            Button("Archive", systemImage: "archivebox", role: .destructive) {
                Task {
                    try? await context.client.archive(workflowID: model.workflowID)
                    await context.store.load()
                    dismiss()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .bighelpToolbarIcon()
        }
        .bighelpIconLabel("More")
        .accessibilityIdentifier("workflows.flow.more")
    }
}

/// Which agent does one role on this computer.
struct WorkflowRolePicker: View {
    let model: WorkflowEditorModel
    let context: WorkflowsContext
    let role: WorkflowDefinition.Role
    @BighelpThemeReader private var theme

    var body: some View {
        HStack {
            Text(role.label)
                .font(.bighelp(.body))
            Spacer()
            Menu {
                ForEach(context.agents) { agent in
                    Button(agent.name) { Task { await model.bind(role: role.key, agentID: agent.id) } }
                }
                if model.agentID(for: role.key) != nil {
                    Button("No agent", role: .destructive) { Task { await model.bind(role: role.key, agentID: nil) } }
                }
            } label: {
                HStack(spacing: BighelpTokens.space4) {
                    Text(context.agentName(model.agentID(for: role.key)) ?? "Choose an agent")
                    Image(systemName: "chevron.up.chevron.down").font(.bighelp(.caption2))
                }
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(model.agentID(for: role.key) == nil ? theme.action : theme.primaryText)
                .frame(minHeight: BighelpTokens.hitTarget)
            }
            .accessibilityIdentifier("workflows.role.\(role.key)")
        }
    }
}

/// ⋯ › Agent roles: the jobs in this workflow and which agent does each one.
/// A stage gets its role when you pick its agent; here you name roles, add
/// them ahead of time, and change who does them.
struct WorkflowRolesEditor: View {
    let model: WorkflowEditorModel
    let context: WorkflowsContext
    @State private var isAdding = false
    @State private var renaming: WorkflowDefinition.Role?
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var roles: [WorkflowDefinition.Role] { model.definition?.roles ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(roles) { role in
                        VStack(alignment: .leading, spacing: 2) {
                            WorkflowRolePicker(model: model, context: context, role: role)
                            Text(usedBy(role))
                                .font(.bighelp(.caption))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .contextMenu { actions(role) }
                        .swipeActions { actions(role) }
                    }
                    Button("New role", systemImage: "plus") {
                        name = ""
                        isAdding = true
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("workflows.roles.add")
                } footer: {
                    Text("A role is a job in this workflow, like Writer. Picking an agent on a stage sets its role too.")
                        .font(.bighelp(.footnote))
                }
            }
            .scrollContentBackground(.hidden)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Agent roles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .bighelpDefaultAction()
                }
            }
        }
        .accessibilityIdentifier("workflows.roles")
        .alert("New role", isPresented: $isAdding) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                model.addRole(named: name)
                model.scheduleSave()
            }
        }
        .alert("Rename role", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let renaming { model.renameRole(renaming.key, to: name) } }
        }
    }

    @ViewBuilder
    private func actions(_ role: WorkflowDefinition.Role) -> some View {
        Button("Rename", systemImage: "pencil") {
            name = role.label
            renaming = role
        }
        if !model.usedRoleKeys.contains(role.key) {
            Button("Remove", systemImage: "trash", role: .destructive) { model.removeRole(role.key) }
        }
    }

    private func usedBy(_ role: WorkflowDefinition.Role) -> String {
        let titles = (model.definition?.allStages ?? []).filter { $0.kind == .agent && $0.role == role.key }.map(\.title)
        return titles.isEmpty ? "No stage uses this role yet." : titles.joined(separator: ", ")
    }
}

/// Run: asks for the workflow's inputs, then starts one run on the computer.
struct WorkflowRunSheet: View {
    let model: WorkflowEditorModel
    let context: WorkflowsContext
    @State private var values: [String: String] = [:]
    @State private var isStarting = false
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var inputs: [WorkflowDefinition.Input] { model.definition?.inputs ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    WorkflowInputFields(inputs: inputs, values: $values)
                } footer: {
                    Text("The run happens on \(context.hostName). It keeps going when you close the app, and asks you before anything is final.")
                        .font(.bighelp(.footnote))
                }
            }
            .scrollContentBackground(.hidden)
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Run \(model.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { start() }
                        .disabled(!isComplete || isStarting)
                        .bighelpDefaultAction()
                        .accessibilityIdentifier("workflows.run-sheet.run")
                }
            }
        }
        .onAppear {
            if values.isEmpty { values = WorkflowInputFields.values(for: inputs) }
        }
    }

    private var isComplete: Bool { WorkflowInputFields.isComplete(inputs, values) }

    private func start() {
        isStarting = true
        let json = WorkflowInputFields.json(inputs, values)
        Task {
            defer { isStarting = false }
            guard let run = await model.run(inputs: json) else { return }
            dismiss()
            await context.store.load()
            context.openRun(run.id)
        }
    }
}
