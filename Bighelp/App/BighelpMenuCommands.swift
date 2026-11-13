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
        // The home's three places, like a Mac app's View menu. iPad keeps its own keys.
        CommandGroup(before: .sidebar) {
            ForEach(Array((actions?.tabs ?? HomeTabItem.standard(view: .chats)).enumerated()), id: \.element.id) { index, tab in
                Button(tab.title) { actions?.selectTab?(tab.id) }
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
    /// The Mac's sidebar.
    let isSidebarOpen: Bool
    let toggleSidebar: @MainActor () -> Void
    /// The home's three places (Mac ⌘1–⌘3). Picking one closes what is open over it.
    var selectTab: (@MainActor (HomeTab) -> Void)? = nil
    /// The places as the bar names them: the first follows the person's default view.
    var tabs: [HomeTabItem] = []
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
