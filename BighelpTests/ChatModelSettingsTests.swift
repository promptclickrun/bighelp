import Testing
@testable import Bighelp

/// Model settings sends each choice as it's made: the newest Thinking level wins, and the levels
/// keep their order whatever order a computer lists them in.
@MainActor
struct ChatModelSettingsTests {
    @Test(.timeLimit(.minutes(1)))
    func theNewestLevelWinsAndEachGoesOnce() async {
        let sender = ThinkingLevelSender()
        let host = SlowHost()
        let send: @MainActor (String) async -> Bool = { level in
            host.sent.append(level)
            // The first level is still out while two more are picked.
            if host.sent.count == 1 { await withCheckedContinuation { host.answer = $0 } }
            return true
        }
        sender.request("low", send: send)
        #expect(sender.pendingLevel == "low")
        await waitUntil { host.answer != nil }
        sender.request("high", send: send)
        sender.request("max", send: send)
        #expect(sender.pendingLevel == "max")
        host.answer?.resume()
        await waitUntil { !sender.isSending }
        #expect(host.sent == ["low", "max"])
        #expect(sender.pendingLevel == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedLevelClearsSoTheChatsOwnShows() async {
        let sender = ThinkingLevelSender()
        sender.request("ultra") { _ in false }
        #expect(sender.pendingLevel == "ultra")
        await waitUntil { !sender.isSending }
        #expect(sender.pendingLevel == nil)
    }

    @Test func levelsRunLowestFirstWithoutTheAutomaticOne() {
        var levels = ChatThinkingLevels()
        #expect(!levels.isKnown)
        levels.take([("high", "High"), ("reset", "Auto"), ("none", "Off"), ("turbo", "Turbo"), ("low", "Low")])
        #expect(levels.isKnown)
        #expect(levels.offersAutomatic)
        // A level bighelp has no name for keeps the computer's, after the ones it knows.
        #expect(levels.levels.map(\.value) == ["none", "low", "high", "turbo"])
        #expect(levels.levels.map(\.shortTitle) == ["Off", "Low", "High", "Turbo"])
    }

    @Test func aModelWithNoLevelsIsKnownToHaveNone() {
        var levels = ChatThinkingLevels()
        levels.take([])
        #expect(levels.isKnown)
        #expect(levels.levels.isEmpty)
        #expect(!levels.offersAutomatic)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A computer that takes its time over the first level it's sent.
@MainActor
private final class SlowHost {
    var sent: [String] = []
    var answer: CheckedContinuation<Void, Never>?
}
