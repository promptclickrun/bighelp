import Foundation

/// The projects Bighelp IDE can start sessions in, for one agent (Hermes keeps
/// projects per agent).
@MainActor
protocol CodeProjectSource: AnyObject {
    func load(agentID: String) async throws -> (projects: [CodeProject], found: [CodeFoundFolder])
    /// Makes a found folder a Hermes project; returns its ID.
    func addProject(_ folder: CodeFoundFolder, agentID: String) async throws -> String
}

/// Hermes's registered projects (one main folder each), with the git folders it
/// found as candidates.
@MainActor
final class LiveCodeProjectSource: CodeProjectSource {
    private let lifecycle: @MainActor (String) throws -> ProjectLifecycleStore

    init(lifecycle: @escaping @MainActor (String) throws -> ProjectLifecycleStore) {
        self.lifecycle = lifecycle
    }

    func load(agentID: String) async throws -> (projects: [CodeProject], found: [CodeFoundFolder]) {
        let store = try lifecycle(agentID)
        await store.load()
        guard let overview = store.overview else {
            throw CodeMessageError(store.errorMessage ?? "Projects couldn't load from your computer.")
        }
        let nodes = Dictionary(overview.tree.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = overview.registeredProjects.compactMap { project -> CodeProject? in
            let primary = project.folders.filter(\.isPrimary)
            guard !project.isArchived, primary.count == 1, let folder = primary.first else { return nil }
            return CodeProject(id: project.id, name: project.name, folder: folder.path,
                               icon: nodes[project.id]?.icon, color: nodes[project.id]?.color)
        }
        let used = Set(overview.registeredProjects.flatMap { $0.folders.map(\.path) })
        let found = overview.discoveredRepositories
            .filter { !used.contains($0.root) }
            .map { CodeFoundFolder(path: $0.root, name: $0.label) }
        return (projects, found)
    }

    func addProject(_ folder: CodeFoundFolder, agentID: String) async throws -> String {
        let store = try lifecycle(agentID)
        store.review(.create(name: folder.name, discoveredRoot: folder.path))
        guard store.preparedAction != nil else {
            throw CodeMessageError(store.errorMessage ?? "\(folder.name) couldn't be added as a project.")
        }
        await store.confirmPreparedAction()
        guard let project = store.overview?.registeredProjects.first(where: {
            !$0.isArchived && $0.folders.contains { $0.isPrimary && $0.path == folder.path }
        }) else {
            throw CodeMessageError(store.errorMessage ?? "\(folder.name) couldn't be added as a project.")
        }
        return project.id
    }
}

/// Demo mode: two sample repositories and one found folder.
@MainActor
final class DemoCodeProjectSource: CodeProjectSource {
    private var projects = [
        CodeProject(id: "bighelp", name: "bighelp", folder: "/Users/demo/code/bighelp", icon: "🚀", color: "#7C5CFC"),
        CodeProject(id: "bighelp-plugin", name: "bighelp-plugin", folder: "/Users/demo/code/bighelp-plugin",
                    icon: "🧩", color: "#2FA37A"),
    ]
    private var found = [CodeFoundFolder(path: "/Users/demo/code/recipe-box", name: "recipe-box")]

    func load(agentID: String) async throws -> (projects: [CodeProject], found: [CodeFoundFolder]) {
        (projects, found)
    }

    func addProject(_ folder: CodeFoundFolder, agentID: String) async throws -> String {
        found.removeAll { $0.path == folder.path }
        projects.append(CodeProject(id: folder.name, name: folder.name, folder: folder.path))
        return folder.name
    }
}

/// A message for the person, already in plain words.
struct CodeMessageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
