import SwiftUI

enum SessionStatusRailDestination: String, Identifiable {
    case goal
    case subagents
    case tasks

    var id: String { rawValue }
}

struct SessionStatusRailView: View {
    let goal: ChatGoalRailState?
    let subagents: [SessionSubagentSnapshot]
    let nativeSubagents: [NativeSubagentRailItem]
    let tasks: ChatTaskDrawerState?
    let onSelect: (SessionStatusRailKind) -> Void
    let onFittingVerticalDrag: (ChatRailScrollDirection) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var didDispatchFittingVerticalDrag = false

    private var displayedSubagentCount: Int {
        subagents.count + nativeSubagents.count
    }

    var body: some View {
        let items = SessionStatusRailPresentation.items(
            goal: goal,
            subagents: subagents,
            nativeSubagents: nativeSubagents,
            tasks: tasks
        )
        return Group {
            if !items.isEmpty { adaptiveRail(items) }
        }
        .companionComposerAnchor(.railViewport)
    }

    @ViewBuilder
    private func adaptiveRail(_ items: [SessionStatusRailItem]) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    ForEach(items) { compactStatusButton($0) }
                }
            } else if dynamicTypeSize >= .xxxLarge {
                wrappedRail(items)
            } else {
                ViewThatFits(in: .horizontal) {
                    if horizontalSizeClass == .regular { fullRailContent(items) }
                    HStack(spacing: BighelpTokens.space4) {
                        ForEach(items) {
                            compactStatusButton($0)
                                .fixedSize(horizontal: true, vertical: true)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    wrappedRail(items)
                }
            }
        }
        .padding(BighelpTokens.space4)
        // A one-row pill grows into a rounded surface when labels need to wrap.
        // There is exactly one background, including on iPad.
        .bighelpNavigationGlass(in: RoundedRectangle(cornerRadius: 26))
        .simultaneousGesture(fittingVerticalDragGesture)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.session-status-rail")
        .frame(maxWidth: ChatCanvasLayout.regularLaneMaximumWidth,
               alignment: horizontalSizeClass == .regular ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: horizontalSizeClass == .regular ? .center : .leading)
    }

    private func wrappedRail(_ items: [SessionStatusRailItem]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: BighelpTokens.space4),
                           count: min(2, max(1, items.count))),
            spacing: BighelpTokens.space4
        ) {
            ForEach(items) { compactStatusButton($0) }
        }
    }

    private var compactStatusLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: 4))
            : AnyLayout(VStackLayout(spacing: 2))
    }

    private func compactStatusButton(_ item: SessionStatusRailItem) -> some View {
        Button { onSelect(item.kind) } label: {
            compactStatusLayout {
                Text(statusTitle(item.kind))
                    .font(.bighelp(.caption2))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: dynamicTypeSize.isAccessibilitySize, vertical: true)
                if dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                Text(statusDetail(item.kind))
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .monospacedDigit()
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(minWidth: BighelpTokens.hitTarget, maxWidth: .infinity,
                   minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .companionComposerAnchor(.railLedge(item.kind.rawValue))
        .accessibilityLabel(accessibilityLabel(for: item.kind))
        .accessibilityHint(item.kind == .subagents ? "Shows what each subagent is doing" : "Opens details")
        .accessibilityIdentifier("chat.session-status.\(item.kind.rawValue)")
        .accessibilityValue(item.kind == .subagents
            ? subagentStreamAcceptanceFixture?.readinessValue(displayedSubagents: subagents) ?? ""
            : "")
    }

    private func fullRailContent(_ items: [SessionStatusRailItem]) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            ForEach(items) { item in
                fullStatusButton(item)
            }
        }
        .padding(.horizontal, BighelpTokens.space4)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func fullStatusButton(_ item: SessionStatusRailItem) -> some View {
        Button { onSelect(item.kind) } label: {
            HStack(spacing: BighelpTokens.space8) {
                Image(systemName: icon(for: item.kind))
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.action)
                    .accessibilityHidden(true)
                Text(statusTitle(item.kind))
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(statusDetail(item.kind))
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: BighelpTokens.hitTarget)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .companionComposerAnchor(.railLedge(item.kind.rawValue))
        .accessibilityLabel(accessibilityLabel(for: item.kind))
        .accessibilityIdentifier("chat.session-status.\(item.kind.rawValue)")
        .accessibilityValue(item.kind == .subagents
            ? subagentStreamAcceptanceFixture?.readinessValue(displayedSubagents: subagents) ?? ""
            : "")
    }

    private func statusDetail(_ kind: SessionStatusRailKind) -> String {
        switch kind {
        case .goal:
            guard let goal else { return "Goal" }
            return (goal.lifecycle == .paused ? "Paused · " : "") + goal.compactSummary
        case .subagents:
            return "\(displayedSubagentCount)"
        case .tasks:
            return tasks.map { "\($0.completedCount)/\($0.totalCount)" } ?? "Session"
        }
    }

    private func statusTitle(_ kind: SessionStatusRailKind) -> String {
        switch kind {
        case .goal: "Goal"
        case .subagents: "Subagents"
        case .tasks: "Tasks"
        }
    }

    private var fittingVerticalDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !didDispatchFittingVerticalDrag,
                      abs(value.translation.height) > abs(value.translation.width),
                      abs(value.translation.height) >= 12 else { return }
                didDispatchFittingVerticalDrag = true
                onFittingVerticalDrag(
                    value.translation.height < 0
                        ? .towardLatest
                        : .towardOldest
                )
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    didDispatchFittingVerticalDrag = false
                }
            }
            .onEnded { _ in
                didDispatchFittingVerticalDrag = false
            }
    }

    private func icon(for kind: SessionStatusRailKind) -> String {
        switch kind {
        case .goal: "target"
        case .subagents: "cpu"
        case .tasks: "checklist"
        }
    }

    private func accessibilityLabel(for kind: SessionStatusRailKind) -> String {
        switch kind {
        case .goal:
            guard let goal else { return "Goal" }
            return "Goal \(goal.lifecycle.rawValue), \(goal.compactSummary)"
        case .subagents:
            return displayedSubagentCount == 1 ? "1 active subagent" : "\(displayedSubagentCount) active subagents"
        case .tasks:
            guard let tasks else { return "Tasks" }
            return "Tasks, \(tasks.completedCount) of \(tasks.totalCount) completed"
        }
    }

    @BighelpThemeReader private var theme

    @Environment(\.subagentStreamAcceptanceFixture)
    private var subagentStreamAcceptanceFixture
}

enum ChatRailScrollDirection: Equatable, Sendable {
    case towardLatest
    case towardOldest
}

struct ChatRailScrollRequest: Equatable, Sendable {
    var generation = 0
    var direction: ChatRailScrollDirection = .towardLatest
}
