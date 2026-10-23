import SwiftUI
import WidgetKit

@main
struct BighelpLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        #if os(iOS)
        BighelpSessionLiveActivity()
        #endif
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            BighelpAlarmLiveActivity()
        }
        #endif
        BighelpAgentWidget()
        BighelpActiveSessionsWidget()
        BighelpScheduledTasksWidget()
        BighelpNewChatWidget()
        BighelpActivityFeedWidget()
        BighelpKanbanWidget()
        BighelpFeedWidget()
        BighelpIdeasWidget()
        BighelpGoalsWidget()
        BighelpPinnedAgentsWidget()
        BighelpBotsWidget()
        BighelpUsageWidget()
        BighelpWorkflowsWidget()
    }
}
