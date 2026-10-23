import XCTest

/// Object cards (`-test-object-cards`): a person, a place and a song in one
/// card, on the demo data with made-up people and places. Each object shows
/// only the buttons its props allow, in light and dark.
///
/// BIGHELP_EVIDENCE=<folder> (TEST_RUNNER_BIGHELP_EVIDENCE through xcodebuild)
/// also saves the screenshots there as PNGs.
final class ObjectCardsUITests: BighelpUITestCase {
    private static let summary = "Coffee with Jordan Sample"

    private let buttons = [
        "card.contact.call", "card.contact.message", "card.contact.email", "card.contact.directions",
        "card.contact.contacts", "card.place.map", "card.place.directions", "card.place.maps",
        "card.music.play", "card.music.open",
    ]

    @MainActor
    func testTheObjectCardInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let timeline = app.descendants(matching: .any)["chat.timeline"].firstMatch
            XCTAssertTrue(timeline.waitForExistence(timeout: 10))
            let card = cardElement(in: app)
            XCTAssertTrue(card.waitForExistence(timeout: 10), "The object card shows in \(appearance)")
            for identifier in buttons {
                let button = app.buttons[identifier].firstMatch
                XCTAssertTrue(button.exists, "\(identifier) in \(appearance)")
                if button.exists, identifier != "card.place.map" {
                    XCTAssertGreaterThanOrEqual(button.frame.width, 44, "\(identifier) is a full touch target")
                    XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(identifier) is a full touch target")
                }
            }
            XCTAssertEqual(app.buttons["card.contact.call"].firstMatch.label, "Call")
            XCTAssertEqual(app.buttons["card.contact.contacts"].firstMatch.label, "Add to Contacts",
                           "The demo person has no saved contact, so it offers Add to Contacts")
            // Give MapKit a moment to make the map picture.
            RunLoop.current.run(until: Date().addingTimeInterval(4))
            save("object-card-\(appearance)", app.screenshot())
            if card.exists, card.frame.height > 40 { save("object-card-\(appearance)-card", card.screenshot()) }

            // Add to Contacts opens Contacts' own new-contact screen, with no permission prompt.
            app.buttons["card.contact.contacts"].firstMatch.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            save("object-card-\(appearance)-add-contact", app.screenshot())
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.waitForExistence(timeout: 3) { cancel.tap() } else { app.swipeDown(velocity: .fast) }
            app.terminate()
        }
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-object-cards",
                               "-loopdy.home.opens-chat", "YES", "-loopdy.settings.nerd-mode", "NO",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func cardElement(in app: XCUIApplication) -> XCUIElement {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.summary))
        // Recycled rows can leave a copy with an empty frame; use the one on screen.
        return matches.allElementsBoundByIndex.first { $0.frame.height > 40 } ?? matches.firstMatch
    }

    @MainActor
    private func save(_ name: String, _ screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
