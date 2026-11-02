import Foundation
import Testing
@testable import Bighelp

/// An agent calls a Device access tool that's off: its chat shows a card, Turn on flips the same
/// switch Settings has and the call goes on, and Not now, an iOS no or no answer refuses it once for
/// that chat.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DeviceAccessCardsTests {
    private let scope = DeviceToolScope(deviceID: "phone-a", authorizationEpoch: 1, hostID: "host-a")

    @Test func turnOnFlipsTheSameSwitchAndTheCallGoesOn() async throws {
        let fixture = CardFixture(scope: scope)
        let asking = Task { await fixture.cards.ask(.reminders, requestID: "call-1", conversationID: "chat-a", until: .now + 60) }
        let card = try await fixture.waitForCard(in: "chat-a")
        #expect(card.capability == .reminders)
        #expect(fixture.cards.cards(in: "chat-b").isEmpty, "Only the chat that asked shows it")
        let revision = fixture.permissions.revision
        await fixture.cards.turnOn(card)
        #expect(await asking.value == .turnedOn)
        #expect(fixture.permissions.isEnabled(.reminders))
        #expect(fixture.requests == [.reminders], "iOS asked once")
        #expect(fixture.permissions.revision == revision, "The channel that carried the call stays open")
        #expect(fixture.cards.cards(in: "chat-a").isEmpty)
        #expect(await fixture.cards.ask(.reminders, requestID: "call-2", conversationID: "chat-b", until: .now + 60)
                == .turnedOn, "On is on, in every chat")
    }

    @Test func notNowRefusesAndTheCardDoesNotComeBackInThatChat() async throws {
        let fixture = CardFixture(scope: scope)
        let asking = Task { await fixture.cards.ask(.calendar, requestID: "call-1", conversationID: "chat-a", until: .now + 60) }
        fixture.cards.notNow(try await fixture.waitForCard(in: "chat-a"))
        #expect(await asking.value == .notNow)
        #expect(DeviceAccessAnswer.notNow.refusalCode == "permission_declined")
        #expect(await fixture.cards.ask(.calendar, requestID: "call-2", conversationID: "chat-a", until: .now + 60) == .notNow)
        #expect(fixture.cards.cards.isEmpty, "No second card in that chat")
        #expect(!fixture.permissions.isEnabled(.calendar) && fixture.requests.isEmpty)
        let elsewhere = Task { await fixture.cards.ask(.calendar, requestID: "call-3", conversationID: "chat-b", until: .now + 60) }
        fixture.cards.notNow(try await fixture.waitForCard(in: "chat-b"))
        _ = await elsewhere.value
    }

    @Test func anIOSNoRefusesAndLeavesTheSwitchOff() async throws {
        let fixture = CardFixture(scope: scope)
        fixture.answer = .denied
        let asking = Task { await fixture.cards.ask(.contacts, requestID: "call-1", conversationID: "chat-a", until: .now + 60) }
        await fixture.cards.turnOn(try await fixture.waitForCard(in: "chat-a"))
        #expect(await asking.value == .denied)
        #expect(DeviceAccessAnswer.denied.refusalCode == "permission_denied")
        #expect(!fixture.permissions.isEnabled(.contacts))
        #expect(await fixture.cards.ask(.contacts, requestID: "call-2", conversationID: "chat-a", until: .now + 60) == .denied)
    }

    @Test func noAnswerBeforeTheCallsTimeRunsOutRefusesIt() async {
        let fixture = CardFixture(scope: scope)
        let answer = await fixture.cards.ask(.photos, requestID: "call-1", conversationID: "chat-a", until: .now + 0.2)
        #expect(answer == .timedOut)
        #expect(answer.refusalCode == "permission_timeout")
        #expect(fixture.cards.cards.isEmpty)
        #expect(await fixture.cards.ask(.photos, requestID: "call-2", conversationID: "chat-a", until: .now + 60) == .timedOut)
    }

    /// The chat closed or the app went away: the channel that carried the call ends, and so does its card.
    @Test func aCallThatEndsTakesItsCardWithIt() async throws {
        let fixture = CardFixture(scope: scope)
        let asking = Task { await fixture.cards.ask(.music, requestID: "call-1", conversationID: "chat-a", until: .now + 60) }
        _ = try await fixture.waitForCard(in: "chat-a")
        asking.cancel()
        #expect(await asking.value == .cancelled)
        #expect(fixture.cards.cards.isEmpty)
        // Not a refusal: the next call may ask again.
        let again = Task { await fixture.cards.ask(.music, requestID: "call-2", conversationID: "chat-a", until: .now + 60) }
        fixture.cards.notNow(try await fixture.waitForCard(in: "chat-a"))
        _ = await again.value
    }

    /// Apple Health's first Turn on shows the note about where the data goes; iOS asks only after Continue.
    @Test func healthShowsItsSharingNoteBeforeIOSAsks() async throws {
        let fixture = CardFixture(scope: scope)
        let asking = Task { await fixture.cards.ask(.health, requestID: "call-1", conversationID: "chat-a", until: .now + 60) }
        let card = try await fixture.waitForCard(in: "chat-a")
        await fixture.cards.turnOn(card)
        #expect(fixture.cards.step(card) == .healthSharing)
        #expect(fixture.requests.isEmpty)
        await fixture.cards.agreeToHealthSharing(card)
        #expect(await asking.value == .turnedOn)
        #expect(fixture.permissions.healthSharingAgreed && fixture.permissions.isEnabled(.health))
        #expect(fixture.requests == [.health])
    }

    /// iOS gives apps no list of shortcuts, so the card names the one the agent wants and adds it.
    @Test func aShortcutsCardAddsTheShortcutItNames() async throws {
        let fixture = CardFixture(scope: scope)
        let asking = Task {
            await fixture.cards.ask(.shortcuts, requestID: "call-1", conversationID: "chat-a",
                                    shortcutName: "Morning Routine", until: .now + 60)
        }
        let card = try await fixture.waitForCard(in: "chat-a")
        #expect(card.shortcutName == "Morning Routine")
        await fixture.cards.turnOn(card, shortcutName: "Morning Routine")
        #expect(await asking.value == .turnedOn)
        #expect(fixture.shortcuts.contains("Morning Routine"))
        #expect(fixture.permissions.isEnabled(.shortcuts))
    }

    /// Two calls waiting for the same tool need one answer: Turn on lets both go on, wherever they are;
    /// Not now refuses both in that chat, and leaves another chat's card for its own answer.
    @Test func oneAnswerSettlesEveryCardWaitingForTheSameTool() async throws {
        let fixture = CardFixture(scope: scope)
        let first = Task { await fixture.cards.ask(.reminders, requestID: "call-1", conversationID: "chat-a", until: .now + 60) }
        let second = Task { await fixture.cards.ask(.reminders, requestID: "call-2", conversationID: "chat-b", until: .now + 60) }
        let card = try await fixture.waitForCard(in: "chat-a")
        _ = try await fixture.waitForCard(in: "chat-b")
        await fixture.cards.turnOn(card)
        #expect(await first.value == .turnedOn)
        #expect(await second.value == .turnedOn)
        #expect(fixture.cards.cards.isEmpty && fixture.requests == [.reminders])

        let here = Task { await fixture.cards.ask(.photos, requestID: "call-3", conversationID: "chat-a", until: .now + 60) }
        let hereAgain = Task { await fixture.cards.ask(.photos, requestID: "call-4", conversationID: "chat-a", until: .now + 60) }
        let there = Task { await fixture.cards.ask(.photos, requestID: "call-5", conversationID: "chat-b", until: .now + 60) }
        _ = try await fixture.waitForCard(in: "chat-b")
        while fixture.cards.cards(in: "chat-a").count < 2 { await Task.yield() }
        fixture.cards.notNow(fixture.cards.cards(in: "chat-a")[0])
        #expect(await here.value == .notNow)
        #expect(await hereAgain.value == .notNow)
        #expect(fixture.cards.cards(in: "chat-b").count == 1, "Another chat answers for itself")
        fixture.cards.notNow(fixture.cards.cards(in: "chat-b")[0])
        _ = await there.value
    }

    @Test func theAskingHandlerRunsTheOriginalCallOnlyAfterTurnOn() async throws {
        let fixture = CardFixture(scope: scope)
        var handled: [String] = []
        let handle = DeviceAccessAsk.asking({ request, _, _ in
            handled.append(request.operation)
            return DeviceToolResult(request: request, status: "completed", payload: ["items": .array([])], sentAt: 1)
        }, cards: fixture.cards, permissions: fixture.permissions, conversationID: "chat-a", clock: { 1 })
        let now = Int(Date().timeIntervalSince1970)
        let call = Task { await handle(fixture.request("reminders.list", now: now), self.scope, { true }) }
        let card = try await fixture.waitForCard(in: "chat-a")
        #expect(card.deadline.timeIntervalSince1970 == TimeInterval(now + 300 - DeviceAccessAsk.margin),
                "It gives up before the host stops waiting")
        #expect(handled.isEmpty, "Nothing runs before the person answers")
        await fixture.cards.turnOn(card)
        let result = await call.value
        #expect(result.status == "completed" && handled == ["reminders.list"])
        // On now: the next call goes straight through.
        _ = await handle(fixture.request("reminders.list", now: now, id: "call-2"), scope, { true })
        #expect(handled.count == 2 && fixture.cards.cards.isEmpty)

        let refused = Task { await handle(fixture.request("calendar.list", now: now, id: "call-3"), self.scope, { true }) }
        fixture.cards.notNow(try await fixture.waitForCard(in: "chat-a"))
        let refusal = await refused.value
        #expect(refusal.status == "failed" && refusal.code == "permission_declined" && refusal.requestId == "call-3")
        #expect(handled.count == 2)
    }

    @Test func askableToolsAreTheOffOnesThisDeviceCanGive() async {
        let fixture = CardFixture(scope: scope)
        await fixture.permissions.refresh()
        await fixture.permissions.setEnabled(true, for: .calendar)
        let askable = DeviceAccessAsk.askable(fixture.permissions)
        #expect(!askable.contains(.calendar), "Already on")
        #expect(askable.contains(.reminders))
        #expect(!askable.contains(.appearance) && !askable.contains(.navigation), "Those are on for everyone")
        #expect(askable.allSatisfy { $0.isOfferedOnThisPlatform })
    }
}

