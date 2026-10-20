import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct AgentHeroHeaderLayoutTests {
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
