import SwiftUI

/// Where the agent's work is. Every value comes from the caller's real data.
enum BighelpActivityPhase: Equatable, Sendable {
    /// Reasoning before or between tools. The orb blinks; the label shimmers.
    case thinking
    /// A tool is running. The label shimmers; take it from `BighelpToolActivityCatalog`.
    case working(BighelpToolActivity)
    /// Paused on the person's answer, in the warning color.
    case waitingForApproval(label: String = "Waiting for your yes")
    /// The turn ended. `elapsed` is the turn's recorded time; without it the row
    /// just says "Done".
    case done(elapsed: TimeInterval?)
    /// Thinking that finished: "Thought for 6s", from its recorded time.
    case thought(elapsed: TimeInterval?)
    /// Work that finished, in the caller's own past-tense words ("Read 2
    /// files, ran tests"), with the check.
    case finished(String)
    /// The work was stopped before it finished.
    case stopped
    /// The work ended on an error, in the danger color.
    case failed

    var isLive: Bool {
        switch self {
        case .thinking, .working: true
        case .waitingForApproval, .done, .thought, .finished, .stopped, .failed: false
        }
    }
}

/// One thing the agent did, as a line in the unfolded row.
struct BighelpActivityStep: Identifiable, Equatable, Sendable {
    let id: String
    var glyph: BighelpActivityGlyph
    /// "Searched the web", or "Reading" while it runs.
    var label: String
    /// Shown in monospace and cut short to fit: a file, a query, a command.
    var detail: String?
    /// Trailing and short: "0.8s", or "+48" for lines added.
    var meta: String?
    /// The meta counts something added, in the success color.
    var metaIsAddition = false
    /// Still running: a small spinner takes the glyph's place.
    var isRunning = false
    /// The meta reports a failure ("Failed"), in the danger color.
    var metaIsFailure = false
}

/// Words for the row, kept apart from the view so they can be tested.
enum BighelpActivitySummary {
    /// "Worked for 14s", like a finished chat turn; "Done" without a real time.
    static func doneLabel(elapsed: TimeInterval?) -> String {
        guard let elapsed, elapsed.isFinite, elapsed >= 0, elapsed < 31_536_000 else { return "Done" }
        let seconds = Int(elapsed.rounded())
        if seconds < 1 { return "Worked for less than a second" }
        if seconds < 60 { return "Worked for \(seconds)s" }
        if seconds < 3_600 { return "Worked for \(seconds / 60)m \(seconds % 60)s" }
        return "Worked for \(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    /// "Thought for 6s", like a finished chat turn; "Thought process" without a
    /// real time of at least a second.
    static func thoughtLabel(elapsed: TimeInterval?) -> String {
        guard let elapsed, elapsed.isFinite, elapsed >= 1, elapsed < 86_400 else { return "Thought process" }
        let seconds = Int(elapsed)
        return seconds < 60 ? "Thought for \(seconds)s" : "Thought for \(seconds / 60)m \(seconds % 60)s"
    }

    /// The agent's thinking with its markdown emphasis drawn instead of spelled
    /// out: models head each thought with `**Checking the tests**`. Only bold
    /// (`**x**`, `__x__`) and italic (`*x*`) within one line count, drawn in
    /// the row's own font. Everything else stays as written, so `2 * 3`,
    /// `snake_case`, `__init__` and code in backticks keep their characters.
    static func note(_ text: String) -> AttributedString {
        let characters = Array(text)
        var result = AttributedString()
        var plain = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "`",
               let close = characters[(index + 1)...].firstIndex(where: { $0 == "`" || $0.isNewline }),
               characters[close] == "`" {
                plain.append(contentsOf: characters[index...close])
                index = close + 1
                continue
            }
            if let run = emphasisRun(in: characters, at: index) {
                result += AttributedString(plain)
                plain = ""
                var inner = note(String(characters[run.content]))
                for (range, intent) in inner.runs.map({ ($0.range, $0.inlinePresentationIntent) }) {
                    inner[range].inlinePresentationIntent = (intent ?? []).union(run.intent)
                }
                result += inner
                index = run.end
                continue
            }
            plain.append(characters[index])
            index += 1
        }
        result += AttributedString(plain)
        return result
    }

