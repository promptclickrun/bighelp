import Foundation

/// Shared bounded decoding for the two administration clients. Secret-bearing
/// response keys are never requested by these helpers or retained in typed rows.
enum DirectHermesAdministrationCodec: DirectHermesPayloadDecoding {
    static var invalidResponse: any Error { WorkspaceClientError.invalidResponse }
    static var arrayOverflow: any Error { WorkspaceClientError.invalidResponse }
    static let requiresNonemptyText = false

    static func string(_ value: BighelpJSONValue?, maximum: Int) throws -> String {
        try text(value, maximumBytes: maximum)
    }

    static func optionalString(_ value: BighelpJSONValue?, maximum: Int) throws -> String? {
        try optionalText(value, maximumBytes: maximum)
    }

    static func bool(_ value: BighelpJSONValue?) throws -> Bool {
        try boolean(value)
    }

    static func optionalBool(_ value: BighelpJSONValue?) throws -> Bool? {
        try optionalBoolean(value)
    }

    static func int(_ value: BighelpJSONValue?, minimum: Int? = nil) throws -> Int {
        try integer(value, range: (minimum ?? Int.min)...Int.max)
    }

    static func optionalInt(_ value: BighelpJSONValue?, minimum: Int? = nil) throws -> Int? {
        try optionalInteger(value, range: (minimum ?? Int.min)...Int.max)
    }

    /// Hermes sends times as seconds, milliseconds or ISO 8601 text, depending on the
    /// provider. Text that isn't a time is no time, not a broken response.
    static func optionalDate(_ value: BighelpJSONValue?) throws -> Date? {
        if case .string(let text)? = value {
            guard text.utf8.count <= 64 else { return nil }
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: text) { return date }
            iso.formatOptions.insert(.withFractionalSeconds)
            return iso.date(from: text)
        }
        guard let timestamp = try optionalNumber(value), timestamp > 0 else { return nil }
        // Seconds since 1970 stay below 1e11 until the year 5138.
        return Date(timeIntervalSince1970: timestamp >= 100_000_000_000 ? timestamp / 1_000 : timestamp)
    }

    static func stringArray(
        _ value: BighelpJSONValue?, maximumCount: Int, maximumBytes: Int, required: Bool = true
    ) throws -> [String] {
        if !required, value == nil || value == .null { return [] }
        let values = try array(value, maximum: maximumCount)
        let strings = try values.map { try string($0, maximum: maximumBytes) }
        guard Set(strings).count == strings.count else { throw WorkspaceClientError.invalidResponse }
        return strings
    }

    static func optionalHTTPSURL(_ value: BighelpJSONValue?) throws -> URL? {
        guard let text = try optionalString(value, maximum: 2_048), !text.isEmpty else { return nil }
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              let url = parts.url else { throw WorkspaceClientError.invalidResponse }
        return url
    }

    static func safeError(_ error: any Error, mutation: Bool) -> any Error {
        if error is CancellationError || error is WorkspaceClientError { return error }
        guard let direct = error as? DirectHermesError else {
            return mutation ? WorkspaceClientError.outcomeUnknown : WorkspaceClientError.transportUnavailable
        }
        if direct.outcomeIsUnknown { return WorkspaceClientError.outcomeUnknown }
        switch direct {
        case .invalidCredentials, .authenticationRequired: return WorkspaceClientError.authenticationRequired
        case .rpcRejected(let code, _) where code == -32601: return WorkspaceClientError.unavailable(.unsupportedOperation)
        case .rpcRejected(_, let message): return WorkspaceClientError.rejected(code: nil, message: message)
        case .invalidResponse: return WorkspaceClientError.invalidResponse
        case .messageTooLarge, .tooManyRequests: return WorkspaceClientError.capacityExceeded
        default: return mutation ? WorkspaceClientError.outcomeUnknown : WorkspaceClientError.transportUnavailable
        }
    }
}
