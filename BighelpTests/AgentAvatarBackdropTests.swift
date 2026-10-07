import Foundation
import Testing

/// Agent avatars are transparent around the face, like Hermes's faces and shapes
/// (`CompanionAvatar.showsBackground` is off). The chat header painted a tinted circle
/// behind a saved character or pet; it showed on new agents once their characters were
/// saved per computer again (#201). The faces animate forever, so an image of one never
/// settles; this reads the drawing code instead.
struct AgentAvatarBackdropTests {
    private let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test func theChatHeaderDrawsNothingBehindACharacterOrPet() throws {
        let face = try section(of: "Bighelp/Board/AgentLiveAvatar.swift",
                               from: "private var face: some View {", to: "private var companionReaction")
        #expect(face.contains("CompanionAvatar(") && face.contains("PetdexAnimatedAvatar("), "The face is still drawn here")
        for shape in ["Circle()", ".fill(", ".background("] {
            #expect(!face.contains(shape), "Something is drawn behind the face: \(shape)")
        }
    }

    @Test func theEditorPreviewDrawsNothingBehindACharacter() throws {
        let preview = try section(of: "Bighelp/Agents/AgentEditorView.swift",
                                  from: "private func avatarPreview(", to: "} else if model.pendingAvatar != nil, let look = model.pendingLook")
        #expect(preview.contains("CompanionAvatar("))
        for shape in ["Circle()", ".fill(", ".background("] {
            #expect(!preview.contains(shape), "Something is drawn behind the character: \(shape)")
        }
    }

    private func section(of path: String, from start: String, to end: String) throws -> String {
        let source = try String(contentsOf: repository.appending(path: path), encoding: .utf8)
        let lower = try #require(source.range(of: start), "\(start) in \(path)")
        let upper = try #require(source.range(of: end, range: lower.upperBound..<source.endIndex), "\(end) in \(path)")
        return String(source[lower.upperBound..<upper.lowerBound])
    }
}
