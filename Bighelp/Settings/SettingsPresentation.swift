import Foundation

enum SettingsMenuSection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case appearance
    case workspace
    case agentsAndPersonalities
    case chat
    case voice
    case notifications
    case permissions
    case connectivityAndNotifications
    case companion
    case help
    case watch
    case carPlay

    var id: Self { self }

    var title: String {
        switch self {
        case .workspace: String(localized: "Workspace")
        case .agentsAndPersonalities: String(localized: "Agents & Personalities")
        case .chat: String(localized: "Chat")
        case .voice: String(localized: "Voice")
        case .notifications: String(localized: "Notifications")
        case .appearance: String(localized: "Appearance")
        case .permissions: String(localized: "Permissions")
        case .connectivityAndNotifications: String(localized: "System")
        case .companion: String(localized: "Companion pet")
        case .help: String(localized: "Help & feedback")
        case .watch: String(localized: "Apple Watch")
        case .carPlay: "CarPlay"
        }
    }

    var detail: String {
        switch self {
        case .workspace: String(localized: "Sessions, scheduled tasks, and gestures")
        case .agentsAndPersonalities: String(localized: "Manage how Hermes agents present themselves")
        case .chat: Self.chatDetail
        case .voice: String(localized: "How voice chats sound")
        case .notifications: String(localized: "Alerts from your agents")
        case .appearance: String(localized: "Colors, light and dark, chat layout")
        case .permissions: String(localized: "Microphone, camera, photos, usage sharing and more")
        case .connectivityAndNotifications: String(localized: "Your computers, Hermes updates and restarts")
        case .companion: String(localized: "Character, motion and agent")
        case .help: String(localized: "Report a problem, guides and version")
        case .watch: String(localized: "Pairing and connection")
        case .carPlay: String(localized: "The agent and computer it talks to")
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
        case .workspace: "rectangle.3.group"
        case .agentsAndPersonalities: "theatermasks"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .voice: "waveform"
        case .notifications: "bell.badge.fill"
        case .appearance: "paintpalette.fill"
        case .permissions: "hand.raised.fill"
        case .connectivityAndNotifications: "desktopcomputer"
        case .companion: "pawprint.fill"
        case .help: "questionmark.circle.fill"
        case .watch: "applewatch"
        case .carPlay: "car.fill"
        }
    }

    /// Tile colors, so rows are easy to tell apart at a glance.
    var tintHex: String? {
        switch self {
        case .appearance: "8E6BD8"
        case .chat: "3F7FD9"
        case .voice: "E0533D"
        case .notifications: "E5484D"
        case .connectivityAndNotifications: "5B6B7F"
        case .permissions: "3478F6"
        case .watch: "6E6E73"
        case .carPlay: "2E9C5A"
        case .companion: "F28B32"
        case .help: "2E9CA6"
        default: nil
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
