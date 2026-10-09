import Foundation
import UIKit
import XCTest

final class NativeWorkspaceProductionUITests: BighelpUITestCase {
    /// Opt-in: on a saved real host, send a first message, then attach an image
    /// and send it; reopening the chat afterwards must still work.
    @MainActor
    func testSavedRealHostImageAfterFirstMessage() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_IMAGE_FOLLOWUP"] == "1" else {
            throw XCTSkip("Requires a saved real host.")
        }
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 20))
        exerciseImageAfterFirstMessage(app)
    }

    /// Send a first message, attach a photo, send it, then reopen the chat.
    @MainActor
    private func exerciseImageAfterFirstMessage(_ app: XCUIApplication) {
        let evidence = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"]
        func record(_ name: String, _ app: XCUIApplication) {
            capture("image-followup-" + name, app)
            if let evidence {
                try? FileManager.default.createDirectory(atPath: evidence, withIntermediateDirectories: true)
                try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: evidence + "/\(name).png"))
                try? app.debugDescription.write(toFile: evidence + "/\(name).txt", atomically: true, encoding: .utf8)
            }
        }
        app.buttons["root.new-chat"].firstMatch.tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap(); composer.typeText("Hi")
        app.buttons["chat.send"].tap()
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "complete")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60), "First turn must complete.")
        sleep(2)
        record("1-after-first-reply", app)
        if let control = ProcessInfo.processInfo.environment["BIGHELP_NETWORK_DROP_CONTROL"],
           let seconds = ProcessInfo.processInfo.environment["BIGHELP_NETWORK_DROP_SECONDS"].flatMap(UInt32.init) {
            // The network path drops while the app stays open (Wi-Fi/cellular
            // handoff, Tailscale re-route) for longer than the quick retries.
            try? "down".write(toFile: control, atomically: true, encoding: .utf8)
            sleep(seconds)
            record("1c-during-drop", app)
            try? "up".write(toFile: control, atomically: true, encoding: .utf8)
            sleep(6)
            record("1d-after-network-returns", app)
        }
        if let seconds = ProcessInfo.processInfo.environment["BIGHELP_IMAGE_BACKGROUND_SECONDS"].flatMap(UInt32.init) {
            // Like leaving to grab a screenshot: the app is suspended and its
            // live connection closes before the person returns.
            XCUIDevice.shared.press(.home)
            sleep(seconds)
            app.activate()
            sleep(3)
            record("1b-after-return", app)
        }

        var attached = false
        if ProcessInfo.processInfo.environment["BIGHELP_IMAGE_VIA_PASTE"] == "1" {
            // Like copying a screenshot in another app and pasting it here.
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400))
            UIPasteboard.general.image = renderer.image { context in
                UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            }
            composer.press(forDuration: 1.2)
            let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"].firstMatch
            if paste.waitForExistence(timeout: 5) { paste.tap(); attached = true }
            let allow = app.buttons["Allow Paste"].firstMatch
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        } else {
        // Attach a photo the way a person does: + › Photo › pick the first image.
        app.buttons["chat.attachment"].tap()
        let photo = app.buttons["chat.action.photo"]
        if photo.waitForExistence(timeout: 5), photo.isEnabled {
            photo.tap()
            let image = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label CONTAINS %@", "PXGGridLayout", "Photo")).firstMatch
            if image.waitForExistence(timeout: 10) { image.tap(); attached = true }
            else {
                let any = app.scrollViews.images.firstMatch
                if any.waitForExistence(timeout: 5) { any.tap(); attached = true }
            }
            let add = app.buttons["Add"]
            if add.waitForExistence(timeout: 2) { add.tap() }
        }
        }
        sleep(4)
        record("2-after-attach", app)
        let send = app.buttons["chat.send"]
        XCTAssertTrue(attached, "A photo must be selectable")
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed, "Send must enable with an image attached")
        record("3-send-state", app)
        if send.isEnabled {
            send.tap()
            sleep(8)
            record("4-after-image-send", app)
        }
        if let signal = ProcessInfo.processInfo.environment["BIGHELP_BEFORE_REOPEN_SIGNAL"] {
            // Lets the harness rewrite the saved turn the way a vision + memory
            // host stores it, so reopening exercises that history shape.
            try? "ready".write(toFile: signal, atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, (try? String(contentsOfFile: signal, encoding: .utf8)) != "done" { sleep(1) }
        }
        app.buttons["Back"].firstMatch.tap()
        sleep(2)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        sleep(3)
        record("5-reopen", app)
        XCTAssertFalse(app.alerts["Unable to open"].exists, "Reopening the chat must work")
        for leaked in ["memory-context", "Image attached", "[screenshot]", "@image:"] {
            let text = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", leaked, leaked)).firstMatch
            XCTAssertFalse(text.exists, "Saved message must not show \(leaked)")
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
    }

    /// A host without live voice must still lead somewhere: the unavailable
    /// screen offers turn-based voice, which opens the listening screen.
    @MainActor
    private func exerciseVoiceFallback(_ app: XCUIApplication) {
        app.buttons["root.new-chat"].firstMatch.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 20))
        app.buttons["chat.voice"].firstMatch.tap()
        let unavailable = app.buttons["voice.live-unavailable.use-turn-based"]
        let failed = app.buttons["live-voice.use-turn-based"]
        let start = app.buttons["live-voice.start"]
        if start.waitForExistence(timeout: 5), !unavailable.exists {
            start.tap()
            _ = failed.waitForExistence(timeout: 20)
        }
        let turnBased = unavailable.exists ? unavailable : failed
        XCTAssertTrue(turnBased.waitForExistence(timeout: 10), "A way to turn-based voice must be offered.")
        capture("voice-fallback-offered", app)
        turnBased.tap()
        XCTAssertTrue(app.descendants(matching: .any)["voice.screen"].waitForExistence(timeout: 10),
                      "Turn-based voice must open.")
        capture("voice-fallback-turn-based", app)
    }

    /// Every way of leaving a chat must come back to canonical Hermes history.
    /// Read-only look at Feed, Goals and Apps on a real host: never sends a
    /// message, so it never spends the host's AI provider.
    @MainActor
    private func inspectBoardReadOnly(_ app: XCUIApplication) {
        let evidence = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"]
        func record(_ name: String) {
            capture("inspect-" + name, app)
            guard let evidence else { return }
            try? FileManager.default.createDirectory(atPath: evidence, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: evidence + "/\(name).png"))
            try? app.debugDescription.write(toFile: evidence + "/\(name).txt", atomically: true, encoding: .utf8)
        }
        sleep(8)
        record("start")
        for tab in ["feed", "goals", "apps"] {
            openRootTab("tab.\(tab)", in: app)
            sleep(tab == "apps" ? 8 : 4)
            record(tab)
        }
        let media = app.buttons["Media"].firstMatch
        if media.exists {
            media.tap(); sleep(10); record("media")
            let first = app.buttons["board.media.item"].firstMatch
            if first.waitForExistence(timeout: 5) { first.tap(); sleep(8); record("media-open") }
        }
    }

    /// The agent home against a real host: the avatar reacts while a tool runs,
    /// the profile shows recorded activity and SOUL, and the board routes answer.
    @MainActor
    private func exerciseAgentHome(_ app: XCUIApplication, prompt: String, reply: String, config: [String: String]) {
        func record(_ name: String) {
            capture("agent-home-" + name, app)
            if let evidence = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] {
                try? FileManager.default.createDirectory(atPath: evidence, withIntermediateDirectories: true)
                try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: evidence + "/\(name).png"))
            }
        }
        // Signing in lands in the agent's home chat; Chat reopens it from the list.
        let avatar = app.buttons["agent.hero.avatar"]
        if !avatar.waitForExistence(timeout: 15) { openRootTab("tab.sessions", in: app) }
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "The Chat tab opens the agent's home chat with its live avatar.")
        record("home-chat")
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap(); composer.typeText(prompt)
        app.buttons["chat.send"].tap()
        let finished = app.textViews.matching(NSPredicate(
            format: "identifier == 'chat.message.inline-selection' AND (label CONTAINS %@ OR value CONTAINS %@)", reply, reply
        )).firstMatch
        var seen: [String] = []
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !finished.exists {
            if let value = avatar.value as? String, seen.last != value {
                seen.append(value)
                record("working-\(seen.count)")
            }
            usleep(150_000)
        }
        print("AGENT-HOME avatar states: \(seen)")
        XCTAssertTrue(finished.exists, "The fixture turn must finish.")
        XCTAssertTrue(seen.contains { $0 != "Here for you" }, "The avatar must react while the agent works: \(seen)")
        sleep(2)
        record("chat-done")

        // Reacting to the reply tells the agent; its [SILENT] answer shows nothing.
        let traffic = config["receipt_path"].map { ($0 as NSString).deletingLastPathComponent + "/traffic.json" }
        func reactionNotes() -> Int {
            guard let traffic, let data = FileManager.default.contents(atPath: traffic),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
            return object["reaction_notes"] as? Int ?? 0
        }
        // Reactions need the reply's saved row; give the host a moment to confirm it.
        sleep(3)
        finished.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 10)).press(forDuration: 1.0)
        let react = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "React")).firstMatch
        if react.waitForExistence(timeout: 5) {
            react.tap()
            let heart = app.buttons["React ❤️"].firstMatch
            XCTAssertTrue(heart.waitForExistence(timeout: 5))
            heart.tap()
            let noted = Date().addingTimeInterval(20)
            while Date() < noted, reactionNotes() == 0 { usleep(500_000) }
            XCTAssertGreaterThan(reactionNotes(), 0, "The agent must hear about the reaction.")
            sleep(4)
            XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                "[SILENT]", "[SILENT]")).firstMatch.exists, "A silent answer must not show.")
            record("reacted")
        } else {
            record("no-react-action")
            XCTFail("The reply offers no React action.")
            app.tap()
        }

        // The agent can react to the person's message, when this host gives app
        // chats the plugin's tools (a code-folder chat may get Hermes' coding set only).
        composer.tap(); composer.typeText("Please react direct to this")
        app.buttons["chat.send"].tap()
        let agentReaction = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Agent reaction")).firstMatch
        let reacted = agentReaction.waitForExistence(timeout: 45)
        record("agent-reacted")
        let offered: [String] = traffic.flatMap { FileManager.default.contents(atPath: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["offered_tools"] as? [String] ?? []
        if offered.contains(where: { $0.contains("react") }) {
            XCTAssertTrue(reacted, "The agent's reaction must show on my message.")
        }

        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent.profile"].waitForExistence(timeout: 10))
        sleep(3)
        record("profile-activity")
        app.buttons["agent.profile.tab.identity"].tap()
        sleep(2)
        record("profile-identity")
        app.buttons["agent.profile.close"].tap()

        for (tab, screen) in [("feed", "board.feed.empty"), ("goals", "board.goals.empty")] {
            openRootTab("tab.\(tab)", in: app)
            XCTAssertTrue(app.descendants(matching: .any)[screen].firstMatch.waitForExistence(timeout: 15), screen)
            XCTAssertFalse(app.descendants(matching: .any)["board.plugin-required"].exists, "The host advertises the board.")
            record(tab)
        }
        openRootTab("tab.sessions", in: app)
        record("chat-list")

        // Settings › Default model and AI providers load from this host.
        let invalid = NSPredicate(format: "label CONTAINS[c] %@", "unsupported or invalid")
        for (row, name) in [("settings.default-model", "default-model"), ("settings.providers", "providers")] {
            openRootTab("tab.profile", in: app)
            let button = app.descendants(matching: .any)[row].firstMatch
            let form = app.descendants(matching: .any)["settings.screen"].firstMatch
            for _ in 0..<4 { form.swipeDown() }
            for _ in 0..<5 where !(button.exists && button.isHittable) { form.swipeUp() }
            record("settings-root-\(name)")
            guard button.waitForExistence(timeout: 10) else { XCTFail("Missing \(row)"); continue }
            button.tap()
            sleep(6)
            record("settings-\(name)")
            XCTAssertFalse(app.descendants(matching: .any).matching(invalid).firstMatch.exists,
                           "\(name) must load from this host")
            let back = app.navigationBars.buttons.firstMatch
            if back.exists { back.tap() }
        }
    }

    /// Leave the app while a reply is still streaming ("slow direct" makes the
    /// fixture model take ~15 s), so the turn finishes on the host while the
    /// app is away. Returning must show the finished reply as part of the
    /// return refresh, not seconds after the header stops saying "Updating…".
    @MainActor
    private func exerciseBackgroundedTurn(_ app: XCUIApplication) {
        let environment = ProcessInfo.processInfo.environment
        func record(_ name: String) {
            capture("background-turn-" + name, app)
            if let evidence = environment["BIGHELP_UI_EVIDENCE"] {
                try? FileManager.default.createDirectory(atPath: evidence, withIntermediateDirectories: true)
                try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: evidence + "/\(name).png"))
                try? app.debugDescription.write(toFile: evidence + "/\(name).txt", atomically: true, encoding: .utf8)
            }
        }
        func bubble(_ text: String) -> XCUIElement {
            app.textViews.matching(NSPredicate(
                format: "identifier == 'chat.message.inline-selection' AND (label CONTAINS %@ OR value CONTAINS %@)",
                text, text
            )).firstMatch
        }
        let finished = "Direct streaming fixture complete."
        let identity = chatStatus(in: app)
        for round in 1...Int(environment["BIGHELP_TURN_BACKGROUND_ROUNDS"] ?? "1")! {
            if round == 1 {
                app.buttons["root.new-chat"].firstMatch.tap()
            }
            let composer = app.textViews["chat.composer.text"]
            XCTAssertTrue(composer.waitForExistence(timeout: 20))
            composer.tap(); composer.typeText("Slow direct reply, round \(round)")
            app.buttons["chat.send"].tap()
            let sent = Date()
            // Leave once the reply is visibly streaming but not finished.
            let finishedReplies = app.textViews.matching(NSPredicate(
                format: "identifier == 'chat.message.inline-selection' AND (label CONTAINS %@ OR value CONTAINS %@)",
                finished, finished
            ))
            let finishedBefore = finishedReplies.count
            _ = bubble("Direct").waitForExistence(timeout: 20)
            while Date().timeIntervalSince(sent) < 4 { usleep(250_000) }
            XCTAssertEqual(finishedReplies.count, finishedBefore, "Round \(round): leave before the reply finishes.")
            record("\(round)-1-streaming")
            XCUIDevice.shared.press(.home)
            sleep(UInt32(environment["BIGHELP_TURN_BACKGROUND_SECONDS"] ?? "30") ?? 30)
            app.activate()
            let returned = Date()
            var sawUpdating = false
            var updatingEnded: TimeInterval?
            var replyShown: TimeInterval?
            while Date().timeIntervalSince(returned) < 45 {
                let elapsed = Date().timeIntervalSince(returned)
                if (identity.value as? String) == "Updating…" {
                    sawUpdating = true
                } else if sawUpdating, updatingEnded == nil {
                    updatingEnded = elapsed
                }
                if replyShown == nil, finishedReplies.count > finishedBefore { replyShown = elapsed }
                if replyShown != nil, updatingEnded != nil || elapsed > 12 { break }
                usleep(200_000)
            }
            print("background-turn round \(round): updating seen \(sawUpdating), ended \(updatingEnded ?? -1)s; "
                + "reply shown \(replyShown ?? -1)s after return")
            record("\(round)-2-returned")
            XCTAssertNotNil(replyShown, "Round \(round): the reply that finished while away must show.")
            if let replyShown {
                XCTAssertLessThan(replyShown, 6, "Round \(round): the finished reply must show right after returning.")
                if let updatingEnded {
                    XCTAssertLessThanOrEqual(replyShown, updatingEnded + 1,
                        "Round \(round): the reply must be in place when the header stops saying Updating….")
                }
            }
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
        }
    }

    /// While the chat is away, the harness (BIGHELP_RETURN_REFRESH_SIGNAL)
    /// appends a saved reply to the host's session; returning must show it
    /// without a manual Force Refresh.
    @MainActor
    private func exerciseReturnRefresh(_ app: XCUIApplication) {
        let environment = ProcessInfo.processInfo.environment
        guard let signal = environment["BIGHELP_RETURN_REFRESH_SIGNAL"] else {
            XCTFail("Requires the return-refresh harness.")
            return
        }
        func record(_ name: String) {
            capture("return-refresh-" + name, app)
            if let evidence = environment["BIGHELP_UI_EVIDENCE"] {
                try? FileManager.default.createDirectory(atPath: evidence, withIntermediateDirectories: true)
                try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: evidence + "/\(name).png"))
                try? app.debugDescription.write(toFile: evidence + "/\(name).txt", atomically: true, encoding: .utf8)
            }
        }
        func appendSavedReply(to firstMessage: String, _ marker: String) {
            try? "insert|\(firstMessage)|\(marker)".write(toFile: signal, atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, (try? String(contentsOfFile: signal, encoding: .utf8)) != "done" {
                usleep(300_000)
            }
        }
        func shows(_ marker: String, within seconds: TimeInterval) -> Bool {
            let started = Date()
            // Only a message bubble in the open chat counts, not a list preview.
            let found = app.textViews.matching(NSPredicate(
                format: "identifier == 'chat.message.inline-selection' AND (label CONTAINS %@ OR value CONTAINS %@)",
                marker, marker
            )).firstMatch.waitForExistence(timeout: seconds)
            print("return-refresh \(marker): \(found ? "shown" : "missing") after \(Date().timeIntervalSince(started))s")
            return found
        }
        func startChat(_ text: String) {
            app.buttons["root.new-chat"].firstMatch.tap()
            let composer = app.textViews["chat.composer.text"]
            XCTAssertTrue(composer.waitForExistence(timeout: 20))
            composer.tap(); composer.typeText(text)
            app.buttons["chat.send"].tap()
            let reply = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "complete")).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 60), "First turn must complete.")
            sleep(2)
        }
        func back() {
            app.buttons["Back"].firstMatch.tap()
            sleep(2)
        }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.row."))
        func open(_ row: XCUIElement, _ step: String) {
            for _ in 0..<2 where !app.textViews["chat.composer.text"].exists {
                if row.waitForExistence(timeout: 5) { row.tap() }
                _ = app.textViews["chat.composer.text"].waitForExistence(timeout: 5)
            }
            XCTAssertTrue(app.textViews["chat.composer.text"].exists, "\(step): the chat must open.")
            record(step + "-opened")
        }

        // 1. Leave for the chat list and come back.
        startChat("Return A")
        back()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let chatAID = rows.element(boundBy: 0).identifier
        print("return-refresh chat A row: \(chatAID)")
        let chatA = app.buttons.matching(NSPredicate(format: "identifier == %@", chatAID)).firstMatch
        appendSavedReply(to: "Return A", "Saved while on the list")
        open(chatA, "1")
        XCTAssertTrue(shows("Saved while on the list", within: 15), "Reopening a chat must reload it from Hermes.")
        record("1-reopen")

        // 1b. On a slow connection the header says the chat is catching up.
        if let control = environment["BIGHELP_NETWORK_DROP_CONTROL"] {
            back()
            try? "slow".write(toFile: control, atomically: true, encoding: .utf8)
            appendSavedReply(to: "Return A", "Saved on a slow connection")
            open(chatA, "1b")
            let identity = chatStatus(in: app)
            let updating = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Updating…'"), object: identity)
            XCTAssertEqual(XCTWaiter.wait(for: [updating], timeout: 5), .completed, "The header must say the chat is updating.")
            record("1b-updating")
            try? "up".write(toFile: control, atomically: true, encoding: .utf8)
            XCTAssertTrue(shows("Saved on a slow connection", within: 30))
        }

        // 2. Switch to another chat, then back.
        back()
        startChat("Return B")
        back()
        appendSavedReply(to: "Return A", "Saved while in another chat")
        open(chatA, "2")
        XCTAssertTrue(shows("Saved while in another chat", within: 15), "Switching back must reload the chat.")
        record("2-switch")

        // 3. Background the app with the chat open, then return.
        XCUIDevice.shared.press(.home)
        sleep(3)
        appendSavedReply(to: "Return A", "Saved while in the background")
        sleep(UInt32(environment["BIGHELP_RETURN_BACKGROUND_SECONDS"] ?? "20") ?? 20)
        app.activate()
        XCTAssertTrue(shows("Saved while in the background", within: 20), "Returning to the app must reload the open chat.")
        record("3-foreground")

        // 4. Step into the chat's files, then close them.
        chatMenuItem("chat.files", in: app).tap()
        sleep(2)
        appendSavedReply(to: "Return A", "Saved while the details were open")
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3), done.isHittable { done.tap() } else {
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(shows("Saved while the details were open", within: 15),
                      "Closing a screen opened from the chat must reload it.")
        record("4-covered")

        // 5. Background while the network is also gone, then come back before it returns.
        if let control = environment["BIGHELP_NETWORK_DROP_CONTROL"] {
            XCUIDevice.shared.press(.home)
            try? "down".write(toFile: control, atomically: true, encoding: .utf8)
            appendSavedReply(to: "Return A", "Saved while offline")
            sleep(20)
            app.activate()
            sleep(8)
            try? "up".write(toFile: control, atomically: true, encoding: .utf8)
            XCTAssertTrue(shows("Saved while offline", within: 45),
                          "Once the connection returns, the open chat must reload.")
            record("5-offline-return")
        }

        // Control: an explicit Force refresh reloads the same saved history.
        appendSavedReply(to: "Return A", "Saved before Force refresh")
        app.buttons["chat.options"].firstMatch.tap()
        let force = app.buttons["Force refresh"].firstMatch
        if !force.waitForExistence(timeout: 3) {
            app.buttons["chat.options.advanced"].firstMatch.tap()
        }
        if force.waitForExistence(timeout: 5) { force.tap() }
        XCTAssertTrue(shows("Saved before Force refresh", within: 20), "Force refresh must reload saved history.")
        record("6-force-refresh")
    }

    /// Opt-in: relaunch onto an already-saved real host and open every root tab
    /// and creation sheet. Run against a Release build to catch device-only
    /// failures such as oversized SwiftUI view types exhausting the main stack.
    @MainActor
    func testSavedRealHostRootTabsStayAlive() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_ROOT_TABS"] == "1" else {
            throw XCTSkip("Requires a saved real host.")
        }
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 20), "The saved host must open the tab bar.")
        func alive(_ step: String) {
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "App must survive: \(step)")
            capture("root-tabs-" + step, app)
        }
        func dismiss() {
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists && cancel.isHittable { cancel.tap() }
            let discard = app.buttons["Discard changes"].firstMatch
            if discard.waitForExistence(timeout: 1) { discard.tap() }
            sleep(1)
        }
        for tab in ["tab.sessions", "tab.feed", "tab.ideas", "tab.goals", "tab.apps",
                    "tab.agents", "tab.scheduled-tasks", "tab.profile"] {
            openRootTab(tab, in: app)
            alive(tab)
        }
        // The agent home's sheets: switcher from Feed, ☰ from Chat.
        openRootTab("tab.feed", in: app)
        if app.buttons["agent.hero.name"].waitForExistence(timeout: 5) {
            app.buttons["agent.hero.name"].tap(); alive("agent-switcher")
            app.buttons["Done"].firstMatch.tap()
        }
        openRootTab("tab.sessions", in: app)
        let menu = [app.buttons["chat.menu"], app.buttons["home.drawer.open"]].first { $0.waitForExistence(timeout: 5) }
        if let menu {
            menu.tap(); alive("home-drawer")
            app.buttons["menu.done"].tap()
        }
        openRootTab("tab.profile", in: app)
        let nerd = app.switches["settings.nerd-mode"]
        for _ in 0..<6 where !nerd.isHittable { app.swipeUp() }
        if nerd.isHittable {
            nerd.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            alive("settings-nerd-on")
            app.swipeUp(); app.swipeUp()
            alive("settings-nerd-lower")
            for _ in 0..<6 where !(nerd.exists && nerd.isHittable) { app.swipeDown() }
            if nerd.exists && nerd.isHittable {
                nerd.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            }
        }
        // Settings › Appearance (bubble color and page picks).
        let colors = app.buttons["settings.themes"]
        for _ in 0..<6 where !(colors.exists && colors.isHittable) { app.swipeDown() }
        if colors.exists && colors.isHittable {
            colors.tap(); alive("appearance")
        }
        openRootTab("tab.agents", in: app)
        if app.buttons["agents.create"].waitForExistence(timeout: 5), app.buttons["agents.create"].isEnabled {
            app.buttons["agents.create"].tap(); alive("agent-studio"); dismiss()
        }
        openRootTab("tab.scheduled-tasks", in: app)
        if app.buttons["scheduled-tasks.create"].waitForExistence(timeout: 5), app.buttons["scheduled-tasks.create"].isEnabled {
            app.buttons["scheduled-tasks.create"].tap(); alive("task-editor"); dismiss()
        }
        app.buttons["tab.sessions"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.row.")).firstMatch
        if row.waitForExistence(timeout: 5) {
            row.tap(); alive("chat")
            if openChatInfo(in: app) { alive("chat-info") }
        }
    }

    @MainActor
    func testSavedRealHostNotificationSetup() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_NOTIFICATIONS_UI"] == "1",
              let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] else {
            throw XCTSkip("Requires actual saved host and optional notification enrollment authorization.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        XCTAssertTrue(app.buttons["tab.workspace"].waitForExistence(timeout: 20))
        app.buttons["tab.workspace"].tap()
        let connections = app.buttons["workspace.open.instances"]
        for _ in 0..<6 where !connections.isHittable { app.swipeUp() }
        XCTAssertTrue(connections.waitForExistence(timeout: 10)); connections.tap()
        let host = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "hosts.host.")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 15)); host.tap()
        let enable = app.buttons["host-setup.enable-notifications"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10)); enable.tap()
        let install = app.buttons["host-setup.install-plugin"]
        XCTAssertTrue(install.waitForExistence(timeout: 5)); install.tap()
        let status = app.staticTexts["host-setup.notification-status"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: install)
        _ = XCTWaiter.wait(for: [finished], timeout: 35)
        try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-notification-setup.txt"), atomically: true, encoding: .utf8)
        capture("real-notification-setup", app)
        XCTAssertFalse(status.label.contains("host did not confirm"))
        XCTAssertFalse(status.label.contains("different or unverified pin"))
        // A simulator without an APNs recipient/account cannot demonstrate
        // physical push delivery. Preserve its actual prerequisite state.
        XCTAssertTrue(status.label.contains("enrollment verified") || status.label.contains("configuration"))
    }

    @MainActor
    func testSavedRealHostModelSelection() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_MODEL_UI"] == "1",
              let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] else {
            throw XCTSkip("Requires authorized actual Hermes session model changes.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        defer {
            try? app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-model-picker-tree.txt"), atomically: true, encoding: .utf8)
            capture("real-model-picker", app)
        }
        XCTAssertTrue(app.buttons["root.new-chat"].waitForExistence(timeout: 20))
        app.buttons["root.new-chat"].tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.tap()
        let controls = chatMenuItem("chat.session-controls", in: app)
        XCTAssertTrue(controls.waitForExistence(timeout: 20))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: controls)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        controls.tap()
        let search = app.searchFields["model-picker.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20)); search.tap(); search.typeText("gpt-5.5")
        let model = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND NOT identifier BEGINSWITH %@", "model-picker.", ".gpt-5.5", "model-picker.pin.")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 25))
        if ProcessInfo.processInfo.environment["BIGHELP_REAL_MODEL_BACKGROUND"] == "1" {
            XCUIDevice.shared.press(.home); app.activate()
            XCTAssertTrue(model.waitForExistence(timeout: 20))
            let reconnected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND enabled == true"), object: model
            )
            let reconnectResult = XCTWaiter.wait(for: [reconnected], timeout: 15)
            try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-model-reconnect-state.txt"), atomically: true, encoding: .utf8)
            capture("real-model-reconnect-state", app)
            XCTAssertEqual(reconnectResult, .completed,
                           "Same-host reconnect must restore model controls without reopening the sheet.")
        }
        model.tap()
        let apply = app.buttons["model-picker.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10)); apply.tap()
        let applied = app.buttons["model-picker.dismiss"].waitForNonExistence(timeout: 30)
        try? app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-model-picker-tree.txt"), atomically: true, encoding: .utf8)
        capture("real-model-picker-after-apply", app)
        XCTAssertTrue(applied, "Real session model selection must apply and close without an expired picker error.")
        XCTAssertFalse(app.debugDescription.contains("That model choice expired"))
        composer.tap()
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        XCTAssertTrue(controls.value.debugDescription.lowercased().contains("gpt-5.5"))
    }

    @MainActor
    func testSavedRealHostFreshCanvasAndCompletedReply() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_FRESH_CHAT_UI"] == "1",
              let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] else {
            throw XCTSkip("Requires authorized actual Hermes chat creation and messaging.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        XCTAssertTrue(app.buttons["root.new-chat"].waitForExistence(timeout: 20))
        let started = Date()
        app.buttons["root.new-chat"].tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2), "New Chat must present a canvas immediately.")
        let timing = ["automationTapToComposerSeconds": Date().timeIntervalSince(started)]
        try JSONEncoder().encode(timing).write(to: URL(fileURLWithPath: directory).appendingPathComponent("fresh-chat-timing-2101.json"))
        XCTAssertFalse(app.staticTexts["Opening new chat"].exists)
        XCTAssertFalse(app.otherElements["new-chat.opening"].exists)
        capture("real-host-fresh-canvas-2101", app)
        composer.tap()
        composer.typeText("Reply with exactly UI2101 OK. Do not call tools or delegate.")
        let send = app.buttons["chat.send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        send.tap()
        let reply = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label ENDSWITH %@",
            "chat.message.", "UI2101 OK"
        )).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90), "The real Hermes session must return its reply.")
        XCTAssertTrue(app.buttons["chat.voice"].waitForExistence(timeout: 15))
        let tree = app.debugDescription
        try tree.write(to: URL(fileURLWithPath: directory).appendingPathComponent("fresh-chat-completed-tree-2101.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(tree.contains("Reasoning completed"))
        XCTAssertFalse(tree.contains("More completed work"))
        capture("real-host-completed-reply-2101", app)
        if ProcessInfo.processInfo.environment["BIGHELP_REAL_BUBBLE_MENU"] == "1" {
            try verifyAgentBubbleActions(app, evidenceName: "real-one-to-one-message-actions")
        }
    }

    @MainActor
    func testSavedRealHostNewGroupSendsAndReopens() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_GROUP_CREATE"] == "1",
              let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] else {
            throw XCTSkip("Requires authorized real-host group creation and messaging.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        openRootTab("tab.agents", in: app, timeout: 20)
        XCTAssertTrue(app.buttons["agents.groups.create"].waitForExistence(timeout: 20))
        app.buttons["agents.groups.create"].tap()
        let name = app.textFields["bot-mode.create.title"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("bighelp verification 117")
        app.buttons["bot-mode.create.participant.default"].tap()
        app.buttons["bot-mode.create.participant.nova"].tap()
        app.buttons["bot-mode.create.submit"].tap()
        let composer = app.textViews["chat.composer.text"]
        let created = composer.waitForExistence(timeout: 20)
        capture("real-host-new-group-create-117", app)
        try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-new-group-tree-117.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(created)
        composer.tap()
        composer.typeText("@all Connectivity test. Each member reply once with your name followed by NEWGROUP117 OK. Do not call tools or delegate.")
        app.buttons["chat.send"].tap()
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Message could not be delivered")).firstMatch
        for _ in 0..<30 {
            if failure.exists { break }
            if app.buttons["chat.voice"].exists { break }
            Thread.sleep(forTimeInterval: 3)
        }
        capture("real-host-new-group-send-117", app)
        let sentTree = app.debugDescription
        try sentTree.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-new-group-send-tree-117.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(failure.exists)
        XCTAssertTrue(app.buttons["chat.voice"].exists)
        XCTAssertTrue(sentTree.contains("Juno NEWGROUP117 OK"))
        XCTAssertTrue(sentTree.contains("Nova NEWGROUP117 OK"))
        app.terminate(); app.launch()
        openRootTab("tab.agents", in: app, timeout: 20)
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "bighelp verification 117")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 20)); group.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        let reopenedTree = app.debugDescription
        XCTAssertTrue(reopenedTree.contains("Juno NEWGROUP117 OK"))
        XCTAssertTrue(reopenedTree.contains("Nova NEWGROUP117 OK"))
        capture("real-host-new-group-reopen-117", app)
    }

    @MainActor
    func testSavedRealHostExistingGroupOpens() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_GROUP_UI"] == "1",
              let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] else {
            throw XCTSkip("Requires the authorized actual Hermes host in the simulator.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        openRootTab("tab.agents", in: app, timeout: 20)
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ProcessInfo.processInfo.environment["BIGHELP_REAL_GROUP_NAME"] ?? "The Gang")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 20))
        group.tap()
        let opened = app.textViews["chat.composer.text"].waitForExistence(timeout: 20)
        capture("real-host-existing-group-117", app)
        try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-group-tree-117.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(opened, "Existing group must open its actual Hermes history.")
        XCTAssertFalse(app.alerts["Unable to open"].exists)
        if ProcessInfo.processInfo.environment["BIGHELP_REAL_GROUP_SEND"] == "1" {
            let composer = app.textViews["chat.composer.text"]
            composer.tap()
            composer.typeText(ProcessInfo.processInfo.environment["BIGHELP_REAL_GROUP_MESSAGE"] ?? "@all Connectivity test. Each member reply once with your name followed by GROUP117 OK. Do not call tools or delegate.")
            app.buttons["chat.send"].tap()
            if ProcessInfo.processInfo.environment["BIGHELP_REAL_GROUP_BACKGROUND"] == "1" {
                XCUIDevice.shared.press(.home)
                app.activate()
                XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 20))
            }
            let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Message could not be delivered")).firstMatch
            for _ in 0..<30 {
                if failure.exists { break }
                if app.buttons["chat.voice"].exists { break }
                Thread.sleep(forTimeInterval: 3)
            }
            capture("real-host-existing-group-send-117", app)
            try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-group-send-tree-117.txt"), atomically: true, encoding: .utf8)
            XCTAssertFalse(failure.exists)
            XCTAssertFalse(app.debugDescription.contains("Delivery is unconfirmed"))
            XCTAssertFalse(app.debugDescription.contains("Room synchronization could not be verified"))
            XCTAssertTrue(app.buttons["chat.voice"].exists, "Group discussion must settle.")
            app.terminate(); app.launch()
            openRootTab("tab.agents", in: app, timeout: 20)
            XCTAssertTrue(group.waitForExistence(timeout: 20)); group.tap()
            XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 20))
            XCTAssertFalse(app.alerts["Unable to open"].exists)
        }
        if ProcessInfo.processInfo.environment["BIGHELP_REAL_BUBBLE_MENU"] == "1" {
            try verifyAgentBubbleActions(app, evidenceName: "real-group-message-actions")
        }
    }

    @MainActor
    private func verifyAgentBubbleActions(_ app: XCUIApplication, evidenceName: String) throws {
        let replies = app.textViews.matching(identifier: "chat.message.inline-selection")
        let reply = try XCTUnwrap(replies.allElementsBoundByIndex.last(where: \.isHittable))
        reply.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 10)).press(forDuration: 1)
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy to clipboard")).firstMatch
        let select = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Select text")).firstMatch
        let menuShown = copy.waitForExistence(timeout: 5) && select.waitForExistence(timeout: 5)
        capture(evidenceName, app)
        XCTAssertTrue(menuShown, "Agent replies must expose the same copy and text selection actions as user messages.")
        select.tap()
        XCTAssertTrue(app.navigationBars["Select text"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    @MainActor
    func testSavedRealHostPhoneCalendar() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_PHONE_UI"] == "1",
              let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] else {
            throw XCTSkip("Requires authorized real-host simulator permission validation.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        XCTAssertTrue(app.buttons["root.new-chat"].waitForExistence(timeout: 20))
        app.buttons["root.new-chat"].tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 15))
        openChatWorkspaceMenu(in: app)
        app.buttons["menu.settings"].tap()
        app.buttons["settings.menu.permissions"].tap()
        app.buttons["permissions.open.calendar"].firstMatch.tap()
        let toggle = app.switches["permissions.device-tools.calendar"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if toggle.value as? String != "1" {
            (toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle).tap()
            let grant = app.alerts.buttons["Allow Full Access"]
            if grant.waitForExistence(timeout: 5) { grant.tap() }
        }
        capture("real-host-phone-calendar-enabled-116", app)
        for _ in 0..<3 { app.navigationBars.buttons.firstMatch.tap() }
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        XCTAssertTrue(app.buttons["root.new-chat"].waitForExistence(timeout: 10))
        app.buttons["root.new-chat"].tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Use iphone_calendar once with operation list, start 2026-09-14T00:00:00-05:00, end 2026-09-15T00:00:00-05:00, timeZone America/Chicago, limit 1. This tests the connected iOS simulator calendar. Do not call any other tools and do not change events. Report only whether the tool succeeded, not event contents.")
        app.buttons["chat.send"].tap()
        for iteration in 0..<24 {
            try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-phone-tree.txt"), atomically: true, encoding: .utf8)
            if iteration % 3 == 0 { capture("real-host-phone-progress-116", app) }
            if FileManager.default.fileExists(atPath: directory + "/real-host-phone-finish.txt") { break }
            Thread.sleep(forTimeInterval: 5)
        }
        capture("real-host-phone-final-116", app)
    }

    @MainActor
    func testSavedRealHostSkillAutocomplete() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_UI"] == "1" else {
            throw XCTSkip("Requires authorization and the simulator's saved real Hermes host.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        XCTAssertTrue(app.buttons["root.new-chat"].waitForExistence(timeout: 20))
        app.buttons["root.new-chat"].tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap(); composer.typeText("/")
        let skill = app.buttons["reference-hub.command.agent-runtime-optimization"]
        let loaded = skill.waitForExistence(timeout: 10)
        capture("real-host-slash-all-116", app)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] {
            try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-slash-tree.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(loaded, "Typing slash must load actual host skills.")
        composer.typeText("agents-sdk")
        let filtered = app.buttons["reference-hub.command.agents-sdk"]
        XCTAssertTrue(filtered.waitForExistence(timeout: 5))
        XCTAssertFalse(skill.exists, "Typing filters the available commands.")
        capture("real-host-slash-filtered-116", app)
        filtered.tap()
        capture("real-host-slash-selected-116", app)
        XCTAssertTrue(app.staticTexts["/agents-sdk"].exists || (composer.value as? String)?.contains("/agents-sdk") == true)
    }

    /// Explicit opt-in: uses the simulator's saved real host and ordinary app
    /// composition. It never installs fixture hosts, credentials, or replies.
    @MainActor
    func testSavedRealHostSessionAndFeatureSettings() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_UI"] == "1" else {
            throw XCTSkip("Requires explicit authorization and a saved real Hermes host.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.launch()
        let entry = app.buttons["root.new-chat"]
        let available = entry.waitForExistence(timeout: 20)
        capture("real-host-root-116", app)
        XCTAssertTrue(available, "The real saved host must expose its normal workspace controls.")
        let sessions = app.buttons["tab.sessions"]
        sessions.tap()
        let knownSession = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Confirm bighelp direct-connect message")).firstMatch
        XCTAssertTrue(knownSession.waitForExistence(timeout: 20))
        knownSession.tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "Existing Hermes chat must load.")
        capture("real-host-existing-chat-116", app)
        openChatWorkspaceMenu(in: app)
        let chatsMenu = app.buttons["quick-workspace.menu.chats"]
        let agentsMenu = app.buttons["menu.agents"]
        let agentsVisible = agentsMenu.waitForExistence(timeout: 5)
        capture("real-host-sidebar-116", app)
        XCTAssertTrue(agentsVisible)
        XCTAssertGreaterThan(agentsMenu.frame.minY, chatsMenu.frame.minY)
        capture("real-host-sidebar-116", app)
        app.buttons["menu.settings"].tap()
        let chatSettings = app.buttons["settings.menu.chat"]
        XCTAssertTrue(chatSettings.waitForExistence(timeout: 5))
        chatSettings.tap()
        app.buttons["settings.chat.voice-settings"].tap()
        let voicePlugin = app.descendants(matching: .any).matching(identifier: "settings.plugin-status.liveVoice").firstMatch
        XCTAssertTrue(voicePlugin.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Codex Live Voice requires the bighelp plugin")).firstMatch.exists)
        capture("real-host-voice-plugin-settings-116", app)
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings.menu.permissions"].tap()
        let devicePlugin = app.descendants(matching: .any).matching(identifier: "settings.plugin-status.deviceAccess").firstMatch
        XCTAssertTrue(devicePlugin.waitForExistence(timeout: 10))
        capture("real-host-device-plugin-settings-116", app)
        app.buttons["permissions.open.calendar"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "You choose each permission separately")).firstMatch.waitForExistence(timeout: 5))
        capture("real-host-calendar-plugin-settings-116", app)
    }

    @MainActor
    func testSavedRealHostGroupsNewChatAndWorkspace() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_UI"] == "1" else {
            throw XCTSkip("Requires explicit authorization and a saved real Hermes host.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        openRootTab("tab.agents", in: app, timeout: 20)
        let createGroup = app.buttons["agents.groups.create"]
        let canCreate = createGroup.waitForExistence(timeout: 20)
        capture("real-host-agents-before-group-116", app)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] {
            try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-agents-tree.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(canCreate)
        createGroup.tap()
        XCTAssertTrue(app.textFields["bot-mode.create.title"].waitForExistence(timeout: 8))
        capture("real-host-new-group-116", app)
        app.buttons["Cancel"].tap()
        let started = Date()
        app.buttons["root.new-chat"].tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] {
            let value = ["uiAutomationTapToComposerSeconds": Date().timeIntervalSince(started)]
            try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: directory).appendingPathComponent("new-chat-ui-timing.json"))
        }
        capture("real-host-new-chat-116", app)
        openChatWorkspaceMenu(in: app)
        app.buttons["menu.folder"].tap()
        XCTAssertTrue(app.otherElements["hermes-workspaces.screen"].waitForExistence(timeout: 8))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@", "hermes-workspace.", "hermes-workspace.archive."))
        let loadedRows = rows.firstMatch.waitForExistence(timeout: 15)
        capture("real-host-project-picker-116", app)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] {
            try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-project-picker-tree.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(loadedRows, "The real host project registry must load.")
        capture("real-host-project-picker-116", app)
        app.buttons["Done"].tap()
    }

    /// Opt-in actual microphone/provider test. Spoken input is supplied outside
    /// XCTest through the simulator's selected physical audio input.
    @MainActor
    func testSavedRealHostLiveVoiceAudio() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_VOICE_UI"] == "1",
              let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] else {
            throw XCTSkip("Requires real-host microphone test authorization.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        XCTAssertTrue(app.buttons["root.new-chat"].waitForExistence(timeout: 20))
        app.buttons["root.new-chat"].tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 15))
        app.buttons["chat.voice"].tap()
        XCTAssertTrue(app.buttons["live-voice.start"].waitForExistence(timeout: 10))
        app.buttons["live-voice.start"].tap()
        defer {
            if app.buttons["live-voice.end"].exists { app.buttons["live-voice.end"].tap() }
            if app.buttons["live-voice.close"].exists { app.buttons["live-voice.close"].tap() }
        }
        let connected = app.staticTexts["Live voice connected"].waitForExistence(timeout: 40)
        capture("real-host-live-voice-start-116", app)
        try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-live-voice-tree.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(connected, "Native microphone and actual provider must become ready.")
        try Data(Date().description.utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-live-voice-ready.txt"))
        for iteration in 0..<72 {
            Thread.sleep(forTimeInterval: 5)
            try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-host-live-voice-tree.txt"), atomically: true, encoding: .utf8)
            if iteration % 3 == 0 { capture("real-host-live-voice-progress-116", app) }
            if !app.buttons["live-voice.end"].exists || FileManager.default.fileExists(atPath: directory + "/real-host-live-voice-finish.txt") { break }
        }
        capture("real-host-live-voice-final-116", app)
        XCTAssertTrue(app.buttons["live-voice.end"].exists, "Voice must remain open during subsequent utterances and delegated work.")
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: "You").count, 2, "The microphone must capture more than the first utterance.")
    }

    /// Opt-in interactive inspection of the actual iOS Shortcuts app. No bighelp
    /// test host or injected intent dependency is installed for this run.
    @MainActor
    func testSavedRealHostShortcutRegistration() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_SHORTCUTS_UI"] == "1",
              let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] else {
            throw XCTSkip("Requires actual Shortcuts validation authorization.")
        }
        let bighelp = XCUIApplication()
        bighelp.launchArguments = []; bighelp.launchEnvironment = [:]
        bighelp.launch()
        bighelp.terminate()
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()
        XCTAssertTrue(shortcuts.wait(for: .runningForeground, timeout: 15))
        for iteration in 0..<48 {
            try shortcuts.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-shortcuts-tree.txt"), atomically: true, encoding: .utf8)
            if iteration % 6 == 0 { capture("real-shortcuts-116", shortcuts) }
            if FileManager.default.fileExists(atPath: directory + "/real-shortcuts-finish.txt") { break }
            Thread.sleep(forTimeInterval: 5)
        }
    }

    @MainActor
    func testAccountOptionalWorkspaceAgainstIsolatedStockHermes() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"] else {
            throw XCTSkip("Requires the isolated stock Hermes production-composition fixture.")
        }
        let config = try readFixtureConfiguration(path)
        let nonce = "NATIVE_PROBE_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let prompt = "Run pwd once, then finish the direct streaming fixture. " + nonce
        let reply = "Direct streaming fixture complete. " + nonce
        continueAfterFailure = false
        let browserHost = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        if browserHost.state != .notRunning { browserHost.terminate() }
        let app = makeApp()
        app.launchArguments = ["-native-workspace-acceptance"]
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_AGENT_HOME"] == "1" {
            app.launchArguments += ["-loopdy.home.opens-chat", "YES"]
        }
        app.launch()
        let getStarted = app.buttons["onboarding.get-started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15))
        capture("native-production-welcome", app)
        getStarted.tap()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15), "A fresh native workspace must not require a bighelp account.")
        guard address.exists else { capture("native-production-entry", app); return }
        address.tap()
        address.typeText(try XCTUnwrap(ProcessInfo.processInfo.environment["NATIVE_PROBE_ADDRESS_OVERRIDE"] ?? config["address"]))
        // The first-run safe-area footer inherits its containing screen's AX ID.
        let connect = app.buttons.matching(identifier: "host-setup.screen").matching(
            NSPredicate(format: "label == %@ OR label == %@", "Continue", "Connect")
        ).firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        let authMode = ProcessInfo.processInfo.environment["NATIVE_PROBE_AUTH_MODE"] ?? config["auth_mode"] ?? "password"
        let method = app.buttons["direct-hermes.auth-picker"]
        XCTAssertTrue(method.waitForExistence(timeout: 20))
        if authMode == "password" {
            method.tap()
            app.buttons["Username & password"].tap()
            let username = app.textFields["direct-hermes.username"]
            XCTAssertTrue(username.waitForExistence(timeout: 10))
            guard username.exists else { capture("native-production-auth-discovery", app); return }
            username.tap()
            username.typeText(try XCTUnwrap(config["username"]))
            let password = app.secureTextFields["direct-hermes.password"]
            password.tap()
            password.typeText(try XCTUnwrap(config["password"]) + "\n")
        } else if authMode == "token" || authMode == "access-token" {
            method.tap()
            app.buttons[authMode == "access-token" ? "Access token" : "Session token"].tap()
            let token = app.secureTextFields["direct-hermes.token"]
            XCTAssertTrue(token.waitForExistence(timeout: 10))
            token.tap(); token.typeText(try XCTUnwrap(config["token"]) + "\n")
        } else {
            XCTAssertFalse(app.textFields["direct-hermes.username"].exists)
            XCTAssertFalse(app.secureTextFields["direct-hermes.token"].exists)
        }
        for _ in 0..<3 where !connect.isHittable { app.swipeUp() }
        connect.tap()
        if authMode == "browser" {
            let consent = app.alerts.buttons["Continue"]
            if consent.waitForExistence(timeout: 3) { consent.tap() }
            let browser = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
            let username = browser.webViews.textFields.firstMatch
            XCTAssertTrue(username.waitForExistence(timeout: 15), "The host's dashboard login form must open.")
            guard username.exists else { capture("native-browser-form", app); return }
            username.tap(); username.typeText(try XCTUnwrap(config["username"]))
            // Safari's form accessory covers the password field with the keyboard up.
            // Tab advances within the host's form without tapping through that accessory.
            username.typeText("\t")
            let password = browser.webViews.secureTextFields.firstMatch
            XCTAssertTrue(password.waitForExistence(timeout: 5))
            if let receipt = config["receipt_path"] {
                try? browser.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: receipt + ".browser-focus.png"))
            }
            password.typeText(try XCTUnwrap(config["password"]))
            let signIn = browser.webViews.buttons.matching(NSPredicate(format: "label ==[c] %@", "Sign in")).firstMatch
            for _ in 0..<2 where !signIn.isHittable { browser.webViews.firstMatch.swipeUp() }
            signIn.tap()
        }
        let proceed = app.buttons.matching(identifier: "host-setup.screen").matching(
            NSPredicate(format: "label == %@", "Let's start chatting")
        ).firstMatch
        XCTAssertTrue(proceed.waitForExistence(timeout: 40))
        guard proceed.exists else { capture("native-production-auth-result", app); return }
        proceed.tap()
        let newChat = app.buttons["root.new-chat"]
        let homeChat = app.buttons["agent.hero.avatar"]
        let reachDeadline = Date().addingTimeInterval(60)
        while Date() < reachDeadline, !newChat.exists, !homeChat.exists { usleep(500_000) }
        XCTAssertTrue(newChat.exists || homeChat.exists, "Real native feature clients must reach the shared workspace.")
        guard newChat.exists || homeChat.exists else { capture("native-production-workspace-load", app); return }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_IMAGE_FOLLOWUP"] == "1" {
            continueAfterFailure = true
            exerciseImageAfterFirstMessage(app)
            return
        }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_VOICE_FALLBACK"] == "1" {
            continueAfterFailure = true
            exerciseVoiceFallback(app)
            return
        }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_RETURN_REFRESH"] == "1" {
            continueAfterFailure = true
            exerciseReturnRefresh(app)
            return
        }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_BACKGROUND_TURN"] == "1" {
            continueAfterFailure = true
            exerciseBackgroundedTurn(app)
            return
        }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_AGENT_HOME"] == "1" {
            continueAfterFailure = true
            exerciseAgentHome(app, prompt: prompt, reply: reply, config: config)
            return
        }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_INSPECT_BOARD"] == "1" {
            continueAfterFailure = true
            inspectBoardReadOnly(app)
            return
        }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_VERIFY_AGENTS"] == "1" {
            openAgents(in: app)
            let create = app.buttons["agents.create"]
            XCTAssertTrue(create.waitForExistence(timeout: 15))
            create.tap()
            XCTAssertTrue(app.textFields["agent.editor.name"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["agent.editor.avatar-picker"].exists)
            app.buttons["agent.editor.design-avatar"].tap()
            // Every creator panel must render (Release builds run on a 1 MB main stack on iPhone).
            let hermia = app.buttons["avatar.creator.character.messenger"]
            XCTAssertTrue(hermia.waitForExistence(timeout: 10))
            hermia.tap()
            for tab in ["color", "eyes", "extras", "moves", "character"] {
                app.buttons["avatar.creator.tab.\(tab)"].tap()
                XCTAssertTrue(app.buttons["avatar.creator.use"].waitForExistence(timeout: 5), tab)
            }
            let inky = app.buttons["avatar.creator.character.octopus"]
            XCTAssertTrue(inky.waitForExistence(timeout: 10))
            for _ in 0..<3 where !inky.isHittable { app.swipeUp() }
            inky.tap()
            app.buttons["avatar.creator.use"].tap()
            let preview = app.descendants(matching: .any)["agent.editor.avatar-preview"].firstMatch
            let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Inky"), object: preview)
            XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 20), .completed)
            capture("native-agent-pet-avatar-selected", app)
            for (id, text) in [("name", "MiXeD Avatar BOT"), ("role", "Helper")] {
                let field = app.textFields["agent.editor.\(id)"]
                for _ in 0..<5 where !field.isHittable { app.swipeUp() }
                field.tap(); field.typeText(text)
                app.buttons["Dismiss keyboard"].tap()
            }
            for (id, text) in [("summary", "A controlled avatar fixture."), ("instructions", "Be concise.")] {
                let field = app.descendants(matching: .any)["agent.editor.\(id)"].firstMatch
                for _ in 0..<6 where !field.isHittable { app.swipeUp() }
                field.tap(); field.typeText(text)
                app.buttons["Dismiss keyboard"].tap()
            }
            app.buttons["agent.editor.save"].tap()
            guard app.buttons["agent.editor.save"].waitForNonExistence(timeout: 40) else {
                capture("native-agent-create-failed", app)
                XCTFail("The real profile/avatar creation must complete: " + app.debugDescription)
                return
            }
            let catalog = try await get(config: config, components: ["api", "profiles"], query: [])
            let rows = try XCTUnwrap(catalog["profiles"] as? [[String: Any]])
            XCTAssertEqual(rows.filter { $0["name"] as? String == "mixed-avatar-bot" }.count, 1)
            XCTAssertFalse(rows.contains { $0["name"] as? String == "MiXeD Avatar BOT" })
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 60))
            openAgents(in: app)
            let agent = app.buttons["agent.mixed-avatar-bot"]
            XCTAssertTrue(agent.waitForExistence(timeout: 25))
            for _ in 0..<5 where !agent.isHittable { app.swipeUp() }
            XCTAssertTrue(agent.label.contains("MiXeD Avatar BOT"))
            capture("native-agent-avatar-cold-reload", app)
            return
        }
        app.buttons["home.drawer.open"].tap()
        for id in ["menu.agents", "menu.chats", "menu.scheduled-tasks"] {
            XCTAssertTrue(app.buttons[id].exists, id)
        }
        app.buttons["menu.done"].tap()
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_VERIFY_SESSION_RECOVERY"] == "1" {
            try await verifyNativeSessionRecovery(config: config, in: app)
            return
        }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_VERIFY_MANAGEMENT"] == "1" {
            for (key, title) in [("projects", "Projects"), ("files", "Files"), ("artifacts", "Artifacts"),
                                 ("toolsets", "Toolsets"), ("memory", "Memory"),
                                 ("plugins", "Plugins"), ("mcp", "MCP Servers"), ("logs", "Logs")] {
                openRootDestination("workspace", sidebarIdentifier: "menu.hermes-tools", in: app)
                let destination = app.buttons["workspace.open.\(key)"]
                for _ in 0..<8 where !destination.isHittable { app.swipeUp() }
                guard destination.waitForExistence(timeout: 10), destination.isHittable else {
                    capture("native-management-missing-\(key)", app)
                    XCTFail("The \(title) entry was not reachable in the Workspace list.")
                    return
                }
                destination.tap()
                guard app.navigationBars[title].waitForExistence(timeout: 20) else {
                    capture("native-management-failed-\(key)", app)
                    XCTFail("The \(title) destination did not open on first tap.")
                    return
                }
                if key == "files" || key == "artifacts" {
                    let root = try XCTUnwrap(config["workspace_path"])
                    let rootText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", root)).firstMatch
                    XCTAssertTrue(rootText.waitForExistence(timeout: 20), "The confirmed host workspace must be visible.")
                    XCTAssertFalse(app.staticTexts["Workspace unavailable"].exists)
                }
                capture("native-management-\(key)", app)
                if ProcessInfo.processInfo.environment["NATIVE_PROBE_VERIFY_MEDIA"] == "1" {
                    if key == "files" {
                        let video = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "native-preview.mp4")).firstMatch
                        XCTAssertTrue(video.waitForExistence(timeout: 15))
                        video.tap()
                        let play = app.buttons["workspace.file-transfers.play-media"]
                        for _ in 0..<6 where !play.isHittable { app.swipeUp() }
                        XCTAssertTrue(play.isHittable)
                        play.tap()
                        XCTAssertTrue(app.navigationBars["Video Preview"].waitForExistence(timeout: 15))
                        let player = app.descendants(matching: .any)["workspace.managed-media.player"].firstMatch
                        XCTAssertTrue(player.waitForExistence(timeout: 20), "The actual native video decoder must become ready.")
                        XCTAssertFalse(app.staticTexts["Playback unavailable"].exists)
                        capture("native-managed-video-playing", app)
                        app.buttons["Done"].tap()
                        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 10))
                    } else if key == "logs" {
                        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "NATIVE_UI_LOG_PROOF")).firstMatch
                        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
                        XCTAssertTrue(row.waitForExistence(timeout: 15), "The bounded host log line must render, not only a severity count.")
                        capture("native-logs-rendered-line", app)
                    }
                }
                let back = app.navigationBars.buttons.element(boundBy: 0)
                XCTAssertTrue(back.isHittable)
                back.tap()
                XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 10))
            }
        }
        openRootDestination("scheduledTasks", sidebarIdentifier: "menu.scheduled-tasks", in: app)
        let createTask = app.buttons["scheduled-tasks.create"]
        XCTAssertTrue(createTask.waitForExistence(timeout: 15), "Native cron management must be reachable from the Tasks menu.")
        XCTAssertFalse(app.alerts["Unable to open"].exists)
        guard createTask.exists else { capture("native-production-cron-route", app); return }
        createTask.tap()
        let taskName = app.textFields["scheduled-task.editor.name"]
        XCTAssertTrue(taskName.waitForExistence(timeout: 10), "Native tasks must expose their existing editor.")
        app.buttons["Cancel"].tap()
        openAgents(in: app)
        XCTAssertTrue(app.buttons["agent.default"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["agents.groups.empty"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["agent.default"].waitForExistence(timeout: 3), "Cached agents should remain visible on foreground.")
        XCTAssertFalse(app.staticTexts["agents.groups.error"].exists)
        app.buttons["agent.default"].tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        guard composer.exists else { capture("native-production-create", app); return }
        XCTAssertTrue(app.otherElements["chat.header-surface"].waitForExistence(timeout: 5))
        app.buttons["chat.attachment"].tap()
        let fileAction = app.buttons["chat.action.file"]
        XCTAssertTrue(fileAction.waitForExistence(timeout: 5))
        XCTAssertTrue(fileAction.isEnabled)
        XCTAssertTrue(app.buttons["chat.action.photo"].isEnabled)
        #if targetEnvironment(simulator)
        XCTAssertFalse(app.buttons["chat.action.camera"].isEnabled)
        #else
        XCTAssertTrue(app.buttons["chat.action.camera"].isEnabled)
        #endif
        XCTAssertFalse(app.staticTexts["chat.attachments.images-unavailable"].exists)
        capture("native-production-attachments", app)
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        )
        XCTAssertTrue(fileAction.waitForNonExistence(timeout: 5))
        guard composer.waitForExistence(timeout: 5) else {
            capture("native-route-lost-after-menu", app)
            XCTFail("Chat disappeared after attachment menu dismissal: " + app.debugDescription)
            return
        }
        composer.tap()
        composer.typeText(prompt)
        app.buttons["chat.send"].tap()
        let answer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", reply)
        ).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 60))
        let originalSession = try await storedSession(config: config, prompt: prompt, reply: reply)
        capture("native-production-stream", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 60), "Device-only credentials must restore the same native workspace.")
        openRootDestination("chats", sidebarIdentifier: "menu.chats", in: app)
        let saved = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "session.row.native-session-v1:", nonce
        )).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 25))
        guard saved.exists else { capture("native-production-cold-catalog", app); return }
        let visibleSessionID = saved.identifier
        saved.tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 30))
        let restoredSession = try await storedSession(config: config, prompt: prompt, reply: reply)
        XCTAssertEqual(restoredSession, originalSession)
        composer.tap()
        // This synthetic provider reports zero token usage. Verify the actual
        // reopened send transaction rather than requiring an unavailable meter.
        XCTAssertTrue(chatMenuItem("chat.session-controls", in: app).waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["chat.session-controls"].waitForNonExistence(timeout: 5))
        composer.tap()
        let followup = "Run the second direct fixture. " + nonce
        composer.typeText(followup)
        let readyToSend = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["chat.send"])
        XCTAssertEqual(XCTWaiter.wait(for: [readyToSend], timeout: 10), .completed)
        app.buttons["chat.send"].tap()
        let followupReply = "Second direct fixture complete. " + nonce
        let nextAnswer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", followupReply)).firstMatch
        XCTAssertTrue(nextAnswer.waitForExistence(timeout: 60), "A restored chat must send through its rebound native client.")
        let afterSend = try await storedSession(config: config, prompt: followup, reply: followupReply)
        XCTAssertEqual(afterSend, originalSession)
        let receipt = ["nonce": nonce, "native_session": originalSession, "restored_session": restoredSession,
                       "ui_session": visibleSessionID, "reply": reply]
        let receiptPath = try XCTUnwrap(config["receipt_path"])
        try JSONEncoder().encode(receipt).write(to: URL(fileURLWithPath: receiptPath), options: .atomic)
        capture("native-production-cold-history", app)
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_VERIFY_REACTIONS"] == "1" {
            // Live frame IDs are intentionally not durable reaction authority.
            // Re-enter through the existing native refresh before choosing rows.
            app.buttons["chat.options"].tap()
            app.buttons["chat.options.advanced"].tap()
            let refresh = app.buttons["chat.force-refresh"]
            XCTAssertTrue(refresh.waitForExistence(timeout: 5))
            refresh.tap()
            XCTAssertFalse(app.buttons["Message reactions"].exists,
                           "Reactions must be reached from the message long-press menu, not a standalone affordance.")
            let reactionTargets = [
                (text: followupReply, role: "assistant", emoji: "👍", usesAnyEmojiField: false),
                (text: followup, role: "user", emoji: "🚀", usesAnyEmojiField: true),
            ]
            var reactionRows: [(rowID: Int, role: String, emoji: String)] = []
            for target in reactionTargets {
                let rowID = try addReaction(
                    target.emoji,
                    toMessageContaining: target.text,
                    in: app,
                    usingAnyEmojiField: target.usesAnyEmojiField
                )
                let selectedReaction = app.buttons["Your reaction, \(target.emoji)"]
                XCTAssertTrue(selectedReaction.waitForExistence(timeout: 15))
                try await verifyReaction(
                    config: config,
                    sessionID: originalSession,
                    rowID: rowID,
                    role: target.role,
                    emoji: target.emoji,
                    present: true
                )
                reactionRows.append((rowID: rowID, role: target.role, emoji: target.emoji))
            }
            capture("native-reaction-confirmed", app)
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 60))
            openRootDestination("chats", sidebarIdentifier: "menu.chats", in: app)
            XCTAssertTrue(saved.waitForExistence(timeout: 25))
            saved.tap()
            for target in reactionRows {
                XCTAssertTrue(
                    app.buttons["Your reaction, \(target.emoji)"].waitForExistence(timeout: 30),
                    "A cold reopen must retain the exact \(target.role) durable-row reaction."
                )
            }
            capture("native-reaction-cold-reopen", app)
            for target in reactionRows {
                let selectedReaction = app.buttons["Your reaction, \(target.emoji)"]
                selectedReaction.tap()
                XCTAssertTrue(selectedReaction.waitForNonExistence(timeout: 15))
                try await verifyReaction(
                    config: config,
                    sessionID: originalSession,
                    rowID: target.rowID,
                    role: target.role,
                    emoji: target.emoji,
                    present: false
                )
            }
        }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_VERIFY_CONTROLS"] == "1" {
            app.buttons["chat.attachment"].tap()
            let controls = app.buttons["chat.composer.menu.native-session-controls"]
            let drawer = app.collectionViews["chat.action-drawer.v3"]
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            for _ in 0..<8 where !controls.exists || !controls.isHittable { drawer.swipeUp() }
            XCTAssertTrue(controls.waitForExistence(timeout: 5))
            XCTAssertTrue(controls.isHittable)
            controls.tap()
            XCTAssertTrue(app.navigationBars["Session controls"].waitForExistence(timeout: 5),
                          "Session controls must open on the first tap after menu dismissal.")
            XCTAssertTrue(app.staticTexts["Status"].waitForExistence(timeout: 20),
                          "The real stock session status must decode and render.")
            XCTAssertFalse(app.descendants(matching: .any)["chat.native-session-controls.error"].exists)
            capture("native-production-session-controls", app)
        }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_VERIFY_SESSION_MAINTENANCE"] == "1" {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
            )
            XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 10))
            openChatWorkspaceMenu(in: app)
            openSidebarDestination("menu.chats", in: app)
            XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 10))
            openRootDestination("workspace", sidebarIdentifier: "menu.hermes-tools", in: app)
            let maintenance = app.buttons["workspace.open.sessionMaintenance"]
            for _ in 0..<10 where !maintenance.isHittable { app.swipeUp() }
            XCTAssertTrue(maintenance.isHittable)
            maintenance.tap()
            XCTAssertTrue(app.navigationBars["Session Maintenance"].waitForExistence(timeout: 15))
            let mostRecent = app.buttons["session-maintenance.most-recent"]
            for _ in 0..<6 where !mostRecent.isHittable { app.swipeUp() }
            mostRecent.tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", originalSession)).firstMatch.waitForExistence(timeout: 15))
            let choose = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Choose sessions (")).firstMatch
            for _ in 0..<10 where !choose.isHittable { app.swipeUp() }
            guard choose.isHittable else {
                capture("native-maintenance-list-failed", app)
                XCTFail("Session Maintenance must load its session list.")
                return
            }
            choose.tap()
            let actions = app.buttons["session-maintenance.actions.\(originalSession)"]
            for _ in 0..<5 where !actions.isHittable { app.swipeUp() }
            XCTAssertTrue(actions.isHittable)
            let beforeVisibility = try await get(config: config, components: ["api", "sessions", originalSession],
                query: [.init(name: "profile", value: "default")])
            let originalArchiveState = try XCTUnwrap(beforeVisibility["archived"] as? NSNumber).boolValue
            for hidden in [true, false] {
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: actions)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
                for _ in 0..<5 where !actions.isHittable { app.swipeUp() }
                actions.tap()
                app.buttons["session-maintenance.hidden.\(originalSession)"].tap()
                let afterVisibility = try await waitForVisibility(config: config, sessionID: originalSession, hidden: hidden)
                let archiveState = try XCTUnwrap(afterVisibility["archived"] as? NSNumber).boolValue
                XCTAssertEqual(archiveState, originalArchiveState)
            }
            let readyToClose = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: actions)
            XCTAssertEqual(XCTWaiter.wait(for: [readyToClose], timeout: 15), .completed)
            actions.tap()
            let close = app.buttons["session-maintenance.close.\(originalSession)"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            app.buttons["Close Runtime"].tap()
            if !app.buttons["home.drawer.open"].waitForExistence(timeout: 5) {
                let success = app.descendants(matching: .any)["session-maintenance.success"].firstMatch
                let error = app.descendants(matching: .any)["session-maintenance.error"].firstMatch
                for _ in 0..<10 where !success.isHittable && !error.isHittable { app.swipeDown() }
                guard success.waitForExistence(timeout: 15), success.label.contains("stored message"), !error.exists else {
                    capture("native-maintenance-close-failed", app)
                    XCTFail("Close must reconcile the exact runtime and preserve history: " + app.debugDescription)
                    return
                }
                app.navigationBars.buttons["Back"].tap()
            }
            XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 15))
            openRootDestination("chats", sidebarIdentifier: "menu.chats", in: app)
            XCTAssertFalse(app.staticTexts["Route unavailable"].exists)
            let preservedSession = try await storedSession(config: config, prompt: followup, reply: followupReply)
            XCTAssertEqual(preservedSession, originalSession)
            let preservedRow = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "session.row.native-session-v1:", nonce
            )).firstMatch
            XCTAssertTrue(preservedRow.waitForExistence(timeout: 15))
            XCTAssertEqual(preservedRow.identifier, visibleSessionID)
            capture("native-maintenance-closed-history-preserved", app)
            preservedRow.tap()
            XCTAssertTrue(nextAnswer.waitForExistence(timeout: 30), "Explicit reopening after close must recover the preserved conversation.")
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            capture("native-maintenance-explicit-reopen", app)
        }
        if ProcessInfo.processInfo.environment["NATIVE_PROBE_VERIFY_PLUGIN_SETUP"] == "1" {
            openSettings(in: app)
            let voiceSettings = app.buttons["settings.chat.voice-settings"]
            for _ in 0..<5 where !voiceSettings.isHittable { app.collectionViews["settings.screen"].swipeUp() }
            guard voiceSettings.isHittable else { XCTFail("Voice settings must be reachable in the flat Settings form."); return }
            voiceSettings.tap()
            let voice = app.staticTexts["settings.plugin-status.liveVoice"].firstMatch
            for _ in 0..<6 where !voice.exists || !voice.isHittable { app.swipeUp() }
            guard voice.waitForExistence(timeout: 15) else { XCTFail("Voice plugin status must be visible."); return }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", "bighelp plugin connected."), object: voice
            )], timeout: 20), .completed)
            capture("native-reviewed-plugin-voice-ready", app)
            app.navigationBars.buttons.firstMatch.tap()
            let permissions = app.buttons["settings.menu.permissions"]
            for _ in 0..<5 where !permissions.isHittable { app.collectionViews["settings.screen"].swipeUp() }
            guard permissions.isHittable else { XCTFail("Permissions must be reachable from Settings."); return }
            permissions.tap()
            let device = app.staticTexts["settings.plugin-status.deviceAccess"].firstMatch
            for _ in 0..<6 where !device.exists || !device.isHittable { app.swipeUp() }
            guard device.waitForExistence(timeout: 15) else { XCTFail("Device plugin status must be visible."); return }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", "bighelp plugin connected."), object: device
            )], timeout: 20), .completed)
            capture("native-reviewed-plugin-device-ready", app)
        }
    }

    @MainActor
    private func addReaction(
        _ emoji: String,
        toMessageContaining text: String,
        in app: XCUIApplication,
        usingAnyEmojiField: Bool
    ) throws -> Int {
        let message = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@ AND identifier CONTAINS %@ AND label CONTAINS %@",
            "chat.message.",
            "chat.message.inline-selection",
            ":row:",
            text
        )).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 15))
        let marker = try XCTUnwrap(message.identifier.range(of: ":row:", options: .backwards))
        let rowID = try XCTUnwrap(Int(message.identifier[marker.upperBound...]))
        let surface = message.descendants(matching: .textView)
            .matching(identifier: "chat.message.inline-selection").firstMatch
        let longPressTarget = surface.exists ? surface : message
        longPressTarget.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 12, dy: 10)).press(forDuration: 1)

        let react = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "React")).firstMatch
        XCTAssertTrue(react.waitForExistence(timeout: 5))
        react.tap()
        let picker = app.descendants(matching: .any)["chat.reaction-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        if usingAnyEmojiField {
            let field = app.textFields["chat.reaction-picker.any-emoji"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(emoji)
            let add = app.buttons["Add reaction"]
            let enabled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"),
                object: add
            )
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
            add.tap()
        } else {
            let choice = app.buttons["React \(emoji)"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
        }
        return rowID
    }

    @MainActor
    private func verifyReaction(
        config: [String: String],
        sessionID: String,
        rowID: Int,
        role: String,
        emoji: String,
        present: Bool
    ) async throws {
        let response = try await get(config: config, components: ["api", "sessions", sessionID, "messages"],
            query: [.init(name: "profile", value: "default"), .init(name: "limit", value: "100"), .init(name: "order", value: "oldest")])
        let rows = try XCTUnwrap(response["messages"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { ($0["id"] as? NSNumber)?.intValue == rowID })
        XCTAssertEqual(row["role"] as? String, role)
        if row["display_metadata"] is NSNull {
            XCTAssertFalse(present, "Null metadata must not satisfy a reaction-add readback.")
            return
        }
        let metadata = try XCTUnwrap(row["display_metadata"] as? [String: Any])
        let reactions = metadata["reactions"] as? [[String: Any]] ?? []
        XCTAssertEqual(
            reactions.contains { $0["author"] as? String == "user" && $0["emoji"] as? String == emoji },
            present
        )
    }

    @MainActor
    private func waitForVisibility(config: [String: String], sessionID: String, hidden: Bool) async throws -> [String: Any] {
        for _ in 0..<30 {
            let value = try await get(config: config, components: ["api", "sessions", sessionID],
                query: [.init(name: "profile", value: "default")])
            if (value["hidden"] as? NSNumber)?.boolValue == hidden { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The exact stored session must reflect the requested hidden state.")
        throw NSError(domain: "NativeFixture.VisibilityReadback", code: 1)
    }

    @MainActor
    private func verifyNativeSessionRecovery(config: [String: String], in app: XCUIApplication) async throws {
        let secondary = try XCTUnwrap(config["secondary_profile"])
        let receiptPath = try XCTUnwrap(config["receipt_path"])
        var receipts: [[String: String]] = []
        for profile in ["default", secondary] {
            openAgents(in: app)
            let agent = app.buttons["agent.\(profile)"]
            XCTAssertTrue(agent.waitForExistence(timeout: 20))
            agent.tap()
            let composer = app.textViews["chat.composer.text"]
            let send = app.buttons["chat.send"]
            XCTAssertTrue(composer.waitForExistence(timeout: 30), "One agent tap must open its new native chat.")
            XCTAssertFalse(app.alerts["Unable to open"].exists)
            var turns: [(prompt: String, reply: String)] = []
            var storedID: String?
            for phase in ["new", "foreground", "warm-reopen", "cold-reopen"] {
                let nonce = "NATIVE_PROBE_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                let prompt = (phase == "new"
                    ? "Run pwd once, then finish the direct streaming fixture. "
                    : "Run the second direct fixture. ") + nonce
                let reply = (phase == "new"
                    ? "Direct streaming fixture complete. "
                    : "Second direct fixture complete. ") + nonce

                if phase == "cold-reopen" {
                    app.terminate()
                    app.launch()
                    XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 60))
                    openRootDestination("chats", sidebarIdentifier: "menu.chats", in: app)
                    let saved = nativeSessionRow(in: app, profileID: profile, storedID: try XCTUnwrap(storedID))
                    XCTAssertTrue(saved.waitForExistence(timeout: 25))
                    saved.tap()
                    XCTAssertTrue(composer.waitForExistence(timeout: 30))
                    XCTAssertFalse(app.alerts["Unable to open"].exists)
                }

                XCTAssertEqual(composer.value as? String, "",
                    "\(profile) \(phase) must not restore an already-sent draft.")
                composer.tap()
                composer.typeText(prompt)
                XCTAssertEqual(composer.value as? String, prompt,
                    "The exact new prompt must be the whole composer, not appended to stale text.")
                if phase == "foreground" {
                    XCUIDevice.shared.press(.home)
                    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
                    app.activate()
                    XCTAssertTrue(composer.waitForExistence(timeout: 15))
                    XCTAssertEqual(composer.value as? String, prompt, "Suspension must preserve the exact draft.")
                } else if phase == "warm-reopen" {
                    openRootDestination("chats", sidebarIdentifier: "menu.chats", in: app)
                    let saved = nativeSessionRow(in: app, profileID: profile, storedID: try XCTUnwrap(storedID))
                    XCTAssertTrue(saved.waitForExistence(timeout: 25))
                    saved.tap()
                    XCTAssertTrue(composer.waitForExistence(timeout: 20))
                    XCTAssertEqual(composer.value as? String, prompt, "Warm navigation must retain its own draft.")
                    XCTAssertFalse(app.alerts["Unable to open"].exists)
                }

                let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed,
                               "\(profile) \(phase) must recover Send without Force Refresh or a second tap.")
                send.tap()
                let answer = app.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS %@", reply)
                ).firstMatch
                XCTAssertTrue(answer.waitForExistence(timeout: 60), "\(profile) \(phase) must stream its reply.")
                let confirmed = try await storedSession(config: config, prompt: prompt, reply: reply, profileID: profile)
                if let storedID { XCTAssertEqual(confirmed, storedID, "Reentry must not allocate another conversation.") }
                else { storedID = confirmed }
                turns.append((prompt, reply))
                receipts.append(["profile": profile, "phase": phase, "session": confirmed, "nonce": nonce])
                try JSONEncoder().encode(receipts).write(to: URL(fileURLWithPath: receiptPath), options: .atomic)
                capture("native-session-\(profile)-\(phase)", app)
            }
            // Recheck all original user rows after every reentry boundary, not
            // just the most recent row. Unknown delivery must never be replayed.
            for turn in turns {
                let confirmed = try await storedSession(config: config, prompt: turn.prompt, reply: turn.reply, profileID: profile)
                XCTAssertEqual(confirmed, storedID)
            }
        }
        XCTAssertEqual(Set(receipts.map { $0["session"] }).count, 2,
                       "Both profiles need distinct durable conversations throughout the same app run.")
    }

    @MainActor
    private func nativeSessionRow(in app: XCUIApplication, profileID: String, storedID: String) -> XCUIElement {
        // Stable native identity, independent of changing previews or AX
        // identifier reads whose cached element belonged to a prior process.
        let suffix = [profileID, storedID].map {
            Data($0.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }.joined(separator: ":")
        return app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "session.row.native-session-v1:", ":" + suffix
        )).firstMatch
    }

    @MainActor
    private func storedSession(config: [String: String], prompt: String, reply: String,
                               profileID: String = "default") async throws -> String {
        let list = try await get(config: config, components: ["api", "sessions"],
                                 query: [URLQueryItem(name: "profile", value: profileID),
                                         URLQueryItem(name: "limit", value: "100")])
        let rows = try XCTUnwrap(list["sessions"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(rows.count, 100)
        var matches: [String] = []
        for row in rows {
            let id = try XCTUnwrap(row["id"] as? String)
            XCTAssertFalse(id.contains("/"))
            let page = try await get(config: config, components: ["api", "sessions", id, "messages"],
                                     query: [URLQueryItem(name: "profile", value: profileID),
                                             URLQueryItem(name: "limit", value: "100"),
                                             URLQueryItem(name: "order", value: "oldest")])
            let messages = try XCTUnwrap(page["messages"] as? [[String: Any]])
            let users = messages.filter { $0["role"] as? String == "user" && $0["content"] as? String == prompt }
            guard !users.isEmpty else { continue }
            XCTAssertEqual(users.count, 1, "A reconnect must not resend the original native user turn.")
            XCTAssertTrue(messages.contains { $0["role"] as? String == "assistant" && $0["content"] as? String == reply })
            matches.append(try XCTUnwrap(page["session_id"] as? String))
        }
        XCTAssertEqual(matches.count, 1, "The nonce must identify exactly one native stored conversation.")
        return try XCTUnwrap(matches.first)
    }

    @MainActor
    private func get(config: [String: String], components: [String],
                     query: [URLQueryItem]) async throws -> [String: Any] {
        var url = try XCTUnwrap(URL(string: XCTUnwrap(config["address"])))
        for component in components { url.append(path: component) }
        var parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        parts.queryItems = query
        var request = URLRequest(url: try XCTUnwrap(parts.url))
        request.setValue("Bearer " + (try XCTUnwrap(config["token"])), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertLessThanOrEqual(data.count, 2 * 1_024 * 1_024)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    private static var fixtureConfiguration: (path: String, values: [String: String])?

    @MainActor
    private func readFixtureConfiguration(_ path: String) throws -> [String: String] {
        if let cached = Self.fixtureConfiguration, cached.path == path { return cached.values }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? input.close() }
        let values = try JSONDecoder().decode([String: String].self, from: input.readToEnd() ?? Data())
        // One private FIFO transfers credentials once. Later captures reuse memory,
        // never a plaintext credential file or a second blocking FIFO read.
        Self.fixtureConfiguration = (path, values)
        return values
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        if let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"],
           let config = try? readFixtureConfiguration(path),
           let receipt = config["receipt_path"], !name.contains("auth") {
            try? app.debugDescription.write(toFile: receipt + "." + name + ".txt", atomically: true, encoding: .utf8)
        }
    }
}


/// Production-path checks that deliberately require an explicit project ID.
/// The test creates a fresh chat and associates only that disposable session
/// with an already-registered project. It never creates, renames, archives, or
/// moves an existing session.
final class NativeProjectActivityProductionUITests: BighelpUITestCase {
    @MainActor
    func testSavedRealHostNewChatSelectsExistingProjectAndShowsCheckmark() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_REAL_PROJECT_SELECTION_UI"] == "1",
              let projectID = ProcessInfo.processInfo.environment["BIGHELP_REAL_PROJECT_ID"],
              !projectID.isEmpty else {
            throw XCTSkip(
                "Requires explicit real-host project-selection authorization and BIGHELP_REAL_PROJECT_ID."
            )
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.launch()

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 20), "The saved native host must expose New Chat.")
        newChat.tap()

        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(
            composer.waitForExistence(timeout: 20),
            "A newly-created disposable chat must reach the composer before project selection."
        )
        guard composer.exists else { return }

        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 10))
        openChatWorkspaceMenu(in: app)

        let workspaceChooser = app.buttons["menu.folder"]
        XCTAssertTrue(
            workspaceChooser.waitForExistence(timeout: 10),
            "The native chat must expose the workspace chooser."
        )
        guard workspaceChooser.exists else { return }
        workspaceChooser.tap()

        let picker = app.descendants(matching: .any)["hermes-workspaces.screen"].firstMatch
        XCTAssertTrue(
            picker.waitForExistence(timeout: 15),
            "The workspace picker must load from the selected native host."
        )
        guard picker.exists else { return }

        let project = app.buttons["hermes-workspace.\(projectID)"]
        XCTAssertTrue(
            project.waitForExistence(timeout: 20),
            "The explicitly selected existing project must be present in the host catalog."
        )
        guard project.exists else { return }
        for _ in 0..<8 where !project.isHittable { app.swipeUp() }
        XCTAssertTrue(project.isHittable, "The existing project row must be selectable.")
        project.tap()
        // Successful selection closes the sheet. Reopen it to verify the
        // host-backed association rather than querying a dismissed row.
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: picker)
        let selectionResult = XCTWaiter.wait(for: [dismissed], timeout: 20)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] {
            try? app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-project-after-selection.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(selectionResult, .completed)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        openChatWorkspaceMenu(in: app)
        XCTAssertTrue(workspaceChooser.waitForExistence(timeout: 5))
        workspaceChooser.tap()
        XCTAssertTrue(project.waitForExistence(timeout: 15))

        let selected = NSPredicate(format: "value == %@", "Selected")
        expectation(for: selected, evaluatedWith: project)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(
            project.value as? String,
            "Selected",
            "Hermes must confirm the existing project association for this new session."
        )

        // The row's selected accessibility state is backed by the visible
        // checkmark in HermesWorkspaceRows. Keep a tree artifact for review
        // without recording prompts, credentials, or host response content.
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] {
            try app.debugDescription.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent(
                    "real-project-selection-checkmark-tree.txt"
                ),
                atomically: true,
                encoding: .utf8
            )
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "real-project-selection-checkmark"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Reply with exactly PROJECT2102 OK. Do not call tools or delegate.")
        let send = app.buttons["chat.send"]
        let canSend = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [canSend], timeout: 20), .completed)
        send.tap()
        XCTAssertTrue(app.buttons["chat.voice"].waitForExistence(timeout: 90))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 20))
        app.buttons["tab.sessions"].tap()
        let filters = app.descendants(matching: .any).matching(identifier: "sessions.filters").firstMatch
        XCTAssertTrue(filters.waitForExistence(timeout: 10)); filters.tap()
        let projectFilter = app.buttons["sessions.filter.project"]
        XCTAssertTrue(projectFilter.waitForExistence(timeout: 10)); projectFilter.tap()
        let home = app.buttons["sessions.filter.project.\(projectID)"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10), "The Chats catalog must restore Home as an assigned project.")
        home.tap()
        let saved = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS[c] %@", "PROJECT2102"
        )).firstMatch
        let visible = saved.waitForExistence(timeout: 15)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] {
            try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-project-filter-state.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(visible, "The newly created chat must remain inside the Home project filter.")
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_REAL_HOST_ARTIFACTS"] {
            try app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-project-chats-after-relaunch.txt"), atomically: true, encoding: .utf8)
        }
    }
}
