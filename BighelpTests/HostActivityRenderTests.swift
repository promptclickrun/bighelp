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