    /// A `**x**`, `__x__` or `*x*` starting at `index`, with CommonMark's
    /// rules for where a run may open and close, kept to one line.
    private static func emphasisRun(
        in characters: [Character], at index: Int
    ) -> (content: Range<Int>, end: Int, intent: InlinePresentationIntent)? {
        let marker = characters[index]
        guard marker == "*" || marker == "_" else { return nil }
        var length = 1
        while index + length < characters.count, characters[index + length] == marker { length += 1 }
        // A single `_` is too often part of a name to read as italic.
        guard length == 2 || (length == 1 && marker == "*") else { return nil }
        let start = index + length
        guard start < characters.count, !characters[start].isWhitespace,
              index == 0 || (characters[index - 1] != marker && !isWordCharacter(characters[index - 1]))
        else { return nil }
        var close = start + 1
        while close + length <= characters.count, !characters[close].isNewline {
            let closes = characters[close..<(close + length)].allSatisfy { $0 == marker }
                && characters[close - 1] != marker && !characters[close - 1].isWhitespace
                && (close + length == characters.count
                    || (characters[close + length] != marker && !isWordCharacter(characters[close + length])))
            if closes {
                let content = start..<close
                // Python's `__init__` and friends are names, not bold.
                if marker == "_", characters[content].allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" }) {
                    return nil
                }
                return (content, close + length, length == 2 ? .stronglyEmphasized : .emphasized)
            }
            close += 1
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// "· 3 steps", or nil with none.
    static func stepCountLabel(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "· 1 step" : "· \(count) steps"
    }

    static func label(for phase: BighelpActivityPhase) -> String {
        switch phase {
        case .thinking: BighelpToolActivityCatalog.thinking.label
        case .working(let activity): activity.label
        case .waitingForApproval(let label): label
        case .done(let elapsed): doneLabel(elapsed: elapsed)
        case .thought(let elapsed): thoughtLabel(elapsed: elapsed)
        case .finished(let summary): summary
        case .stopped: "Stopped"
        case .failed: "Hit a snag"
        }
    }

    static func glyph(for phase: BighelpActivityPhase) -> BighelpActivityGlyph {
        switch phase {
        case .thinking: .thinking
        case .working(let activity): activity.glyph
        case .waitingForApproval: .glyph(.shield)
        case .done, .finished: .done
        case .thought: .thinking
        case .stopped: .symbol("stop.circle")
        case .failed: .symbol("exclamationmark.triangle")
        }
    }
}

/// What the agent is doing, as one quiet line: a glyph and a shimmering label
/// ("Browsing the web… · 2 steps"). Tap or click it to unfold the steps
/// underneath. When the turn ends it settles into a summary ("Worked for 14s ·
/// 3 steps") with a check.
///
/// Opening it only grows the row downward, so the header stays where it was.
/// In the chat, pass the disclosure store's binding and its
/// `onDisclosureChange` (which hands scrolling to the reader) so a toggle never
/// moves the conversation.
struct BighelpActivityRow: View {
    let phase: BighelpActivityPhase
    var steps: [BighelpActivityStep] = []
    /// The real number of steps when not all of them are passed in.
    var stepCount: Int?
    /// What the agent said about its thinking, shown first when unfolded.
    var note: String?
    /// The caller draws the unfolded steps itself, under this row (the chat
    /// gives each step its own recycled row, inside `bighelpActivityRail()`).
    /// The header still unfolds and folds them.
    var detailsBelow = false
    var onDisclosureChange: () -> Void = {}
    var accessibilityIdentifier: String?

    private let expansion: Binding<Bool>?
    @State private var localExpanded: Bool

    init(phase: BighelpActivityPhase, steps: [BighelpActivityStep] = [], stepCount: Int? = nil,
         note: String? = nil, detailsBelow: Bool = false, isExpanded: Binding<Bool>,
         onDisclosureChange: @escaping () -> Void = {}, accessibilityIdentifier: String? = nil) {
        self.phase = phase
        self.steps = steps
        self.stepCount = stepCount
        self.note = note
        self.detailsBelow = detailsBelow
        self.onDisclosureChange = onDisclosureChange
        self.accessibilityIdentifier = accessibilityIdentifier
        expansion = isExpanded
        _localExpanded = State(initialValue: isExpanded.wrappedValue)
    }

