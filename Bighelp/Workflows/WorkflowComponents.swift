import SwiftUI

// Pieces every Workflows screen shares: the state pill, stage icons, cards,
// the "update the plugin" note and the horizontal stage graph.

extension WorkflowRunState {
    func color(_ theme: BighelpTheme) -> Color {
        switch self {
        case .planned, .cancelled, .unknown: theme.secondaryText
        case .launched, .running, .checkingOutput: theme.information
        case .accepted, .succeeded: theme.success
        case .waitingForYou: theme.action
        case .needsAttention: theme.warning
        case .failed: theme.danger
        }
    }

    var symbol: String {
        switch self {
        case .planned: "circle.dotted"
        case .launched, .running, .checkingOutput: "arrow.triangle.2.circlepath"
        case .accepted, .succeeded: "checkmark.circle.fill"
        case .waitingForYou: "person.crop.circle.badge.clock"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

extension WorkflowStage.Kind {
    func color(_ theme: BighelpTheme) -> Color {
        switch self {
        case .agent: BighelpTokens.Palette.violet
        case .check: theme.success
        case .decision: BighelpTokens.Palette.gold
        case .signoff: theme.action
        case .unknown: theme.secondaryText
        }
    }
}

/// A run's state in a capsule: "Running", "Waiting for you · 38 min".
struct WorkflowStatePill: View {
    let state: WorkflowRunState
    var detail: String?
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space4) {
            Image(systemName: state.symbol)
                .font(.bighelp(.caption2).weight(.bold))
            Text([state.title, detail].compactMap { $0 }.joined(separator: " · "))
                .font(.bighelp(.caption).weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(state.color(theme))
        .padding(.horizontal, BighelpTokens.space8)
        .padding(.vertical, 3)
        .background(state.color(theme).opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workflows.state-pill")
    }
}

/// A stage's kind as a small rounded tile.
struct WorkflowStageIcon: View {
    let kind: WorkflowStage.Kind
    var size: CGFloat = 36
    var isDashed = false
    @BighelpThemeReader private var theme

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(kind.color(theme))
            .frame(width: size, height: size)
            .background(kind.color(theme).opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay {
                if isDashed {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(kind.color(theme).opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .accessibilityHidden(true)
    }
}

/// The inputs node's icon, which isn't a stage.
struct WorkflowInputsIcon: View {
    var size: CGFloat = 36
    @BighelpThemeReader private var theme

    var body: some View {
        Image(systemName: "arrow.right.to.line")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .frame(width: size, height: size)
            .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Inputs, then each stage, as little tiles on a line.
struct WorkflowMiniRail: View {
    let kinds: [WorkflowStage.Kind]
    var unboundAgentStages: Bool = false
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: 0) {
            WorkflowInputsIcon(size: 22)
            ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                Rectangle().fill(theme.border).frame(width: 10, height: 1)
                WorkflowStageIcon(kind: kind, size: 22, isDashed: unboundAgentStages && kind == .agent)
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// The Workflows card: the app's surface, border and corner.
    func workflowCard(_ theme: BighelpTheme, padding: CGFloat = BighelpTokens.space16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            }
    }

    /// The main action: the app's action color with its own text color, which
    /// stays readable in dark mode (the system's white on a light tint doesn't).
    func workflowProminent(_ theme: BighelpTheme) -> some View {
        buttonStyle(.borderedProminent)
            .tint(theme.action)
            .foregroundStyle(theme.actionForeground)
    }

    /// A small rounded chip ("research.brief", "Terminal").
    func workflowChip(_ theme: BighelpTheme, tint: Color? = nil) -> some View {
        self
            .font(.bighelp(.caption))
            .foregroundStyle(tint ?? theme.primaryText)
            .padding(.horizontal, BighelpTokens.space8)
            .padding(.vertical, 4)
            .background((tint ?? theme.secondaryText).opacity(0.12), in: Capsule())
    }
}

/// A section's title with an optional trailing link ("All runs", "Templates").
struct WorkflowSectionHeader: View {
    let title: String
    var count: Int?
    var link: (title: String, id: String, action: () -> Void)?
    @BighelpThemeReader private var theme

    var body: some View {
        HStack {
            Text(title)
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: BighelpTokens.space8)
            if let count {
                Text(count.formatted())
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.action)
            }
            if let link {
                Button(link.title, action: link.action)
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .bighelpPlainButtonStyle()
                    .accessibilityIdentifier(link.id)
            }
        }
    }
}

/// Loading, an older plugin or Hermes, or a problem: one plain message.
struct WorkflowLoadStateView: View {
    let state: WorkflowsLoadState
    var retry: (() -> Void)?

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 160)
                .accessibilityIdentifier("workflows.loading")
        case .needsPluginUpdate:
            ContentUnavailableView {
                Label("Update the bighelp plugin", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Update the bighelp plugin to use Workflows. Hosts › your computer › Update plugin.")
            }
            .accessibilityIdentifier("workflows.update-plugin")
        case .needsHermesUpdate:
            ContentUnavailableView {
                Label("Update Hermes", systemImage: "arrow.down.circle")
            } description: {
                Text("Update Hermes to use Workflows. This version can't run workflow stages.")
            }
            .accessibilityIdentifier("workflows.update-hermes")
        case .cantRunHere(let code):
            let words = WorkflowWords.unavailable(code)
            ContentUnavailableView {
                Label("Workflows can't run on this computer", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            } description: {
                Text("\(words.reason)\n\n\(words.action)")
                    .accessibilityIdentifier("workflows.cant-run.reason")
            } actions: {
                if let retry { Button("Check again", action: retry).accessibilityIdentifier("workflows.retry") }
            }
            .accessibilityIdentifier("workflows.cant-run")
        case .unavailable(let message):
            ContentUnavailableView {
                Label("Workflows aren't available", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let retry { Button("Try again", action: retry).accessibilityIdentifier("workflows.retry") }
            }
        case .loaded:
            EmptyView()
        }
    }
}

// MARK: - Stage graph

/// Where each node is, so the loop connector can be drawn between two of them.
struct WorkflowNodeFrames: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Inputs and every stage left to right at fixed spacing, with the decision's
/// "changes" loop drawn above. Used read-only by the iPad canvas and the run monitor.
struct WorkflowGraph: View {
    struct Node: Identifiable {
        let id: String
        let kind: WorkflowStage.Kind?
        let title: String
        let detail: String
        var state: WorkflowRunState?
    }

    let nodes: [Node]
    /// Decision: from its key back to the stage it loops to, with its label.
    var loop: (from: String, to: String, label: String)?
    var selected: String?
    var select: ((String) -> Void)?
    @BighelpThemeReader private var theme

    private let tile: CGFloat = 56

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    connector(done: node.state.map { $0 != .planned } ?? false)
                        .padding(.top, tile / 2)
                }
                nodeView(node)
            }
        }
        .padding(.top, loop == nil ? 0 : 64)
        .overlayPreferenceValue(WorkflowNodeFrames.self) { anchors in
            GeometryReader { proxy in
                if let loop, let from = anchors[loop.from], let to = anchors[loop.to] {
                    let start = proxy[from]
                    let end = proxy[to]
                    let top = min(start.minY, end.minY) - 36
                    Path { path in
                        path.move(to: CGPoint(x: start.midX, y: start.minY))
                        path.addLine(to: CGPoint(x: start.midX, y: top))
                        path.addLine(to: CGPoint(x: end.midX, y: top))
                        path.addLine(to: CGPoint(x: end.midX, y: end.minY - 4))
                    }
                    .stroke(BighelpTokens.Palette.gold, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    Text(loop.label)
                        .font(.bighelp(.caption2).monospaced())
                        .foregroundStyle(BighelpTokens.Palette.gold)
                        .padding(.horizontal, BighelpTokens.space8)
                        .padding(.vertical, 2)
                        .background(theme.canvas, in: Capsule())
                        .overlay(Capsule().strokeBorder(BighelpTokens.Palette.gold.opacity(0.5)))
                        .position(x: (start.midX + end.midX) / 2, y: top)
                    Text("changes")
                        .font(.bighelp(.caption2))
                        .foregroundStyle(BighelpTokens.Palette.gold)
                        .position(x: start.midX + 30, y: start.minY - 14)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func connector(done: Bool) -> some View {
        Rectangle()
            .fill(done ? theme.success : theme.border)
            .frame(width: 16, height: 2)
    }

    private func nodeView(_ node: Node) -> some View {
        let isSelected = node.id == selected
        let tint = node.kind?.color(theme) ?? theme.secondaryText
        let dim = node.state == .planned
        return Button { select?(node.id) } label: {
            VStack(spacing: BighelpTokens.space8) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let kind = node.kind {
                            Image(systemName: kind.symbol)
                        } else {
                            Image(systemName: "arrow.right.to.line")
                        }
                    }
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint.opacity(dim ? 0.5 : 1))
                    .frame(width: tile, height: tile)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? theme.action : (node.state.map { $0.color(theme) } ?? theme.border),
                                          lineWidth: isSelected || node.state?.isWorking == true ? 2 : 1)
                    }
                    .anchorPreference(key: WorkflowNodeFrames.self, value: .bounds) { [node.id: $0] }
                    if let state = node.state, state != .planned {
                        Image(systemName: state.symbol)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(state.color(theme))
                            .background(Circle().fill(theme.canvas).padding(-2))
                            .offset(x: 6, y: -6)
                    }
                }
                VStack(spacing: 2) {
                    Text(node.title)
                        .font(.bighelp(.footnote).weight(.semibold))
                        .foregroundStyle(isSelected ? theme.action : theme.primaryText)
                    Text(node.detail)
                        .font(.bighelp(.caption2).monospaced())
                        .foregroundStyle(theme.secondaryText)
                }
                .lineLimit(1)
                .frame(width: 88)
            }
            .contentShape(Rectangle())
        }
        .bighelpPlainButtonStyle()
        .disabled(select == nil)
        .accessibilityLabel("\(node.title), \(node.state?.title ?? node.kind?.title ?? "Inputs")")
        .accessibilityIdentifier("workflows.graph.\(node.id)")
    }
}

// MARK: - Text changes

/// "Changes from v1": paragraphs added and removed between two versions of a file.
enum WorkflowTextDiff {
    enum Kind: Equatable, Sendable { case same, added, removed }

