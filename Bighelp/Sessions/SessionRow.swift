import Foundation
import SwiftUI

/// One Messages-style inbox row: the agent avatar doubles as the live status,
/// then a single title line and a single plain-text preview line.
struct SessionRow: View {
    let session: SessionSummary
    let agents: AgentDirectoryStore

    static let avatarSize: CGFloat = 52
    /// Separators start where the text column starts, like Messages.
    static let textLeading: CGFloat = avatarSize + BighelpTokens.space12

    @ScaledMetric(relativeTo: .callout) private var titleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .footnote) private var timeSize: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var previewSize: CGFloat = 14

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            SessionIdentityView(session: session, agents: agents, size: Self.avatarSize, state: liveState)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                    Text(session.title)
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: timeSize * 0.8))
                            .foregroundStyle(theme.tertiaryText)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: BighelpTokens.space4)
                    Text(Self.compactTimestamp(session.updatedAt))
                        .font(.system(size: timeSize))
                        .monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                HStack(spacing: 6) {
                    if liveState != .idle {
                        Circle()
                            .fill(liveState.dotColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                    if let origin = SessionOrigin.label(session.origin) {
                        Text(origin)
                            .font(.system(size: timeSize * 0.85, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(theme.incomingMessageBackground, in: .capsule)
                            .fixedSize()
                    }
                    Text(previewLine)
                        .font(.system(size: previewSize))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("session.row.\(session.id)")
    }

    /// Live state from the catalog's real activity flag; nothing is inferred.
    private var liveState: AgentLiveState { session.isActive ? .thinking : .idle }

    private var plainPreview: String { SessionPreviewText.plain(session.preview) }

    private var previewLine: String {
        if !plainPreview.isEmpty { return plainPreview }
        if liveState != .idle { return liveState.label }
        return agentNames.joined(separator: ", ")
    }

    /// Messages-style timestamp: time today, then "Yesterday", weekday, or a short date.
    nonisolated static func compactTimestamp(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        // Relative to `now`, not the device clock, so it holds across midnight and time zones.
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < now {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    private var profilesByID: [String: AgentProfile] {
        Dictionary(uniqueKeysWithValues: agents.profiles.map { ($0.id, $0) })
    }

    private var agentNames: [String] {
        session.agentIDs.map { profilesByID[$0]?.name ?? "Unavailable agent" }
    }

    private var accessibilityLabel: String {
        let kind = session.kind == .botMode ? "Group chat" : "Chat"
        let preview = plainPreview.isEmpty ? "No preview" : plainPreview
        let state = [
            session.isActive ? "Active" : nil,
            session.isPinned ? "Pinned" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        let stateLabel = state.isEmpty ? "" : "\(state). "
        let origin = SessionOrigin.label(session.origin).map { " Started in \($0)." } ?? ""
        return "\(session.title). \(stateLabel)\(preview). \(agentNames.joined(separator: ", ")). \(kind).\(origin) \(session.updatedAt.formatted(.relative(presentation: .named)))"
    }

    @BighelpThemeReader private var theme

}

/// Reduces a Markdown message preview to one line of plain text so list rows
/// never show raw `**`, `#`, or link syntax.
enum SessionPreviewText {
    nonisolated static func plain(_ raw: String) -> String {
        // Previews render on one line; bound the parse work for long replies.
        let bounded = String(raw.prefix(600))
        var lines: [String] = []
        var insideFence = false
        for line in bounded.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            if insideFence {
                lines.append(trimmed)
                continue
            }
            // Block markers: headings, quotes, list bullets, task boxes, rules.
            let unblocked = trimmed.replacingOccurrences(
                of: #"^(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)+"#,
                with: "",
                options: .regularExpression
            )
            if unblocked.range(of: #"^(?:[-*_]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            if !unblocked.isEmpty { lines.append(unblocked) }
        }
        let joined = lines.joined(separator: " ")
        let inline: String
        if let attributed = try? AttributedString(
            markdown: joined,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            inline = String(attributed.characters)
        } else {
            inline = joined
        }
        return inline
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The identity for chat rows and pins. Single-agent chats show that agent's
/// avatar with its live state; group chats show an overlapping avatar stack.
struct SessionIdentityView: View {
    let session: SessionSummary
    let agents: AgentDirectoryStore
    let size: CGFloat
    var state: AgentLiveState = .idle

    var body: some View {
        Group {
            if identities.count == 1, let identity = identities.first {
                AvatarView(
                    stableID: identity.id,
                    displayName: identity.name,
                    imageURL: identity.imageURL,
                    size: size,
                    state: state
                )
            } else {
                AvatarStack(
                    avatars: identities.prefix(2).map {
                        AvatarStack.Avatar(stableID: $0.id, displayName: $0.name, imageURL: $0.imageURL)
                    },
                    size: size * 0.65,
                    outlineColor: theme.canvas
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.title)
    }

    private struct Identity: Identifiable {
        let id: String
        let name: String
        let imageURL: URL?
    }

    private var identities: [Identity] {
        let mapped = session.agentIDs.prefix(4).map { agentID -> Identity in
            guard let profile = agents.profiles.first(where: { $0.id == agentID }) else {
                return Identity(id: "unavailable-\(agentID)", name: "Unavailable agent", imageURL: nil)
            }
            return Identity(id: profile.id, name: profile.name, imageURL: agents.avatarURL(for: profile))
        }
        return mapped.isEmpty
            ? [Identity(id: "session-\(session.id)", name: session.title, imageURL: nil)]
            : mapped
    }

    @BighelpThemeReader private var theme
}

/// Shape-matched stand-in for `SessionRow` while the first page of chats loads.
struct SessionRowPlaceholder: View {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            Circle()
                .fill(theme.incomingMessageBackground)
                .frame(width: SessionRow.avatarSize, height: SessionRow.avatarSize)
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                HStack {
                    bar(width: index.isMultiple(of: 2) ? 140 : 100, height: 14)
                    Spacer(minLength: BighelpTokens.space8)
                    bar(width: 36, height: 10)
                }
                bar(width: index.isMultiple(of: 3) ? 160 : 220, height: 12)
            }
        }
        .padding(.vertical, BighelpTokens.space4)
        .opacity(isPulsing ? 0.45 : 1)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                .delay(Double(index) * 0.08),
            value: isPulsing
        )
        .onAppear { isPulsing = true }
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(theme.incomingMessageBackground)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    @BighelpThemeReader private var theme
}

/// First-run Chats screen: one clear action, then three plain steps.
struct SessionsGettingStartedView: View {
    let onStart: (() -> Void)?

    private let steps: [(title: String, detail: String)] = [
        ("Pick an agent", "Each agent keeps its own skills and memory."),
        ("Say what you need", "Type, talk, or attach a photo or file."),
        ("Get notified when it's done", "Work keeps going while you're away."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space24) {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Text("Your first chat")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.action)
                Text("Ask for anything.\nYour agent takes it from there.")
                    .font(.bighelp(.title2).bold())
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let onStart {
                    Button(action: onStart) {
                        Label("New chat", systemImage: "square.and.pencil")
                            .font(.bighelp(.body).weight(.semibold))
                            .padding(.horizontal, BighelpTokens.space8)
                            .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .bighelpProminentButtonStyle()
                    .buttonBorderShape(.capsule)
                    .tint(theme.action)
                    .accessibilityIdentifier("sessions.empty.new-chat")
                }
            }
            .padding(BighelpTokens.space20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.cardCornerRadius, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: BighelpTokens.hairline)
            }

            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                Text("How it works")
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: BighelpTokens.space12) {
                        Text("\(index + 1)")
                            .font(.bighelp(.headline))
                            .foregroundStyle(theme.action)
                            .frame(width: 40, height: 40)
                            .background(theme.incomingMessageBackground, in: .circle)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.bighelp(.subheadline).weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                            Text(step.detail)
                                .font(.bighelp(.subheadline))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(BighelpTokens.space12)
                    .overlay {
                        RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                            .strokeBorder(theme.border, lineWidth: BighelpTokens.hairline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(index + 1): \(step.title). \(step.detail)")
                }
            }
        }
        .padding(.vertical, BighelpTokens.space8)
        .accessibilityElement(children: .contain)
    }

    @BighelpThemeReader private var theme
}
