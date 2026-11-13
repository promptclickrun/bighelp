import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct WorkspaceManagementLayoutTests {
    @Test(arguments: [WorkspaceDestination.projects, .models, .files, .memory, .keys, .webhooks])
    func managementViewsMountTheirRealFixtureContent(_ destination: WorkspaceDestination) async {
        let store = WorkspaceManagementStore(hostName: "Demo Hermes", profileName: "Research",
            client: FixtureWorkspaceManagementClient(), isCurrent: { true })
        await store.load(destination)
        let controller = UIHostingController(rootView:
            NavigationStack { WorkspaceManagementView(store: store, destination: destination) }
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        controller.view.layoutIfNeeded()
        #expect(store.content != nil)
        #expect(store.errorMessage == nil)
        #expect(allFramesAreFinite(controller.view))
    }

    private func allFramesAreFinite(_ view: UIView) -> Bool {
        let rect = view.frame
        return rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && view.subviews.allSatisfy(allFramesAreFinite)
    }
}