    /// Keeps its own open/closed state.
    init(phase: BighelpActivityPhase, steps: [BighelpActivityStep] = [], stepCount: Int? = nil,
         note: String? = nil, startsExpanded: Bool = false, accessibilityIdentifier: String? = nil) {
        self.phase = phase
        self.steps = steps
        self.stepCount = stepCount
        self.note = note
        self.accessibilityIdentifier = accessibilityIdentifier
        expansion = nil
        _localExpanded = State(initialValue: startsExpanded)
    }

    @BighelpThemeReader private var theme
    @BighelpLoaderMotionReader private var motion
    @BighelpLoaderScaled(relativeTo: .subheadline) private var glyphSide: CGFloat = BighelpActivityMetrics.glyphSide
    @State private var isHovered = false

    private var isExpanded: Bool { expansion?.wrappedValue ?? localExpanded }
    private var hasDetails: Bool { detailsBelow || !steps.isEmpty || note?.isEmpty == false }
    private var count: Int { max(stepCount ?? 0, steps.count) }
    private var label: String { BighelpActivitySummary.label(for: phase) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded, hasDetails, !detailsBelow {
                details
                    .transition(motion.moves
                        ? .asymmetric(insertion: .opacity.combined(with: .offset(y: -3)), removal: .opacity)
                        : .opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(motion.moves ? BighelpLoaderCurve.site.animation(duration: BighelpLoaderTiming.stepRise) : nil,
                   value: steps.map(\.id))
    }

    // MARK: Header

    private var header: some View {
        Button {
            guard hasDetails else { return }
            onDisclosureChange()
            let next = !isExpanded
            withAnimation(motion.moves ? BighelpLoaderCurve.site.animation(duration: BighelpTokens.transitionDuration)
                                       : .easeOut(duration: BighelpTokens.stateDuration)) {
                if let expansion { expansion.wrappedValue = next } else { localExpanded = next }
            }
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                headerGlyph
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .bighelpShimmer(isActive: phase.isLive)
                    .contentTransition(.opacity)
                if let meta = BighelpActivitySummary.stepCountLabel(count) {
                    Text(meta)
                        .fontWeight(.regular)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(theme.tertiaryText)
                        .fixedSize()
                }
                if hasDetails {
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.caption, weight: .bold))
                        .foregroundStyle(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Spacer(minLength: 0)
            }
            .font(.bighelp(.subheadline, weight: .medium))
            .foregroundStyle(headerColor)
            .padding(.horizontal, BighelpTokens.space4)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: headerMinHeight, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: BighelpTokens.radius8, style: .continuous)
                    .fill(theme.primaryText.opacity(isHovered && hasDetails ? (theme.isDarkPalette ? 0.10 : 0.06) : 0))
            }
            .contentShape(.rect)
            .modifier(BighelpActivityHover(isHovered: $isHovered))
        }
        .buttonStyle(BighelpActivityHeaderPressStyle())
        .animation(.easeOut(duration: BighelpTokens.stateDuration), value: phase)
        .accessibilityLabel([label, BighelpActivitySummary.stepCountLabel(count).map { String($0.dropFirst(2)) }]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(hasDetails ? (isExpanded ? "Expanded" : "Collapsed") : "")
        .accessibilityHint(hasDetails ? disclosureHint : "")
        // With nothing to unfold it's a line of status, not a button.
        .accessibilityRemoveTraits(hasDetails ? [] : .isButton)
        .accessibilityAddTraits(hasDetails ? [] : .isStaticText)
        .accessibilityIdentifier(accessibilityIdentifier ?? "activity.row")
    }

    /// A row that unfolds only the agent's note (thinking) says so.
    private var disclosureHint: String {
        let what = steps.isEmpty && !detailsBelow ? "the thinking" : "the steps"
        return isExpanded ? "Hides \(what)." : "Shows \(what)."
    }

    /// Touch needs a full 44-point target (56 on Vision Pro); a mouse on the Mac
    /// is happy with less, which keeps a stack of rows compact there.
    private var headerMinHeight: CGFloat {
        BighelpPlatform.isMac ? BighelpTokens.scaled(32) : BighelpTokens.hitTarget
    }

    private var headerColor: Color {
        switch phase {
        case .waitingForApproval: theme.warning
        case .failed: theme.danger
        default: theme.secondaryText
        }
    }

