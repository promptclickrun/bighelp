import Foundation

/// The read timestamp belongs to this client, fencing older in-flight history
/// against a newer picker selection. It is never a transcript ordering key.
struct SessionRuntimeSnapshot: Codable, Equatable, Sendable {
    let model: String
    let provider: String?
    let observedAt: Date
}

struct SessionContextSnapshot: Codable, Equatable, Sendable {
    private(set) var sessionId: String
    let title: String?
    let model: String
    let contextUsed: Int
    let contextMax: Int
    let contextPercent: Int
    let compressions: Int
    let isCompacting: Bool
    let updatedAt: Int
    /// Token accounting is optional so a Hermes host running an older bighelp
    /// plugin keeps publishing a valid `session.context` projection. The chat
    /// surface degrades to the window-only summary when these are absent.
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedTokens: Int?
    let totalTokens: Int?
    /// Cumulative session usage. The scope flag distinguishes a plugin-proved
    /// nested/finished subagent roll-up from parent-only native host counters.
    /// Missing fields remain unknown; zero is a real measurement.
    let sessionInputTokens: Int?
    let sessionOutputTokens: Int?
    let sessionCachedTokens: Int?
    let sessionTotalTokens: Int?
    let sessionIncludesSubagents: Bool?

    init(
        sessionId: String,
        title: String? = nil,
        model: String,
        contextUsed: Int,
        contextMax: Int,
        contextPercent: Int,
        compressions: Int,
        isCompacting: Bool,
        updatedAt: Int,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedTokens: Int? = nil,
        totalTokens: Int? = nil,
        sessionInputTokens: Int? = nil,
        sessionOutputTokens: Int? = nil,
        sessionCachedTokens: Int? = nil,
        sessionTotalTokens: Int? = nil,
        sessionIncludesSubagents: Bool? = nil
    ) {
        self.sessionId = sessionId
        self.title = title
        self.model = model
        self.contextUsed = contextUsed
        self.contextMax = contextMax
        self.contextPercent = contextPercent
        self.compressions = compressions
        self.isCompacting = isCompacting
        self.updatedAt = updatedAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.totalTokens = totalTokens
        self.sessionInputTokens = sessionInputTokens
        self.sessionOutputTokens = sessionOutputTokens
        self.sessionCachedTokens = sessionCachedTokens
        self.sessionTotalTokens = sessionTotalTokens
        self.sessionIncludesSubagents = sessionIncludesSubagents
    }

    /// True when Hermes published at least one latest or cumulative token metric.
    var hasTokenAccounting: Bool {
        inputTokens != nil || outputTokens != nil || cachedTokens != nil || totalTokens != nil
            || sessionInputTokens != nil || sessionOutputTokens != nil
            || sessionCachedTokens != nil || sessionTotalTokens != nil
    }

    func routed(to sessionID: String) -> SessionContextSnapshot {
        var snapshot = self
        snapshot.sessionId = sessionID
        return snapshot
    }
}

enum ChatSessionTitlePresentation {
    static let lineLimit = 1
    static let minimumHeight = 36.0
    static let verticalOffset = -4.0
}

/// The single source of truth for the active-turn model lockout.
///
/// Hermes applies a model or reasoning change on the next turn, so offering the
/// picker mid-turn promises something the runtime will not deliver. The chip
/// stays visible and readable — only its selection affordance is withheld.
enum ChatRuntimeSelectionLockout {
    static let message = "The model and thinking level stay fixed until this turn finishes."
    static let accessibilityHint = "Unavailable while this turn is running."

    static func isLocked(isTurnActive: Bool) -> Bool {
        isTurnActive
    }

    static func accessibilityHint(isTurnActive: Bool) -> String {
        isLocked(isTurnActive: isTurnActive)
            ? accessibilityHint
            : "Opens settings for this session."
    }
}

