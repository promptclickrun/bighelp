import SwiftUI

/// The Mac menu bar's New Chat, Settings and text size, also listed when an
/// iPad's keyboard Command key is held. The shell publishes what they do.
/// The Mac's app menu also gets Check for Updates… (`BighelpMacUpdates`).
struct BighelpMenuCommands: Commands {
    @FocusedValue(\.bighelpShellActions) private var actions

    var body: some Commands {
        #if targetEnvironment(macCatalyst)
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { BighelpMacUpdates.shared.checkForUpdates() }
                .disabled(!BighelpMacUpdates.shared.isAvailable)
        }
        #endif
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { actions?.newChat() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(actions?.isSidebarOpen == true ? "Hide Sidebar" : "Show Sidebar") { actions?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(actions == nil)
            // The Unified Mode Toggle's modes. ⌘1–⌘5 are the tabs, so these add Control.
            if let modeSwitch = actions?.modeSwitch {
                Divider()
                ForEach(Array(modeSwitch.modes.enumerated()), id: \.element) { index, mode in
                    Button(mode.title) { modeSwitch.select(mode) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
                        .disabled(mode == modeSwitch.current)
                }
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { BighelpInterfaceSize.shared.stepText(by: 1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { BighelpInterfaceSize.shared.stepText(by: -1) }
                .keyboardShortcut("-")
            Button("Default Text Size") { BighelpInterfaceSize.shared.resetText() }
                .keyboardShortcut("0")
        }
        #if targetEnvironment(macCatalyst)
        // The bottom bar's tabs, like a Mac app's View menu. iPad keeps its own keys.
        CommandGroup(before: .sidebar) {
            ForEach(Array((actions?.tabs ?? AppTab.allCases).enumerated()), id: \.element) { index, tab in
                Button(tab.commandTitle) { actions?.selectTab?(tab) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(actions?.selectTab == nil)
            }
            Divider()
        }
        #endif
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { actions?.openSettings() }
                .keyboardShortcut(",")
                .disabled(actions == nil)
        }
    }
}

struct BighelpShellActions {
    let newChat: @MainActor () -> Void
    let openSettings: @MainActor () -> Void
    /// ☰: the Mac's sidebar.
    let isSidebarOpen: Bool
    let toggleSidebar: @MainActor () -> Void
    /// Bots, Chat and Code (⌃⌘1–⌃⌘3) while the Unified Mode Toggle is on.
    var modeSwitch: BighelpModeSwitch? = nil
    /// The bottom bar's tabs (Mac ⌘1–⌘5), while the bar shows.
    var selectTab: (@MainActor (AppTab) -> Void)? = nil
    /// The bar's tabs in its order (Appearance › App layout).
    var tabs: [AppTab] = AppTab.allCases
}

extension AppTab {
    /// The bottom bar's tabs by name, for the menu bar.
    var commandTitle: String {
        self == .scheduledTasks ? String(localized: "Scheduled Tasks") : title
    }
}

private struct BighelpShellActionsKey: FocusedValueKey {
    typealias Value = BighelpShellActions
}

extension FocusedValues {
    var bighelpShellActions: BighelpShellActions? {
        get { self[BighelpShellActionsKey.self] }
        set { self[BighelpShellActionsKey.self] = newValue }
    }
}