    struct Segment: Equatable, Sendable, Identifiable {
        var id: Int
        var kind: Kind
        var text: String
    }

    static func paragraphs(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func compare(old: String, new: String) -> [Segment] {
        let before = paragraphs(old)
        let after = paragraphs(new)
        let difference = after.difference(from: before)
        var removedAt: [Int: [String]] = [:]
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, let element, _): removedAt[offset, default: []].append(element)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Walk the old text and the new one together, keeping removed paragraphs
        // where they were.
        var segments: [Segment] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < before.count || newIndex < after.count {
            if oldIndex < before.count, removedAt[oldIndex] != nil {
                segments.append(Segment(id: segments.count, kind: .removed, text: before[oldIndex]))
                oldIndex += 1
            } else if newIndex < after.count, inserted.contains(newIndex) {
                segments.append(Segment(id: segments.count, kind: .added, text: after[newIndex]))
                newIndex += 1
            } else if newIndex < after.count {
                segments.append(Segment(id: segments.count, kind: .same, text: after[newIndex]))
                newIndex += 1
                oldIndex += 1
            } else {
                oldIndex += 1
            }
        }
        return segments
    }
}

/// Markdown as the chat draws it, or the changes from an earlier version.
struct WorkflowDocumentView: View {
    let text: String
    var previous: String?
    var showsChanges = false
    @BighelpThemeReader private var theme

