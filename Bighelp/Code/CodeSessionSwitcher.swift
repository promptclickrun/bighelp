import SwiftUI

extension CodeHomeStore {
    /// A card's state: its send while that's still under way, else what the chat or the list says.
    func status(of session: CodeSessionRecord, reader: any CodeSessionStatusReading) -> CodeSessionStatus {
        if let launch = launch(for: session) {
            if case .failed(let reason) = launch.step { return .failed(reason) }
            return .starting("Sending your message…")
        }
        return reader.status(of: session.id)
    }

    /// Code mode's switcher beside a chat (`BighelpChatSwitcher`): this project's sessions, the
    /// ones working or waiting on you first, then the newest.
    func switcherSessions(reader: any CodeSessionStatusReading) -> [(CodeSessionRecord, CodeSessionStatus)] {
        let sessions = projectSingleSessions.map { ($0, status(of: $0, reader: reader)) }
        func rank(_ status: CodeSessionStatus) -> Int {
            switch status {
            case .needsYou: 0
            case .starting, .running: 1
            case .ready, .failed: 2
            }
        }
        return Array(sessions.sorted { left, right in
            rank(left.1) != rank(right.1) ? rank(left.1) < rank(right.1) : left.0.startedAt > right.0.startedAt
        }.prefix(BighelpChatSwitcher.limit))
    }
}

/// A Code session in the switcher: its initials in its color, and a badge for what it's doing.
struct CodeSessionSwitcherTile: View {
    let title: String
    let status: CodeSessionStatus
    let color: Color

    var body: some View {
        Text(initials)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 38, height: 38)
            .background(color.opacity(0.16), in: .rect(cornerRadius: 11, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(badge.tint, in: .circle)
                        .overlay(Circle().stroke(theme.canvas, lineWidth: 1.5))
                        .offset(x: 4, y: 4)
                }
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }

    private var badge: (symbol: String, tint: Color)? {
        switch status {
        case .starting, .running: ("gearshape.2.fill", theme.action)
        case .needsYou: ("hand.raised.fill", theme.warning)
        case .failed: ("exclamationmark", theme.danger)
        case .ready: nil
        }
    }

    @BighelpThemeReader private var theme
}

extension CodeSessionStatus {
    /// What VoiceOver says after the session's name in the switcher.
    var switcherLabel: String {
        switch self {
        case .starting: String(localized: "Starting")
        case .running: String(localized: "Working")
        case .needsYou: String(localized: "Needs you")
        case .ready: String(localized: "Ready")
        case .failed: String(localized: "Couldn't start")
        }
    }
}
