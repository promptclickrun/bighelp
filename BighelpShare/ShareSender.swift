import Foundation

/// One thing the sheet is carrying. Pictures go up on the host's own image method;
/// a file takes the `data:` route and answers with the reference line Hermes wants in
/// the prompt, exactly as `DirectHermes/DirectHermesConversationClient+Attachments.swift`
/// does for a draft.
struct ShareAttachment: Sendable, Identifiable {
    enum Kind: String, Sendable { case image, file }

    let kind: Kind
    let fileName: String
    let mimeType: String
    let data: Data
    let id = UUID()
}

/// Creates (or resumes) one chat, stages what was shared, and submits the prompt.
///
/// It never closes the session: the turn has to keep running on the computer after the
/// sheet is dismissed, which is why every session here opens with
/// `close_on_disconnect: false` — the same contract the app's chats use.
@MainActor
final class ShareSender {
    /// The same ceiling the app applies to an ordinary attachment (8 MB each, 24 MB a
    /// batch, carried inline). Anything larger is the app's chunked uploader's job, and
    /// that does not run in an extension.
    static let maximumItemBytes = 8 * 1_024 * 1_024
    static let maximumBatchBytes = 24 * 1_024 * 1_024
    /// The session source the app writes, so a shared chat is an ordinary bighelp chat.
    static let sessionSource = "bighelp"

    private let rpc: ShareRPC

    init(rpc: ShareRPC) { self.rpc = rpc }

    /// Returns the chat's runtime id, for the confirmation's "Open in bighelp".
    func send(text: String, attachments: [ShareAttachment], agent: String, chatID: String?) async throws -> String {
        let runtimeID: String
        if let chatID, !chatID.isEmpty {
            let resumed = try await rpc.call("session.resume", [
                "session_id": chatID,
                "profile": agent,
                "source": Self.sessionSource,
                "close_on_disconnect": false,
            ])
            guard let id = resumed["session_id"] as? String, !id.isEmpty else { throw ShareRPC.Failure.invalidResponse }
            runtimeID = id
        } else {
            let created = try await rpc.call("session.create", [
                "profile": agent,
                "source": Self.sessionSource,
                "close_on_disconnect": false,
                // A lost reply must not mint a second chat when the person taps again.
                "idempotency_key": UUID().uuidString,
            ])
            guard let id = created["session_id"] as? String, !id.isEmpty else { throw ShareRPC.Failure.invalidResponse }
            runtimeID = id
        }

        var references: [String] = []
        for attachment in attachments {
            switch attachment.kind {
            case .image:
                _ = try await rpc.call("image.attach_bytes", [
                    "session_id": runtimeID,
                    "filename": attachment.fileName,
                    "content_base64": attachment.data.base64EncodedString(),
                ])
            case .file:
                let receipt = try await rpc.call("file.attach", [
                    "session_id": runtimeID,
                    "name": attachment.fileName,
                    "data_url": "data:" + attachment.mimeType + ";base64," + attachment.data.base64EncodedString(),
                ])
                if let reference = receipt["ref_text"] as? String, !reference.isEmpty {
                    references.append(reference)
                }
            }
        }

        let body = ([text] + references).filter { !$0.isEmpty }.joined(separator: "\n")
        _ = try await rpc.call("prompt.submit", ["session_id": runtimeID, "text": body])
        return runtimeID
    }
}
