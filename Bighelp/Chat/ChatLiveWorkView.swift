import SwiftUI

/// What a running turn's block (`ChatLiveWork`) shows, all from its real entries: its steps in order,
/// the agent's newest note and what it's doing now.
@MainActor
struct ChatLiveWorkPresentation {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable { case note, step, thought }
        let id: String
        let kind: Kind
        /// A note's words.
        var text = ""
        /// A tool call's or thought's line.
        var step: BighelpActivityStep?
    }

    let lines: [Line]
    let latestNote: String?
    private let events: [ChatActivityEvent]

    init(entries: [ChatTranscriptEntry]) {
        enum Piece { case note(String, String), step(ChatActivityEvent), thought([ChatActivityEvent]) }
        var pieces: [Piece] = []
        var events: [ChatActivityEvent] = []
        for entry in entries {
            switch entry {
            case .message(let item):
                guard case .message(let text) = item.content else { continue }
                let words = Self.preview(text)
                if !words.isEmpty { pieces.append(.note(entry.id, words)) }
            case .activity(let turn):
                for event in turn.events {
                    events.append(event)
                    guard event.kind == .reasoning else {
                        pieces.append(.step(event))
                        continue
                    }
                    // Back-to-back thinking is one thought, as in the chat.
                    if case .thought(let run)? = pieces.last {
                        pieces[pieces.count - 1] = .thought(run + [event])
                    } else {
                        pieces.append(.thought([event]))
                    }
                }
            }
        }
        self.events = events
        lines = pieces.map { piece in
            switch piece {
            case .note(let id, let text):
                return Line(id: id, kind: .note, text: text)
            case .step(let event):
                return Line(id: event.id, kind: .step, step: ChatActivityPresentation.step(for: event))
            case .thought(let run):
                let phase = ChatActivityPresentation.thinkingPhase(for: run)
                let title = ChatActivityPresentation.thinkingTitle(for: run) ?? BighelpActivitySummary.label(for: phase)
                return Line(id: "thought:\(run[0].id)", kind: .thought,
                            step: BighelpActivityStep(id: run[0].id, glyph: .thinking, label: title,
                                                      isRunning: phase == .thinking))
            }
        }
        latestNote = lines.last { $0.kind == .note }?.text
    }

    /// A note's words for a line or two: no Markdown heading or quote marks, no code ticks and no
    /// blank lines. Bold and italic stay; the line draws them (`BighelpActivitySummary.note`).
    static func preview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { line in
                line.drop { $0 == "#" || $0 == ">" }.replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The running tool in its words, or what the turn waits on; between steps, thinking. Once the agent
    /// writes its answer (`isAnswering`) and nothing runs, what it did ("Read 2 files").
    func phase(waiting: ChatActivityWaiting?, isAnswering: Bool = false) -> BighelpActivityPhase {
        ChatActivityPresentation.trailPhase(for: events.filter { $0.kind != .reasoning }, waiting: waiting,
                                            isLive: !isAnswering)
    }

    /// While the agent thinks with no tool running, the heading of its thought ("Finding a free slot").
    var title: String? {
        guard !events.contains(where: { $0.kind != .reasoning && $0.lifecycle == .running }) else { return nil }
        let thinking = Array(events.reversed().prefix { $0.kind == .reasoning }.reversed())
        guard thinking.contains(where: { $0.lifecycle == .running }) else { return nil }
        return ChatActivityPresentation.thinkingTitle(for: thinking)
    }
}

/// Card and Minimal (`ChatWorkStyle`): the running turn's work as one block. Card is a soft card that
/// says who's working and shows the newest steps, older ones fading out at the top; Minimal is one line
/// with the agent's newest note under it. A tap lists every step under it, each its own chat row.
struct ChatLiveWorkView: View {
    let work: ChatLiveWork
    let agentName: String
    let waiting: ChatActivityWaiting?
    @Binding var isExpanded: Bool
    let onDisclosureChange: () -> Void

    /// Card's window: enough to follow along, short enough that the answer stays in view.
    static let windowLines = 4

    @BighelpThemeReader private var theme
    @BighelpLoaderMotionReader private var motion
    @BighelpLoaderScaled(relativeTo: .subheadline) private var glyphSide: CGFloat = BighelpActivityMetrics.glyphSide
    @Environment(\.bighelpActivityLoaderFocus) private var loaderFocus
    @State private var isHovered = false

