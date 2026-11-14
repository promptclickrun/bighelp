#if os(visionOS)
import SwiftUI

/// Vision Pro opens Kanban in its own glass window beside bighelp, so the
/// board stays in the room while you chat. Look at a card, pinch and drag it
/// to another lane.
@MainActor @Observable
final class KanbanWindowCoordinator {
    static let shared = KanbanWindowCoordinator()
    static let windowID = "kanban"

    private(set) var model: KanbanBoardModel?
    private(set) var taskID: String?
    private(set) var generation = 0

    /// XCUITest can't touch a second window on Vision Pro, so UI tests of the
    /// pinch-drag open the same board inside bighelp's own window.
    static var opensInMainWindowForTests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-test-kanban-main-window")
        #else
        false
        #endif
    }

    func show(_ model: KanbanBoardModel, taskID: String?) {
        self.model = model
        self.taskID = taskID
        generation &+= 1
    }
}

struct KanbanWindowScene: Scene {
    let settings: SettingsStore
    let companion: CompanionStore
    let companionAgentScope: String

    var body: some Scene {
        WindowGroup(id: KanbanWindowCoordinator.windowID) {
            KanbanWindowRoot(settings: settings)
                .modifier(SpatialSceneEnvironment(settings: settings, companion: companion,
                                                  companionAgentScope: companionAgentScope))
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // Wide enough for all five lanes at once. visionOS opens it where you're
        // looking; move it anywhere in the room with the bar underneath.
        .defaultSize(width: 1_640, height: 940)
    }
}

struct KanbanWindowRoot: View {
    let settings: SettingsStore
    private let coordinator = KanbanWindowCoordinator.shared

    var body: some View {
        NavigationStack {
            if let model = coordinator.model {
                KanbanScreen(model: model, isNerdMode: settings.nerdModeEnabled, initialTaskID: coordinator.taskID)
                    .id(coordinator.generation)
            } else {
                ContentUnavailableView("Open Kanban from Bighelp", systemImage: "rectangle.split.3x1",
                                       description: Text("Choose Kanban in Bighelp's menu to bring your board here."))
            }
        }
        .accessibilityIdentifier("kanban.window")
    }
}
#endif
