import Foundation

/// A computer's tool page, opened with `RootShellView.openWorkspaceDestination(_:)` from where it
/// belongs (Settings, a computer's page, a bot's Advanced Options) on the route `.workspaceManagement`.
enum WorkspaceDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case scheduledTasks
    case projects, files, artifacts, wiki
    case models, skills, toolsets, memory
    case plugins, mcp, messaging, voice, webhooks, keys
    case usage, logs, profiles, system
    case sessionMaintenance, profileLifecycle
    case instances, security, appearance, tabBar, caching, contact, permissions, watch

    var id: Self { self }

    var title: String {
        switch self {
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
        case .keys: "AI providers"
        case .usage: "Usage"
        case .logs: "Logs"
        case .profiles: "Profiles"
        case .sessionMaintenance: "Manage Sessions"
        case .profileLifecycle: "Manage Profiles"
        case .system: "System"
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
}
