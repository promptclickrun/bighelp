import XCTest

/// The attachment tag above the message box, in each state, light and dark, and the
/// sheet behind it. BIGHELP_ATTACHMENT_EVIDENCE (a folder) also saves screenshots.
final class DraftAttachmentRailUITests: BighelpUITestCase {
    @MainActor
    func testTheTagSaysWhatsAttachedAndOpensTheSheet() throws {
        let states: [(hold: String, label: String)] = [
            ("photo", "1 photo"), ("file", "Lease 2026.pdf"), ("mixed", "4 attached, 3 photos, 1 PDF"),
            ("adding", "Adding 2 of 4, photos"), ("failed", "1 didn't attach"),
        ]
        for appearance in ["light", "dark"] {
            for (hold, label) in states {
                let app = launch(hold, appearance: appearance)
                let rail = app.buttons["chat.draft-attachments.rail"]
                XCTAssertTrue(rail.waitForExistence(timeout: 15), hold)
                XCTAssertTrue(rail.label.hasPrefix(label), "\(hold): \(rail.label)")
                let send = app.buttons["chat.send"]
                if hold == "adding" || hold == "failed" {
                    XCTAssertFalse(send.isEnabled, "\(hold): Send waits until everything is in")
                }
                save("rail-\(hold)-\(appearance)", app)
                if hold == "mixed" {
                    rail.tap()
                    let rows = app.descendants(matching: .any).matching(identifier: "chat.draft-attachment")
                    XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "The sheet lists each one")
                    XCTAssertEqual(rows.count, 4)
                    save("rail-sheet-\(appearance)", app)
                    app.buttons.matching(identifier: "chat.draft-attachment.remove").firstMatch.tap()
                    let fewer = expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: rows)
                    wait(for: [fewer], timeout: 5)
                    app.buttons["Done"].firstMatch.tap()
                    XCTAssertTrue(rail.waitForExistence(timeout: 5))
                    XCTAssertTrue(rail.label.hasPrefix("3 attached"), rail.label)
                }
                if hold == "failed" {
                    app.buttons["chat.draft-attachments.try-again"].tap()
                    let fixed = expectation(for: NSPredicate(format: "label BEGINSWITH %@", "3 attached"),
                                            evaluatedWith: rail)
                    wait(for: [fixed], timeout: 10)
                    XCTAssertTrue(send.isEnabled, "Send is back once it attached")
                    save("rail-failed-fixed-\(appearance)", app)
                }
                app.terminate()
            }
        }
    }

    @MainActor private func launch(_ hold: String, appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                               "-loopdy.demo.appearance", appearance, "-test-draft-attachments", hold]
        app.launch()
        return app
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_ATTACHMENT_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
