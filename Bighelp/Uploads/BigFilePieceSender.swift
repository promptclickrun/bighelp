import UIKit

/// Sends each piece of a big file the fastest way that works at that moment. While Bighelp is
/// in front, that is an ordinary session, at the link's own speed. iOS's background transfers
/// run outside the app, when and as fast as iOS decides, so they are kept for the background:
/// there a piece goes through the background session and outlives the app's last seconds. The
/// host takes a piece whole or not at all, so which session carried one never matters.
final class BigFilePieceSender: BigFileChunkSending {
    static let shared = BigFilePieceSender()

    private let inFront: any BigFileChunkSending
    private let away: any BigFileChunkSending
    private let isAway: @Sendable () async -> Bool

    init(inFront: any BigFileChunkSending = BigFilePieceSession.inFront,
         away: any BigFileChunkSending = BigFilePieceSession.background,
         isAway: @escaping @Sendable () async -> Bool = {
             await MainActor.run { UIApplication.shared.applicationState == .background }
         }) {
        self.inFront = inFront
        self.away = away
        self.isAway = isAway
    }

    func send(_ request: URLRequest, fromFile file: URL,
              onSent: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        try await (await isAway() ? away : inFront).send(request, fromFile: file, onSent: onSent)
    }
}
