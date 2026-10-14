import Foundation
import Testing
@testable import Bighelp

/// The open screen against demo mode's screen, which speaks real RFB: taking and
/// handing back control, someone else taking over, and closing.
@MainActor
struct BotScreenViewerModelTests {
    private func open(_ service: DemoBotScreenService) async throws -> (BotScreenViewerModel, Task<Void, Never>) {
        let model = BotScreenViewerModel(agentID: "default", agentName: "Avery", size: .standard, service: service)
        let run = Task { await model.run() }
        try await waitUntil { model.phase == .live && model.hasPicture }
        #expect(model.screenSize == DemoBotDesktop.size, "The picture's own size wins over the setting")
        return (model, run)
    }

    @Test func takeControlThenHandBack() async throws {
        let service = DemoBotScreenService()
        let (model, run) = try await open(service)
        defer { run.cancel() }
        #expect(model.control.holder == .agent)
        await model.takeControl()
        #expect(model.isInControl)
        #expect(try await service.status(agentID: "default").lease.holder == .human)
        guard case .hidden = try await service.thumbnail(agentID: "default") else {
            Issue.record("While a person is in control the still is hidden")
            return
        }
        model.type("ls")
        model.click(.left, at: CGPoint(x: 100, y: 100))
        await model.handBack()
        #expect(model.control.holder == .agent)
        #expect(try await service.status(agentID: "default").lease.holder == .agent)
    }

    @Test func someoneElseTakingOverDropsThisViewerToWatching() async throws {
        let service = DemoBotScreenService()
        let (model, run) = try await open(service)
        defer { run.cancel() }
        await model.takeControl()
        #expect(model.isInControl)
        _ = try await service.takeControl(agentID: "default", viewerID: "another-phone")
        try await waitUntil { model.control.holder == .someoneElse }
        #expect(model.notice == "Someone else took control.")
        #expect(!model.showsKeyboard)
    }

    @Test func closingHandsControlBack() async throws {
        let service = DemoBotScreenService()
        let (model, run) = try await open(service)
        await model.takeControl()
        #expect(try await service.status(agentID: "default").lease.holder == .human)
        model.close()
        run.cancel()
        try await waitUntil { (try? await service.status(agentID: "default").lease.holder) == .agent }
        // Nothing changes on a closed viewer.
        await model.takeControl()
        #expect(try await service.status(agentID: "default").lease.holder == .agent)
    }

    @Test func aScreenTurnedOffElsewhereEndsTheViewer() async throws {
        let service = DemoBotScreenService()
        let (model, run) = try await open(service)
        defer { run.cancel() }
        _ = try await service.stop(agentID: "default")
        try await waitUntil { model.phase == .ended("The screen is off.") }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out")
    }
}
