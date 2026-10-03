import SwiftUI
import WidgetKit

@main
struct BighelpLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        #if os(iOS)
        BighelpSessionLiveActivity()
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
    }
}