    var body: some View {
        let presentation = ChatLiveWorkPresentation(entries: work.entries)
        let phase = presentation.phase(waiting: waiting, isAnswering: work.isAnswering)
        if work.style == .minimal {
            VStack(alignment: .leading, spacing: 0) {
                header(label: presentation.title ?? BighelpActivitySummary.label(for: phase), phase: phase)
                if !isExpanded, let note = presentation.latestNote {
                    Text(BighelpActivitySummary.note(note))
                        .font(.bighelp(.footnote))
                        .italic()
                        .foregroundStyle(theme.tertiaryText)
                        .lineLimit(2)
                        .padding(.leading, BighelpTokens.space4 + glyphSide + BighelpTokens.space8)
                        .padding(.bottom, BighelpTokens.space4)
                        .accessibilityLabel("Last said: \(String(BighelpActivitySummary.note(note).characters))")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header(label: waiting?.label
                       ?? (phase.isLive ? String(localized: "\(agentName) is working") : BighelpActivitySummary.label(for: phase)),
                       phase: phase)
                if !isExpanded, !presentation.lines.isEmpty {
                    window(presentation.lines)
                }
            }
            .modifier(ChatWorkCardSurface())
        }
    }

    private var playsLoader: Bool { loaderFocus?.allows(work.id) ?? true }

    private func header(label: String, phase: BighelpActivityPhase) -> some View {
        Button {
            onDisclosureChange()
            withAnimation(motion.moves ? BighelpLoaderCurve.site.animation(duration: BighelpTokens.transitionDuration)
                                       : .easeOut(duration: BighelpTokens.stateDuration)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                glyph(phase)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .bighelpShimmer(isActive: phase.isLive && playsLoader)
                    .contentTransition(.opacity)
                if work.style == .minimal, let steps = BighelpActivitySummary.stepCountLabel(work.stepCount) {
                    Text(steps)
                        .fontWeight(.regular)
                        .monospacedDigit()
                        .foregroundStyle(theme.tertiaryText)
                        .fixedSize()
                }
                Spacer(minLength: BighelpTokens.space4)
                if work.style != .minimal { progress(ticks: phase.isLive) }
                Image(systemName: "chevron.right")
                    .font(.bighelp(.caption, weight: .bold))
                    .foregroundStyle(theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .font(.bighelp(.subheadline, weight: .medium))
            .foregroundStyle(waiting == nil ? theme.secondaryText : theme.warning)
            .padding(.horizontal, BighelpTokens.space4)
            .frame(maxWidth: .infinity, minHeight: BighelpPlatform.isMac ? BighelpTokens.scaled(32) : BighelpTokens.hitTarget,
                   alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: BighelpTokens.radius8, style: .continuous)
                    .fill(theme.primaryText.opacity(isHovered ? (theme.isDarkPalette ? 0.10 : 0.06) : 0))
            }
            .contentShape(.rect)
            .modifier(BighelpActivityHover(isHovered: $isHovered))
        }
        .buttonStyle(BighelpActivityHeaderPressStyle())
        .animation(.easeOut(duration: BighelpTokens.stateDuration), value: phase)
        .accessibilityLabel([label, Self.stepWords(work.stepCount)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(ChatActivityDisclosureAccessibility.value(isExpanded: isExpanded))
        .accessibilityHint(isExpanded ? "Hides the steps." : "Shows every step.")
        .accessibilityIdentifier("chat.live-work")
    }

    private func glyph(_ phase: BighelpActivityPhase) -> some View {
        Group {
            if phase.isLive, playsLoader {
                BighelpNoodleView(motion: phase == .thinking ? .thinking : .loader, size: glyphSide)
            } else {
                BighelpActivityGlyphView(glyph: BighelpActivitySummary.glyph(for: phase), side: glyphSide)
                    .foregroundStyle(waiting != nil ? theme.warning : phase.isLive ? theme.tertiaryText : theme.success)
            }
        }
        .frame(width: glyphSide, height: glyphSide)
        .accessibilityHidden(true)
    }

    /// "14s · 4 steps": how long the agent has worked, by the second, and what it ran. Once it
    /// answers, only the steps: the time it took shows on "Worked for…" when the turn ends.
    private func progress(ticks: Bool) -> some View {
        Group {
            if ticks, let startedAt = work.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text([Self.elapsed(from: startedAt, to: context.date), Self.stepWords(work.stepCount)]
                        .compactMap { $0 }.joined(separator: " · "))
                }
            } else if let steps = Self.stepWords(work.stepCount) {
                Text(steps)
            }
        }
        .font(.bighelp(.footnote))
        .monospacedDigit()
        .foregroundStyle(theme.tertiaryText)
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// The newest lines, the oldest fading out at the top when there are more.
    private func window(_ lines: [ChatLiveWorkPresentation.Line]) -> some View {
        let shown = lines.suffix(Self.windowLines)
        let clipped = lines.count > shown.count
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { line in
                switch line.kind {
                case .note:
                    Text(BighelpActivitySummary.note(line.text))
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(ChatInterimReplyStyle(theme: theme))
                case .step, .thought:
                    if let step = line.step { BighelpActivityStepRow(step: step) }
                }
            }
            .transition(motion.moves ? .asymmetric(insertion: .opacity.combined(with: .offset(y: 3)), removal: .opacity)
                                     : .opacity)
        }
        .padding(.leading, BighelpTokens.space4)
        .padding(.bottom, BighelpTokens.space8)
        .mask {
            LinearGradient(stops: [.init(color: .black.opacity(clipped ? 0.15 : 1), location: 0),
                                   .init(color: .black, location: clipped ? 0.45 : 0)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(motion.moves ? BighelpLoaderCurve.site.animation(duration: BighelpLoaderTiming.stepRise) : nil,
                   value: shown.map(\.id))
    }

    static func stepWords(_ count: Int) -> String? {
        BighelpActivitySummary.stepCountLabel(count).map { String($0.dropFirst(2)) }
    }

    /// "14s", "2m 5s", "1h 3m" since the question was sent.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}
