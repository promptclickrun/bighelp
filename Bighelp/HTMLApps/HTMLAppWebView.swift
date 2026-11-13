import SwiftUI
import UIKit
import WebKit

/// An agent's app page, full screen (docs/HTML_APPS.md › The page). It loads from its own
/// `bighelp-app://<app id>/` origin, so it shares nothing with other apps or with bighelp, and may
/// load anything it asks for: the agent's page is shown as made. bighelp keeps only its own side
/// safe: links and new windows open outside, the page can't move itself elsewhere, the camera and
/// microphone are refused, and `window.bighelp` is the page's one way to reach the app.
struct HTMLAppWebView: UIViewRepresentable {
    static let scheme = HTMLAppNavigationPolicy.appScheme
    /// Every app's storage (each origin keeps its own), apart from the rest of bighelp's web views.
    static let dataStoreID = UUID(uuidString: "6B1F3C2A-8D4E-4F5A-9B6C-2E7D8A9F0B1C")!

    let appID: String
    let html: String
    let sendsAnswers: Bool
    /// The page's latest data as JSON text, given to `bighelp.onData` when it changes.
    let dataJSON: String?
    let colorScheme: ColorScheme
    /// The page's `sendAnswer`: true once the person sent it, false when they didn't.
    let onAnswer: @MainActor (HTMLAppAnswer) async -> Bool
    let onClose: @MainActor () -> Void

    static func url(appID: String) -> URL? { URL(string: "\(scheme)://\(appID)/") }

    @MainActor static let dataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)

    /// What erasing this phone's data removes: every app's storage.
    @MainActor static func eraseStorage() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func makeCoordinator() -> Coordinator { Coordinator(appID: appID) }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.parent = self
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.setURLSchemeHandler(HTMLAppSchemeHandler(appID: appID, html: html), forURLScheme: Self.scheme)
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: HTMLAppBridge.script, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: .page))
        content.addScriptMessageHandler(coordinator, contentWorld: .page, name: HTMLAppBridge.handlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        webView.accessibilityIdentifier = "html-app.page"
        #if DEBUG
        webView.isInspectable = true
        #endif
        coordinator.webView = webView
        coordinator.openURL = context.environment.openURL
        if let url = Self.url(appID: appID) { webView.load(URLRequest(url: url)) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.openURL = context.environment.openURL
        webView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        coordinator.deliver(dataJSON)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        // The content controller keeps its handler; letting go here lets the coordinator go too.
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        coordinator.finish()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
        let appID: String
        var parent: HTMLAppWebView?
        weak var webView: WKWebView?
        var openURL: OpenURLAction?
        private var isLoaded = false
        private var delivered: String?
        /// The data waiting for the page to load.
        private var pending: String?
        private var isFinished = false

        init(appID: String) {
            self.appID = appID
        }

        func finish() {
            isFinished = true
            parent = nil
        }

        /// Hands the page new data once it has loaded, and only when it changed.
        func deliver(_ json: String?) {
            guard let json, json != delivered else { return }
            guard isLoaded, let webView else { pending = json; return }
            delivered = json
            pending = nil
            Task {
                _ = try? await webView.callAsyncJavaScript("window.bighelp && window.bighelp.__deliver(json)",
                                                           arguments: ["json": json], contentWorld: .page)
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let decision = HTMLAppNavigationPolicy.decide(
                url: url, appID: appID, isMainFrame: action.targetFrame?.isMainFrame != false,
                navigationType: action.navigationType)
            switch decision {
            case .allowInPage:
                return .allow
            case .openOutside:
                // The page stays the app: a web link the person tapped opens outside bighelp.
                openURL?(url)
                return .cancel
            case .drop:
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            delivered = nil
            if let json = pending ?? parent?.dataJSON { deliver(json) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isLoaded = false
            webView.reload()
        }

        // MARK: Windows, prompts and permissions

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url,
               HTMLAppNavigationPolicy.decide(url: url, appID: appID, isMainFrame: true,
                                              navigationType: action.navigationType) == .openOutside {
                openURL?(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                     initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
            .deny
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo) async {
            await present(message, in: webView, cancels: false)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo) async -> Bool {
            await present(message, in: webView, cancels: true)
        }

        /// The page's `alert` and `confirm`, as iOS's own alert over the app.
        private func present(_ message: String, in webView: WKWebView, cancels: Bool) async -> Bool {
            guard var presenter = webView.window?.rootViewController else { return false }
            while let next = presenter.presentedViewController { presenter = next }
            return await withCheckedContinuation { continuation in
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                if cancels {
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
                }
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume(returning: true) })
                presenter.present(alert, animated: true)
            }
        }

        // MARK: window.bighelp

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard message.frameInfo.isMainFrame, !isFinished, let parent,
                  let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
                return (nil, "bighelp didn't understand that.")
            }
            switch kind {
            case "getData":
                return (parent.dataJSON ?? "null", nil)
            case "sendAnswer":
                guard parent.sendsAnswers else { return (nil, "This app can't send answers.") }
                guard let json = body["answer"] as? String, json.utf8.count <= HTMLAppBridge.maximumMessageBytes,
                      let answer = try? HTMLAppAnswer(json: json) else {
                    return (nil, "bighelp can't send that. Send text, or names with text, numbers, yes or no, or lists of text.")
                }
                return (await parent.onAnswer(answer), nil)
            case "close":
                parent.onClose()
                return (true, nil)
            default:
                return (nil, "bighelp doesn't know \(kind.prefix(40)).")
            }
        }
    }
}

