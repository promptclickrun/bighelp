#if DEBUG
import UIKit

/// Debug builds only: `-test-shortcut-ask <gateway name>` runs Ask an agent's own steps
/// (pick the gateway, then send and wait) a few seconds after launch, and shows what came
/// back in an alert. XCUITest can't drive a Shortcut through to its answer in the
/// simulator (bighelp is suspended behind Shortcuts), so ShortcutGatewaySwitchHostUITests
/// checks the gateway switch this way.
enum BighelpShortcutAskProbe {
    @MainActor static func runIfRequested(_ service: BighelpShortcutService) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-test-shortcut-ask"), arguments.indices.contains(index + 1) else {
            return
        }
        let gatewayName = arguments[index + 1]
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            let answer: String
            do {
                try service.useGateway(service.availableGateways().first { $0.name == gatewayName }?.id)
                let result = try await service.send(BighelpShortcutChatRequest(
                    message: "Say hello in five words.", agentID: nil, model: nil, reasoning: .automatic,
                    attachments: [], waitForResponse: true))
                switch result.delivery {
                case .completed(let response): answer = response
                case .queued: answer = "Queued without an answer"
                }
            } catch {
                answer = "Failed: \(error.localizedDescription)"
            }
            show(answer)
        }
    }

    @MainActor private static func show(_ answer: String) {
        let alert = UIAlertController(title: "Ask an agent", message: answer, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?
            .rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(alert, animated: false)
    }
}
#endif
