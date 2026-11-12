import SwiftUI
import XCTest
@testable import Bighelp

final class HostActivityRenderTests: XCTestCase {
    @MainActor
    func testSharedChatRowsRenderAtPhoneWidth() throws {
        let now = Int(Date().timeIntervalSince1970)
        let rows: [BighelpActivitySession] = [
            .init(id: "review", phase: .waiting, timestamp: now),
            .init(id: "code", phase: .usingTool, timestamp: now, latestTool: "terminal"),
            .init(id: "plan", phase: .thinking, timestamp: now - 180),
            .init(id: "team", phase: .delegating, timestamp: now, activeSubagentCount: 2),
            .init(id: "done", phase: .completed, timestamp: now)
        ]
        let titles = ["Review the weekend plan", "Update the project", "Plan a garden", "Gather ideas", "Draft the invitation"]
        var infos: [String: BighelpActivitySessionInfo] = [:]
        for (index, row) in rows.enumerated() {
            let attributes = try XCTUnwrap(LoopdySessionActivityAttributes.make(sessionID: row.id, sessionTitle: "Chat",
                agentID: "agent", agentName: index.isMultiple(of: 2) ? "Juno" : "Avery"))
            infos[row.id] = .init(attributes: attributes, title: titles[index])
        }
        var state = BighelpActivitySession.aggregate(rows, timestamp: now)
        state.activeCount = 8
        let out = ProcessInfo.processInfo.environment["BIGHELP_WIDGET_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        for dark in [false, true] {
            for accessible in [false, true] {
                let view = BighelpActivityRowsView(state: state, infos: infos)
                    .padding(12).frame(width: 364)
                    .background(dark ? Color.black : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertLessThanOrEqual(image.size.height, 220)
                let name = "shared-card-\(dark ? "dark" : "light")-\(accessible ? "accessibility" : "standard")"
                let attachment = XCTAttachment(image: image)
                attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                if let out { try XCTUnwrap(image.pngData()).write(to: out.appendingPathComponent(name + ".png")) }
            }
        }
    }

    /// The card with one chat in full (made-up detail), in each state, both looks and two text sizes.
    /// Lock Screen cards are at most 160 points tall.
    @MainActor
    func testCardWithDetailRendersInsideTheLockScreenHeight() throws {
        let now = Int(Date().timeIntervalSince1970)
        var working = BighelpActivityDetail()
        working.started = now - 141; working.steps = 9; working.tool = "execute_code"; working.note = "price per lb by brand"
        working.trail = [.init(tool: "web_extract", count: 6), .init(tool: "web_search", count: 3)]
        working.contextUsed = 30_300; working.contextWindow = 272_000; working.model = "sample-model-1"
        var asking = working; asking.question = "Send the order to Northfield for $47.00? It ships on Friday and the price holds until then."
        var done = working; done.tool = nil; done.steps = 12
        done.preview = "Cheapest per lb is Northfield Whey at $9.40. Four brands compared, and the table is in the chat."
        let cases: [(String, BighelpActivitySession.Phase, BighelpActivityDetail, Int, Bool)] = [
            ("working", .usingTool, working, 0, false), ("working-nerd", .usingTool, working, 0, true),
            ("asking", .waiting, asking, 2, false), ("done", .completed, done, 0, false), ("working-busy", .usingTool, working, 4, false)
        ]
        let out = ProcessInfo.processInfo.environment["BIGHELP_WIDGET_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        for (name, phase, detail, others, nerd) in cases {
            var rows = [BighelpActivitySession(id: "a-first", phase: phase, timestamp: now, activeSubagentCount: phase == .usingTool ? 2 : 0)]
            rows += (0..<others).map { .init(id: "other-\($0)", phase: $0 == 0 ? .usingTool : .thinking, timestamp: now) }
            var infos: [String: BighelpActivitySessionInfo] = [:]
            for (index, row) in rows.enumerated() {
                let attributes = try XCTUnwrap(LoopdySessionActivityAttributes.make(sessionID: row.id, sessionTitle: "Chat",
                    agentID: "agent", agentName: ["Scout", "Mabel", "Otto"][index % 3]))
                infos[row.id] = .init(attributes: attributes, title: ["Protein powder prices", "Order follow-up", "Trip to Lisbon"][index % 3])
            }
            let state = BighelpActivitySession.aggregate(rows, timestamp: now)
            for dark in [false, true] {
                for size in [DynamicTypeSize.large, .xxxLarge] {
                    let view = BighelpActivityRowsView(state: state, infos: infos, details: ["a-first": detail],
                                                       level: .stepsAndText, showsNerdLine: nerd)
                        .foregroundStyle(dark ? Color.white : Color.black)
                        .padding(12).frame(width: 364)
                        .background(dark ? Color.black : Color.white)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.dynamicTypeSize, size)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.uiImage)
                    let file = "feed-card-\(name)-\(dark ? "dark" : "light")-\(size == .large ? "standard" : "xxxl")"
                    XCTAssertLessThanOrEqual(image.size.height, 160, file)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = file; attachment.lifetime = .keepAlways; add(attachment)
                    if let out { try XCTUnwrap(image.pngData()).write(to: out.appendingPathComponent(file + ".png")) }
                }
            }
        }
        // Status only, or a row with no detail: the card is the plain rows it was.
        let plain = ImageRenderer(content: BighelpActivityRowsView(state: BighelpActivitySession.aggregate(
            [.init(id: "a-first", phase: .usingTool, timestamp: now)], timestamp: now), details: [:]).frame(width: 364))
        XCTAssertLessThan(try XCTUnwrap(plain.uiImage).size.height, 60)
    }

    @MainActor
    func testProductionActivityCardsRenderAtPhoneWidth() throws {
        let attributes = try XCTUnwrap(LoopdySessionActivityAttributes.make(sessionID: "session-render",
            sessionTitle: "PRIVATE TITLE", agentID: "agent", agentName: "Juno"))
        typealias State = LoopdySessionActivityAttributes.ContentState
        let rows: [(String, State, Bool)] = [
            ("Working", State(phase: .usingTool, currentAction: "Private command", progress: 38, completedSteps: 8, activeSubagentCount: 0, latestTool: "secret", timestamp: 100), false),
            ("Delegating", State(phase: .delegating, currentAction: "Response ready", progress: 0, completedSteps: 8, activeSubagentCount: 2, latestTool: nil, timestamp: 100), false),
            ("Attention", State(phase: .waiting, currentAction: "Private question", progress: 0, completedSteps: 8, activeSubagentCount: 0, latestTool: nil, timestamp: 100), false),
            ("Stale", State.initial(agentName: "Juno", timestamp: 100), true),
            ("Finished", State(phase: .completed, currentAction: "Finished", progress: 100, completedSteps: 8, activeSubagentCount: 0, latestTool: nil, timestamp: 100), false),
            ("Failed", State(phase: .failed, currentAction: "Could not finish", progress: 100, completedSteps: 8, activeSubagentCount: 0, latestTool: nil, timestamp: 100), false)
        ]
        for dark in [false, true] {
            let view = VStack(spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    // The card draws the app's page color itself, as it does on the Lock Screen.
                    BighelpLiveActivityCard(attributes: attributes, state: row.1, isStale: row.2)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                }
            }.padding(16).frame(width: 393).background(dark ? Color.black : Color(white: 0.55))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.height, 500)
            let attachment = XCTAttachment(image: image)
            attachment.name = dark ? "activity-cards-dark" : "activity-cards-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let large = ImageRenderer(content: BighelpLiveActivityCard(attributes: attributes, state: rows[2].1)
            .frame(width: 320).environment(\.dynamicTypeSize, .accessibility3))
        let attachment = XCTAttachment(image: try XCTUnwrap(large.uiImage))
        attachment.name = "activity-attention-accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
