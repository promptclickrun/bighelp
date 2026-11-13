import SwiftUI

/// How much of a card a panel shows (`BighelpCardRenderer` reads it): fewer list items, table rows
/// and columns, a shorter chart and fewer lines of text, so a card made for a chat fits a panel.
/// Nil in chats, where cards draw as they always have.
struct BighelpCardLimits: Equatable, Sendable {
    var maxListItems: Int
    var maxTableRows: Int
    var maxTableColumns: Int
    var chartHeight: CGFloat
    var maxTextLines: Int
    /// The panel's header already names the space, so the root card's own title isn't drawn again.
    var omitsRootTitle: Bool

    static func panel(_ size: SpaceSize) -> Self {
        switch size {
        case .small: Self(maxListItems: 3, maxTableRows: 3, maxTableColumns: 3, chartHeight: 48, maxTextLines: 2,
                          omitsRootTitle: true)
        case .wide: Self(maxListItems: 3, maxTableRows: 3, maxTableColumns: 5, chartHeight: 64, maxTextLines: 2,
                         omitsRootTitle: true)
        case .tall: Self(maxListItems: 8, maxTableRows: 8, maxTableColumns: 8, chartHeight: 140, maxTextLines: 4,
                         omitsRootTitle: true)
        }
    }
}

private struct BighelpCardLimitsKey: EnvironmentKey {
    static let defaultValue: BighelpCardLimits? = nil
}

extension EnvironmentValues {
    var bighelpCardLimits: BighelpCardLimits? {
        get { self[BighelpCardLimitsKey.self] }
        set { self[BighelpCardLimitsKey.self] = newValue }
    }
}

/// What Try again on a stopped panel is doing, and what the computer said last.
enum SpacePanelRetry: Equatable, Sendable {
    case idle
    case running
    /// Update now ran less than a minute ago (`refresh_too_soon`).
    case tooSoon
    /// The routine ran and failed (`routine_failed`).
    case failed

    /// Only the two answers the person can act on get words; anything else offers Try again again.
    static func after(_ error: SpacesError) -> Self {
        switch error {
        case .tooSoon: .tooSoon
        case .routineFailed: .failed
        default: .idle
        }
    }
}

/// A panel's one footer line, from what the computer said about the space. Never the time the
/// panel was drawn: "Updated" is the space's own `updatedAt`.
enum SpacePanelFooter: Equatable, Sendable {
    /// The card isn't read yet: a still placeholder.
    case loading
    /// The computer sent a card this app can't draw.
    case unreadable
    /// Its computer isn't connected: the last card stays above.
    case notConnected
    case updated(Date?, usesAI: Bool)
    /// The routine isn't running: Try again, and what it did.
    case stopped(SpacePanelRetry)
    /// The person paused its routine in Scheduled tasks: only they resume it, there. No Try again.
    case paused
    /// The bot changed its script after the space was added: the bot drafts it again and the
    /// person adds it again (the draft card). No Try again, which can't fix it.
    case scriptChanged
    /// A draft's preview in the chat: nothing has updated it yet.
    case none

    static func state(for item: TodaySpace, size: SpaceSize, retry: SpacePanelRetry = .idle) -> Self {
        state(space: item.space, size: size, isConnected: item.isConnected, retry: retry)
    }

    static func state(space: Space, size: SpaceSize, isConnected: Bool, retry: SpacePanelRetry = .idle) -> Self {
        if !isConnected { return .notConnected }
        if space.card(for: size) == nil { return space.cardUnreadable ? .unreadable : .loading }
        if space.state == .draft { return .none }
        if space.isStopped {
            if space.isScriptChanged { return .scriptChanged }
            if space.isPaused { return .paused }
            return .stopped(retry)
        }
        return .updated(space.updatedAt, usesAI: space.routine.usesAI)
    }
}

/// "2:14 PM" for today, "Nov 10" for another day this year, "Nov 10, 2025" before that.
enum SpacePanelTime {
    static func text(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let zone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                   calendar: calendar, timeZone: zone))
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: zone).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }
}

/// Runs a panel's Try again and keeps its answer. Owned by the panel's `@State`: a panel that
/// goes away takes it with it, and a late answer then changes nothing.
@MainActor
@Observable
final class SpacePanelRetryModel {
    private(set) var state: SpacePanelRetry = .idle
    @ObservationIgnored private var running: Task<Void, Never>?

    /// The action throws `SpacesError`. Its type says plain `throws`: a view can't keep a typed-throws
    /// closure before iOS 18 (the runtime has no type for it).
    func run(_ action: @escaping @MainActor () async throws -> SpaceRefreshRun) {
        guard running == nil else { return }
        state = .running
        running = Task { [weak self] in
            let next: SpacePanelRetry
            do {
                // A paused routine ran nothing (`.paused`): the space it came back with says so.
                _ = try await action()
                next = .idle
            } catch {
                next = SpacePanelRetry.after(error as? SpacesError ?? .other(code: nil))
            }
            guard let self else { return }
            self.state = next
            self.running = nil
        }
    }
}

/// One space on Today: its title and bot, its card at the panel's size in a fixed frame, and one
/// footer line. A tap opens its page. The grid around it (`TodayPanelCell`) draws the surface and
/// the long-press menu; the chat's draft card shows the same view as its preview.
struct SpacePanelView: View {
    let space: Space
    let size: SpaceSize
    /// Small, beside the title. Nil leaves it out (a preview in the bot's own chat).
    var botName: String? = nil
    var isConnected = true
    /// Opens the page. Nil for a space without one, and for a preview.
    var onOpen: (() -> Void)? = nil
    /// Try again on a stopped panel: Update now on its computer. Nil hides it.
    var runNow: (@MainActor () async throws -> SpaceRefreshRun)? = nil

