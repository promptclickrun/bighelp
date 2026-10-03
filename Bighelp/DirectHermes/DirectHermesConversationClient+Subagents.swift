import Foundation

/// A helper's saved session, read over this chat's own host connection.
extension DirectHermesConversationClient {
    /// The newest page of the child's saved rows. Children run under their
    /// parent's profile and save into its store, so the read names this chat's
    /// profile. A child that hasn't saved its first step yet answers 404.
    func subagentHistory(childSessionID: String, subagentID: String) async throws -> SubagentCanvasHistory {
        let owner = generation
        let capturedRuntimeID = runtimeID
        guard connected, let http = rpc as? any DirectHermesAuthenticatedHTTP else {
            throw DirectHermesError.notConnected
        }
        let response = try await http.request(.init(
            path: "/api/sessions/\(try Self.subagentPathComponent(childSessionID))/messages",
            method: .get,
            query: [
                .init(name: "profile", value: profile),
                .init(name: "limit", value: String(SubagentCanvasHistory.pageSize)),
                .init(name: "order", value: "latest"),
            ],
            maximumResponseBytes: DirectHermesWire.maximumMessageBytes
        ))
        guard connected, generation == owner, Data(runtimeID.utf8) == Data(capturedRuntimeID.utf8) else {
            throw DirectHermesError.notConnected
        }
        guard let object = response.object,
              let values = object["messages"]?.array, values.count <= SubagentCanvasHistory.pageSize else {
            throw DirectHermesError.invalidResponse
        }
        if let served = object["profile"], served.string.map({ Data($0.utf8) != Data(profile.utf8) }) ?? true {
            throw DirectHermesError.invalidResponse
        }
        // Hermes follows a compressed child to its newest segment and includes
        // the earlier ones, so each row is checked against the session it names.
        let rows = try values.map { value in
            guard let rowSession = value.object?["session_id"]?.string, !rowSession.isEmpty,
                  rowSession.utf8.count <= 512 else { throw DirectHermesError.invalidResponse }
            return try DirectHermesHistoryRow(value, sessionID: rowSession)
        }
        return try SubagentCanvasHistory(childSessionID: childSessionID, subagentID: subagentID,
                                         profile: profile, rows: rows)
    }

    private static func subagentPathComponent(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 512, value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectHermesError.invalidResponse
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw DirectHermesError.invalidResponse
        }
        return encoded
    }
}
