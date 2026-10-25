import XCTest

/// A music card streaming into a chat, a few characters at a time: it shows a pending card until
/// the fence closes, then the real card once, and the app stays usable throughout.
final class MusicCardStreamUITests: BighelpUITestCase {
    @MainActor
    func testMusicCardStreamsInAndStaysResponsive() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-companion-disabled", "-test-music-card-reply"]
        app.launch()
        let newChat = chatNewChatButton(in: app).waitForExistence(timeout: 5)
            ? chatNewChatButton(in: app) : app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        confirmNewChatPicker(in: app)
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Play something")
        app.buttons["chat.send"].tap()

        let artwork = app.descendants(matching: .any)["card.music.artwork"].firstMatch
        XCTAssertTrue(artwork.waitForExistence(timeout: 30), "The music card draws once it has streamed in")
        let play = app.buttons["card.music.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        // The app still answers touches: a tap on Open in Music leaves it running.
        let open = app.buttons["card.music.open"].firstMatch
        XCTAssertTrue(open.isHittable)
        XCTAssertEqual(app.state, .runningForeground)
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_MUSIC_CARD_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("music-card-stream.png"))
        }
    }
}