    @State private var retry = SpacePanelRetryModel()
    @BighelpThemeReader private var theme

    /// The card's room at each size; header and footer come on top.
    static func cardHeight(_ size: SpaceSize) -> CGFloat {
        BighelpTokens.scaled(size == .tall ? 260 : 96)
    }

    private var footerState: SpacePanelFooter {
        SpacePanelFooter.state(space: space, size: size, isConnected: isConnected, retry: retry.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if let onOpen {
                Button(action: onOpen) { content }
                    .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: space.title))
                    .accessibilityValue(Text(verbatim: space.card(for: size)?.spokenSummary ?? ""))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("today.space.\(space.spaceID).open")
            } else {
                content
            }
            SpacePanelFooterLine(state: footerState, canRetry: runNow != nil) {
                if let runNow { retry.run(runNow) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.space.\(space.spaceID)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            header
            cardArea
        }
        .contentShape(.rect)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                title
                Spacer(minLength: BighelpTokens.space4)
                bot
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                bot
            }
        }
    }

    private var title: some View {
        Text(verbatim: space.title)
            .font(.bighelp(.subheadline, weight: .semibold))
            .foregroundStyle(theme.primaryText)
            .lineLimit(2)
    }

    @ViewBuilder
    private var bot: some View {
        if let botName {
            Text(verbatim: botName)
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
    }

    private var cardArea: some View {
        let height = Self.cardHeight(size)
        return ZStack(alignment: .topLeading) {
            if let card = space.card(for: size) {
                // The card takes the panel's height and shows the rows and lines that fit, each whole
                // (`BighelpCardWholeRows`): a line cut or faded at the edge reads as a broken panel.
                BighelpCardRenderer(card: card)
                    .environment(\.bighelpCardLimits, .panel(size))
                    .frame(maxWidth: .infinity, maxHeight: height, alignment: .topLeading)
            } else if space.cardUnreadable {
                Image(systemName: "rectangle.dashed")
                    .font(.bighelp(.title2))
                    .foregroundStyle(theme.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else {
                SpacePanelPlaceholder()
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .clipped()
    }
}

/// A still block where the card will be. Never animated.
struct SpacePanelPlaceholder: View {
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).frame(width: 64, height: 22)
            RoundedRectangle(cornerRadius: 5, style: .continuous).frame(maxWidth: 140).frame(height: 12)
        }
        .foregroundStyle(theme.separator.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The footer: one status and, on a stopped panel, Try again. It wraps under itself at large text.
private struct SpacePanelFooterLine: View {
    let state: SpacePanelFooter
    let canRetry: Bool
    let onRetry: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .loading:
            Capsule()
                .fill(theme.separator.opacity(0.6))
                .frame(width: 80, height: 10)
                .accessibilityHidden(true)
        case .unreadable:
            status(Text("Can't show this"), symbol: "exclamationmark.triangle")
        case .notConnected:
            status(Text("Not connected"), symbol: "bolt.horizontal.circle")
        case .updated(let date, let usesAI):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BighelpTokens.space8) { updated(date); badge(usesAI) }
                VStack(alignment: .leading, spacing: BighelpTokens.space4) { updated(date); badge(usesAI) }
            }
        case .paused:
            status(Text("Paused in Scheduled tasks"), symbol: "pause.circle")
        case .scriptChanged:
            status(Text("Stopped: its script changed"), symbol: "exclamationmark.circle")
        case .stopped(let retry):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BighelpTokens.space8) {
                    stoppedText(retry)
                    Spacer(minLength: 0)
                    retryControl(retry)
                }
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    stoppedText(retry)
                    retryControl(retry)
                }
            }
        }
    }

    @ViewBuilder
    private func updated(_ date: Date?) -> some View {
        if let date {
            Text("Updated \(SpacePanelTime.text(date, now: Date()))")
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("today.space.updated")
        }
    }

    @ViewBuilder
    private func badge(_ usesAI: Bool) -> some View {
        if usesAI {
            Text("Uses AI")
                .font(.bighelp(.caption2, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay { Capsule().strokeBorder(theme.border) }
                .accessibilityIdentifier("today.space.uses-ai")
        }
    }

    private func stoppedText(_ retry: SpacePanelRetry) -> some View {
        let text: Text = switch retry {
        case .idle, .running: Text("Stopped updating")
        case .tooSoon: Text("Try again in a minute")
        case .failed: Text("Its update failed")
        }
        return status(text, symbol: "pause.circle")
    }

    @ViewBuilder
    private func retryControl(_ retry: SpacePanelRetry) -> some View {
        if retry == .running {
            Text("Updating…")
                .font(.bighelp(.caption, weight: .semibold))
                .foregroundStyle(theme.tertiaryText)
                .frame(minHeight: BighelpTokens.hitTarget)
        } else if canRetry {
            Button(action: onRetry) {
                Text("Try again")
                    .font(.bighelp(.caption, weight: .semibold))
                    .foregroundStyle(theme.action)
                    .padding(.horizontal, BighelpTokens.space4)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("today.space.try-again")
        }
    }

    private func status(_ text: Text, symbol: String) -> some View {
        Label { text } icon: { Image(systemName: symbol) }
            .font(.bighelp(.caption))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("today.space.status")
    }
}

/// One choice in a row of chips (sizes, examples): a capsule, filled while it's picked.
struct SpacesChip: View {
    let title: Text
    var isOn = false
    let identifier: String
    let action: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        Button(action: action) {
            title
                .lineLimit(1)
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(isOn ? theme.actionForeground : theme.primaryText)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: BighelpTokens.scaled(34))
                .background(isOn ? theme.action : theme.surface, in: .capsule)
                .overlay { Capsule().strokeBorder(isOn ? .clear : theme.border) }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
