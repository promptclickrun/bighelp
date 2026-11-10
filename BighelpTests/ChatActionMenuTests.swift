import Testing
@testable import Bighelp

/// The plus button's menu holds only ways to add something to a message.
@MainActor
struct ChatActionMenuTests {
    @Test func theMenuListsTheAttachmentSourcesInOrder() {
        #expect(ChatActionMenuAction.allCases == [.camera, .scanDocument, .photo, .file, .drawing])
        #expect(ChatActionMenuAction.allCases.map(\.title)
            == ["Camera", "Scan Document", "Photo Library", "Files", "Drawing"])
        // Only what this device has is offered, in the same order.
        let offered = ChatActionMenuAction.offered
        #expect(offered == ChatActionMenuAction.allCases.filter(offered.contains))
        #expect(offered.contains(.drawing) == ChatDrawingSheet.isSupported)
    }

    /// A connection that takes no pictures (or no files) turns those rows off, not the menu.
    @Test func eachSourceNeedsTheKindItAdds() {
        for action in [ChatActionMenuAction.photo, .drawing] {
            #expect(action.isAvailable(taking: [.image], hasCamera: false))
            #expect(!action.isAvailable(taking: [.file], hasCamera: true))
        }
        for action in [ChatActionMenuAction.file, .scanDocument] {
            #expect(action.isAvailable(taking: [.file], hasCamera: false))
            #expect(!action.isAvailable(taking: [.image], hasCamera: true))
        }
        #expect(ChatActionMenuAction.camera.isAvailable(taking: [.image], hasCamera: true))
        #expect(!ChatActionMenuAction.camera.isAvailable(taking: [.image], hasCamera: false))
        #expect(!ChatActionMenuAction.camera.isAvailable(taking: [], hasCamera: true))
    }
}