/// The circular context indicator reads its fill and tint from the authoritative
/// Hermes projection. Thresholds are shared with tests so the visual language
/// cannot drift from the accessibility description.
enum SessionContextRingPresentation {
    struct RGBA: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        fileprivate func interpolated(to other: RGBA, progress: Double) -> RGBA {
            RGBA(
                red: red + ((other.red - red) * progress),
                green: green + ((other.green - green) * progress),
                blue: blue + ((other.blue - blue) * progress),
                alpha: alpha + ((other.alpha - alpha) * progress)
            )
        }
    }

    enum Theme: Equatable, Sendable {
        case light
        case dark
    }

    private struct TintAnchor {
        let usedPercent: Double
        let color: RGBA
    }

    static let diameter: CGFloat = 30
    static let lineWidth: CGFloat = 3

    /// A theme-aware tint that stays neutral at low usage, then transitions
    /// continuously through yellow, orange, and red as the window fills.
    static func tint(usedPercent: Int, theme: Theme) -> RGBA {
        let usedPercent = Double(clampPercent(usedPercent))
        let anchors = tintAnchors(for: theme)

        guard let upperIndex = anchors.firstIndex(where: { usedPercent <= $0.usedPercent }) else {
            return anchors[anchors.count - 1].color
        }
        let upper = anchors[upperIndex]
        guard usedPercent != upper.usedPercent else { return upper.color }
        guard upperIndex > 0 else { return upper.color }

        let lower = anchors[upperIndex - 1]
        let progress = (usedPercent - lower.usedPercent)
            / (upper.usedPercent - lower.usedPercent)
        return lower.color.interpolated(to: upper.color, progress: progress)
    }

    /// Fraction of the ring that is drawn as consumed, in `0...1`.
    static func fill(usedPercent: Int) -> Double {
        Double(clampPercent(usedPercent)) / 100
    }

    /// The short label rendered inside the ring. Percentages are shown as the
    /// remaining share so the ring and its label agree with the popover.
    static func remainingLabel(usedPercent: Int) -> String {
        "\(100 - clampPercent(usedPercent))%"
    }

    static func accessibilityValue(for snapshot: SessionContextSnapshot) -> String {
        SessionContextPresentation.summary(for: snapshot)
    }

    private static func tintAnchors(for theme: Theme) -> [TintAnchor] {
        let colors: (neutral: RGBA, yellow: RGBA, orange: RGBA, red: RGBA) = switch theme {
        case .light:
            (
                RGBA(red: 0.36, green: 0.36, blue: 0.38),
                RGBA(red: 0.78, green: 0.58, blue: 0),
                RGBA(red: 0.88, green: 0.32, blue: 0),
                RGBA(red: 0.80, green: 0.08, blue: 0.10)
            )
        case .dark:
            (
                RGBA(red: 0.78, green: 0.78, blue: 0.80),
                RGBA(red: 1, green: 0.80, blue: 0),
                RGBA(red: 1, green: 0.45, blue: 0),
                RGBA(red: 1, green: 0.12, blue: 0.10)
            )
        }

        return [
            TintAnchor(usedPercent: 0, color: colors.neutral),
            TintAnchor(usedPercent: 40, color: colors.neutral),
            TintAnchor(usedPercent: 50, color: colors.yellow),
            TintAnchor(usedPercent: 80, color: colors.orange),
            TintAnchor(usedPercent: 98, color: colors.red),
            TintAnchor(usedPercent: 100, color: colors.red),
        ]
    }

    static func clampPercent(_ value: Int) -> Int {
        max(0, min(100, value))
    }
}

struct SessionContextTokenRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let value: String
}

/// The context window's line on the chat's Model settings sheet: how full it is, in plain words.
struct SessionContextWindowLine: Equatable {
    /// 0 to 1 of the window in use.
    let fraction: Double
    /// "34% used", or "Compacting…" while Hermes compacts.
    let value: String
    let caption: String
    /// Drawn in the warning color.
    let isAlmostFull: Bool
    let isCompacting: Bool
}

enum SessionContextPresentation {
    /// From here the window reads as almost full.
    static let almostFullPercent = 85

    /// Nil when Hermes reported no window size: there's nothing true to draw. `showsTokens` is Nerd
    /// Mode, where the token counts take the plain words' place.
    static func windowLine(for snapshot: SessionContextSnapshot, showsTokens: Bool) -> SessionContextWindowLine? {
        guard snapshot.contextMax > 0 else { return nil }
        let percent = max(0, min(100, snapshot.contextPercent))
        let isAlmostFull = percent >= almostFullPercent
        if snapshot.isCompacting {
            return SessionContextWindowLine(
                fraction: Double(percent) / 100, value: String(localized: "Compacting…"),
                caption: String(localized: "Making room in this chat."), isAlmostFull: false, isCompacting: true)
        }
        let compacted: String? = switch snapshot.compressions {
        case ..<1: nil
        case 1: String(localized: "Compacted once")
        default: String(localized: "Compacted \(snapshot.compressions) times")
        }
        let caption: String
        if showsTokens {
            let tokens = String(localized: "\(exactCount(snapshot.contextUsed)) of \(exactCount(snapshot.contextMax)) tokens")
            caption = [tokens, compacted].compactMap { $0 }.joined(separator: " · ")
        } else if isAlmostFull {
            caption = String(localized: "Almost full. Hermes compacts the chat to make room.")
        } else {
            let room = percent < 60 ? String(localized: "Plenty of room left") : String(localized: "Filling up")
            caption = [room, compacted].compactMap { $0 }.joined(separator: " · ")
        }
        return SessionContextWindowLine(
            fraction: Double(percent) / 100, value: String(localized: "\(percent)% used"), caption: caption,
            isAlmostFull: isAlmostFull, isCompacting: false)
    }

