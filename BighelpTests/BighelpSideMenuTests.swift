import Observation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

@MainActor
@Suite(.serialized)
struct BighelpSideMenuTests {
    /// The Mac title bar's sidebar button does nothing while there's no sidebar
    /// to show (first-run setup), then each click asks the shell to toggle it.
    @Test func titleBarRequestsToggleOnlyWhenThereIsASidebar() {
        let menu = BighelpSideMenu()
        menu.requestToggle()
        #expect(menu.toggleRequests == 0)
        menu.canToggle = true
        menu.requestToggle()
        menu.requestToggle()
        #expect(menu.toggleRequests == 2)
    }

    @Test(arguments: [true, false])
    func openMenuFollowsHostReadinessWithoutBeingReopened(_ sidebar: Bool) async throws {
        let source = MenuSource()
        let menu = BighelpSideMenu()
        let controller = UIHostingController(rootView: MenuHarness(source: source, menu: menu, sidebar: sidebar))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        window.rootViewController = controller
        window.isHidden = false
        defer { menu.hide(); window.isHidden = true; window.rootViewController = nil }

        func settle(ready: Bool, host: String = "First host") async throws {
            for _ in 0..<100 {
                controller.view.layoutIfNeeded()
                if source.renderedReady == ready, source.renderedHost == host { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle(ready: false)
        #expect(menu.isOpen == sidebar)
        #expect(source.renderedReady == false)
        source.isReady = true
        try await settle(ready: true)
        #expect(menu.isOpen == sidebar)
        #expect(source.renderedReady == true)
        source.isReady = false
        try await settle(ready: false)
        #expect(menu.isOpen == sidebar)
        #expect(source.renderedReady == false)
        #expect(source.renderedHost == "First host")
        source.host = MenuHost(name: "Second host")
        try await settle(ready: false, host: "Second host")
        #expect(menu.isOpen == sidebar)
        #expect(source.renderedHost == "Second host")
    }

    @MainActor @Observable final class MenuSource {
        var isReady = false
        var host = MenuHost(name: "First host")
        @ObservationIgnored var renderedReady: Bool?
        @ObservationIgnored var renderedHost: String?
    }

    final class MenuHost {
        let name: String
        init(name: String) { self.name = name }
    }

    private struct MenuHarness: View {
        let source: MenuSource
        let menu: BighelpSideMenu
        let sidebar: Bool
        @State private var isPresented = true

        var body: some View {
            let host = source.host
            HStack {
                if let panel = menu.content { panel }
                Text("Chat")
                    .modifier(HomeMenuPresentation(isPresented: $isPresented, onDismiss: {},
                                                   contentID: ObjectIdentifier(host)) {
                        MenuPanel(ready: source.isReady, host: host.name, source: source)
                    })
            }
            .environment(\.bighelpSideMenu, sidebar ? menu : nil)
            .environment(\.horizontalSizeClass, .regular)
        }
    }

    private struct MenuPanel: View {
        let ready: Bool
        let host: String
        let source: MenuSource

        var body: some View {
            Text(ready ? "Projects, Workflows, Usage" : "Settings")
                .onChange(of: ready, initial: true) { _, value in source.renderedReady = value }
                .onChange(of: host, initial: true) { _, value in source.renderedHost = value }
        }
    }

    @Test func showingAndHidingReportsTheCloseOnce() {
        let menu = BighelpSideMenu()
        var closes = 0
        menu.show(AnyView(Text("Menu"))) { closes += 1 }
        #expect(menu.isOpen)
        menu.hide()
        menu.hide()
        #expect(!menu.isOpen)
        #expect(closes == 1)
    }
}
