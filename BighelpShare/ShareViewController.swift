import SwiftUI
import UIKit

/// The share sheet's entry point (`NSExtensionPrincipalClass`). It hands what was shared to
/// `ShareModel` and ends the request with Send or Cancel. It never opens bighelp: iOS supports
/// `NSExtensionContext.open` only in Today and iMessage extensions. Send saves the share and asks
/// iOS to wake bighelp, which sends it to the default bot (#1069).
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Cancel and Send are the only ways out, so a half-read share is never left behind unsaid.
        isModalInPresentation = true

        let host = UIHostingController(rootView: ShareView(
            model: model,
            cancel: { [weak self] in self?.cancel() },
            done: { [weak self] in self?.finish() }
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

    /// The share is saved and iOS was asked to wake bighelp. The sheet's process then has to go: iOS
    /// starts bighelp for the wake request only when nothing of the sheet is left to take its result,
    /// and iOS keeps a finished sheet's process around (a minute or more). Nothing is lost by
    /// leaving: the share is on disk and the request belongs to the system by now.
    private func finish() {
        extensionContext?.completeRequest(returningItems: []) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
        }
    }

    private func cancel() {
        model.cancel()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
