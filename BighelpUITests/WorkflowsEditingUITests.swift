import XCTest

/// Workflows v2 on demo data: create from scratch, save as template, pin and
/// archive from the long-press menu, the canvas (iPad: move a node after its
/// menu shows, rewire a port), the iPhone's vertical flow, a computer that
/// can't run workflows, and the All runs header. BIGHELP_WORKFLOWS_EVIDENCE
/// (TEST_RUNNER_…) saves screens as PNGs; run in light and dark.
final class WorkflowsEditingUITests: BighelpUITestCase {
    // MARK: Home

    @MainActor
    func testCreateFromScratchOpensAnEmptyFlowToBuild() throws {
        let app = launch()
        openWorkflows(app)
        let scratch = app.buttons["workflows.template.scratch"]
        scrollTo(scratch, in: app)
        scratch.tap()
        // Alert fields and buttons drop their identifiers; find them in the alert.
        let prompt = app.alerts["New workflow"]
        let name = prompt.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Create from scratch asks for a name")
        name.typeText("Weekly notes")
        prompt.buttons["Create"].tap()

        let inputs = element(app.userInterfaceIdiom == .pad ? "workflows.canvas.node.inputs" : "workflows.flow.inputs", app)
        XCTAssertTrue(inputs.waitForExistence(timeout: 8), "The new workflow opens in the editor")
        XCTAssertTrue(element("workflows.issues", app).exists || element("workflows.flow.issues", app).exists,
                      "An empty flow says to add a stage")
        save("20-scratch-empty", app)

        // Add an agent stage, then a sign-off after it.
        let add = app.buttons[app.userInterfaceIdiom == .pad ? "workflows.canvas.add" : "workflows.flow.add"]
        add.tap()
        app.buttons["workflows.add.agent"].firstMatch.tap()
        XCTAssertTrue(element("workflows.stage-editor", app).waitForExistence(timeout: 5))
        app.buttons["workflows.stage.done"].tap()
        let stage = element(app.userInterfaceIdiom == .pad ? "workflows.canvas.node.stage1" : "workflows.flow.stage.stage1", app)
        XCTAssertTrue(stage.waitForExistence(timeout: 8), "The new stage is in the flow")
        add.tap()
        app.buttons["workflows.add.signoff"].firstMatch.tap()
        XCTAssertTrue(element("workflows.stage-editor", app).waitForExistence(timeout: 5))
        app.buttons["workflows.stage.done"].tap()
        let signoff = element(app.userInterfaceIdiom == .pad ? "workflows.canvas.node.signoff2" : "workflows.flow.stage.signoff2", app)
        XCTAssertTrue(signoff.waitForExistence(timeout: 8))
        save("21-scratch-built", app)
    }

