import Foundation
import Observation

/// Where each big file on its way stands, for its tile in the chat. Kept apart from the
/// row so each new piece redraws only the tile's ring, not the message row around it.
@MainActor
@Observable
final class BigFileUploadBoard {
    static let shared = BigFileUploadBoard()

    enum State: Equatable {
        case uploading(sentBytes: Int, byteCount: Int)
        /// Why it didn't go, in plain words; the tile offers Try again.
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var retries: [String: @MainActor () -> Void] = [:]

    func state(for fileID: String) -> State? { states[fileID] }

    func uploading(_ fileID: String, sentBytes: Int, byteCount: Int) {
        states[fileID] = .uploading(sentBytes: min(sentBytes, byteCount), byteCount: byteCount)
    }

    func failed(_ fileID: String, message: String, retry: @escaping @MainActor () -> Void) {
        states[fileID] = .failed(message)
        retries[fileID] = retry
    }

    func retry(_ fileID: String) {
        guard let retry = retries.removeValue(forKey: fileID) else { return }
        retry()
    }

    func finish(_ fileID: String) {
        states[fileID] = nil
        retries[fileID] = nil
    }
}
