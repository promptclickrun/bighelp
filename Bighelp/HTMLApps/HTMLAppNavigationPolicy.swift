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
    /// asks as a main-frame navigation. WebKit gives no public "user-initiated" flag, so
    /// `.linkActivated` (a tap on a link) is what counts as the person's tap; a script's own
    /// `location` or `window.open` is `.other` and goes nowhere.
    static func decide(url: URL, appID: String, isMainFrame: Bool, navigationType: WKNavigationType) -> Decision {
        guard let scheme = url.scheme?.lowercased() else { return .drop }
        if scheme == appScheme {
            return url.host() == appID ? .allowInPage : .drop
        }
        let isWeb = scheme == "http" || scheme == "https"
        if isMainFrame {
            return isWeb && navigationType == .linkActivated ? .openOutside : .drop
        }
        // Frames inside the page, and blank documents, load as the page asks.
        return isWeb || scheme == "about" || scheme == "data" || scheme == "blob" ? .allowInPage : .drop
    }
}