    private var headerGlyph: some View {
        let color: Color = switch phase {
        case .done, .finished: theme.success
        case .waitingForApproval: theme.warning
        case .failed: theme.danger
        case .thinking, .working, .thought, .stopped: theme.tertiaryText
        }
        return BighelpLoaderClock(isRunning: phase.isLive, cadence: .soft) { time in
            let breath = time.pingPong(BighelpLoaderTiming.breathe / 2, rest: 0.5)
            BighelpActivityGlyphView(glyph: BighelpActivitySummary.glyph(for: phase), side: glyphSide,
                                     time: phase.isLive ? time : .still)
                .scaleEffect(time.isStill ? 1 : 0.92 + 0.14 * breath)
                .opacity(time.isStill ? 1 : 0.6 + 0.4 * breath)
        }
        .foregroundStyle(color)
        .frame(width: glyphSide, height: glyphSide)
        .accessibilityHidden(true)
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let note, !note.isEmpty {
                Text(BighelpActivitySummary.note(note))
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.vertical, 3)
            }
            ForEach(steps) { step in
                BighelpActivityStepRow(step: step, showsSpinner: step.isRunning && phase.isLive)
                    .transition(motion.moves
                        ? .asymmetric(insertion: .opacity.combined(with: .offset(y: 3)), removal: .opacity)
                        : .opacity)
            }
        }
        .padding(.vertical, 2)
        .bighelpActivityRail()
        .padding(.top, 2)
        .padding(.bottom, BighelpTokens.space4)
    }
}

/// Sizes the row, its steps and the rail share, so steps drawn as their own
/// rows (the chat) line up with the header's glyph.
enum BighelpActivityMetrics {
    static let glyphSide: CGFloat = 18
    static let stepGlyphSide: CGFloat = 16
    static let stepMinHeight: CGFloat = 26
    static let railWidth: CGFloat = 1.5
}

extension View {
    /// The thin line the unfolded steps hang from, under the header's glyph.
    /// Rows stacked with no gap between them draw one continuous line.
    func bighelpActivityRail() -> some View {
        modifier(BighelpActivityRail())
    }
}

private struct BighelpActivityRail: ViewModifier {
    @BighelpThemeReader private var theme
    @BighelpLoaderScaled(relativeTo: .subheadline) private var glyphSide: CGFloat = BighelpActivityMetrics.glyphSide

    func body(content: Content) -> some View {
        content
            .padding(.leading, BighelpTokens.space16)
            .overlay(alignment: .leading) {
                Rectangle().fill(theme.separator).frame(width: BighelpActivityMetrics.railWidth)
            }
            .padding(.leading, BighelpTokens.space4 + glyphSide / 2 - BighelpActivityMetrics.railWidth / 2)
    }
}

/// One step as a line: its glyph (or a spinner while it runs), the words, a
/// monospaced detail cut short to fit, and a short trailing meta.
struct BighelpActivityStepRow: View {
    let step: BighelpActivityStep
    /// Spin in the glyph's place. Only while the step and its row are live.
    var showsSpinner = false

