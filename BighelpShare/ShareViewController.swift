import SwiftUI
import UIKit

/// The share sheet's entry point (`NSExtensionPrincipalClass`). It hands what was shared to
/// `ShareModel` and ends the request with Done or Cancel. It never opens bighelp: iOS supports
/// `NSExtensionContext.open` only in Today and iMessage extensions, so the saved screen tells
/// the person to open bighelp themselves.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Cancel and Done are the only ways out, so a half-read share is never left behind unsaid.
        isModalInPresentation = true

        let host = UIHostingController(rootView: ShareView(
            model: model,
            cancel: { [weak self] in self?.cancel() },
            done: { [weak self] in self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil) }
        ))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        model.start(items.flatMap { $0.attachments ?? [] })
    }

    private func cancel() {
        model.cancel()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
