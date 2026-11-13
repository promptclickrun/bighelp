import Foundation
import Testing
import WebKit
@testable import Bighelp

/// Where an agent's app page may go (`HTMLAppNavigationPolicy`): a page leaves for the outside only
/// as a web link the person tapped. Everything else goes nowhere.
struct HTMLAppNavigationPolicyTests {
    static let appID = "a_0123456789abcdef0123456789abcdef"
    static let otherID = "a_ffffffffffffffffffffffffffffffff"

    private func decide(_ text: String, mainFrame: Bool = true,
                        _ type: WKNavigationType = .other) -> HTMLAppNavigationPolicy.Decision {
        HTMLAppNavigationPolicy.decide(url: URL(string: text)!, appID: Self.appID, isMainFrame: mainFrame,
                                       navigationType: type)
    }

    @Test(arguments: [
        "https://example.com/page", "http://example.com", "HTTPS://Example.com/x",
    ])
    func aTappedWebLinkOpensOutside(_ link: String) {
        #expect(decide(link, .linkActivated) == .openOutside)
    }

    /// A script's own `location` or `window.open`, a form, a reload: no tap, nowhere to go.
    @Test(arguments: [WKNavigationType.other, .formSubmitted, .formResubmitted, .reload, .backForward])
    func aWebAddressWithoutATapGoesNowhere(_ type: WKNavigationType) {
        #expect(decide("https://example.com/page", type) == .drop)
    }

    @Test(arguments: [
        "loopdy://voice?agent=default", "LOOPDY://voice", "app.loopdy.mobile://settings", "tel:5550100",
        "sms:5550100", "shortcuts://run-shortcut?name=x", "mailto:a@example.com", "file:///etc/hosts",
        "data:text/html,hi", "javascript:alert(1)", "about:blank", "blob:https://example.com/1",
        "itms-apps://apps.apple.com/app/id1", "facetime://5550100", "x-apple-reminderkit://",
    ])
    func nothingButWebLinksLeavesThePageEvenWithATap(_ link: String) {
        #expect(decide(link, .linkActivated) == .drop)
        #expect(decide(link, .other) == .drop)
    }

    @Test func thePageStaysOnItsOwnOrigin() {
        #expect(decide("bighelp-app://\(Self.appID)/") == .allowInPage)
        #expect(decide("bighelp-app://\(Self.appID)/index.html#top", .linkActivated) == .allowInPage)
        #expect(decide("bighelp-app://\(Self.appID)/", .reload) == .allowInPage)
        // Another app's origin, or none, is never reached.
        #expect(decide("bighelp-app://\(Self.otherID)/", .linkActivated) == .drop)
        #expect(decide("bighelp-app://\(Self.otherID)/") == .drop)
        #expect(decide("bighelp-app:///") == .drop)
        #expect(decide("BIGHELP-APP://\(Self.otherID)/", .linkActivated) == .drop)
    }

    @Test func framesInsideThePageLoadAsTheyAskButNeverReachTheApp() {
        #expect(decide("https://example.com/embed", mainFrame: false) == .allowInPage)
        #expect(decide("about:blank", mainFrame: false) == .allowInPage)
        #expect(decide("data:text/html,hi", mainFrame: false) == .allowInPage)
        #expect(decide("blob:https://example.com/1", mainFrame: false) == .allowInPage)
        #expect(decide("bighelp-app://\(Self.appID)/frame.html", mainFrame: false) == .allowInPage)
        #expect(decide("bighelp-app://\(Self.otherID)/", mainFrame: false) == .drop)
        for link in ["loopdy://voice", "app.loopdy.mobile://x", "tel:5550100", "shortcuts://x", "file:///etc/hosts"] {
            #expect(decide(link, mainFrame: false, .linkActivated) == .drop)
        }
    }
}
