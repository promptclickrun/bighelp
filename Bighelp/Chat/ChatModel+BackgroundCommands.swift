import SwiftUI

/// The chat's background commands: what the "In the background" chip counts beside its subagents,
/// and what its sheet lists and stops.
extension ChatModel {
    /// One read of `process.list`. False when this chat can't be asked (no live connection, a
    /// group chat, or a Hermes without the method), so its reader stops until the next connection.
    @discardableResult
    func refreshBackgroundCommands(now: Date = .now) async -> Bool {
        guard !referenceOwnerRetired, !isBotMode, let native = nativeConversationClient else { return false }
        let connection = ObjectIdentifier(native)
        guard backgroundCommandsUnsupported != connection else { return false }
        do {
            let commands = try await native.backgroundCommands(now: now)
            guard nativeConversationClient === native else { return true }
            show(commands)
        } catch DirectHermesError.rpcRejected(let code, _) where code == -32601 {
            backgroundCommandsUnsupported = connection
            show([])
            return false
        } catch {
            // A passing failure (reconnecting, a slow answer) keeps what the chat shows.
        }
        return true
    }

    private func show(_ commands: [ChatBackgroundCommand]) {
        if commands != backgroundCommands { backgroundCommands = commands }
        let running = commands.count(where: \.isRunning)
        if running != runningBackgroundCommands { runningBackgroundCommands = running }
        if commands.isEmpty == hasBackgroundCommands { hasBackgroundCommands = !commands.isEmpty }
    }

    /// Stops one, then reads the list again. False when it had already ended or Hermes didn't stop it.
    func stopBackgroundCommand(_ id: String) async -> Bool {
        guard let native = nativeConversationClient else { return false }
        let stopped = (try? await native.stopBackgroundCommand(id: id)) ?? false
        await refreshBackgroundCommands()
        return stopped
    }
}

/// Reads the chat's background commands (`process.list`) while it's on screen and the app is
/// active: every few seconds while one runs, less often otherwise, and again when a turn ends or
/// the chat gets a new connection.
struct ChatBackgroundCommandsWatch: ViewModifier {
    let model: ChatModel
    @Environment(\.scenePhase) private var scenePhase

    static let runningInterval: Duration = .seconds(4)
    static let quietInterval: Duration = .seconds(15)

    private struct Key: Equatable {
        let connection: ObjectIdentifier?
        let isActive: Bool
        let isSending: Bool
    }

    func body(content: Content) -> some View {
        content.task(id: Key(connection: model.nativeConversationClient.map(ObjectIdentifier.init),
                             isActive: scenePhase == .active, isSending: model.isSending)) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled, await model.refreshBackgroundCommands() {
                try? await Task.sleep(for: model.runningBackgroundCommands > 0 ? Self.runningInterval : Self.quietInterval)
            }
        }
    }
}
