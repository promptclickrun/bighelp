import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct AgentHeroHeaderLayoutTests {
    /// The shell makes the chrome again on every update; only what it shows may redraw the chat.
    @Test func chromeIsTheSameWhenWhatItShowsIsTheSame() {
        var opened = 0
        let first = AgentHomeChrome(isEnabled: true, showsTabBar: true, onMenu: { opened += 1 },
                                    unreadTabs: [.feed], barTabs: [.sessions, .feed])
        let again = AgentHomeChrome(isEnabled: true, showsTabBar: true, onMenu: { opened += 2 },
                                    unreadTabs: [.feed], barTabs: [.sessions, .feed])
        #expect(first == again)
        var read = again
        read.unreadTabs = []
        #expect(first != read, "A dot going away still redraws the bar")
    }

    @Test func chatHomeUsesACompactIdentityPill() {
        let controller = UIHostingController(rootView:
            AgentHomeChatHeader(agentID: "default", displayName: "Atlas", imageURL: nil,
                                activity: .idle, groupIdentity: nil, options: AnyView(Color.clear),
                                chrome: AgentHomeChrome(), screenHeight: 852, beforeAction: {})
        )
        let size = controller.sizeThatFits(in: CGSize(width: 393, height: 852))
        #expect(size.height <= 54, "Chat mode should use Bots mode's single-row pill")
    }

    /// The chat's top inset is the header's height, so a status line that grew the header
    /// pushed every message down and back each time "Updating…" came and went.
    @Test(arguments: [DynamicTypeSize.large, .accessibility3])
    func statusLineKeepsTheHeaderHeight(_ typeSize: DynamicTypeSize) async {
        let idle = await height(status: nil, typeSize: typeSize)
        let updating = await height(status: "Updating…", typeSize: typeSize)
        #expect(idle > 0)
        #expect(idle == updating)
    }

    private func height(status: String?, typeSize: DynamicTypeSize) async -> CGFloat {
        let controller = UIHostingController(rootView:
            AgentHeroHeader(agentID: "default", displayName: "default", imageURL: nil,
                            status: status, onAvatarTap: {}, onNameTap: {})
                .environment(\.dynamicTypeSize, typeSize)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        await Task.yield()
        return controller.sizeThatFits(in: CGSize(width: 393, height: 852)).height
    }
}
