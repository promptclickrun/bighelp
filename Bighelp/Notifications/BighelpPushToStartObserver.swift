import BuzzKit
import Foundation
#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Watches the app's push-to-start token (iOS 17.2 and later) and hands each one on. Registration
/// only: nothing starts a Live Activity from it yet. BuzzKit watches the same stream for itself;
/// this one opens through the same serial lane (`ActivityKitSerialAccess`), because ActivityKit can
/// deadlock when several threads open token streams at once. Vision Pro and the Mac have no Live
/// Activities, so there it never starts.
@MainActor
final class BighelpPushToStartObserver {
    static let shared = BighelpPushToStartObserver()

    private var task: Task<Void, Never>?
    private var handler: (@MainActor (Data) async -> Void)?

    /// The token the system has now. Apple documents the stream as the way to hear changes but not that a new
    /// iteration repeats the current token, so the registrar reads it here at each foreground as well.
    func currentToken() async -> Data? {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 17.2, *) {
            return await ActivityKitSerialAccess.read { Activity<LoopdySessionActivityAttributes>.pushToStartToken }
        }
        #endif
        return nil
    }

    /// Starts watching once per launch. A later call only replaces who hears the tokens.
    func start(_ handler: @escaping @MainActor (Data) async -> Void) {
        self.handler = handler
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        guard task == nil else { return }
        if #available(iOS 17.2, *) {
            task = Task {
                let tokens = await ActivityKitSerialAccess.iterate {
                    Activity<LoopdySessionActivityAttributes>.pushToStartTokenUpdates
                }
                while let token = await tokens.next() {
                    await self.handler?(token)
                }
            }
        }
        #endif
    }
}
