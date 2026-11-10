import Foundation
import Testing

struct ChatGlassArchitectureTests {
    @Test func chatChromeUsesOnlyBoundedControlGlass() throws {
        let source = try load("Bighelp/Chat/ChatView.swift")
        #expect(!source.contains("ChatFloatingChromeBackdropLayer"))
        #expect(!source.contains("ChatFloatingChromeBackdropSurface"))
        #expect(source.contains("bighelpNavigationGlass"))
    }

    @Test func presentedChatSurfacesDoNotPaintOpaqueCanvasBackings() throws {
        let picker = try load("Bighelp/DesignSystem/BighelpModelPickerSheet.swift")
        let settings = try load("Bighelp/Chat/ChatSessionSettingsView.swift")
        let references = try load("Bighelp/References/ReferenceHubDrawer.swift")

        #expect(!picker.contains("presentationBackground(theme.canvas)"))
        #expect(settings.contains(".scrollContentBackground(.hidden)"))
        #expect(!references.contains(".fill(theme.surface)"))
    }

    private func load(_ relativePath: String) throws -> String {
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repository.appending(path: relativePath), encoding: .utf8)
    }
}