    @MainActor
    func testSaveAsTemplateFromTheLongPressMenu() throws {
        let app = launch()
        openWorkflows(app)
        let row = app.buttons["workflows.workflow.wf-research"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.2)
        let menuItem = app.buttons["Save as template"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "The long-press menu offers Save as template")
        save("22-row-menu", app)
        menuItem.tap()
        let prompt = app.alerts["Save as template"]
        let field = prompt.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Saving asks for a name")
        field.clearAndType("Review loop")
        prompt.buttons["Save"].tap()
        let yours = app.staticTexts["Yours"]
        scrollTo(yours, in: app)
        XCTAssertTrue(yours.exists, "Templates show your own")
        XCTAssertTrue(app.staticTexts["Review loop"].exists)
        save("23-your-templates", app)

        // Yours can be deleted with a long press; built-in ones can't.
        let template = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'workflows.template.tpl-'")).firstMatch
        template.press(forDuration: 1.2)
        let delete = app.buttons["Delete template"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(app.staticTexts["Review loop"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testPinAndArchiveFromTheLongPressMenu() throws {
        let app = launch()
        openWorkflows(app)
        let captions = app.buttons["workflows.workflow.wf-captions"]
        XCTAssertTrue(captions.waitForExistence(timeout: 5))
        let research = app.buttons["workflows.workflow.wf-research"]
        XCTAssertLessThan(research.frame.minY, captions.frame.minY)

        captions.press(forDuration: 1.2)
        app.buttons["Pin"].firstMatch.tap()
        let pinned = app.descendants(matching: .any)["workflows.workflow.pinned"].firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 5), "A pinned workflow says so")
        XCTAssertTrue(waitUntil { captions.frame.minY < research.frame.minY }, "Pinned first")
        save("24-pinned", app)

        captions.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 5), "A pinned workflow offers Unpin")
        app.buttons["Archive"].firstMatch.tap()
        XCTAssertTrue(captions.waitForNonExistence(timeout: 5), "Archived workflows leave the list")

        let archived = app.buttons["workflows.archived"]
        scrollTo(archived, in: app)
        archived.tap()
        let row = element("workflows.archived.wf-captions", app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        save("25-archived", app)
        row.press(forDuration: 1.2)
        let unarchive = app.buttons["Unarchive"].firstMatch
        XCTAssertTrue(unarchive.waitForExistence(timeout: 5), "The archived list's long-press menu has Unarchive")
        unarchive.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(captions.waitForExistence(timeout: 5), "Back in the list")
    }

    // MARK: Canvas (iPad)

    /// Touch and hold shows the node's menu; moving the finger then drags the
    /// node, the menu goes away and nothing in it runs.
    @MainActor
    func testLongPressShowsTheMenuThenDraggingMovesTheNode() throws {
        let app = launch()
        try requirePad(app)
        openCanvas(app)
        let node = app.buttons["workflows.canvas.node.review"]
        XCTAssertTrue(node.waitForExistence(timeout: 8))

        node.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5), "Touch and hold shows the node's menu")
        save("30-canvas-menu", app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Delete"].waitForNonExistence(timeout: 5))

        let before = node.value as? String
        let start = node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Held long enough for the menu to open before the finger moves.
        start.press(forDuration: 1.4, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitUntil { (node.value as? String) != before }, "The node moved (\(before ?? "?"))")
        XCTAssertFalse(app.buttons["Delete"].exists, "The menu went away once the drag started")
        XCTAssertFalse(app.buttons["End the flow here"].exists)
        XCTAssertTrue(node.exists, "Nothing in the menu ran")
        save("31-canvas-moved", app)

        // The place is saved: it's still there after leaving and coming back.
        let moved = node.value as? String
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openCanvas(app, alreadyHome: true)
        XCTAssertTrue(waitUntil { (app.buttons["workflows.canvas.node.review"].value as? String) == moved })
    }

    @MainActor
    func testDraggingAPortRewiresTheFlow() throws {
        let app = launch()
        try requirePad(app)
        openCanvas(app)
        let port = element("workflows.canvas.port.research.next", app)
        XCTAssertTrue(port.waitForExistence(timeout: 8))
        XCTAssertEqual(port.value as? String, "draft")
        let target = app.buttons["workflows.canvas.node.check"]
        port.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(waitUntil { (port.value as? String) == "check" }, "Research now goes to the check")
        XCTAssertTrue(element("workflows.issues", app).waitForExistence(timeout: 5),
                      "The canvas says the draft can't be reached any more")
        save("32-canvas-rewired", app)

        // Grab the wire's end at the check and put it back on the draft.
        let inPort = element("workflows.canvas.in.check", app)
        let draft = app.buttons["workflows.canvas.node.draft"]
        app.buttons["workflows.canvas.node.research"].tap()
        inPort.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: draft.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(waitUntil { (port.value as? String) == "draft" }, "The wire's end moved back to the draft")
    }

