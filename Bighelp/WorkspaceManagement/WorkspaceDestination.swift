import Foundation

enum WorkspaceDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case activity, tasks, scheduledTasks
    case projects, files, artifacts, wiki
    case models, skills, toolsets, memory
    case plugins, mcp, messaging, voice, webhooks, keys
    case usage, logs, profiles, config, system, documentation
    case sessionMaintenance, profileLifecycle
    case instances, security, appearance, tabBar, caching, contact, permissions, watch

    /// Hermes Tools lists the host's tools. This app's own settings live in Settings, and usage on ☰ › Usage.
    static let appMenuCases = allCases.filter { $0 != .wiki && $0 != .tasks && $0 != .usage && $0.section != .app }

    var id: Self { self }

    enum Section: String, CaseIterable, Identifiable {
        case work = "Your work"
        case intelligence = "Intelligence"
        case connections = "Connections"
        case host = "Manage Hermes"
        case app = "On this device"
        var id: Self { self }
    }

    var section: Section {
        switch self {
        case .activity, .tasks, .scheduledTasks, .projects, .files, .artifacts, .wiki: .work
        case .models, .skills, .toolsets, .memory: .intelligence
        case .plugins, .mcp, .messaging, .voice, .webhooks, .keys: .connections
        case .usage, .logs, .profiles, .config, .system, .documentation, .sessionMaintenance, .profileLifecycle: .host
        case .instances, .security, .appearance, .tabBar, .caching, .contact, .permissions, .watch: .app
        }
    }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .tasks: "Tasks"
        case .scheduledTasks: "Scheduled Tasks"
        case .projects: "Projects"
        case .files: "Files"
        case .artifacts: "Artifacts"
        case .wiki: "Wiki"
        case .models: "Models"
        case .skills: "Skills"
        case .toolsets: "Toolsets"
        case .memory: "Memory"
        case .plugins: "Plugins"
        case .mcp: "MCP Servers"
        case .messaging: "Messaging"
        case .voice: "Voice"
        case .webhooks: "Webhooks"
        case .keys: "Provider Keys"
        case .usage: "Usage"
        case .logs: "Logs"
        case .profiles: "Profiles"
        case .sessionMaintenance: "Manage Sessions"
        case .profileLifecycle: "Manage Profiles"
        case .config: "Configuration"
        case .system: "System"
        case .documentation: "Documentation"
        case .instances: "Hosts"
        case .security: "Security"
        case .appearance: "Look & Feel"
        case .tabBar: "App Layout"
        case .caching: "Caching"
        case .contact: "Contact"
        case .permissions: "Device Permissions"
        case .watch: "Apple Watch"
        }
    }

    var symbol: String {
        switch self {
        case .activity: "bell"
        case .tasks: "checklist"
        case .scheduledTasks: "calendar.badge.clock"
        case .projects: "folder"
        case .files: "doc"
        case .artifacts: "doc.richtext"
        case .wiki: "books.vertical"
        case .models: "cpu"
        case .skills: "sparkles"
        case .toolsets: "wrench.and.screwdriver"
        case .memory: "brain"
        case .plugins: "puzzlepiece.extension"
        case .mcp: "externaldrive.connected.to.line.below"
        case .messaging: "bubble.left.and.bubble.right"
        case .voice: "waveform"
        case .webhooks: "arrow.triangle.branch"
        case .keys: "key"
        case .usage: "chart.bar"
        case .logs: "doc.text.magnifyingglass"
        case .profiles: "person.crop.rectangle.stack"
        case .sessionMaintenance: "tray.full"
        case .profileLifecycle: "person.crop.circle.badge.gearshape"
        case .config: "slider.horizontal.3"
        case .system: "server.rack"
        case .documentation: "book"
        case .instances: "network"
        case .security: "lock.shield"
        case .appearance: "paintpalette"
        case .tabBar: "rectangle.bottomthird.inset.filled"
        case .caching: "internaldrive"
        case .contact: "envelope"
        case .permissions: "hand.raised"
        case .watch: "applewatch"
        }
    }

    var summary: String {
        switch self {
        case .activity: "Updates and work needing your attention"
        case .tasks: "Goals and tasks in your sessions"
        case .scheduledTasks: "Work scheduled and run by Hermes"
        case .projects: "Registered workspaces and folders"
        case .files: "Browse the host's permitted file root"
        case .artifacts: "Files in this host’s configured workspace"
        case .wiki: "Connected knowledge folders"
        case .models: "Configured providers and available models"
        case .skills: "Discover and manage agent skills"
        case .toolsets: "Tools enabled for the selected profile"
        case .memory: "What Hermes remembers"
        case .plugins: "Extensions installed on this host"
        case .mcp: "Tool servers connected through Hermes"
        case .messaging: "Hermes messaging connections"
        case .voice: "Speech and voice preferences"
        case .webhooks: "External events handled by Hermes"
        case .keys: "Sign in to model providers and add API keys"
        case .usage: "Host-reported model usage"
        case .logs: "Bounded, redacted host diagnostics"
        case .profiles: "Agent profiles and runtime defaults"
        case .sessionMaintenance: "Import, export, and clean up saved sessions"
        case .profileLifecycle: "Import, rename, and manage agent profiles"
        case .config: "Profile configuration"
        case .system: "Host health and version"
        case .documentation: "Official Hermes guides"
        case .instances: "Saved hosts and connection settings"
        case .security: "Account and device access"
        case .appearance: "Themes, typography and appearance"
        case .tabBar: "Bottom bar and menu order"
        case .caching: "Local storage and offline state"
        case .contact: "Help and feedback"
        case .permissions: "Phone tools and system permissions"
        case .watch: "Paired Watch and phone connectivity"
        }
    }

    /// The shell supplies these existing destinations rather than duplicating their models.
    var usesExistingDestination: Bool {
        switch self {
        case .activity, .tasks, .scheduledTasks, .artifacts, .wiki, .skills, .voice, .profiles, .sessionMaintenance, .profileLifecycle,
             .instances, .security, .appearance, .tabBar, .caching, .contact, .permissions, .watch: true
        default: false
        }
    }
}