    var body: some View {
        if showsChanges, let previous {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                ForEach(WorkflowTextDiff.compare(old: previous, new: text)) { segment in
                    MarkdownMessageView(document: MarkdownDocument(segment.text), primaryText: theme.primaryText)
                        .strikethrough(segment.kind == .removed)
                        .opacity(segment.kind == .removed ? 0.6 : 1)
                        .padding(.horizontal, segment.kind == .same ? 0 : BighelpTokens.space8)
                        .padding(.vertical, segment.kind == .same ? 0 : BighelpTokens.space4)
                        .background {
                            if segment.kind != .same {
                                RoundedRectangle(cornerRadius: BighelpTokens.radius8, style: .continuous)
                                    .fill((segment.kind == .added ? theme.success : theme.danger).opacity(0.12))
                            }
                        }
                        .accessibilityLabel(segment.kind == .added ? "Added: \(segment.text)"
                                            : segment.kind == .removed ? "Removed: \(segment.text)" : segment.text)
                }
            }
            .accessibilityIdentifier("workflows.document.changes")
        } else {
            MarkdownMessageView(document: MarkdownDocument(text), primaryText: theme.primaryText)
                .textSelection(.enabled)
                .accessibilityIdentifier("workflows.document")
        }
    }
}

// MARK: - What's wrong with the flow

/// The flow's problems, plainly, in a card on the canvas.
/// One problem. "Choose an agent for …" opens Agent roles.
struct WorkflowIssueRow: View {
    let issue: WorkflowValidation.Issue
    var editRoles: (() -> Void)?
    @BighelpThemeReader private var theme

    var body: some View {
        if issue.code == WorkflowEditorModel.roleUnbound, let editRoles {
            Button(action: editRoles) { label }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("workflows.issue.roles")
        } else {
            label
        }
    }

    private var label: some View {
        Label(issue.message, systemImage: issue.isError ? "xmark.octagon" : "exclamationmark.triangle")
            .font(.bighelp(.footnote))
            .foregroundStyle(issue.isError ? theme.danger : theme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WorkflowIssuesCard: View {
    let issues: [WorkflowValidation.Issue]
    var editRoles: (() -> Void)?
    @State private var isExpanded = false
    @BighelpThemeReader private var theme

    var body: some View {
        if !issues.isEmpty {
            let shown = isExpanded ? issues : Array(issues.prefix(3))
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Text(issues.contains(where: \.isError) ? "To fix before it can run" : "Worth a look")
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                ForEach(shown) { issue in
                    WorkflowIssueRow(issue: issue, editRoles: editRoles)
                }
                if issues.count > 3 {
                    Button(isExpanded ? "Show less" : "Show all \(issues.count)") { isExpanded.toggle() }
                        .font(.bighelp(.footnote).weight(.semibold))
                        .foregroundStyle(theme.action)
                        .bighelpPlainButtonStyle()
                        .frame(minHeight: BighelpTokens.hitTarget - 12)
                }
            }
            .workflowCard(theme, padding: BighelpTokens.space12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workflows.issues")
        }
    }
}
