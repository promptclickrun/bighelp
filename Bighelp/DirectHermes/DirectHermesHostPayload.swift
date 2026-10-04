import CryptoKit
import Foundation

// MARK: - Schema decoding

enum DirectHermesHostPayload: DirectHermesPayloadDecoding {
    static var invalidResponse: any Error { HostOperationsError.invalidResponse }
    static var arrayOverflow: any Error { HostOperationsError.invalidResponse }
    static let requiresNonemptyText = false

    static func strings(
        _ value: BighelpJSONValue?,
        maximum: Int,
        maximumBytes: Int
    ) throws -> [String] {
        guard value != nil, value != .null else { return [] }
        return try array(value, maximum: maximum).map { try text($0, maximumBytes: maximumBytes) }
    }

    static func numbers(
        _ value: BighelpJSONValue?,
        maximum: Int,
        range: ClosedRange<Double>
    ) throws -> [Double] {
        guard value != nil, value != .null else { return [] }
        return try array(value, maximum: maximum).map { try number($0, range: range) }
    }

    static func safeIdentifier(_ value: String, maximumBytes: Int) throws -> String {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostOperationsError.invalidResponse
        }
        return value
    }

    static func profile(_ value: String) throws -> String {
        let profile = try safeIdentifier(value, maximumBytes: 128)
        guard profile != "all", profile != ".", profile != "..",
              !profile.contains("/"), !profile.contains("\\") else {
            throw HostOperationsError.invalidRequest
        }
        return profile
    }

    static func hostArchivePath(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.lowercased().hasSuffix(".zip"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostOperationsError.invalidRequest
        }
        return value
    }

    static func hostFilesystemPath(_ value: BighelpJSONValue?) throws -> String {
        let path = try text(value, maximumBytes: 4_096)
        guard !path.isEmpty,
              Data(path.utf8) == Data(path.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostOperationsError.invalidResponse
        }
        return path
    }

    static func isConfigPath(_ configPath: String, insideProfileHome home: String) -> Bool {
        let separator = home.hasSuffix("/") || home.hasSuffix("\\") ? "" : "/"
        let posix = home + separator + "config.yaml"
        if Data(configPath.utf8) == Data(posix.utf8) { return true }
        guard separator == "/" else { return false }
        return Data(configPath.utf8) == Data((home + "\\config.yaml").utf8)
    }

    static func uploadFilename(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 255,
              value.lowercased().hasSuffix(".zip"), value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostOperationsError.invalidRequest
        }
        return value
    }

    static func capacity(
        _ value: BighelpJSONValue?,
        availableKey: String
    ) throws -> HermesSystemStats.Capacity? {
        guard let value, value != .null else { return nil }
        let row = try object(value)
        return .init(
            total: try integer(row["total"], range: 0...Int.max),
            used: try integer(row["used"], range: 0...Int.max),
            available: try integer(row[availableKey], range: 0...Int.max),
            percent: try number(row["percent"], range: 0...100)
        )
    }

    static func process(_ value: BighelpJSONValue?) throws -> HermesSystemStats.Process? {
        guard let value, value != .null else { return nil }
        let row = try object(value)
        return .init(
            residentBytes: try integer(row["rss"], range: 0...Int.max),
            threadCount: try integer(row["num_threads"], range: 0...1_000_000),
            createdAt: date(try optionalInteger(row["create_time"], range: 0...Int.max))
        )
    }

    /// `/api/status`. Hermes leaves the gateway's fields null while it's stopped or runs under
    /// another profile, so only the version is required: a missing part hides one row, not the
    /// whole System page.
    static func overview(_ value: BighelpJSONValue) throws -> HermesHostOverview {
        let row = try object(value)
        let componentRows = (try? object(row["components"] ?? .object([:]))) ?? [:]
        let components = componentRows.prefix(128).compactMap { key, value -> HermesHostOverview.Component? in
            guard let id = try? safeIdentifier(key, maximumBytes: 128), let component = try? object(value) else {
                return nil
            }
            return .init(id: id, status: (try? optionalText(component["status"], maximumBytes: 128)) ?? "unknown")
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let gatewayRunning = try optionalBoolean(row["gateway_running"]) ?? false
        let gatewayComponentState = componentRows["gateway"]
            .flatMap { try? object($0) }
            .flatMap { try? optionalText($0["state"], maximumBytes: 128) }
        return .init(
            version: try text(row["version"], maximumBytes: 128),
            releaseDate: try optionalText(row["release_date"], maximumBytes: 128),
            gatewayRunning: gatewayRunning,
            gatewayState: try optionalText(row["gateway_state"], maximumBytes: 128)
                ?? gatewayComponentState ?? (gatewayRunning ? "running" : "stopped"),
            gatewayBusy: try optionalBoolean(row["gateway_busy"]) ?? false,
            gatewayDrainable: try optionalBoolean(row["gateway_drainable"]) ?? false,
            gatewayMode: try optionalText(row["gateway_mode"], maximumBytes: 64) ?? "none",
            gatewaySharedWith: try strings(row["gateway_shared_with"], maximum: 128, maximumBytes: 128),
            activeAgents: try optionalInteger(row["active_agents"], range: 0...1_000_000) ?? 0,
            activeSessions: try optionalInteger(row["active_sessions"], range: 0...1_000_000) ?? 0,
            restartDrainTimeout: try optionalNumber(row["restart_drain_timeout"], range: 0...86_400) ?? 0,
            overall: try optionalText(row["overall"], maximumBytes: 64) ?? "unknown",
            components: components
        )
    }

    /// The compact summary beside a receipt. Hermes sends null when it couldn't build one, and
    /// commit IDs can be empty; either way the receipt itself still counts.
    static func updateSummary(_ value: BighelpJSONValue, receipt: [String: BighelpJSONValue] = [:]) throws
        -> HermesUpdateReceiptSummary {
        guard let row = try? object(value) else {
            return .init(
                outcome: (try? optionalText(receipt["outcome"], maximumBytes: 32)) ?? "unknown",
                startedAt: date((try? optionalText(receipt["started_at"], maximumBytes: 128)) ?? nil),
                finishedAt: date((try? optionalText(receipt["finished_at"], maximumBytes: 128)) ?? nil),
                preUpdateSHA: nil, postUpdateSHA: nil, postUpdateVersion: nil, fleetStates: []
            )
        }
        return .init(
            outcome: try optionalText(row["outcome"], maximumBytes: 32)
                ?? (try? optionalText(receipt["outcome"], maximumBytes: 32)) ?? "unknown",
            startedAt: date(try optionalText(row["started_at"], maximumBytes: 128)),
            finishedAt: date(try optionalText(row["finished_at"], maximumBytes: 128)),
            preUpdateSHA: lenientSHA(row["pre_sha"]),
            postUpdateSHA: lenientSHA(row["post_sha"]),
            postUpdateVersion: try optionalText(row["post_version"], maximumBytes: 128),
            fleetStates: (try? strings(row["fleet_states"], maximum: 32, maximumBytes: 64)) ?? []
        )
    }

    /// `hermes update`'s receipt. Rows that don't read are left out rather than failing the
    /// update check that comes with it.
    static func updateReceipt(_ value: BighelpJSONValue) throws -> HermesUpdateReceipt {
        let envelope = try object(value)
        let receipt = try object(envelope["receipt"] ?? .null)
        let summary = try updateSummary(envelope["summary"] ?? .null, receipt: receipt)
        let schema = try optionalInteger(receipt["schema"], range: 1...1_000) ?? 1
        let steps = ((try? array(receipt["steps"], maximum: 500)) ?? []).enumerated().compactMap { index, value in
            guard let row = try? object(value), let name = try? text(row["name"], maximumBytes: 256),
                  let succeeded = try? boolean(row["ok"]) else { return nil as HermesUpdateReceipt.Step? }
            return HermesUpdateReceipt.Step(
                index: index, name: name, succeeded: succeeded,
                occurredAt: date((try? optionalText(row["at"], maximumBytes: 128)) ?? nil)
            )
        }
        let skips = ((try? array(receipt["skips"], maximum: 500)) ?? []).enumerated().compactMap { index, value in
            guard let row = try? object(value), let name = try? text(row["name"], maximumBytes: 256) else {
                return nil as HermesUpdateReceipt.Skip?
            }
            return HermesUpdateReceipt.Skip(
                index: index, name: name,
                occurredAt: date((try? optionalText(row["at"], maximumBytes: 128)) ?? nil)
            )
        }
        let fleet = ((try? array(receipt["fleet"], maximum: 128)) ?? []).compactMap { value in
            guard let row = try? object(value),
                  let name = try? text(row["profile"], maximumBytes: 128),
                  let profile = try? safeIdentifier(name, maximumBytes: 128),
                  let state = try? text(row["state"], maximumBytes: 64) else { return nil as HermesUpdateReceipt.FleetMember? }
            return HermesUpdateReceipt.FleetMember(
                profile: profile, codeSHA: lenientSHA(row["code_sha"]),
                codeVersion: (try? optionalText(row["code_version"], maximumBytes: 128)) ?? nil, state: state
            )
        }
        let gateway = (try? object(receipt["gateway_restart"] ?? .object([:]))) ?? [:]
        let incomplete: Bool?
        if gateway.isEmpty { incomplete = nil }
        else { incomplete = gateway["incomplete"]?.boolean }
        return .init(
            schema: schema, summary: summary, steps: steps, skips: skips,
            fleet: fleet, gatewayRestartIncomplete: incomplete
        )
    }

    /// A commit ID when it is one; empty or odd values (Hermes writes "" when it couldn't tell) are nil.
    static func lenientSHA(_ value: BighelpJSONValue?) -> String? {
        (try? optionalSHA(value)) ?? nil
    }

    static func sha(_ value: BighelpJSONValue?) throws -> String {
        guard let sha = try optionalSHA(value) else { throw HostOperationsError.invalidResponse }
        return sha
    }

    static func optionalSHA(_ value: BighelpJSONValue?) throws -> String? {
        guard let value = try optionalText(value, maximumBytes: 64) else { return nil }
        guard (7...64).contains(value.utf8.count),
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
              }) else { throw HostOperationsError.invalidResponse }
        return value
    }

    static func optionalHTTPSURL(_ value: BighelpJSONValue?) throws -> URL? {
        guard let value = try optionalText(value, maximumBytes: 4_096), !value.isEmpty else { return nil }
        guard let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https", parts.user == nil,
              parts.password == nil, parts.host?.isEmpty == false,
              let url = parts.url else { throw HostOperationsError.invalidResponse }
        return url
    }

    static func downloadFilename(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 255,
              value.lowercased().hasSuffix(".zip"),
              value != ".", value != "..", !value.contains("/"), !value.contains("\\"),
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }) else { throw HostOperationsError.invalidResponse }
        return value
    }

    static func hasZIPSignature(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let signature = Array(data.prefix(4))
        return signature == [0x50, 0x4b, 0x03, 0x04]
            || signature == [0x50, 0x4b, 0x05, 0x06]
            || signature == [0x50, 0x4b, 0x07, 0x08]
    }

    static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func date(_ unixSeconds: Int?) -> Date? {
        unixSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

extension DirectHermesHostPayload {
    static func canonicalBytes(_ value: BighelpJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
