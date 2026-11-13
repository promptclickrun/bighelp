import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct AgentHeroHeaderLayoutTests {
    /// The shell makes the chrome again on every update; only what it shows may redraw the chat.
    @Test func pushedChatChromeIsTheSameWhateverItsAction() {
        var opened: [String] = []
        let pushed = AgentHomeChrome.pushedChat(onProfile: { opened.append($0) })
        #expect(pushed == AgentHomeChrome.pushedChat(onProfile: { _ in }))
        #expect(pushed != AgentHomeChrome())
        pushed.onProfile("atlas")
        #expect(opened == ["atlas"])
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
