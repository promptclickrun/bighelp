import Foundation
import OSLog

/// Why an app didn't open or update, in the words its screen shows.
enum HTMLAppsError: Error, Equatable {
    /// The computer's plugin has no `native-html-apps-v1`.
    case needsPluginUpdate
    /// Not this agent's app, or gone.
    case notFound
    case noConnection
    case failed

    init(_ error: any Error) {
        if let error = error as? HTMLAppsError { self = error; return }
        switch error as? WorkspaceClientError {
        case .unavailable(.unsupportedOperation)?, .unavailable(.pluginRequired)?: self = .needsPluginUpdate
        case .rejected(let code, _)? where code == "app_not_found": self = .notFound
        case .transportUnavailable?, .ownerChanged?, .authenticationRequired?, .unavailable?: self = .noConnection
        default: self = .failed
        }
    }

    var message: String {
        switch self {
        case .needsPluginUpdate: "Update the bighelp plugin on this computer to open apps."
        case .notFound: "This app isn't on the computer anymore."
        case .noConnection: "bighelp can't reach the computer right now."
        case .failed: "The app didn't open."
        }
    }
}

/// What the plugin says about an app (`html-apps/get`).
struct HTMLAppInfo: Equatable, Sendable {
    let appID: String
    let title: String
    let description: String
    let sendsAnswers: Bool
    let isLive: Bool
    let revision: Int
    let updatedAt: Date?
    let htmlSHA256: String
    let htmlBytes: Int
}

struct HTMLAppPage: Equatable, Sendable {
    let info: HTMLAppInfo
    /// Nil when the phone already has this HTML (`knownSha256`).
    let html: String?
}

/// An app's latest data (`html-apps/data`), as the JSON text its page gets.
struct HTMLAppData: Equatable, Sendable {
    enum Problem: String, Sendable {
        case missing, invalid
        case tooLarge = "too_large"
    }

    /// Nil when the app has no data now.
    let json: String?
    let updatedAt: Date?
    let problem: Problem?
}

// MARK: - The plugin's routes

enum HTMLAppsOperation: CaseIterable, Sendable {
    case get, data

    var workspaceOperation: WorkspaceOperation {
        switch self {
        case .get: .htmlAppsGet
        case .data: .htmlAppsData
        }
    }
}

/// One computer's `html-apps` routes.
@MainActor
protocol HTMLAppsClient: AnyObject {
    func perform(_ operation: HTMLAppsOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]
}

/// The plugin's routes on the computer in use.
@MainActor
final class DirectHermesHTMLAppsClient: HTMLAppsClient {
    private let workspace: @MainActor () -> (any WorkspaceOperationPerforming)?

    init(workspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?) {
        self.workspace = workspace
    }

    func perform(_ operation: HTMLAppsOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard let workspace = workspace(), let owner = workspace.owner else {
            throw WorkspaceClientError.transportUnavailable
        }
        do {
            return try await workspace.perform(operation.workspaceOperation, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            return try await workspace.perform(operation.workspaceOperation, payload: payload, owner: owner)
        }
    }
}

/// Typed calls over a client: the payloads docs/HTML_APPS.md names, lenient reading of the
/// replies, and a check that the HTML is the HTML the plugin described.
@MainActor
struct HTMLAppsAPI {
    static let log = Logger(subsystem: "app.loopdy.mobile", category: "HTMLApps")

    let client: any HTMLAppsClient

    init(client: any HTMLAppsClient) {
        self.client = client
    }

    private func call(_ operation: HTMLAppsOperation,
                      _ payload: [String: BighelpJSONValue]) async throws(HTMLAppsError) -> [String: BighelpJSONValue] {
        do { return try await client.perform(operation, payload: payload) } catch {
            // The transport's own error, before it's folded into HTMLAppsError. Codes only.
            Self.log.error("html apps \(String(describing: operation), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw HTMLAppsError(error)
        }
    }

    func app(agentID: String, appID: String, knownSHA256: String?) async throws(HTMLAppsError) -> HTMLAppPage {
        var payload: [String: BighelpJSONValue] = ["agentId": .string(agentID), "appId": .string(appID)]
        if let knownSHA256 { payload["knownSha256"] = .string(knownSHA256) }
        let reply = try await call(.get, payload)
        guard let info = reply["app"]?.object.flatMap(Self.info), info.appID == appID else { throw .failed }
        guard let encoded = reply["html"]?.string else {
            guard knownSHA256 == info.htmlSHA256 else { throw .failed }
            return HTMLAppPage(info: info, html: nil)
        }
        guard let bytes = Data(base64Encoded: encoded), bytes.count == info.htmlBytes,
              HTMLAppHash.sha256(bytes) == info.htmlSHA256,
              let html = String(data: bytes, encoding: .utf8) else { throw .failed }
        return HTMLAppPage(info: info, html: html)
    }

    func data(agentID: String, appID: String) async throws(HTMLAppsError) -> HTMLAppData {
        let reply = try await call(.data, ["agentId": .string(agentID), "appId": .string(appID)])
        guard reply["appId"]?.string == appID else { throw .failed }
        let json: String? = switch reply["data"] {
        case nil, .null?: nil
        case let value?: Self.text(of: value)
        }
        return HTMLAppData(json: json, updatedAt: reply["updatedAt"]?.string.flatMap(Self.date),
                           problem: reply["problem"]?.string.flatMap(HTMLAppData.Problem.init(rawValue:)))
    }

    private static func info(_ object: [String: BighelpJSONValue]) -> HTMLAppInfo? {
        guard let appID = object["appId"]?.string,
              let title = object["title"]?.string, !title.isEmpty,
              let hash = object["htmlSha256"]?.string, hash.utf8.count == 64,
              let bytes = object["htmlBytes"]?.integer, (1...HTMLAppWire.maximumHTMLBytes).contains(bytes) else { return nil }
        return HTMLAppInfo(appID: appID, title: title, description: object["description"]?.string ?? "",
                           sendsAnswers: object["sendsAnswers"]?.boolean ?? false,
                           isLive: object["live"]?.boolean ?? false,
                           revision: object["revision"]?.integer ?? 1,
                           updatedAt: object["updatedAt"]?.string.flatMap(date),
                           htmlSHA256: hash, htmlBytes: bytes)
    }

    /// Compact JSON with sorted keys, so the same data is the same text.
    private static func text(of value: BighelpJSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// RFC 3339, with or without fractions of a second.
    private static func date(_ text: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
