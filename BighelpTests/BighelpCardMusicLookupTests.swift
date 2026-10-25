import Foundation
import Testing
@testable import Bighelp

/// A music card's picture lookup when MusicKit's service doesn't answer: a chat full of cards
/// must neither hang the app nor ask a service that isn't there once per card.
@MainActor
struct BighelpCardMusicLookupTests {
    /// What the fake MusicKit saw, from any thread.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0, _running = 0, _peak = 0, _onMain = false
        var count: Int { lock.withLock { _count } }
        var peak: Int { lock.withLock { _peak } }
        var sawMainThread: Bool { lock.withLock { _onMain } }
        func begin() {
            lock.withLock {
                _count += 1
                _running += 1
                _peak = max(_peak, _running)
                if Thread.isMainThread { _onMain = true }
            }
        }
        func end() { lock.withLock { _running -= 1 } }
    }

    private func card(_ number: Int, kind: String = "song") throws -> BighelpCardMusic {
        try BighelpCardMusic(props: [
            "kind": .string(kind), "title": .string("Sample Song \(number) \(UUID().uuidString)"),
            "artist": .string("The Placeholders"), "music_id": .string("\(1_000 + number)"),
        ])
    }

    private func store(
        timeout: TimeInterval = 5, publicLookups: Calls = Calls(),
        musicKit: @escaping BighelpCardMusicArtworkStore.MusicKitLookup
    ) -> BighelpCardMusicArtworkStore {
        BighelpCardMusicArtworkStore(musicKit: musicKit, publicLookup: { _, _ in
            publicLookups.begin()
            publicLookups.end()
            return nil
        }, musicKitTimeout: timeout)
    }

    private func ask(_ store: BighelpCardMusicArtworkStore, _ music: BighelpCardMusic) async
        -> BighelpCardMusicArtworkStore.Found? {
        await store.artwork(for: music, key: BighelpCardMusicLookup.cacheKey(for: music), usesMusicKit: true)
    }

    // MARK: Streaming

    /// The card streams in as a pending card, and the real card (and its lookup key) appears once.
    @Test func aStreamingMusicCardDrawsOnceAfterTheFenceCloses() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(BighelpCardEnvelope.card(BighelpCardDemoFixtures.objects)),
                          as: UTF8.self)
        let text = "Here you go:\n\n```loopdy-card\n\(json)\n```\n\nEnjoy it."
        let characters = Array(text)
        var cardsSeen = 0
        var keys = Set<String>()
        var lastWasCard = false
        for count in stride(from: 1, through: characters.count, by: 5) {
            let projection = ChatCardMessageProjection(
                source: String(characters.prefix(count)), role: .assistant, isStreaming: count < characters.count)
            let cards = projection.segments.compactMap { segment -> BighelpCardDocument? in
                if case .card(.card(let card)) = segment { card } else { nil }
            }
            if !cards.isEmpty && !lastWasCard { cardsSeen += 1 }
            lastWasCard = !cards.isEmpty
            for card in cards {
                for element in card.elements.values {
                    guard let object = element.object, object["type"]?.string == "music",
                          let props = object["props"]?.object else { continue }
                    keys.insert(BighelpCardMusicLookup.cacheKey(for: try BighelpCardMusic(props: props)))
                }
            }
        }
        #expect(cardsSeen == 1, "The card appears once, when its fence closes, never as partial cards")
        #expect(keys.count == 1, "Every redraw after that asks for the same picture")
    }

    // MARK: Service unavailable

    @Test func lookupsRunOffTheMainThreadAFewAtATime() async throws {
        let calls = Calls()
        let release = AsyncGate()
        let store = store { _ in
            calls.begin()
            defer { calls.end() }
            await release.wait()
            return nil
        }
        let cards = try (0..<12).map { try card($0) }
        let tasks = cards.map { music in Task { await ask(store, music) } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(BighelpCardMusicArtworkStore.maximumLookups <= 4)
        #expect(calls.peak == BighelpCardMusicArtworkStore.maximumLookups, "A chat of cards never asks MusicKit all at once (peak \(calls.peak))")
        await release.open()
        for task in tasks { _ = await task.value }
        #expect(calls.count == 12)
        #expect(!calls.sawMainThread, "MusicKit is never asked on the main thread")
    }

    @Test func aServiceThatCannotBeReachedIsAskedOnceThenLeftAlone() async throws {
        let calls = Calls()
        let publicLookups = Calls()
        let store = store(publicLookups: publicLookups) { _ in
            calls.begin()
            defer { calls.end() }
            throw URLError(.notConnectedToInternet)
        }
        for number in 0..<6 { _ = try await ask(store, card(number)) }
        #expect(calls.count == 1, "After MusicKit's service fails, the other cards skip it")
        #expect(publicLookups.count == 6, "Every card still tries Apple's public lookup")
        #expect(store.musicKitIsPaused)
    }

    @Test func aFailureThatIsNotTheServiceDoesNotPauseMusicKit() async throws {
        let calls = Calls()
        let store = store { _ in
            calls.begin()
            defer { calls.end() }
            throw NSError(domain: "Fixture", code: 1)
        }
        for number in 0..<3 { _ = try await ask(store, card(number)) }
        #expect(calls.count == 3)
        #expect(!store.musicKitIsPaused)
    }

    @Test func aRequestThatNeverAnswersGivesUpAndPausesMusicKit() async throws {
        let calls = Calls()
        let store = store(timeout: 0.2) { _ in
            calls.begin()
            // Ignores cancellation, as a request waiting on a dead service can.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return nil
        }
        let started = Date()
        let found = try await ask(store, card(1))
        #expect(found == nil)
        #expect(Date().timeIntervalSince(started) < 3, "The card gives up instead of waiting for ever")
        #expect(store.musicKitIsPaused)
        _ = try await ask(store, card(2))
        #expect(calls.count == 1)
    }

    @Test func aCardWithNoPictureIsNotAskedAgainRightAway() async throws {
        let calls = Calls()
        let store = store { _ in calls.begin(); calls.end(); return nil }
        let music = try card(1)
        for _ in 0..<5 { _ = await ask(store, music) }
        #expect(calls.count == 1)
    }

    @Test func cardsWaitingOnTheSameItemShareOneLookup() async throws {
        let calls = Calls()
        let release = AsyncGate()
        let store = store { _ in
            calls.begin()
            defer { calls.end() }
            await release.wait()
            return nil
        }
        let music = try card(1)
        let tasks = (0..<5).map { _ in Task { await ask(store, music) } }
        try await Task.sleep(for: .milliseconds(200))
        await release.open()
        for task in tasks { _ = await task.value }
        #expect(calls.count == 1)
    }

    @Test func theRaceReturnsWhatFinishesFirstEvenIfWorkIgnoresCancellation() async throws {
        let value = try await BighelpCardRace.run(timeout: 5) { 7 }
        #expect(value == 7)
        await #expect(throws: BighelpCardRace.TimedOut.self) {
            try await BighelpCardRace.run(timeout: 0.1) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
    }
}

/// Holds callers until it's opened.
private actor AsyncGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiting { waiter.resume() }
        waiting.removeAll()
    }
}
