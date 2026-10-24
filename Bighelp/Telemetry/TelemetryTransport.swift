import Foundation

struct TelemetryRequest: Equatable, Sendable {
    let url: URL
    let body: Data
    let isGzip: Bool
}

enum TelemetryResponse: Equatable, Sendable {
    /// The service took it (202).
    case accepted
    /// Slow down (429); `after` is the service's Retry-After, in seconds.
    case rateLimited(after: TimeInterval?)
    /// No answer, or a server error (5xx). The events are kept and tried again later.
    case failed
    /// Any other answer (a 4xx that isn't 429). The service refused it; it is not sent again.
    case dropped
}

/// The one way telemetry leaves the phone. Tests give it a fake.
protocol TelemetryTransport: Sendable {
    func send(_ request: TelemetryRequest) async -> TelemetryResponse
}

struct URLSessionTelemetryTransport: TelemetryTransport {
    /// Fixed in code (contract §5).
    static let endpoint = URL(string: "https://telemetry.bighelp.app/v1/batch")!
    static let timeout: TimeInterval = 5

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func send(_ request: TelemetryRequest) async -> TelemetryResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: Self.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if request.isGzip { urlRequest.setValue("gzip", forHTTPHeaderField: "Content-Encoding") }
        urlRequest.httpBody = request.body
        do {
            let (_, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 202: return .accepted
            case 429: return .rateLimited(after: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
            case 500...599: return .failed
            default: return .dropped
            }
        } catch {
            return .failed
        }
    }
}
