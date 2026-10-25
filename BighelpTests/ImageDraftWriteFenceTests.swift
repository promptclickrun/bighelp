import Foundation
import Testing
@testable import Bighelp

/// The image fence (docs/IMAGE_DRAFTS.md › Image fence): only `contacts.create` and
/// `calendar.create`, only in a chat with the person's picture or after the agent read a photo.
@MainActor
struct ImageDraftWriteFenceTests {
    private let scope = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-a")

    private func request(_ operation: String, session: String = "session-1") -> DeviceToolRequest {
        DeviceToolRequest(version: 1, type: "device.tool.request", requestId: "request-\(operation)-\(session)",
                          deviceId: scope.deviceID, hostId: scope.hostID, authorizationEpoch: 1, sessionId: session,
                          agentId: "default", turnId: "turn-1", operation: operation,
                          arguments: ["givenName": .string("Riley")], sentAt: 1_000, expiresAt: 1_100)
    }

    /// The handler behind the fence: records what reached it and completes.
    @MainActor
    private final class Inner {
        var handled: [String] = []
    }

    private func fence(picture: Bool, reads: ImageDraftPhotoReads = ImageDraftPhotoReads()) -> (NativeDeviceToolSession.Handler, Inner) {
        let inner = Inner()
        let handler = ImageDraftWriteFence.guarding({ request, _, _ in
            inner.handled.append(request.operation)
            return DeviceToolResult(request: request, status: "completed", payload: ["id": .string("x")], sentAt: 1_000)
        }, holdsPicture: { picture }, photoReads: reads, clock: { 1_000 })
        return (handler, inner)
    }

    // MARK: B01, B18

    @Test func createIsRefusedInAChatWithThePersonsPicture() async {
        let (handle, inner) = fence(picture: true)
        for operation in ["contacts.create", "calendar.create"] {
            let result = await handle(request(operation), scope, { true })
            #expect(result.status == "failed")
            #expect(result.code == "review_required")
            #expect(result.payload["note"]?.string?.contains("bighelp_draft_contact") == true)
            #expect(result.requestId == request(operation).requestId)
        }
        #expect(inner.handled.isEmpty)
    }

    @Test func everythingElseIsUnchanged() async {
        let (pictureChat, inner) = fence(picture: true)
        for operation in ["contacts.list", "contacts.update", "contacts.delete", "calendar.list", "calendar.update",
                          "calendar.delete", "reminders.create", "alarms.create", "photos.list"] {
            let result = await pictureChat(request(operation), scope, { true })
            #expect(result.status == "completed")
        }
        #expect(inner.handled.count == 9)
        let (plainChat, plainInner) = fence(picture: false)
        #expect(await plainChat(request("contacts.create"), scope, { true }).status == "completed")
        #expect(await plainChat(request("calendar.create"), scope, { true }).status == "completed")
        #expect(plainInner.handled == ["contacts.create", "calendar.create"])
    }

    @Test func aPhotoTheAgentReadFencesThatChat() async {
        let reads = ImageDraftPhotoReads()
        let (handle, inner) = fence(picture: false, reads: reads)
        #expect(await handle(request("photos.get"), scope, { true }).status == "completed")
        #expect(await handle(request("contacts.create"), scope, { true }).code == "review_required")
        // Another chat is unaffected.
        #expect(await handle(request("contacts.create", session: "session-2"), scope, { true }).status == "completed")
        #expect(inner.handled == ["photos.get", "contacts.create"])
    }

    // MARK: Which chats hold a picture

    @Test func onlyThePersonsPicturesCount() throws {
        let person = TimelineSender.user(snapshot: .init(name: "You"))
        let agent = TimelineSender.agent(id: "default", snapshot: .init(name: "Avery"))
        let photo = try ChatAttachment(id: "fence-test-photo-1", fileName: "card.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let file = try ChatAttachment(id: "fence-test-file-0001", fileName: "notes.txt", mimeType: "text/plain", data: Data([1]))
        func item(_ role: TimelineRole, _ text: String, _ attachments: [ChatAttachment] = []) -> TimelineItem {
            TimelineItem(id: UUID().uuidString, role: role, sender: role == .human ? person : agent,
                         content: .message(text), metadata: .init(sourceOrder: 1), attachments: attachments)
        }
        #expect(!ImageDraftWriteFence.holdsPersonPicture([item(.human, "Add Riley"), item(.assistant, "Done", [photo])]))
        #expect(!ImageDraftWriteFence.holdsPersonPicture([item(.human, "Notes", [file])]))
        #expect(ImageDraftWriteFence.holdsPersonPicture([item(.human, "Add this", [photo]), item(.assistant, "Sure")]))
        #expect(ImageDraftWriteFence.holdsPersonPicture([item(.human, "Add this\n@image:/tmp/hermes/card.png")]))
        #expect(ImageDraftWriteFence.holdsPersonPicture([item(.human, "[Image attached at: /tmp/hermes/card.png]")]))
        #expect(!ImageDraftWriteFence.holdsPersonPicture([item(.human, "What does @image: mean?")]))
        #expect(!ImageDraftWriteFence.holdsPersonPicture([item(.assistant, "@image:/tmp/hermes/generated.png")]))
    }
}
