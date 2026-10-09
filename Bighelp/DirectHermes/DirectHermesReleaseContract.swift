import Foundation

/// Shared Hermes wire contracts. Version metadata never gates connection or
/// features; availability comes from the host's actual capabilities.
enum DirectHermesReleaseContract {
    struct ResumedSession: Equatable, Sendable {
        let runtimeID: String
        let storedID: String
    }

    static func validateHealth(_ value: [String: BighelpJSONValue]) throws {
        guard value["ok"]?.boolean == true, value["auth_required"]?.boolean != nil else {
            throw WorkspaceClientError.authenticationRequired
        }
    }

    static let readOperations: Set<WorkspaceCapability> = [
        .profilesRead, .sessionsRead, .modelsRead, .schedulesRead, .projectsRead,
        .systemStatus, .skillsRead, .usageRead, .logsRead, .memoryRead,
        .personalitiesRead, .toolsetsRead, .pluginsRead, .mcpServersRead, .messagingPlatformsRead,
        .webhooksRead, .configRead, .keysRead, .filesRead, .dashboardRead, .dashboardEdit,
    ]

    /// Operations whose safety depends on the gateway serializing submitters
    /// for one live runtime. Reads, prompt responses, and session controls stay
    /// truthful when a host reports that it does not enforce this behavior.
    static let exclusiveSubmissionOperations: Set<WorkspaceCapability> = [
        .chatSend, .chatQueue, .slashCommands,
    ]

    static let nonSubmissionSessionOperations: Set<WorkspaceCapability> = [
        .canonicalAgentChat, .sessionsCreate, .sessionsEdit, .chatStop,
        .chatSteer, .approvalsRead, .approvalsRespond,
        .clarificationRespond, .subagentsRead, .subagentTail, .attachmentsUpload,
        .sessionModelEdit, .reasoningEdit, .sessionsFork,
    ]

    static let sessionOperations = nonSubmissionSessionOperations.union(exclusiveSubmissionOperations)

    static let profileOperations: Set<WorkspaceCapability> = [
        .profilesCreate, .profilesEdit, .profilesClone, .agentDefaultsEdit,
        .skillsEdit, .personalitiesEdit, .voiceOutput, .configEdit, .keysEdit, .webhooksEdit,
    ]

    static var operationsIndependentOfExclusiveSubmit: Set<WorkspaceCapability> {
        readOperations.union(profileOperations).union(nonSubmissionSessionOperations)
    }

    /// Where Hermes records a chat as coming from. Hermes words the agent's
    /// instructions by it: left out, a chat counts as its terminal UI (no files,
    /// cards or reminders), and "desktop" promises Hermes Desktop's own tools.
    /// The plugin gives the agent bighelp's instructions for this label.
    static let sessionSource = "bighelp"

    static func resumeParameters(profile: String, storedID: String) -> [String: BighelpJSONValue] {
        [
            "session_id": .string(storedID),
            "profile": .string(profile),
            "source": .string(sessionSource),
            "close_on_disconnect": .boolean(false),
            "defer_history": .boolean(true),
            "omit_messages": .boolean(true),
        ]
    }

    /// Decode only the identity needed to transfer a retained client to the
    /// runtime returned by `session.resume`. The returned durable ID may be a
    /// compaction successor of the requested ID and is therefore authoritative.
    static func decodeResumedSession(_ value: BighelpJSONValue, profile: String) throws -> ResumedSession {
        guard let object = value.object,
              let runtimeID = object["session_id"]?.string,
              !runtimeID.isEmpty, runtimeID.utf8.count <= 512,
              let info = object["info"]?.object else {
            throw WorkspaceClientError.invalidResponse
        }
        if let profileValue = info["profile_name"] {
            guard let returnedProfile = profileValue.string,
                  DirectHermesSessionValidation.same(returnedProfile, profile) else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        try DirectHermesSessionValidation.coordinate(runtimeID)

        var storedValues: [String] = []
        for key in ["session_key", "stored_session_id", "resumed"] {
            guard let value = object[key] else { continue }
            guard let stored = value.string else { throw WorkspaceClientError.invalidResponse }
            storedValues.append(stored)
        }
        guard let storedID = storedValues.first, !storedID.isEmpty,
              storedID.utf8.count <= 512,
              storedValues.allSatisfy({ DirectHermesSessionValidation.same($0, storedID) }) else {
            throw WorkspaceClientError.invalidResponse
        }
        try DirectHermesSessionValidation.coordinate(storedID)
        if let running = object["running"], running.boolean == nil {
            throw WorkspaceClientError.invalidResponse
        }
        return ResumedSession(runtimeID: runtimeID, storedID: storedID)
    }
}
