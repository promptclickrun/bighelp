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
        // A click reaches the screen and comes back drawn: demo mode marks where it landed.
        let before = try #require(model.lastFrame)
        #expect(Self.pixel(before, x: 1_000, y: 200) != Self.clickMark)
        model.click(.left, at: CGPoint(x: 1_000, y: 200))
        try await waitUntil { model.lastFrame.map { Self.pixel($0, x: 1_000, y: 200) } == Self.clickMark }
        // Typing reaches the screen's terminal.
        let terminal = DemoBotDesktop.terminal
        let typedBefore = Self.pixels(try #require(model.lastFrame), in: terminal)
        model.type("ls")
        try await waitUntil { model.lastFrame.map { Self.pixels($0, in: terminal) } != typedBefore }
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

    /// The demo's click mark, 0x00RRGGBB.
    private static let clickMark: UInt32 = 0xFF_8A7A

    private static func pixel(_ frame: RFBFrame, x: Int, y: Int) -> UInt32? {
        pixels(frame, in: RFBRect(x: x, y: y, width: 1, height: 1)).first
    }

    /// Every fourth pixel of a rectangle, 0x00RRGGBB, read with one copy of the picture.
    private static func pixels(_ frame: RFBFrame, in rect: RFBRect) -> [UInt32] {
        guard let data = frame.image.dataProvider?.data as Data? else { return [] }
        let rowBytes = frame.image.bytesPerRow
        return (rect.y..<(rect.y + rect.height)).flatMap { y in
            stride(from: rect.x, to: rect.x + rect.width, by: 4).map { x in
                let offset = y * rowBytes + x * 4
                return UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset])
            }
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out")
    }
}