    @MainActor
    func testCanvasForEvidence() throws {
        let app = launch()
        try requirePad(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        openCanvas(app)
        XCTAssertTrue(app.buttons["workflows.canvas.fit"].waitForExistence(timeout: 5))
        save("33-canvas-landscape", app)
        app.buttons["workflows.canvas.node.decide"].tap()
        save("34-canvas-decision-selected", app)
        app.buttons["workflows.canvas.zoom-in"].tap()
        app.buttons["workflows.canvas.zoom-in"].tap()
        save("35-canvas-zoomed", app)
        app.buttons["workflows.canvas.fit"].tap()
        // Frames for a short animation of a node being moved.
        let node = app.buttons["workflows.canvas.node.signoff"]
        let start = node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.2, thenDragTo: start.withOffset(CGVector(dx: -60, dy: 200)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        save("36-canvas-after-move", app)
        XCUIDevice.shared.orientation = .portrait
    }

    /// "Three takes" puts three agents in one parallel block; the block's
    /// editor lists them, and each opens its own editor.
    @MainActor
    func testAParallelBlockListsItsAgents() throws {
        let app = launch()
        openWorkflows(app)
        let template = element("workflows.template.three-takes", app)
        scrollTo(template, in: app)
        XCTAssertTrue(template.exists, "The Three takes template is offered")
        template.buttons["workflows.template.use"].tap()
        let pad = app.userInterfaceIdiom == .pad
        let block = element(pad ? "workflows.canvas.node.takes" : "workflows.flow.stage.takes", app)
        XCTAssertTrue(block.waitForExistence(timeout: 8), "The copy opens with its parallel block")
        save("40-parallel-flow", app)
        block.tap()
        if pad, !element("workflows.stage-editor", app).waitForExistence(timeout: 2) {
            block.tap()
        }
        XCTAssertTrue(element("workflows.stage-editor", app).waitForExistence(timeout: 5))
        for key in ["facts", "risks", "practice"] {
            XCTAssertTrue(app.buttons["workflows.stage.branch.\(key)"].waitForExistence(timeout: 5),
                          "The block lists \(key)")
        }
        save("41-parallel-block-editor", app)
        app.buttons["workflows.stage.branch.risks"].tap()
        XCTAssertTrue(app.staticTexts["The risks"].waitForExistence(timeout: 5) || app.textFields["The risks"].exists,
                      "An agent of the block opens in its own editor")
        save("42-parallel-agent-editor", app)
    }

    /// Morning numbers (demo): a Delivery node, a decision whose way ends the run as succeeded, and
    /// output names that fix themselves as they're typed.
    @MainActor
    func testDeliveryNodeDecisionEndingsAndNames() throws {
        let app = launch()
        openWorkflows(app)
        let morning = app.buttons["workflows.workflow.wf-morning"]
        scrollTo(morning, in: app)
        morning.tap()
        let pad = app.userInterfaceIdiom == .pad
        let send = element(pad ? "workflows.canvas.node.send" : "workflows.flow.stage.send", app)
        XCTAssertTrue(send.waitForExistence(timeout: 8), "The flow has its Delivery node")
        save("50-delivery-flow", app)
        if pad { throw XCTSkip("The rest taps the iPhone's flow") }

        send.tap()
        XCTAssertTrue(element("workflows.stage.delivery.to", app).waitForExistence(timeout: 5), "It says where it sends")
        XCTAssertTrue(element("workflows.stage.delivery.output.make.chart", app).waitForExistence(timeout: 5),
                      "It lists what it can send, the picture too")
        save("51-delivery-editor", app)
        app.buttons["Cancel"].firstMatch.tap()

        let decision = element("workflows.flow.stage.anything", app)
        XCTAssertTrue(decision.waitForExistence(timeout: 5))
        decision.tap()
        XCTAssertTrue(element("workflows.stage.changes-way", app).waitForExistence(timeout: 5))
        let note = element("workflows.stage.changes-note", app)
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Ending the run shows its note")
        XCTAssertEqual(note.value as? String, "No new numbers since yesterday.")
        save("52-decision-ends", app)
        app.buttons["Cancel"].firstMatch.tap()

        let make = element("workflows.flow.stage.make", app)
        XCTAssertTrue(make.waitForExistence(timeout: 5))
        make.tap()
        app.buttons["Output"].firstMatch.tap()
        let name = app.textFields["workflows.stage.output.0"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "Weekly Chart")
        XCTAssertEqual(name.value as? String, "weekly_chart", "Capitals turn lowercase and spaces turn into _")
        save("53-output-name", app)
        app.buttons["Cancel"].firstMatch.tap()
    }

    /// A run of Morning numbers that the decision ended says so, and why.
    @MainActor
    func testARunSaysWhyItsDecisionEndedIt() throws {
        let app = launch()
        openRun("run-6", app)
        XCTAssertTrue(element("workflows.run.ended", app).waitForExistence(timeout: 8),
                      "The run says the decision ended it")
        save("55-run-ended", app)
    }

    /// A run of Morning numbers shows the picture its agent made.
    @MainActor
    func testARunShowsThePictureItsAgentMade() throws {
        let app = launch()
        openRun("run-7", app)
        let make = app.buttons["workflows.run.stage.make"]
        XCTAssertTrue(make.waitForExistence(timeout: 8))
        scrollTo(make, in: app)
        make.tap()
        let chart = element("workflows.run.stage.file.make.chart", app)
        for _ in 0..<4 where !(chart.exists && chart.isHittable) {
            element("workflows.run.stage-sheet", app).swipeUp()
        }
        chart.tap()
        XCTAssertTrue(element("workflows.run.file.image", app).waitForExistence(timeout: 8), "The picture opens")
        save("54-run-picture", app)
    }

    @MainActor
    private func openRun(_ id: String, _ app: XCUIApplication) {
        openWorkflows(app)
        let all = app.buttons["workflows.all-runs"].firstMatch
        scrollTo(all, in: app)
        all.tap()
        let row = app.buttons["workflows.run.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        scrollTo(row, in: app)
        row.tap()
    }

    /// A Shortcut's link opens one workflow, or its Run sheet (demo).
    @MainActor
    func testAWorkflowLinkOpensItOrItsRunSheet() throws {
        let app = launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"]))
            .firstMatch.waitForExistence(timeout: 15))
        app.open(URL(string: "loopdy://workflows/wf-morning")!)
        let pad = app.userInterfaceIdiom == .pad
        let make = element(pad ? "workflows.canvas.node.make" : "workflows.flow.stage.make", app)
        XCTAssertTrue(make.waitForExistence(timeout: 10), "The workflow opens")
        save("60-link-workflow", app)
        app.open(URL(string: "loopdy://workflows/wf-research?run=1")!)
        XCTAssertTrue(app.buttons["workflows.run-sheet.run"].waitForExistence(timeout: 10), "Its Run sheet opens")
        save("61-link-run-sheet", app)
    }

    /// The layout switch on a phone: the vertical flow becomes one row to swipe through, and back.
    @MainActor
    func testThePhoneFlowCanShowItsStagesSideBySide() throws {
        let app = launch()
        if app.userInterfaceIdiom == .pad { throw XCTSkip("For a phone in portrait") }
        openWorkflows(app)
        app.buttons["workflows.workflow.wf-research"].tap()
        let toggle = app.buttons["workflows.layout"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        // The choice is remembered: a run before may have left it side by side.
        if element("workflows.canvas.board", app).exists { toggle.tap() }
        XCTAssertTrue(element("workflows.flow.stage.research", app).waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Show side by side")
        save("70-layout-top-to-bottom", app)
        toggle.tap()
        let research = app.buttons["workflows.canvas.node.research"], draft = app.buttons["workflows.canvas.node.draft"]
        XCTAssertTrue(research.waitForExistence(timeout: 5), "Side by side, on the canvas")
        XCTAssertEqual(research.frame.midY, draft.frame.midY, accuracy: 2, "One row")
        XCTAssertLessThan(research.frame.maxX, draft.frame.minX)
        save("71-layout-side-by-side", app)
        app.buttons["workflows.layout"].tap()
        XCTAssertTrue(element("workflows.flow.stage.research", app).waitForExistence(timeout: 5), "Top to bottom again")
    }

    /// The layout switch on a wide screen (a big phone in landscape): your canvas becomes one column,
    /// and back, and the places you gave the nodes never change.
    @MainActor
    func testAWideCanvasCanStackItsStagesAndKeepsYourPlaces() throws {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        openWorkflows(app)
        app.buttons["workflows.workflow.wf-research"].tap()
        guard element("workflows.canvas.board", app).waitForExistence(timeout: 8) else {
            throw XCTSkip("This screen is compact in landscape")
        }
        let toggle = app.buttons["workflows.layout"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.label == "Show your layout" { toggle.tap() }
        let research = app.buttons["workflows.canvas.node.research"], draft = app.buttons["workflows.canvas.node.draft"]
        XCTAssertTrue(waitUntil { abs(research.frame.midY - draft.frame.midY) < 2 }, "Your layout: side by side")
        let place = draft.value as? String
        save("72-layout-yours", app)
        toggle.tap()
        XCTAssertTrue(waitUntil { abs(research.frame.midX - draft.frame.midX) < 2 && research.frame.maxY < draft.frame.minY },
                      "One column, top to bottom")
        XCTAssertEqual(toggle.label, "Show your layout")
        XCTAssertEqual(draft.value as? String, place, "The place you gave it stays saved")
        save("73-layout-stacked", app)
        toggle.tap()
        XCTAssertTrue(waitUntil { abs(research.frame.midY - draft.frame.midY) < 2 }, "Your layout again")
        XCTAssertEqual(draft.value as? String, place)
    }

    // MARK: iPhone

    /// Compact width: every stage in one line, top to bottom, inside the screen,
    /// even when the canvas has them far apart.
    @MainActor
    func testCompactWidthLinesTheStagesUp() throws {
        let app = launch()
        if app.userInterfaceIdiom == .pad { throw XCTSkip("Compact width is the iPhone's") }
        openWorkflows(app)
        app.buttons["workflows.workflow.wf-research"].tap()
        let keys = ["research", "draft", "check", "review", "decide", "signoff"]
        var last: CGFloat = -1
        let width = app.windows.firstMatch.frame.width
        for key in keys {
            let stage = element("workflows.flow.stage.\(key)", app)
            if !stage.waitForExistence(timeout: 5) || !stage.isHittable { app.swipeUp() }
            XCTAssertTrue(stage.exists, key)
            XCTAssertGreaterThan(stage.frame.minY, last, "\(key) is below the stage before it")
            XCTAssertGreaterThanOrEqual(stage.frame.minX, 0, key)
            XCTAssertLessThanOrEqual(stage.frame.maxX, width, "\(key) is on screen")
            last = stage.frame.minY
            if key == "check" { save("26-flow-compact", app) }
        }
        XCTAssertEqual(element("workflows.flow.port.research.next", app).value as? String, "draft")
        save("27-flow-compact-end", app)
    }

    /// iPhone: touch and hold a stage (its menu shows), then drag it to another place in the line.
    @MainActor
    func testCompactReorderByLongPressThenDrag() throws {
        let app = launch()
        if app.userInterfaceIdiom == .pad { throw XCTSkip("Compact width is the iPhone's") }
        openWorkflows(app)
        app.buttons["workflows.workflow.wf-research"].tap()
        let check = element("workflows.flow.stage.check", app)
        let draft = element("workflows.flow.stage.draft", app)
        XCTAssertTrue(check.waitForExistence(timeout: 8) && draft.exists)
        XCTAssertLessThan(draft.frame.minY, check.frame.minY)

        check.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5), "Touch and hold shows the stage's menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.buttons["Delete"].waitForNonExistence(timeout: 5))

        // Down, away from the menu (it opens above the stage): moving into a menu picks from it.
        let review = element("workflows.flow.stage.review", app)
        let start = check.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let below = review.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.85))
        start.press(forDuration: 1.4, thenDragTo: below, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitUntil { check.frame.minY > review.frame.minY }, "The check moved below the review")
        XCTAssertFalse(app.buttons["Delete"].exists, "The menu went away once the drag started")
        XCTAssertEqual(element("workflows.flow.port.draft.next", app).value as? String, "review",
                       "The draft now goes on to the review")
        save("27a-flow-reordered", app)

        // Up: the menu has Move up, since a drag toward the menu picks from it.
        sleep(1)
        check.press(forDuration: 2)
        let moveUp = app.buttons["Move up"]
        XCTAssertTrue(moveUp.waitForExistence(timeout: 5), "The stage's menu offers Move up")
        moveUp.tap()
        XCTAssertTrue(waitUntil { check.frame.minY < review.frame.minY }, "The check is back above the review")
        XCTAssertEqual(element("workflows.flow.port.check.next", app).value as? String, "review")
    }

    /// iPhone: drag a stage's port onto another stage to send its way out there.
    @MainActor
    func testCompactRewireByDraggingAPort() throws {
        let app = launch()
        if app.userInterfaceIdiom == .pad { throw XCTSkip("Compact width is the iPhone's") }
        openWorkflows(app)
        app.buttons["workflows.workflow.wf-research"].tap()
        let port = element("workflows.flow.port.research.next", app)
        XCTAssertTrue(port.waitForExistence(timeout: 8))
        XCTAssertEqual(port.value as? String, "draft")
        let review = element("workflows.flow.stage.review", app)
        port.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: review.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        XCTAssertTrue(waitUntil { (port.value as? String) == "review" }, "Research now goes to the review")
        XCTAssertTrue(element("workflows.flow.issues", app).waitForExistence(timeout: 5),
                      "The flow says what can't be reached any more")
        save("27b-flow-rewired", app)
    }

    // MARK: Computers that can't run workflows

    @MainActor
    func testAComputerThatCantRunWorkflowsSaysWhyInPlainWords() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                               "-demo-workflows-unavailable", "chat_runner_missing"]
        app.launch()
        openMenuRow(app)
        let explanation = element("workflows.cant-run", app)
        XCTAssertTrue(explanation.waitForExistence(timeout: 8), "The screen explains instead of failing")
        let words = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Update Hermes'")).firstMatch
        XCTAssertTrue(words.exists, "It says what to do")
        let code = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'chat_runner'")).firstMatch
        XCTAssertFalse(code.exists, "Never the raw code")
        save("28-cant-run", app)
    }

