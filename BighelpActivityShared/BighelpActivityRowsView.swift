import SwiftUI

/// Compact, independently linked chat rows on the Lock Screen and expanded island.
struct BighelpActivityRowsView: View {
    let state: LoopdySessionActivityAttributes.ContentState
    var isStale = false
    var maximumRows = 5
    var showsHeader = true
    var asOf = Date.now
    var snapshot: BighelpWidgetSnapshot = .empty
    var infos: [String: BighelpActivitySessionInfo] = BighelpActivitySessionInfo.load()
    /// Details by row ID, for tests and previews. Nil opens each row's own sealed detail.
    var details: [String: BighelpActivityDetail]? = nil
    var level = BighelpActivityDetailLevel.current
    var showsNerdLine = BighelpActivityDetailLevel.showsNerdLine
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.dynamicTypeSize) private var typeSize

    private var ordered: [BighelpActivitySession] {
        (state.sessions ?? []).filter { BighelpActivityText.coordinate($0.id, maximum: 128) != nil }.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
    }
    private var limit: Int { typeSize.isAccessibilitySize ? min(maximumRows, 1) : maximumRows }
    private var activeCount: Int { max(0, state.activeCount ?? ordered.filter { !$0.phase.isTerminal }.count) }
    private var attentionCount: Int { ordered.filter { $0.phase == .waiting && !stale($0) }.count }

    /// The first chat and its detail, when the card may show one. Without it the card is the plain rows.
    private var hero: (row: BighelpActivitySession, detail: BighelpActivityDetail)? {
        guard level != .statusOnly, !typeSize.isAccessibilitySize, let row = ordered.first,
              let detail = details.map({ $0[row.id] }) ?? row.openDetail() else { return nil }
        return (row, detail)
    }

    var body: some View {
        if let hero { heroCard(hero.row, hero.detail) } else { plainRows }
    }

    /// One chat in full, the next ones as rows under it. The card is at most 160 points tall, so
    /// the lines are counted: fewer at larger text, and each other chat takes one.
    private func heroCard(_ row: BighelpActivitySession, _ detail: BighelpActivityDetail) -> some View {
        let room = (maximumRows >= 5 ? 4 : 2) - (typeSize >= .xLarge ? 1 : 0)
        // A question or a finished reply keeps two lines; the other chats take what is left.
        let words = level == .stepsAndText && ((row.phase == .waiting && detail.question != nil) || (row.phase.isTerminal && detail.preview != nil))
        let others = Array(ordered.dropFirst().prefix(max(0, min(2, maximumRows - 1, room - (words ? 2 : 1)))))
        let more = max(0, activeCount - ([row] + others).filter { !$0.phase.isTerminal }.count)
        let info = infos[row.id]
        return VStack(alignment: .leading, spacing: 5) {
            Link(destination: BighelpWidgetSnapshot.chatURL(row.id)) {
                BighelpActivityHeroView(
                    row: row, title: info?.title ?? "Chat",
                    attributes: info?.attributes ?? LoopdySessionActivityAttributes(sessionID: row.id, sessionTitle: "Chat", agentID: "agent", agentName: "Your bot"),
                    detail: detail, level: level, showsNerdLine: showsNerdLine, isStale: stale(row),
                    lines: max(0, room - others.count - (more > 0 ? 1 : 0)),
                    colors: BighelpActivityColors(snapshot: snapshot, scheme: scheme))
            }
            .buttonStyle(.plain)
            ForEach(others) { other in
                Link(destination: BighelpWidgetSnapshot.chatURL(other.id)) { rowContent(other) }.buttonStyle(.plain)
            }
            if more > 0 {
                Text("+\(more) more active chats").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var plainRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsHeader && typeSize.isAccessibilitySize {
                Text(isStale && activeCount > 0 ? "Updates paused" : activeCount == 0 ? "Chats finished" : "\(activeCount) active chats")
                    .font(.caption2.weight(.semibold)).lineLimit(1)
            } else if showsHeader {
                HStack(spacing: 8) {
                    Text("bighelp").font(.system(.caption, design: .rounded, weight: .bold))
                    Spacer(minLength: 6)
                    Text(isStale && activeCount > 0 ? "Updates paused" : activeCount == 0 ? "Chats finished" : "\(activeCount) active")
                        .font(.caption.weight(.semibold))
                    if !isStale, attentionCount > 0 {
                        Text(attentionCount == 1 ? "Needs you" : "\(attentionCount) need you").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                .lineLimit(1)
                .padding(.bottom, 2)
            }
            ForEach(ordered.prefix(limit)) { row in
                Link(destination: BighelpWidgetSnapshot.chatURL(row.id)) {
                    rowContent(row)
                }
                .buttonStyle(.plain)
            }
            let more = max(0, activeCount - ordered.prefix(limit).filter { !$0.phase.isTerminal }.count)
            if more > 0 {
                Text("+\(more) more active chats").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    @ViewBuilder
    private func rowContent(_ row: BighelpActivitySession) -> some View {
        let info = infos[row.id]
        let attributes = info?.attributes ?? LoopdySessionActivityAttributes(sessionID: row.id, sessionTitle: "Chat", agentID: "agent", agentName: "Your bot")
        let rowIsStale = stale(row)
        let presentation = BighelpActivityPresentation(attributes: attributes, state: row.state, isStale: rowIsStale)
        let tint = BighelpActivityColors(snapshot: snapshot, scheme: scheme).stateColor(row.phase, isStale: rowIsStale)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info?.title ?? "Chat").font(.caption.weight(.semibold)).lineLimit(2)
                    Label(shortStatus(row, presentation: presentation), systemImage: presentation.symbolName)
                        .font(.caption2.weight(.semibold)).foregroundStyle(tint).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: presentation.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(luminanceReduced ? Color.secondary : tint)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text(info?.title ?? "Chat").font(.caption.weight(.semibold)).lineLimit(1)
                            Text(presentation.agentName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(info?.title ?? presentation.agentName).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(shortStatus(row, presentation: presentation))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(luminanceReduced ? Color.secondary : tint)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([info?.title ?? "Chat", presentation.accessibilityLabel].joined(separator: ". "))
        .accessibilityHint("Opens this conversation")
    }

    private func stale(_ row: BighelpActivitySession) -> Bool {
        !row.phase.isTerminal && (isStale || asOf.timeIntervalSince1970 >= Double(row.timestamp) + 120)
    }

    private func shortStatus(_ row: BighelpActivitySession, presentation: BighelpActivityPresentation) -> String {
        if stale(row) { return "Paused" }
        return switch row.phase {
        case .waiting: "Needs you"
        case .failed: "Failed"
        case .completed: "Done"
        case .responding: "Replying"
        case .delegating: "Teamwork"
        case .usingTool: presentation.pose == .tools ? "Working" : presentation.pose.label
        case .thinking: "Thinking"
        }
    }
}
