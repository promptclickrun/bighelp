import Foundation
import XCTest

/// Opt-in production-path validation for the native Hermes subagent rail.
///
/// This test intentionally has no fixture launch arguments and never creates a
/// host, account, child session, file, or external action. The prompt asks the
/// already-authorized Hermes host to perform one safe delegation; the test only
/// observes the resulting native UI and the persisted chat after relaunch.
final class NativeSubagentProductionUITests: BighelpUITestCase {
    @MainActor
    func testRealSubagentRailAndFoldSurviveReopen() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_SUBAGENT_UI"] == "1",
              let artifactDirectory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"],
              !artifactDirectory.isEmpty else {
            throw XCTSkip("Requires explicit real Hermes subagent UI authorization and an artifact directory.")
        }
        continueAfterFailure = false

        let nonce = "RAIL2102-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let prompt = "\(nonce). Call delegate_task exactly once. Delegate one child with this instruction: wait 20 seconds, then reply exactly RAIL2102 OK. Do not write files, access external services, or call any other tools. After the child completes, return exactly RAIL2102 OK."

        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]
        app.launch()
        defer { capture("real-subagent-final-state-2102", app, directory: artifactDirectory) }

        XCTAssertTrue(app.buttons["root.new-chat"].waitForExistence(timeout: 30),
                      "The authorized Hermes workspace must expose New Chat.")
        app.buttons["root.new-chat"].tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20),
                      "The real chat composer must be available before sending.")
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10) && send.isEnabled,
                      "The delegated prompt must be sendable.")
        send.tap()

        let rail = app.buttons["chat.session-status.subagents"]
        XCTAssertTrue(rail.waitForExistence(timeout: 60),
                      "A native subagent start event must surface the Subagents rail.")
        capture("real-subagent-rail-running-2102", app, directory: artifactDirectory)

        rail.tap()
        let nativeRows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "subagent.native.roster."
        ))
        XCTAssertTrue(nativeRows.firstMatch.waitForExistence(timeout: 15),
                      "The Subagents roster must render the authoritative native delegation.")
        let nativeRow = nativeRows.firstMatch
        XCTAssertTrue(nativeRow.isHittable)
        XCTAssertTrue(nativeRow.label.localizedCaseInsensitiveContains("working"),
                      "The child must show as working while it waits.")
        XCTAssertTrue(
            nativeRow.label.localizedCaseInsensitiveContains("delegate")
                || nativeRow.label.localizedCaseInsensitiveContains("wait")
                || nativeRow.label.localizedCaseInsensitiveContains("rail2102"),
                      "The roster must expose the real delegated goal.")
        capture("real-subagent-roster-running-2102", app, directory: artifactDirectory)
        XCTAssertEqual(
            Set((0..<nativeRows.count).compactMap {
                let row = nativeRows.element(boundBy: $0)
                return row.isHittable ? row.identifier : nil
            }).count,
            1,
            "Exactly one native delegation must be rendered for delegate_task exactly once."
        )
        capture("real-subagent-roster-running-2102", app, directory: artifactDirectory)
        dismissSheet(app)

        let reply = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label ENDSWITH %@", "chat.message.inline-selection", "RAIL2102 OK"
        )).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 150),
                      "The parent chat must return the delegated child result.")
        XCTAssertTrue(app.buttons["chat.voice"].waitForExistence(timeout: 120),
                      "The real parent turn must finish before checking terminal rail state.")
        capture("real-subagent-before-terminal-check-2102", app, directory: artifactDirectory)
        XCTAssertTrue(rail.waitForNonExistence(timeout: 20),
                      "The active Subagents rail must settle after the native delegation completes.")
        capture("real-subagent-completed-2102", app, directory: artifactDirectory)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 30),
                      "The real chat catalog must restore after relaunch.")
        app.buttons["tab.sessions"].tap()
        let search = app.descendants(matching: .any).matching(identifier: "sessions.search").firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15),
                      "The session catalog must expose its real search field.")
        search.tap()
        search.typeText(nonce)
        let matchingSessions = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "session.row.", nonce
        ))
        XCTAssertTrue(matchingSessions.firstMatch.waitForExistence(timeout: 45),
                      "The nonce must locate the same persisted Hermes chat after relaunch.")
        matchingSessions.firstMatch.tap()

        let reopenedComposer = app.textViews["chat.composer.text"]
        XCTAssertTrue(reopenedComposer.waitForExistence(timeout: 30),
                      "The searched Hermes chat must reopen.")
        let reopenedReply = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label ENDSWITH %@", "chat.message.inline-selection", "RAIL2102 OK"
        )).firstMatch
        XCTAssertTrue(reopenedReply.waitForExistence(timeout: 30),
                      "The delegated result must remain visible after reopening.")

        let folds = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "chat.completed-turn:"
        ))
        XCTAssertTrue(folds.firstMatch.waitForExistence(timeout: 30),
                      "Completed delegated work must remain represented by a collapsed fold.")
        XCTAssertEqual(folds.count, 1,
                       "One delegated turn must remain one completed-work fold after reopening.")
        let standaloneActivities = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "chat.activity."
        ))
        XCTAssertEqual(standaloneActivities.count, 0,
                       "Collapsed completed work must not expose standalone tool/activity rows.")
        capture("real-subagent-reopened-folded-2102", app, directory: artifactDirectory)
    }

    @MainActor
    private func dismissSheet(_ app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 10),
                      "The Subagents roster must expose a native sheet dismissal handle.")
        guard grabber.exists else { return }
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        )
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.navigationBars["Subagents"].exists && !app.navigationBars["Session agents"].exists
        }, object: app)
        XCTAssertEqual(
            XCTWaiter.wait(for: [closed], timeout: 10),
            .completed,
            "The Subagents roster must close before observing the completed reply."
        )
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication, directory: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        try? app.screenshot().pngRepresentation.write(to: base.appendingPathComponent(name + ".png"))
        try? app.debugDescription.write(
            to: base.appendingPathComponent(name + ".txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