    // MARK: All runs

    /// The computer's name in the top bar stays on one line and readable.
    @MainActor
    func testAllRunsHostLabelStaysOnOneLine() throws {
        let app = launch(["-demo-workflows-host-name", "Studio Mac mini in the back office"])
        openWorkflows(app)
        let allRuns = app.buttons["workflows.all-runs"].firstMatch
        XCTAssertTrue(allRuns.waitForExistence(timeout: 5))
        allRuns.tap()
        XCTAssertTrue(element("workflows.monitor", app).waitForExistence(timeout: 8))
        let host = app.navigationBars.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Studio Mac mini'")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        let lineHeight: CGFloat = app.userInterfaceIdiom == .pad ? 26 : 24
        XCTAssertLessThanOrEqual(host.frame.height, lineHeight, "One line, not wrapped (\(host.frame))")
        let title = app.navigationBars.staticTexts["Runs"].firstMatch
        XCTAssertTrue(title.exists)
        XCTAssertGreaterThan(host.frame.minX, title.frame.maxX, "It doesn't run into the title (\(host.frame))")
        XCTAssertLessThanOrEqual(host.frame.maxX, app.windows.firstMatch.frame.maxX, "It stays on screen")
        save("29-all-runs", app)
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func requirePad(_ app: XCUIApplication) throws {
        if app.userInterfaceIdiom != .pad { throw XCTSkip("The free canvas is for regular width") }
    }

    @MainActor
    private func openMenuRow(_ app: XCUIApplication) {
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let row = app.buttons["menu.workflows"]
        XCTAssertTrue(row.waitForExistence(timeout: 8), "☰ lists Workflows")
        row.tap()
    }

    @MainActor
    private func openWorkflows(_ app: XCUIApplication) {
        openMenuRow(app)
        XCTAssertTrue(element("workflows.home", app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["workflows.workflow.wf-research"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func openCanvas(_ app: XCUIApplication, alreadyHome: Bool = false) {
        if !alreadyHome { openWorkflows(app) }
        let workflow = app.buttons["workflows.workflow.wf-research"]
        XCTAssertTrue(workflow.waitForExistence(timeout: 8))
        workflow.tap()
        XCTAssertTrue(element("workflows.canvas.board", app).waitForExistence(timeout: 8))
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    @MainActor
    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_WORKFLOWS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let device = app.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        // The whole screen: an app screenshot in landscape comes back cut to a square.
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
    }
}

private extension XCUIApplication {
    var userInterfaceIdiom: UIUserInterfaceIdiom { UIDevice.current.userInterfaceIdiom }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        // At the end of the text, so every delete removes a letter.
        coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        if let value = value as? String, !value.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        typeText(text)
    }
}
