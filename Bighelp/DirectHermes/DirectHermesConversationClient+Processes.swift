import Foundation

/// The chat's background commands (Hermes' `process.list` and `process.kill`), over this chat's
/// own connection: Hermes answers only for the live session attached to it.
extension DirectHermesConversationClient {
    /// The commands this chat's agent started in the background, running and recently finished.
    func backgroundCommands(now: Date = .now) async throws -> [ChatBackgroundCommand] {
        let result = try await processControl("process.list", [:])
        guard let commands = ChatBackgroundCommand.list(.object(result), now: now) else {
            throw DirectHermesError.invalidResponse
        }
        return commands
    }

    /// Stops one of them. False when it had already ended or Hermes no longer knows it.
    func stopBackgroundCommand(id: String) async throws -> Bool {
        let result = try await processControl("process.kill", ["process_id": .string(id)])
        switch result["status"]?.string {
        case "killed": return true
        case "already_exited", "not_found": return false
        default: throw DirectHermesError.invalidResponse
        }
    }

    private func processControl(_ method: String,
                                _ params: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        let owner = generation
        guard connected else { throw DirectHermesError.notConnected }
        var request = params
        request["session_id"] = .string(runtimeID)
        let result = try await rpc.request(method, params: request)
        guard connected, generation == owner else { throw DirectHermesError.notConnected }
        guard let object = result.object else { throw DirectHermesError.invalidResponse }
        return object
    }
}
