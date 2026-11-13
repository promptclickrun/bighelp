import Foundation

/// Synthetic, in-memory host behavior. Never composed into a production connection.
@MainActor
final class FixtureWorkspaceManagementClient: WorkspaceManagementClient {
    var editableDestinations: Set<WorkspaceDestination> = [.projects, .keys, .webhooks]
    var failure: WorkspaceManagementError?
    private var projects: [WorkspaceProject] = [
        .init(id: "research", name: "Research", summary: "A synthetic workspace for notes and analysis.",
            isArchived: false, folders: [.init(path: "/workspace/research", label: "Notes", isPrimary: true)]),
        .init(id: "website", name: "Website", summary: "A sample project, not a live repository.",
            isArchived: false, folders: [.init(path: "/workspace/website", label: nil, isPrimary: true)])
    ]
    private var credentialIsSet = false
    private var webhookEnabled = true

    func load(_ destination: WorkspaceDestination, path: String?, root: String?) async throws -> WorkspaceManagementContent {
        try Task.checkCancellation()
        if let failure { throw failure }
        switch destination {
        case .projects: return .projects(projects)
        case .models:
            return .models(.init(
                providers: [.init(id: "example", name: "Example provider", models: ["example-reasoner", "example-fast"], isAuthenticated: true)],
                currentProvider: "example", currentModel: "example-reasoner"
            ))
        case .keys:
            return .credentials([.init(id: "EXAMPLE_API_KEY", description: "Synthetic provider credential", category: "Models",
                isSet: credentialIsSet, canReplace: true)])
        case .webhooks:
            return .webhooks([.init(id: "sample-event", description: "Synthetic event handler", events: ["sample.completed"],
                isEnabled: webhookEnabled, hasSecret: true)], platformEnabled: true)
        case .files:
            let selectedPath = path ?? "/workspace"
            guard ["/workspace", "/workspace/notes"].contains(selectedPath), root == nil || root == "/workspace" else {
                throw WorkspaceManagementError.fileRootNotConfined
            }
            let entries: [WorkspaceFileListing.Entry] = selectedPath == "/workspace"
                ? [.init(path: "/workspace/notes", name: "notes", isDirectory: true, size: nil)]
                : [.init(path: "/workspace/notes/example.txt", name: "example.txt", isDirectory: false, size: 23)]
            return .files(.init(path: selectedPath, root: "/workspace", parent: selectedPath == "/workspace" ? nil : "/workspace", entries: entries))
        case .logs:
            return .logs(["INFO - Message withheld to protect private host data"])
        case .memory:
            return .inventory([.init(id: "builtin", title: "Built-in memory", summary: "Synthetic storage status, not memory contents.",
                status: "Selected", details: [.init(label: "Memory bytes", value: "128"), .init(label: "User context bytes", value: "64")])])
        case .usage:
            return .inventory([.init(id: "totals", title: "Last 30 days", summary: "Synthetic sessions started in this period.",
                status: nil, details: [.init(label: "Sessions", value: "3"), .init(label: "Input tokens", value: "1200")])])
        case .system:
            return .inventory([.init(id: "system", title: "Demo Hermes", summary: "Synthetic host information.",
                status: nil, details: [.init(label: "Hermes", value: "Fixture"), .init(label: "Operating system", value: "Fixture")])])
        case .plugins, .toolsets, .mcp, .messaging:
            return .inventory([.init(id: "example", title: "Example \(destination.title)", summary: "Synthetic configuration for preview.",
                status: "Configured", details: [.init(label: "Owner", value: "Hermes fixture")])])
        default:
            throw WorkspaceManagementError.unavailable("This fixture uses the existing app destination for this feature.")
        }
    }

    func apply(_ mutation: WorkspaceManagementMutation) async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        switch mutation {
        case .archiveProject(let id, let restore):
            guard let index = projects.firstIndex(where: { $0.id == id }) else { throw WorkspaceManagementError.invalidInput }
            let project = projects[index]
            projects[index] = .init(id: project.id, name: project.name, summary: project.summary, isArchived: !restore, folders: project.folders)
        case .renameProject(let id, let name):
            guard let index = projects.firstIndex(where: { $0.id == id }), !name.isEmpty, name.utf8.count <= 200 else {
                throw WorkspaceManagementError.invalidInput
            }
            let project = projects[index]
            projects[index] = .init(id: project.id, name: name, summary: project.summary, isArchived: project.isArchived, folders: project.folders)
        case .replaceCredential(let key, let value):
            guard key == "EXAMPLE_API_KEY", !value.isEmpty else { throw WorkspaceManagementError.invalidInput }
            credentialIsSet = true
        case .setWebhookEnabled(let name, let enabled):
            guard name == "sample-event" else { throw WorkspaceManagementError.invalidInput }
            webhookEnabled = enabled
        }
    }

    func previewFile(path: String, root: String) async throws -> WorkspaceFilePreview {
        if let failure { throw failure }
        guard path == "/workspace/notes/example.txt", root == "/workspace" else {
            throw WorkspaceManagementError.fileRootNotConfined
        }
        return .init(path: path, name: "example.txt", text: "Synthetic example file.")
    }
}
