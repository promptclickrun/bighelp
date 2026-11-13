import Foundation

/// A page inside the Settings sheet, by name. The sheet's stack pushes these by value, so code
/// (an agent's drive, a link) can open Settings straight to one with `AppState.openSettings(at:)`.
/// Pages that are not reachable by a push (sheets, the host's own tools) are not listed.
enum SettingsDestination: Hashable, Sendable {
    /// One page by its `SettingsMenuSection` (Appearance, Chat, Voice, Help ...).
    case section(SettingsMenuSection)
    /// The first row: your name and photo.
    case you
    /// Appearance › Chat layout.
    case chatLayout
    // One home: delete with the old shell; no row opens it, only the drive catalog's "App layout" place.
    /// Appearance › App layout: the bottom bar and the order of ☰.
    case appLayout
    /// Appearance › Thinking: the look of the Thinking control.
    case thinking
    /// Apps & skills: this device's access, the apps and skills bots can use (its own pages open
    /// from it), then the credential vault. Device access opens from it as `.section(.permissions)`.
    case apps
    /// Connection details of the computer in use, from its page with Advanced options on.
    case connection
}
