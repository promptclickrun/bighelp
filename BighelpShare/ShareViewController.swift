import SwiftUI
import UIKit

/// The share sheet's entry point. It reads what was shared, then hands the sheet to
/// SwiftUI; the `NSExtensionPrincipalClass` in Info.plist names this class.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let context = extensionContext
        Task { @MainActor [weak self] in
            let input = await ShareInputReader.read(from: context)
            guard let self else { return }
            let model = ShareModel(input: input)
            self.model = model
            let root = ShareView(
                model: model,
                complete: { [weak self] in self?.finish() },
                openChat: { [weak self] chatID in self?.openChat(chatID) }
            )
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .systemBackground
            self.addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            ])
            host.didMove(toParent: self)
        }
    }

    /// Returns what was shared to the app that sent it, which is what a share extension
    /// owes its callers when nothing was written.
    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The app already routes `loopdy://agent-chat`; the chat the sheet just wrote is
    /// where that link should land, so the person can see the turn running.
    private func openChat(_ chatID: String) {
        guard var components = URLComponents(string: "loopdy://agent-chat") else { return finish() }
        if let agent = model?.agent?.id {
            components.queryItems = [URLQueryItem(name: "agent", value: agent)]
        }
        guard let url = components.url else { return finish() }
        let context = extensionContext
        context?.open(url) { [weak self] _ in self?.finish() }
    }
}