    static func compactUsage(for snapshot: SessionContextSnapshot) -> String {
        "\(compactCount(snapshot.contextUsed)) / \(compactCount(snapshot.contextMax)) (\(snapshot.contextPercent)%)"
    }

    static func summary(for snapshot: SessionContextSnapshot) -> String {
        let remainingPercent = max(0, min(100, 100 - snapshot.contextPercent))
        return "\(remainingPercent)% left (\(compactCount(snapshot.contextUsed)) used / \(compactCount(snapshot.contextMax)))"
    }

    /// The popover rows. Only metrics Hermes actually published are listed, so
    /// an older plugin never renders a misleading zero.
    static func tokenRows(for snapshot: SessionContextSnapshot) -> [SessionContextTokenRow] {
        var rows: [SessionContextTokenRow] = []
        if let inputTokens = snapshot.inputTokens {
            rows.append(SessionContextTokenRow(
                id: "latest-input",
                title: "Latest input",
                value: exactCount(inputTokens)
            ))
        }
        if let outputTokens = snapshot.outputTokens {
            rows.append(SessionContextTokenRow(
                id: "latest-output",
                title: "Latest output",
                value: exactCount(outputTokens)
            ))
        }
        if let cachedTokens = snapshot.cachedTokens {
            rows.append(SessionContextTokenRow(
                id: "latest-cached",
                title: "Latest cached",
                value: exactCount(cachedTokens)
            ))
        }
        if let totalTokens = snapshot.totalTokens {
            rows.append(SessionContextTokenRow(
                id: "latest-total",
                title: "Latest request total",
                value: exactCount(totalTokens)
            ))
        }
        rows.append(SessionContextTokenRow(
            id: "context",
            title: "Context used",
            value: "\(exactCount(snapshot.contextUsed)) / \(exactCount(snapshot.contextMax))"
        ))
        if let sessionInputTokens = snapshot.sessionInputTokens {
            rows.append(SessionContextTokenRow(
                id: "session-input", title: "Session input",
                value: exactCount(sessionInputTokens)
            ))
        }
        if let sessionOutputTokens = snapshot.sessionOutputTokens {
            rows.append(SessionContextTokenRow(
                id: "session-output", title: "Session output",
                value: exactCount(sessionOutputTokens)
            ))
        }
        if let sessionCachedTokens = snapshot.sessionCachedTokens {
            rows.append(SessionContextTokenRow(
                id: "session-cached", title: "Session cached",
                value: exactCount(sessionCachedTokens)
            ))
        }
        if let sessionTotalTokens = snapshot.sessionTotalTokens {
            rows.append(SessionContextTokenRow(
                id: "session-total",
                title: snapshot.sessionIncludesSubagents == true
                    ? "Session total (incl. subagents)"
                    : "Session total",
                value: exactCount(sessionTotalTokens)
            ))
        }
        if snapshot.compressions > 0 {
            rows.append(SessionContextTokenRow(
                id: "compressions",
                title: "Compactions",
                value: exactCount(snapshot.compressions)
            ))
        }
        return rows
    }

    static func exactCount(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private static func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return scaledCount(value, divisor: 1_000_000, suffix: "M")
        }
        if value >= 1_000 {
            return scaledCount(value, divisor: 1_000, suffix: "K")
        }
        return String(value)
    }

    private static func scaledCount(
        _ value: Int,
        divisor: Int,
        suffix: String
    ) -> String {
        let whole = value / divisor
        let remainder = value % divisor
        guard remainder != 0, whole < 10 else { return "\(whole)\(suffix)" }
        let decimal = (Double(value) / Double(divisor) * 10).rounded() / 10
        return "\(decimal.formatted(.number.precision(.fractionLength(0...1))))\(suffix)"
    }
}
