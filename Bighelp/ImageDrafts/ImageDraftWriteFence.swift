import Foundation

/// The image fence (docs/IMAGE_DRAFTS.md › Image fence): in a chat that holds a picture the person
/// sent, or after the agent read a photo with `iphone_photos get`, an agent's own
/// `contacts.create` or `calendar.create` is refused with `review_required`, so what it read from a
/// picture goes through a draft the person reviews. Every other call, and every chat without a
/// picture, is handled exactly as before.
enum ImageDraftWriteFence {
    static let fencedOperations: Set<String> = ["contacts.create", "calendar.create"]
    static let code = "review_required"
    static let note = "This chat has a picture from the person. Don't add contacts or events read from a picture "
        + "directly: call bighelp_draft_contact or bighelp_draft_event so the person reviews it in bighelp first."

    static func refuses(operation: String, chatHoldsPicture: Bool) -> Bool {
        chatHoldsPicture && fencedOperations.contains(operation)
    }

    /// A photo or image the person sent: an image attachment on their message, or a reloaded
    /// message's `@image:` line (or Hermes' own `[Image attached` hint). Called per fenced tool
    /// call, never per redraw; newest first, so a recent picture answers at once.
    static func holdsPersonPicture(_ items: [TimelineItem]) -> Bool {
        for item in items.reversed() where item.role == .human {
            if item.attachments.contains(where: { $0.kind == .image }) { return true }
            if case .message(let text) = item.content, mentionsPicture(text) { return true }
        }
        return false
    }

    static func mentionsPicture(_ text: String) -> Bool {
        let image = ChatTextMarker.mayContain("@image:", in: text), hint = ChatTextMarker.mayContain("[Image attached", in: text)
        guard image || hint else { return false }
        return text.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            return trimmed.hasPrefix("@image:") || trimmed.hasPrefix("[Image attached")
        }
    }

    static func refusal(_ request: DeviceToolRequest, sentAt: Int) -> DeviceToolResult {
        DeviceToolResult(request: request, status: "failed", code: code, payload: ["note": .string(note)], sentAt: sentAt)
    }

    /// Wraps a chat's device-tool handler. `holdsPicture` reads the chat the channel was opened for.
    @MainActor static func guarding(_ handle: @escaping NativeDeviceToolSession.Handler,
                                    holdsPicture: @escaping @MainActor () -> Bool,
                                    photoReads: ImageDraftPhotoReads = .shared,
                                    clock: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) })
        -> NativeDeviceToolSession.Handler {
        { request, owner, isCurrent in
            let readKey = ImageDraftPhotoReads.key(request)
            if fencedOperations.contains(request.operation), holdsPicture() || photoReads.contains(readKey) {
                return refusal(request, sentAt: clock())
            }
            let result = await handle(request, owner, isCurrent)
            if request.operation == "photos.get", result.status == "completed" { photoReads.insert(readKey) }
            return result
        }
    }
}

/// Chats in which the agent read a photo with `iphone_photos get` during this run of the app.
@MainActor
final class ImageDraftPhotoReads {
    static let shared = ImageDraftPhotoReads()
    static let maximum = 200

    private var keys: [String] = []

    static func key(_ request: DeviceToolRequest) -> String {
        [request.hostId, request.agentId, request.sessionId].joined(separator: "\u{1F}")
    }

    func contains(_ key: String) -> Bool { keys.contains(key) }

    func insert(_ key: String) {
        guard !keys.contains(key) else { return }
        keys.append(key)
        if keys.count > Self.maximum { keys.removeFirst(keys.count - Self.maximum) }
    }
}
