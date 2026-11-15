import SwiftUI
import Testing
import UIKit
import WebKit
@testable import Bighelp

/// An agent's page opens a web address outside Bighelp only when the person taps a link. A script
/// that clicks a link for them must open nothing. The page here runs in the app's own web view.
@MainActor
struct HTMLAppLinkTapTests {
    @MainActor
    private final class Seen {
        var opened: [URL] = []
        var didClose = false
    }

    /// Runs `script` in an app page with one web link (`#out`), waits until the page says it is done
    /// (`bighelp.close()`), and returns what the page tried to open outside.
    private func opened(byPageScript script: String, linkAttributes: String = "") async throws -> [URL] {
        let seen = Seen()
        let html = """
        <!doctype html><html><body>
        <a id="out" href="https://example.com/taken" \(linkAttributes)>Out</a>
        <script>
        \(script)
        setTimeout(() => window.bighelp.close(), 600);
        </script></body></html>
        """
        let page = HTMLAppWebView(
            appID: "a_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())", html: html,
            sendsAnswers: false, dataJSON: nil, colorScheme: .light,
            onAnswer: { _ in false }, onClose: { seen.didClose = true }
        )
        .environment(\.openURL, OpenURLAction { url in
            seen.opened.append(url)
            return .handled
        })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.rootViewController = UIHostingController(rootView: page)
        window.isHidden = false
        defer { window.isHidden = true }
        // The page ran its script: without this, "nothing opened" could mean nothing loaded.
        for _ in 0..<200 where !seen.didClose { try await Task.sleep(for: .milliseconds(100)) }
        #expect(seen.didClose, "The page loaded and ran its script")
        // Room for a navigation the click started to reach the app.
        try await Task.sleep(for: .milliseconds(500))
        return seen.opened
    }

    @Test(.timeLimit(.minutes(1))) func aScriptsClickOnALinkOpensNothingOutside() async throws {
        let opened = try await opened(byPageScript: #"document.getElementById("out").click();"#)
        #expect(opened.isEmpty, "A script clicked the link, not the person: \(opened)")
    }

    @Test(.timeLimit(.minutes(1))) func aMadeUpClickEventOpensNothingOutside() async throws {
        let opened = try await opened(byPageScript: #"""
        document.getElementById("out").dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
        """#)
        #expect(opened.isEmpty, "A script made the click, not the person: \(opened)")
    }

    @Test(.timeLimit(.minutes(1))) func aScriptsClickOnALinkToANewWindowOpensNothingOutside() async throws {
        let opened = try await opened(byPageScript: #"document.getElementById("out").click();"#,
                                      linkAttributes: #"target="_blank""#)
        #expect(opened.isEmpty, "A script clicked the link, not the person: \(opened)")
    }
}
