import Foundation
import OSLog

/// Why an app didn't open or update, in the words its screen shows.
enum HTMLAppsError: Error, Equatable {
    /// The computer's plugin has no `native-html-apps-v1`.
    case needsPluginUpdate
    /// Not this agent's app, or gone.
    case notFound
    case noConnection
    /// The page changed while its pieces loaded; loading again gets the new one.
    case changed
    case failed

    init(_ error: any Error) {
        if let error = error as? HTMLAppsError { self = error; return }
        switch error as? WorkspaceClientError {
        case .unavailable(.unsupportedOperation)?, .unavailable(.pluginRequired)?: self = .needsPluginUpdate
        case .rejected(let code, _)? where code == "app_not_found": self = .notFound
        case .rejected(let code, _)? where code == "app_changed": self = .changed
        case .transportUnavailable?, .ownerChanged?, .authenticationRequired?, .unavailable?: self = .noConnection
        default: self = .failed
        }
    }

    var message: String {
        switch self {
        case .needsPluginUpdate: "Update the bighelp plugin on this computer to open apps."
        case .notFound: "This app isn't on the computer anymore."
        case .noConnection: "bighelp can't reach the computer right now."
        case .changed, .failed: "The app didn't open."
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
    static let pieceRetryDelays: [Duration] = [.seconds(1), .seconds(3)]

    let client: any HTMLAppsClient
    let retryDelays: [Duration]

    init(client: any HTMLAppsClient, retryDelays: [Duration] = Self.pieceRetryDelays) {
        self.client = client
        self.retryDelays = retryDelays
    }

    private func call(_ operation: HTMLAppsOperation,
                      _ payload: [String: BighelpJSONValue]) async throws(HTMLAppsError) -> [String: BighelpJSONValue] {
        do { return try await client.perform(operation, payload: payload) } catch {
            // The transport's own error, before it's folded into HTMLAppsError. Codes only.
            Self.log.error("html apps \(String(describing: operation), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw HTMLAppsError(error)
        }
    }

    /// The app and its page, which comes in pieces of up to 2 MiB so a page of any size fits one
    /// answer. A page that changes while it loads starts again.
    func app(agentID: String, appID: String, knownSHA256: String?) async throws(HTMLAppsError) -> HTMLAppPage {
        var restarts = 0
        while true {
            do throws(HTMLAppsError) {
                return try await page(agentID: agentID, appID: appID, knownSHA256: knownSHA256)
            } catch .changed where restarts < 2 {
                restarts += 1
            }
        }
    }

    private func page(agentID: String, appID: String, knownSHA256: String?) async throws(HTMLAppsError) -> HTMLAppPage {
        let base: [String: BighelpJSONValue] = ["agentId": .string(agentID), "appId": .string(appID)]
        var first = base
        if let knownSHA256 { first["knownSha256"] = .string(knownSHA256) }
        var reply = try await piece(first)
        guard let info = reply["app"]?.object.flatMap(Self.info), info.appID == appID else { throw .failed }
        guard reply["html"] != nil else {
            guard knownSHA256 == info.htmlSHA256 else { throw .failed }
            return HTMLAppPage(info: info, html: nil)
        }
        var bytes = Data()
        while true {
            // A plugin from before pieces sends the whole page with no offset.
            guard (reply["offset"]?.integer ?? 0) == bytes.count,
                  reply["app"]?.object?["htmlSha256"]?.string == info.htmlSHA256,
                  let encoded = reply["html"]?.string, let chunk = Data(base64Encoded: encoded), !chunk.isEmpty,
                  bytes.count + chunk.count <= info.htmlBytes else { throw .failed }
            bytes.append(chunk)
            switch reply["nextOffset"] {
            case nil, .null?:
                guard bytes.count == info.htmlBytes, HTMLAppHash.sha256(bytes) == info.htmlSHA256,
                      let html = String(data: bytes, encoding: .utf8) else { throw .failed }
                return HTMLAppPage(info: info, html: html)
            case .integer(let next)? where next == bytes.count && next < info.htmlBytes:
                var payload = base
                payload["offset"] = .integer(next)
                payload["htmlSha256"] = .string(info.htmlSHA256)
                reply = try await piece(payload)
            default:
                throw .failed
            }
        }
    }

    /// One `html-apps/get`. A dropped request is asked again, from the same offset.
    private func piece(_ payload: [String: BighelpJSONValue]) async throws(HTMLAppsError) -> [String: BighelpJSONValue] {
        var retries = retryDelays[...]
        while true {
            do throws(HTMLAppsError) {
                return try await call(.get, payload)
            } catch {
                guard error == .noConnection || error == .failed, !retries.isEmpty else { throw error }
                do { try await Task.sleep(for: retries.removeFirst()) } catch { throw .noConnection }
            }
        }
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
