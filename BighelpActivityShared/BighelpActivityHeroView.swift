import SwiftUI

/// The first chat on the card, with what its agent is doing now: the step in progress, the last
/// steps, a timer that runs on the phone, the question that waits or the reply's first lines.
/// Everything past the title and phase comes from the row's sealed detail; none of it is guessed.
struct BighelpActivityHeroView: View {
    let row: BighelpActivitySession
    let title: String
    let attributes: LoopdySessionActivityAttributes
    let detail: BighelpActivityDetail
    var level = BighelpActivityDetailLevel.stepsAndText
    var showsNerdLine = false
    var isStale = false
    /// How many lines of text fit under the title block. The card is at most 160 points tall.
    var lines = 4
    var colors: BighelpActivityColors
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    private var agentName: String { BighelpActivityText.personName(attributes.agentName) ?? "Your agent" }
    private var showsText: Bool { level == .stepsAndText }
    private var tint: Color { luminanceReduced ? colors.secondary : colors.stateColor(row.phase, isStale: isStale) }
    private var helpers: Int { min(max(row.activeSubagentCount, 0), 99) }

    /// Where the turn's timer starts, only while it makes sense: not in the future, not days old.
    private var started: Date? {
        guard let seconds = detail.started, seconds <= row.timestamp + 60, row.timestamp - seconds < 86_400 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private var status: String {
        if isStale && !row.phase.isTerminal { return "Updates paused" }
        switch row.phase {
        case .waiting: return "\(agentName) needs you"
        case .completed:
            guard let seconds = detail.started, row.timestamp > seconds, row.timestamp - seconds < 86_400 else { return "Done" }
            return "Done in \(BighelpActivityStepWords.duration(row.timestamp - seconds))"
        case .failed: return BighelpActivityStatus.couldNotFinish
        case .delegating: return helpers == 1 ? "Working with 1 helper" : "Working with \(helpers) helpers"
        case .responding: return "Writing the response"
        case .thinking, .usingTool:
            if let tool = detail.tool { return BighelpActivityStepWords.now(tool) }
            return row.phase == .thinking && detail.steps == 0 ? "Thinking" : "Thinking about the next step"
        }
    }

    /// The words under the title block: the person's question, the reply, or what the step works on.
    private var quote: String? {
        guard showsText, !(isStale && !row.phase.isTerminal) else { return nil }
        switch row.phase {
        case .waiting: return detail.question
        case .completed, .failed: return detail.preview
        case .delegating: return detail.helperGoals.first ?? detail.say
        default: return detail.tool == nil ? detail.say : detail.note ?? detail.say
        }
    }

    private var footer: String? {
        var parts: [String] = []
        if detail.steps > 0 { parts.append(row.phase.isTerminal ? (detail.steps == 1 ? "1 step" : "\(detail.steps) steps") : "Step \(detail.steps)") }
        if helpers > 0, row.phase != .delegating { parts.append(helpers == 1 ? "1 helper" : "\(helpers) helpers") }
        if showsNerdLine {
            if let used = detail.contextUsed, let window = detail.contextWindow {
                parts.append("\(BighelpActivityStepWords.tokens(used)) of \(BighelpActivityStepWords.tokens(window))")
            }
            if let model = detail.model { parts.append(model) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func stepLine(_ step: BighelpActivityDetail.Step) -> String {
        let words = BighelpActivityStepWords.done(step.tool, count: step.count)
        guard showsText, step.count == 1, let note = step.note else { return words }
        return "\(words) · \(note)"
    }

    var body: some View {
        // A question or a finished reply gets two lines; the steps give way to it.
        let attention = row.phase == .waiting || row.phase.isTerminal
        let quote = quote
        let quoteLines = quote == nil ? 0 : min(lines, attention ? 2 : 1)
        let footer = lines - quoteLines > 0 ? footer : nil
        let trail = attention && quote != nil ? [] : Array(detail.trail.prefix(max(0, min(2, lines - quoteLines - (footer == nil ? 0 : 1)))))
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                BighelpActivityAvatar(agentID: attributes.agentID, name: agentName, diameter: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(status).font(.footnote.weight(.semibold)).foregroundStyle(tint).lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    if let started, !row.phase.isTerminal, !isStale {
                        // Counts on the phone, so it moves between updates. It stops with the turn.
                        Text(timerInterval: started...started.addingTimeInterval(86_400), countsDown: false)
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .multilineTextAlignment(.trailing).frame(maxWidth: 64, alignment: .trailing)
                    }
                    Text(agentName).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                }
                .layoutPriority(1)
            }
            if let quote, quoteLines > 0 {
                Text(quote).font(.footnote).lineLimit(quoteLines).padding(.leading, 48)
            }
            ForEach(Array(trail.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.caption2.weight(.bold))
                    Text(stepLine(step)).font(.caption).lineLimit(1)
                }
                .foregroundStyle(colors.secondary).padding(.leading, 48)
            }
            if let footer {
                Text(footer).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1).padding(.leading, 48)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, agentName, status, quote, footer].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint("Opens this conversation")
    }
}
