import Foundation
import SwiftUI

/// `focus.current`: the agent's `iphone_focus` tool, which Focus filter is on and the note the person left for agents.
/// iOS tells an app nothing about Focus except through the app's own Focus filter (`BighelpFocusFilter`),
/// so a Focus without bighelp's filter reads as not active. Nothing here asks iOS or turns a Focus on or off.
@MainActor
final class DeviceFocusTool: DeviceCapabilityTool {
    let capability = DeviceToolCapability.focus

    static let hint = "The person sets this up in iOS Settings, under Focus, by adding bighelp's Focus filter to a "
        + "Focus. A Focus without that filter shows as not active, even while it is on."

    private let store: BighelpFocusFilterStore

    init(store: BighelpFocusFilterStore) {
        self.store = store
    }

    static func live(_ environment: DeviceToolEnvironment) -> DeviceFocusTool {
        // Demo mode never reads the real filter.
        DeviceFocusTool(store: environment.usesFixtures ? BighelpFocusFilterStore(defaults: environment.defaults) : .shared)
    }

    /// The data comes only from the filter the person set up, so there is no iOS permission to ask for.
    func status() async -> DeviceToolSystemAccess { Self.isOffered ? .available : .unavailable }
    func request() async -> DeviceToolSystemAccess { await status() }

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        context: DeviceToolCallContext,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        guard operation == "focus.current" else { throw AppleDeviceToolError.unsupportedOperation }
        guard arguments.isEmpty else { throw AppleDeviceToolError.invalidArguments }
        try authorize()
        return Self.payload(store.read())
    }

    static func payload(_ state: BighelpFocusFilterState) -> [String: BighelpJSONValue] {
        var payload: [String: BighelpJSONValue] = [
            "active": .boolean(state.active),
            "quietAlerts": .boolean(state.active && state.quietAlerts),
            "hint": .string(hint),
        ]
        guard state.active else { return payload }
        if let name = state.name { payload["name"] = .string(name) }
        if let note = state.note { payload["note"] = .string(note) }
        if let since = state.since { payload["since"] = .string(timestamp(since)) }
        return payload
    }

    private static var isOffered: Bool {
        #if os(visionOS)
        false
        #else
        true
        #endif
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// What Device access shows under the focus switch.
@MainActor
struct FocusPermissionExtras: View {
    let permissions: DeviceToolPermissions

    var body: some View {
        if permissions.isEnabled(.focus) {
            Text("To share a Focus, add bighelp's filter to it in iOS Settings › Focus. Then pick a name and a note for your agents, and choose if their alerts stay quiet.")
                .bighelpFont(.metadata).foregroundStyle(.secondary)
                .accessibilityIdentifier("permissions.device-tools.focus.setup")
        }
    }
}
