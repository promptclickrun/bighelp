import SwiftUI

/// Settings › Permissions (the "Device access" page): the switch for usage numbers and crash
/// reports. On unless turned off. Off stops sending at once, throws away what was waiting and tells
/// the connected computers to stop theirs. What is and isn't sent: docs/SECURITY_AND_PRIVACY.md.
@MainActor
struct TelemetrySettingsSection: View {
    let controller: TelemetryController

    init(controller: TelemetryController = .shared) { self.controller = controller }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { controller.isEnabled },
                set: { value in Task { await controller.setEnabled(value) } }
            )) {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text("Share usage and diagnostics").bighelpFont(.body, weight: .semibold)
                    Text("Counts and crash reports tied to a random ID. Never your messages, files or names.")
                        .bighelpFont(.metadata).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("settings.telemetry.toggle")
        } header: {
            Text("Usage and diagnostics")
        } footer: {
            Text("Turning it off also tells your connected computers to stop sending their usage reports.")
                .bighelpFont(.metadata)
                .accessibilityIdentifier("settings.telemetry.footer")
                .accessibilityValue(demoToldDescription)
        }
        .listRowBackground(theme.surface)
    }

    /// Demo runs only: what the stand-in computer was told, for UI tests to check.
    private var demoToldDescription: String {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-use-demo-fixtures") ? DemoTelemetryHosts.shared.toldDescription : ""
        #else
        ""
        #endif
    }

    @BighelpThemeReader private var theme
}
