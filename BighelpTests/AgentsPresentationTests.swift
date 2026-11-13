import Foundation
import Testing
@testable import Bighelp

struct AgentsPresentationTests {
    private let studio = AgentProfile(
        id: "studio", name: "Studio", role: "Everyday planning",
        summary: "Practical ideas for a small workshop.", instructions: "Private instruction marker.",
        isDefault: true
    )
    private let field = AgentProfile(
        id: "field", name: "Field Notes", role: "Research partner",
        summary: "Sources and careful explanations.", instructions: "", isDefault: false
    )

    @MainActor @Test func nativeRefreshFlightOutlivesCancelledViewCallerUntilExplicitSuspension() async {
        let flight = NativeWorkspaceRefreshFlight()
        let state = NativeRefreshFlightTestState()
        let caller = Task { @MainActor in
            await flight.run {
                state.started = true
                await Task.yield()
                state.finished = !Task.isCancelled
            }
        }

        while !state.started { await Task.yield() }
        caller.cancel()
        await caller.value
        #expect(state.finished)

        let secondState = NativeRefreshFlightTestState()
        let second = Task { @MainActor in
            await flight.run {
                secondState.started = true
                while !Task.isCancelled { await Task.yield() }
            }
        }
        while !secondState.started { await Task.yield() }
        flight.cancel()
        let replacementState = NativeRefreshFlightTestState()
        let replacement = Task { @MainActor in
            await flight.run {
                replacementState.started = true
            }
        }
        while !replacementState.started { await Task.yield() }
        await replacement.value
        await second.value
    }

    private func room(id: String = "research-circle") -> HermesBotModeRoomSummary {
        let members = ["studio", "field", "absent"].map { id in
            HermesBotModeRoomMember(
                memberID: "member-\(id)", profile: id, handle: id,
                target: ["kind": .string("local"), "profile": .string(id)]
            )
        }
        return HermesBotModeRoomSummary(
            room: HermesBotModeRoomState(
                roomID: id, name: "Research Circle", members: members,
                authorityGatewayID: "fixture-gateway", authorityEpoch: 1, revision: 1,
                createdAt: 1_700_000_000, updatedAt: 1_700_000_060,
                latestSequence: 0, disbandedAt: nil, driverStatus: nil
            ),
            capabilities: nil
        )
    }
}

@MainActor
private final class NativeRefreshFlightTestState {
    var started = false
    var finished = false
}
