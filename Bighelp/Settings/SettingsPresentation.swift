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

    var id: Self { self }

    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .agentsAndPersonalities: "Agents & Personalities"
        case .chat: "Chat"
        case .voice: "Voice"
        case .notifications: "Notifications"
        case .appearance: "Appearance"
        case .permissions: "Permissions"
        case .connectivityAndNotifications: "System"
        case .companion: "Companion pet"
        case .help: "Help & feedback"
        case .watch: "Apple Watch"
        }
    }

    var detail: String {
        switch self {
        case .workspace: "Sessions, scheduled tasks, and gestures"
        case .agentsAndPersonalities: "Manage how Hermes agents present themselves"
        case .chat: Self.chatDetail
        case .voice: "How voice chats sound"
        case .notifications: "Alerts from your agents"
        case .appearance: "Colors, light and dark, chat layout"
        case .permissions: "Microphone, camera, photos and more"
        case .connectivityAndNotifications: "Your computers, Hermes updates and restarts"
        case .companion: "Character, motion and agent"
        case .help: "Report a problem, guides and version"
        case .watch: "Pairing and connection"
        }
    }

    private static var chatDetail: String {
        #if targetEnvironment(macCatalyst) // A Mac has no haptics or Dynamic Island.
        "Where it opens, reactions and Return"
        #else
        "Where it opens, haptics and reactions"
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
