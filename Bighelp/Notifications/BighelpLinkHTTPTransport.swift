import Foundation

enum BighelpLinkAPIError: Error, Equatable {
    case invalidConfiguration
    case invalidResponse
    case requestFailed(status: Int, code: String)
}

@MainActor
protocol BighelpLinkHTTPTransport: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
