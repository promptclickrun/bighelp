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

    /// One home's chat chrome is a look of its own, and wins over the home look: the chat keeps no
    /// bar, side strip or ornament of tabs with it.
    @Test func pushedChatChromeKeepsNoTabsInTheChat() {
        var opened: [String] = []
        let pushed = AgentHomeChrome.pushedChat(onProfile: { opened.append($0) })
        #expect(pushed == AgentHomeChrome.pushedChat(onProfile: { _ in }))
        #expect(pushed != AgentHomeChrome())
        #expect(!pushed.keepsTabsInChat)
        pushed.onProfile("atlas")
        #expect(opened == ["atlas"])

        var home = AgentHomeChrome(isEnabled: true, showsTabBar: true, tabSelection: Binding.constant(AppTab.sessions))
        #expect(home.keepsTabsInChat)
        home.isPushedChat = true
        #expect(!home.keepsTabsInChat)
    }

    /// Back, the bot and ⋯ are one row, as in Bots mode. A new chat's To row is a row of its own
    /// under them: it adds its height and leaves the buttons where they are.
    @Test func aNewChatsToRowSitsUnderTheHeadersButtons() {
        func height(toRow: AnyView?) -> CGFloat {
            let pill = ChatAgentIdentityPill(agentID: "default", name: "Atlas", imageURL: nil)
            let controller = UIHostingController(rootView:
                ChatPushedHeader(identity: AnyView(pill), toRow: toRow, options: AnyView(Color.clear), onBack: {})
            )
            return controller.sizeThatFits(in: CGSize(width: 393, height: 852)).height
        }
        let plain = height(toRow: nil)
        #expect(plain > 0)
        #expect(plain <= 54)
        let withToRow = height(toRow: AnyView(Color.clear.frame(height: 48)))
        #expect(abs(withToRow - plain - 48) < 1)
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
