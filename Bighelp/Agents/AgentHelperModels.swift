import Foundation
import Observation

/// A bot's helper tasks: the small jobs Hermes runs beside a chat (reading a picture, summing up a
/// long chat, naming it), each on the chat model (Hermes' `auto`) or a model of its own. Read from
/// `/api/model/auxiliary`, changed one task at a time through `/api/model/set`.
@MainActor
@Observable
final class AgentHelperModelsModel {
    private(set) var tasks: [DirectHermesAuxiliaryModelAssignment] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// The task being saved, or `allTasks` while every task goes back to the chat model.
    private(set) var savingTask: String?
    private(set) var errorMessage: String?
    /// A model Hermes wants confirmed first (an expensive one), with the change that asked.
    private(set) var pendingConfirmation: DirectHermesModelAssignmentConfirmation?

    static let allTasks = "*"

    let agentID: String
    private let client: DirectHermesModelAdministrationClient

    init(agentID: String, client: DirectHermesModelAdministrationClient) {
        self.agentID = agentID
        self.client = client
    }

    /// How many tasks use a model of their own.
    var ownModelCount: Int { tasks.filter { !$0.usesChatModel }.count }

    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            tasks = try await client.auxiliaryModels(profileID: agentID).tasks
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = String(localized: "The helper tasks couldn’t be read. Try again.")
        }
    }

    func choose(_ task: String, providerID: String, modelID: String) async {
        await assign(task, scope: .auxiliary(task: task), providerID: providerID, modelID: modelID)
    }

    func useChatModel(_ task: String) async {
        await assign(task, scope: .automaticAuxiliary(task: task), providerID: "auto", modelID: "")
    }

    func useChatModelForAll() async {
        await assign(Self.allTasks, scope: .resetAuxiliary, providerID: "auto", modelID: "")
    }

    func confirmPending() async {
        guard let confirmation = pendingConfirmation, savingTask == nil else { return }
        pendingConfirmation = nil
        savingTask = Self.task(of: confirmation.request.scope)
        defer { savingTask = nil }
        do {
            try await client.confirmModelAssignment(profileID: agentID, confirmation: confirmation)
            await load()
        } catch {
            fail(error)
        }
    }

    func dismissConfirmation() { pendingConfirmation = nil }
    func clearError() { errorMessage = nil }

    private func assign(_ task: String, scope: DirectHermesModelAssignmentScope,
                        providerID: String, modelID: String) async {
        guard savingTask == nil else { return }
        savingTask = task
        errorMessage = nil
        defer { savingTask = nil }
        let request = DirectHermesModelAssignmentRequest(scope: scope, providerID: providerID, modelID: modelID,
                                                         reasoningEffort: nil, confirmExpensiveModel: false)
        do {
            switch try await client.setModel(profileID: agentID, request: request) {
            case .applied: await load()
            case .confirmationRequired(let confirmation): pendingConfirmation = confirmation
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        errorMessage = String(localized: "That change wasn’t saved. Try again.")
        Task { await load() }
    }

    private static func task(of scope: DirectHermesModelAssignmentScope) -> String {
        switch scope {
        case .auxiliary(let task), .automaticAuxiliary(let task): task
        case .main, .resetAuxiliary: allTasks
        }
    }
}

extension DirectHermesAuxiliaryModelAssignment {
    /// Hermes' `auto`: the task runs on the chat model.
    var usesChatModel: Bool { modelID.isEmpty && (providerID.isEmpty || providerID == "auto") }

    /// A task with its own address (a local server) is set on the computer.
    var isSetOnComputer: Bool { !baseURL.isEmpty }

    /// What the task does, in plain words. A task the app doesn't know (a plugin's) shows the
    /// host's own name.
    var title: String { Self.title(for: task) }

    static func title(for task: String) -> String {
        if let known = titles[task] { return known }
        let words = task.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static let titles: [String: String] = [
        "vision": String(localized: "Looking at pictures"),
        "compression": String(localized: "Summing up long chats"),
        "title_generation": String(localized: "Naming chats"),
        "skills_hub": String(localized: "Checking skills"),
        "approval": String(localized: "Checking risky commands"),
        "mcp": String(localized: "Tool servers"),
        "review": String(localized: "Reviewing its work"),
        "background_review": String(localized: "Reviewing in the background"),
        "voice_chat": String(localized: "Voice chats"),
        "triage_specifier": String(localized: "Sorting new tasks"),
        "kanban_decomposer": String(localized: "Splitting Kanban cards"),
        "profile_describer": String(localized: "Describing agents"),
        "curator": String(localized: "Tidying memory"),
        "memory_query_rewrite": String(localized: "Searching memory"),
        "goal_judge": String(localized: "Checking goals"),
        "monitor": String(localized: "Watching long tasks"),
        "tts_audio_tags": String(localized: "Voice expression"),
    ]
}
