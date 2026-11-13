import SwiftUI

/// One row on Work: Code home's own card for coding work, `WorkRowCard` for everything else.
struct WorkItemCard: View {
    let item: WorkItem
    let onOpen: (WorkTarget) -> Void
    /// Code home's long-press actions; nil without a Code store.
    var code: CodeHomeStore?

    var body: some View {
        switch item.card {
        case .session(let record, let status, let pullRequest):
            Button { onOpen(.codeSession(record.id)) } label: {
                CodeSessionCard(session: record, status: status, pullRequest: pullRequest)
            }
            .buttonStyle(.bighelpTilePress)
            .contextMenu {
                Button("Changes", systemImage: "plus.forwardslash.minus") { onOpen(.codeChanges(record.id)) }
                if let code {
                    Button("Remove from list", systemImage: "eye.slash") { code.forget(record) }
                }
            }
            .accessibilityIdentifier("work.item.\(item.id)")
        case .launch(let launch):
            // A send still starting has nothing to open until Hermes has its session.
            CodeLaunchCard(launch: launch) { code?.dismiss(launch) }
                .onTapGesture { if let target = item.target { onOpen(target) } }
                .accessibilityIdentifier("work.item.\(item.id)")
        case .batch(let batch, let lines, let startedCount):
            Button { onOpen(.codeBatch(batch.id)) } label: {
                CodeBatchCard(batch: batch, lines: lines.map { line in
                    CodeBatchCard.Line(id: line.id, title: line.title, color: CodeSessionColor.color(at: line.index),
                                       status: line.status)
                }, startedCount: startedCount)
            }
            .buttonStyle(.bighelpTilePress)
            .contextMenu {
                if let code {
                    Button("Remove from list", systemImage: "eye.slash") { code.forget(batch) }
                }
            }
            .accessibilityIdentifier("work.item.\(item.id)")
        case .row:
            if let target = item.target {
                Button { onOpen(target) } label: { WorkRowCard(item: item) }
                    .buttonStyle(.bighelpTilePress)
                    .accessibilityIdentifier("work.item.\(item.id)")
            } else {
                WorkRowCard(item: item)
                    .accessibilityIdentifier("work.item.\(item.id)")
            }
        }
    }
}

/// A workflow run, Kanban card, chat, background work or scheduled task, drawn like Code home's
/// session card: the status dot, the title, where it is, then the pill and when.
struct WorkRowCard: View {
    let item: WorkItem

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            dot
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(item.title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                if !item.line.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space4) {
                        Image(systemName: item.lineSymbol)
                        Text(item.line).lineLimit(2)
                    }
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                }
                statusLine
                    .padding(.top, BighelpTokens.space4)
            }
            Spacer(minLength: 0)
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(theme.border, lineWidth: BighelpTokens.hairline)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// Code home's dot for live states; an upcoming task waits, so it gets a still clock instead.
    @ViewBuilder
    private var dot: some View {
        switch item.tone {
        case .needsYou: CodeStatusDot(status: .needsYou(""))
        case .working: CodeStatusDot(status: .running(nil))
        case .done: CodeStatusDot(status: .ready)
        case .failed: CodeStatusDot(status: .failed(""))
        case .upcoming:
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 18, height: 18)
                .padding(.top, 2)
                .accessibilityHidden(true)
        }
    }

    private var statusLine: some View {
        HStack(spacing: BighelpTokens.space8) {
            if let pill = item.pill {
                CodePill(text: pill, tint: tint, systemImage: item.tone == .needsYou ? "hand.raised" : nil)
            }
            Spacer(minLength: 0)
            // Worked out when the card draws; no ticking timer. An upcoming task's time is in its pill.
            if item.bucket != .upcoming, let time = item.time {
                Text(time.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .font(.bighelp(.subheadline))
    }

    private var tint: Color {
        switch item.tone {
        case .needsYou: theme.warning
        case .working: theme.action
        case .done: theme.success
        case .failed: theme.danger
        case .upcoming: theme.secondaryText
        }
    }

    @BighelpThemeReader private var theme
}

/// All, Needs you, Working, Done: one row that scrolls sideways, in Code home's chip style.
struct WorkFilterChips: View {
    @Binding var filter: WorkFilter
    let counts: [WorkFilter: Int]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(WorkFilter.allCases) { chip in
                    let isOn = filter == chip
                    Button { filter = chip } label: {
                        HStack(spacing: BighelpTokens.space4) {
                            Text(chip.title)
                            Text("\(counts[chip] ?? 0)")
                                .foregroundStyle(isOn ? theme.canvas.opacity(0.7) : theme.secondaryText)
                        }
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(isOn ? theme.canvas : theme.primaryText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, BighelpTokens.space12)
                        .frame(minHeight: 34)
                        .background(isOn ? theme.primaryText : theme.surface, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .bighelpPlainButtonStyle(.capsule)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("work.filter.\(chip.rawValue)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("work.filters")
    }

    @BighelpThemeReader private var theme
}