/// Serves an app's page at its own origin. Nothing else is there: the page brings or fetches the rest.
@MainActor
final class HTMLAppSchemeHandler: NSObject, WKURLSchemeHandler {
    private let appID: String
    private let html: Data

    init(appID: String, html: String) {
        self.appID = appID
        self.html = Data(html.utf8)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let isPage = url.host() == appID && ["", "/", "/index.html"].contains(url.path())
        let body = isPage ? html : Data()
        let headers = ["Content-Type": isPage ? "text/html; charset=utf-8" : "text/plain",
                       "Content-Length": String(body.count), "Cache-Control": "no-store"]
        guard let response = HTTPURLResponse(url: url, statusCode: isPage ? 200 : 404,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// `window.bighelp`, the page's side of the app (docs/HTML_APPS.md › The page API).
enum HTMLAppBridge {
    static let handlerName = "bighelp"
    static let maximumMessageBytes = 65_536

    static let script = #"""
    (() => {
      if (window.bighelp) return;
      const post = (message) => window.webkit.messageHandlers.bighelp.postMessage(message);
      const parse = (text) => { try { return JSON.parse(text); } catch (error) { return null; } };
      const listeners = new Set();
      let latest = null;
      let hasLatest = false;
      Object.defineProperty(window, "bighelp", { configurable: false, writable: false, value: Object.freeze({
        version: 1,
        getData: async () => parse(await post({ kind: "getData" })),
        onData(listener) {
          if (typeof listener !== "function") throw new TypeError("bighelp.onData takes a function");
          listeners.add(listener);
          if (hasLatest) queueMicrotask(() => listener(latest));
          return () => listeners.delete(listener);
        },
        sendAnswer: async (answer) => {
          let value;
          if (typeof answer === "string") value = answer;
          else if (answer && typeof answer === "object" && !Array.isArray(answer)) value = Object.entries(answer);
          else throw new TypeError("bighelp.sendAnswer takes text or an object");
          return post({ kind: "sendAnswer", answer: JSON.stringify(value) });
        },
        close: () => { post({ kind: "close" }); },
        __deliver(text) {
          latest = parse(text);
          hasLatest = true;
          for (const listener of [...listeners]) {
            try { listener(latest); } catch (error) { console.error(error); }
          }
        },
      }) });
      // A page without a viewport would draw at desktop width on a phone.
      document.addEventListener("DOMContentLoaded", () => {
        if (document.querySelector('meta[name="viewport"]')) return;
        const meta = document.createElement("meta");
        meta.name = "viewport";
        meta.content = "width=device-width, initial-scale=1";
        document.head.appendChild(meta);
      });
    })();
    """#
}
