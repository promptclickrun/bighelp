import Foundation
import SwiftUI

/// What the phone tools may use from the app, given when bighelp starts.
@MainActor
struct DeviceToolEnvironment {
    let settings: SettingsStore
    let defaults: UserDefaults
    let dataDirectory: URL
    /// Demo mode: tools never ask iOS or touch real data.
    let usesFixtures: Bool
}

/// Things the phone tools need that exist only once bighelp is running, set beside CarPlay's.
@MainActor
enum DeviceToolServices {
    /// The same host path as Shortcuts: connects (or reuses the connection) and gives the agents,
    /// chats and plugin of the gateway in use. Works with bighelp in the background.
    static var workspace: (@MainActor () async throws -> BighelpShortcutWorkspace)?
}

/// Extra rows under some Device access switches.
@MainActor
struct DeviceToolPermissionExtras: View {
    let kind: DeviceToolCapability
    let permissions: DeviceToolPermissions

    var body: some View {
        switch kind {
        case .geofences: GeofencePermissionExtras(permissions: permissions)
        case .focus: FocusPermissionExtras(permissions: permissions)
        case .shortcuts: ShortcutsPermissionExtras(permissions: permissions)
        default: EmptyView()
        }
    }
}
