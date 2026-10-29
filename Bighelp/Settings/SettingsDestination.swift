import Foundation

/// A page inside the Settings sheet, by name. The sheet's stack pushes these by value, so code
/// (an agent's drive, a link) can open Settings straight to one with `AppState.openSettings(at:)`.
/// Pages that are not reachable by a push (sheets, the host's own tools) are not listed.
enum SettingsDestination: Hashable, Sendable {
    /// One row of the Settings menu (Appearance, Chat, Voice, System ...).
    case section(SettingsMenuSection)
    /// Appearance › Chat layout.
    case chatLayout
    /// Appearance › App layout: the bottom bar and the order of ☰.
    case appLayout
    /// The Apps row: the hub of Native App Connections and Composio Apps (or just the native list).
    case apps
    /// Apps › Native App Connections: Hermes' own connectors on this computer.
    case nativeAppConnections
    /// Apps › Composio Apps.
    case composioApps
    /// System › Connection & plugin features (Nerd Mode).
    case connection
    /// One page of Bots mode's short Settings.
    case bots(SimpleBotsSettingsPage)
    /// The full Settings menu, as Bots mode's All Settings row opens it.
    case allSettings
}
