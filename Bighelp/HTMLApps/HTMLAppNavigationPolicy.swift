import Foundation
import WebKit

/// Where a navigation in an agent's app page may go. The page is untrusted (a routine can rewrite
/// a space's page with nobody watching), so the app is strict: a page leaves for the outside only as
/// a web link the person tapped. It never reaches bighelp's own links (`loopdy:`,
/// `app.loopdy.mobile:`), another app's scheme (`tel:`, `sms:`, `shortcuts:`), a file or another
/// page's `bighelp-app://` origin.
enum HTMLAppNavigationPolicy {
    enum Decision: Equatable {
        /// The page loads it.
        case allowInPage
        /// The person's tap on a web link: iOS opens it outside bighelp.
        case openOutside
        /// Nothing happens.
        case drop
    }

    /// The scheme every app page loads from (`HTMLAppWebView.scheme`).
    static let appScheme = "bighelp-app"

    /// `isMainFrame` is false for a frame inside the page. A `window.open` or `target="_blank"` link
    /// asks as a main-frame navigation. A script's own `location` or `window.open` is `.other` and
    /// goes nowhere. `.linkActivated` alone is not the person's tap: WebKit reports it for a link a
    /// script clicked too (`element.click()`, a made-up click event). So a link also needs
    /// `personTapped`: the tap seen where the page can't fake it (`HTMLAppLinkTaps`).
    static func decide(url: URL, appID: String, isMainFrame: Bool, navigationType: WKNavigationType,
                       personTapped: Bool) -> Decision {
        guard let scheme = url.scheme?.lowercased() else { return .drop }
        if scheme == appScheme {
            return url.host() == appID ? .allowInPage : .drop
        }
        let isWeb = scheme == "http" || scheme == "https"
        if isMainFrame {
            return isWeb && navigationType == .linkActivated && personTapped ? .openOutside : .drop
        }
        // Frames inside the page, and blank documents, load as the page asks.
        return isWeb || scheme == "about" || scheme == "data" || scheme == "blob" ? .allowInPage : .drop
    }
}

/// The person's own taps on links in an agent's page. A script in a world of its own, which the
/// page's scripts can't reach, listens for clicks and reports only the ones the browser marks as
/// the person's (`isTrusted`): a tap, a pointer click, a key on a focused link, an assistive
/// technology's activation. A click a script makes is never trusted, and the page can't post to this
/// world's handler. A tap stands only for the address it was on, and only for a moment.
@MainActor
final class HTMLAppLinkTaps: NSObject, WKScriptMessageHandler {
    static let handlerName = "bighelpLinkTap"
    static let world = WKContentWorld.world(name: "bighelp.link-taps")
    /// How long a tap stands for the navigation it starts.
    static let lifetime: TimeInterval = 2
    private static let maximumAddressBytes = 8_192

    static let script = #"""
    (() => {
      window.addEventListener("click", (event) => {
        if (!event.isTrusted) return;
        const start = event.target && event.target.nodeType === 1 ? event.target : event.target && event.target.parentElement;
        const link = start && start.closest ? start.closest("a[href], area[href]") : null;
        if (link && link.href) window.webkit.messageHandlers.bighelpLinkTap.postMessage(String(link.href));
      }, true);
    })();
    """#

    private var last: (address: String, at: Date)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let address = message.body as? String else { return }
        note(address)
    }

    /// The person tapped a link to `address`.
    func note(_ address: String, at time: Date = Date()) {
        guard address.utf8.count <= Self.maximumAddressBytes, let url = URL(string: address) else { return }
        last = (url.absoluteString, time)
    }

    /// True once, for the navigation the person's tap started: the same address, moments later.
    func take(for url: URL, at time: Date = Date()) -> Bool {
        guard let last, last.address == url.absoluteString else { return false }
        self.last = nil
        let age = time.timeIntervalSince(last.at)
        return age >= 0 && age <= Self.lifetime
    }

    /// The same, waiting a moment for the tap's own report: it and the navigation it starts come
    /// from the page's process one after the other, and the report must not lose that race.
    func takeWaiting(for url: URL) async -> Bool {
        for _ in 0..<6 {
            if take(for: url) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return take(for: url)
    }
}