    @BighelpThemeReader private var theme
    @BighelpLoaderScaled(relativeTo: .footnote) private var glyphSide: CGFloat = BighelpActivityMetrics.stepGlyphSide
    @BighelpLoaderScaled(relativeTo: .footnote) private var minHeight: CGFloat = BighelpActivityMetrics.stepMinHeight

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            Group {
                if showsSpinner {
                    BighelpSpinner(size: glyphSide * 0.75, lineWidth: 1.6)
                } else {
                    BighelpActivityGlyphView(glyph: step.glyph, side: glyphSide, time: .still)
                }
            }
            .foregroundStyle(theme.tertiaryText)
            .frame(width: glyphSide, height: glyphSide)
            Text(step.label)
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
            if let detail = step.detail, !detail.isEmpty {
                Text(detail)
                    .font(.bighelp(.caption, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            if let meta = step.meta, !meta.isEmpty {
                Text(meta)
                    .font(.bighelp(.caption))
                    .monospacedDigit()
                    .foregroundStyle(metaColor)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(minHeight: minHeight)
        .accessibilityElement(children: .combine)
    }

    private var metaColor: Color {
        if step.metaIsFailure { return theme.danger }
        return step.metaIsAddition ? theme.success : theme.tertiaryText
    }
}

/// Draws an activity glyph at a size. The thinking orb blinks on the clock it's given.
struct BighelpActivityGlyphView: View {
    let glyph: BighelpActivityGlyph
    let side: CGFloat
    var time: BighelpLoaderTime = .still

    var body: some View {
        Group {
            switch glyph {
            case .glyph(let glyph):
                Image(glyph.assetName).resizable().renderingMode(.template).scaledToFit()
            case .symbol(let name):
                BighelpSymbolImage(systemName: name)
            case .thinking:
                BighelpOrbGlyph(time: time)
            case .done:
                Image(systemName: "checkmark").resizable().scaledToFit()
                    .fontWeight(.bold).scaleEffect(0.72)
            }
        }
        .frame(width: side, height: side)
    }
}

/// bighelp's agent orb as a line glyph, with eyes that look around and blink.
/// Drawn on the 24-point glyph grid in the current foreground style.
struct BighelpOrbGlyph: View {
    var time: BighelpLoaderTime = .still

    /// The eyes' sideways glance (in grid points) and how open they are, through
    /// one 3.2 s loop: center, left, right, center, with a blink in the middle.
    static func eyes(at time: BighelpLoaderTime) -> (glance: Double, openness: Double) {
        guard !time.isStill else { return (0, 1) }
        let p = time.phase(BighelpLoaderTiming.orbEyes)
        func ease(_ from: Double, _ to: Double, _ start: Double, _ end: Double) -> Double {
            from + (to - from) * BighelpLoaderCurve.easeInOut((p - start) / (end - start))
        }
        let glance: Double = switch p {
        case ..<0.18: 0
        case ..<0.25: ease(0, -1.4, 0.18, 0.25)
        case ..<0.45: -1.4
        case ..<0.52: ease(-1.4, 1.4, 0.45, 0.52)
        case ..<0.70: 1.4
        case ..<0.78: ease(1.4, 0, 0.70, 0.78)
        default: 0
        }
        let openness: Double = switch p {
        case 0.46..<0.48: 1 - 0.9 * (p - 0.46) / 0.02
        case 0.48..<0.50: 0.1 + 0.9 * (p - 0.48) / 0.02
        default: 1
        }
        return (glance, openness)
    }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.translateBy(x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            var orb = Path()
            orb.move(to: CGPoint(x: 3.935, y: 13.196))
            orb.addCurve(to: CGPoint(x: 12, y: 4.235), control1: CGPoint(x: 3.935, y: 6.476), control2: CGPoint(x: 7.52, y: 4.235))
            orb.addCurve(to: CGPoint(x: 20.064, y: 13.196), control1: CGPoint(x: 16.48, y: 4.235), control2: CGPoint(x: 20.064, y: 6.476))
            orb.addCurve(to: CGPoint(x: 12, y: 19.916), control1: CGPoint(x: 20.064, y: 17.9), control2: CGPoint(x: 16.704, y: 19.916))
            orb.addCurve(to: CGPoint(x: 3.935, y: 13.196), control1: CGPoint(x: 7.295, y: 19.916), control2: CGPoint(x: 3.935, y: 17.9))
            orb.closeSubpath()
            context.stroke(orb, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let eyes = Self.eyes(at: time)
            let radius = 1.288
            for x in [9.424, 14.576] {
                let height = radius * 2 * eyes.openness
                let rect = CGRect(x: x + eyes.glance - radius, y: 10.508 - height / 2, width: radius * 2, height: height)
                context.fill(Path(ellipseIn: rect), with: .foreground)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A row header's press: a slight dim, never a color change.
private struct BighelpActivityHeaderPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? BighelpButtonPress.opacity : 1)
            .animation(.easeOut(duration: BighelpTokens.pressDuration), value: configuration.isPressed)
    }
}

/// Pointer feedback for the header: a soft wash under the Mac's pointer, the
/// system highlight for an iPad pointer and for looking at it on Vision Pro.
private struct BighelpActivityHover: ViewModifier {
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: BighelpTokens.pressDuration), value: isHovered)
        #else
        content
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: BighelpTokens.radius8, style: .continuous))
            .hoverEffect(.highlight)
        #endif
    }
}
