import Foundation

/// A page inside the Settings sheet, by name. The sheet's stack pushes these by value, so code
/// (an agent's drive, a link) can open Settings straight to one with `AppState.openSettings(at:)`.
/// Pages that are not reachable by a push (sheets, the host's own tools) are not listed.
enum SettingsDestination: Hashable, Sendable {
    /// One row of the Settings menu (Modes, Appearance, Chat, Voice, System ...).
    case section(SettingsMenuSection)
    /// The first row: your name and photo.
    case you
    /// Appearance › Chat layout.
    case chatLayout
    /// Appearance › App layout: the bottom bar and the order of ☰.
    case appLayout
    /// Connections: this device's access, then Native App Connections and Composio Apps, then the
    /// credential vault. Device access opens from it as `.section(.permissions)`.
    case apps
    /// Connections › Native App Connections: Hermes' own connectors on this computer.
    case nativeAppConnections
    /// Connections › Composio Apps.
    case composioApps
    /// System › Connection & plugin features (Nerd Mode).
    case connection
    /// One page of Bots mode's short Settings.
    case bots(SimpleBotsSettingsPage)
    /// The full Settings menu, as Bots mode's All Settings row opens it.
    case allSettings
}