@MainActor
private final class CardFixture {
    var requests: [DeviceToolCapability] = []
    var answer: DeviceToolSystemAccess = .available
    let permissions: DeviceToolPermissions
    let cards: DeviceAccessCardStore
    let shortcuts = ShortcutNameStore(defaults: .standard, persists: false)

    init(scope: DeviceToolScope) {
        let box = Box()
        permissions = DeviceToolPermissions(
            status: { _ in .notRequested },
            request: { kind in box.fixture?.requests.append(kind); return box.fixture?.answer ?? .denied },
            isForeground: { true }, readGrants: { _ in nil }, writeGrants: { _, _ in })
        permissions.bind(scope)
        cards = DeviceAccessCardStore(permissions: permissions)
        let shortcuts = shortcuts
        cards.shortcuts = { shortcuts }
        box.fixture = self
    }

    func waitForCard(in conversationID: String) async throws -> DeviceAccessCardStore.Card {
        for _ in 0..<500 {
            if let card = cards.cards(in: conversationID).first { return card }
            await Task.yield()
        }
        throw CardNeverShowed()
    }

    func request(_ operation: String, now: Int, id: String = "call-1") -> DeviceToolRequest {
        DeviceToolRequest(version: 1, type: "device.tool.request", requestId: id, deviceId: "phone-a",
                          hostId: "host-a", authorizationEpoch: 1, sessionId: "session", agentId: "default",
                          turnId: "turn", operation: operation, arguments: [:], sentAt: now,
                          expiresAt: now + NativeDeviceToolSession.askWindow)
    }

    private final class Box { weak var fixture: CardFixture? }
    private struct CardNeverShowed: Error {}
}
