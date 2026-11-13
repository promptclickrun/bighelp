import Foundation

enum SettingsMenuSection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case modes
    case appearance
    case chat
    case voice
    case notifications
    case permissions
    case companion
    case help

    var id: Self { self }

    var title: String {
        switch self {
        case .modes: String(localized: "Modes")
        case .chat: String(localized: "Chat")
        case .voice: String(localized: "Voice")
        case .notifications: String(localized: "Notifications")
        case .appearance: String(localized: "Appearance")
        case .permissions: String(localized: "Device access")
        case .companion: String(localized: "Companion pet")
        case .help: String(localized: "Help & feedback")
        }
    }

    var detail: String {
        switch self {
        case .modes: String(localized: "Bots, Chat and Code")
        case .chat: Self.chatDetail
        case .voice: String(localized: "How voice chats sound")
        case .notifications: String(localized: "Alerts from your bots")
        case .appearance: String(localized: "Colors, light and dark, chat layout")
        case .permissions: String(localized: "Health, calendar, location, microphone and more")
        case .companion: String(localized: "Size and movement")
        case .help: String(localized: "Report a problem, usage sharing and version")
        }
    }

    private static var chatDetail: String {
        #if targetEnvironment(macCatalyst) // A Mac has no haptics or Dynamic Island.
        String(localized: "Where it opens, reactions and Return")
        #else
        String(localized: "Where it opens, haptics and reactions")
        #endif
    }

    var systemImage: String {
        switch self {
        case .modes: "circle.hexagongrid"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .voice: "waveform"
        case .notifications: "bell.badge.fill"
        case .appearance: "paintpalette.fill"
        case .permissions: "hand.raised.fill"
        case .companion: "pawprint.fill"
        case .help: "questionmark.circle.fill"
        }
    }

    /// Existing tests and deep links know these rows by their older names.
    var accessibilityIdentifier: String {
        switch self {
        case .appearance: "settings.themes"
        case .voice: "settings.chat.voice-settings"
        case .companion: "companion-settings-entry"
        default: "settings.menu.\(rawValue)"
        }
    }
}
