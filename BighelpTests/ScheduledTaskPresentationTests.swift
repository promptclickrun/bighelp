import Foundation
import Testing
@testable import Bighelp

struct ScheduledTaskPresentationTests {
    @Test func rowAccessibilityIncludesLastResultWhenPresent() {
        let task = ScheduledTask.fixture(
            id: "task-1",
            agentID: "finance",
            name: "Morning brief",
            nextRun: Date(timeIntervalSinceReferenceDate: 777_600_000),
            lastResult: "Completed successfully"
        )

        let presentation = ScheduledTaskPresentation(task: task, agentName: "Avery Park")

        #expect(presentation.rowAccessibilityLabel.contains("Completed successfully"))
    }

    @Test func deleteConfirmationNamesTaskAndUnavailableBoundAgent() {
        let task = ScheduledTask.fixture(id: "task-1", agentID: "missing", name: "Morning brief")

        let presentation = ScheduledTaskPresentation(task: task, agentName: nil)

        #expect(presentation.deleteConfirmationTitle == "Delete Morning brief for Unavailable bot?")
        #expect(presentation.deleteConfirmationMessage.contains("Unavailable bot"))
    }

    @Test func unavailableAgentKeepsMutatingActionsVisibleButDisabled() {
        let task = ScheduledTask.fixture(id: "task-1", agentID: "missing", name: "Morning brief")

        let presentation = ScheduledTaskPresentation(task: task, agentName: nil)

        #expect(presentation.action(.edit).isVisible)
        #expect(!presentation.action(.edit).isEnabled)
        #expect(presentation.action(.edit).reason == "Bot unavailable")
        #expect(presentation.action(.pauseOrResume).isVisible)
        #expect(!presentation.action(.runNow).isEnabled)
        #expect(presentation.action(.delete).isEnabled)
        #expect(presentation.action(.duplicate).isEnabled)
    }

    @Test func editorRoundTripPreservesScheduleAcrossDeviceTimeZones() {
        let taskTimeZoneID = TimeZone.current.identifier == "America/Chicago"
            ? "Asia/Tokyo"
            : "America/Chicago"
        let schedule = ScheduleInput.weekly(
            day: .monday,
            time: DateComponents(hour: 9, minute: 30),
            timeZoneID: taskTimeZoneID
        )

        let state = ScheduledTaskEditorPickerState(
            schedule: schedule,
            fallbackTimeZoneID: TimeZone.current.identifier
        )

        #expect(taskTimeZoneID != TimeZone.current.identifier)
        #expect(state.timeZoneID == taskTimeZoneID)
        #expect(state.timeComponents.hour == 9)
        #expect(state.timeComponents.minute == 30)
        #expect(state.schedule() == schedule)
    }

    @Test func monthlyScheduleSurvivesEditorRoundTrip() {
        let schedule = ScheduleInput.monthly(
            day: 17,
            time: DateComponents(hour: 6, minute: 45),
            timeZoneID: "Pacific/Auckland"
        )

        let state = ScheduledTaskEditorPickerState(
            schedule: schedule,
            fallbackTimeZoneID: "America/Los_Angeles"
        )

        #expect(state.kind == .monthly)
        #expect(state.monthlyDay == 17)
        #expect(state.schedule() == schedule)
    }

    @Test func weekdayTogglesMutateOnlyTheChosenDayAndPreserveCronAxes() throws {
        var state = ScheduledTaskEditorPickerState(
            schedule: .repeating(
                days: Set(Weekday.allCases),
                time: DateComponents(hour: 8, minute: 15),
                timeZoneID: "America/Chicago"
            ),
            fallbackTimeZoneID: "America/Chicago"
        )

        state.toggle(.monday)

        #expect(!state.selectedDays.contains(.monday))
        #expect(state.selectedDays.contains(.tuesday))
        #expect(state.selectedDays.count == 6)
        #expect(try ScheduleRequestBuilder.hermesRequest(for: #require(state.schedule())) ==
            "15 8 * * 0,2,3,4,5,6")
    }

    @Test func deliverySelectionAcceptsOfficialTargetsAndValidatedManualChannelsOnly() throws {
        let targets = [
            ScheduledTaskDeliveryTarget(
                id: "local",
                name: "Local (save only)",
                homeTargetSet: true
            ),
            ScheduledTaskDeliveryTarget(
                id: "loopdy",
                name: "bighelp",
                homeTargetSet: true
            ),
            ScheduledTaskDeliveryTarget(
                id: "slack",
                name: "Slack",
                homeTargetSet: false
            ),
        ]

        #expect(try ScheduledTaskDeliverySelection.resolve(
            selectedID: "loopdy",
            manualValue: "",
            targets: targets
        ) == "loopdy")
        #expect(try ScheduledTaskDeliverySelection.resolve(
            selectedID: ScheduledTaskDeliverySelection.manualID,
            manualValue: "slack:C012345:thread-42",
            targets: targets
        ) == "slack:C012345:thread-42")
        #expect(throws: ScheduledTasksError.invalidDeliveryTarget) {
            try ScheduledTaskDeliverySelection.resolve(
                selectedID: "slack",
                manualValue: "",
                targets: targets
            )
        }
        for invalid in [
            "unknown:room",
            "local:room",
            "loopdy:",
            "loopdy:room,slack:other",
            "loopdy:room\u{0}",
        ] {
            #expect(throws: ScheduledTasksError.invalidDeliveryTarget) {
                try ScheduledTaskDeliverySelection.resolve(
                    selectedID: ScheduledTaskDeliverySelection.manualID,
                    manualValue: invalid,
                    targets: targets
                )
            }
        }
    }

    @Test func hermesReadBackDoesNotClaimDeviceFallbackAsConfirmedZone() throws {
        let schedule = ScheduleInput.hermes(
            request: "0 8 * * *",
            display: "Every day at 8:00 AM",
            timeZoneID: "America/Chicago"
        )
        let validated = try ScheduleRequestBuilder.validatedHermesRequest(for: schedule)

        #expect(schedule.requestedTimeZoneID == nil)
        #expect(validated.requestedTimeZoneID == nil)
        #expect(schedule.timeZoneDisclosure == "Time zone not confirmed by Hermes. Editing uses America/Chicago as a device fallback.")
        #expect(try ScheduleRequestBuilder.request(for: schedule) == "Every day at 8:00 AM")
    }
}
