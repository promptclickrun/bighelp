import Foundation
import Testing
@testable import Bighelp

@MainActor
struct NativeDeviceToolSessionTests {
    @Test func phoneLifetimeSurvivesNavigationTaskAndSerializesReplacement() async {
        let lifetime = NativeDeviceToolLifetime()
        var started = false
        var closed = false
        var replacementStarted = false
        var duplicateStarted = false
        var releaseClose: CheckedContinuation<Void, Never>?
        let navigation = Task { @MainActor in
            lifetime.update("host-a:chat-a:foreground") {
                started = true
                while !Task.isCancelled { await Task.yield() }
                await withCheckedContinuation { releaseClose = $0 }
                closed = true
            }
        }
        await navigation.value
        for _ in 0..<100 where !started { await Task.yield() }
        navigation.cancel()
        #expect(started && !closed)

        lifetime.update("host-a:chat-a:foreground") { duplicateStarted = true }
        lifetime.update("host-b:chat-b:foreground") { replacementStarted = true }
        for _ in 0..<100 where releaseClose == nil { await Task.yield() }
        #expect(releaseClose != nil)
        #expect(!replacementStarted && !duplicateStarted)
        releaseClose?.resume()
        for _ in 0..<100 where !replacementStarted { await Task.yield() }
        #expect(closed && replacementStarted)
        lifetime.stop()
        var resumedAfterUnlock = false
        lifetime.update("host-b:chat-b:foreground") { resumedAfterUnlock = true }
        for _ in 0..<100 where !resumedAfterUnlock { await Task.yield() }
        #expect(resumedAfterUnlock)
        lifetime.stop()
    }

    @Test func directPhoneToolUsesNativePluginAndReturnsResultToSameChannel() async throws {
        let fixture = try Fixture()
        let session = fixture.session()
        try await session.connect()
        try await session.pollOnce()
        #expect(fixture.handled == 1)
        #expect(fixture.http.paths == ["context", "device-tools/connect", "device-tools/poll", "device-tools/result"])
        #expect(fixture.http.results.first?["requestId"]?.string == "tool-call")
        #expect(fixture.http.results.first?["sessionId"]?.string == "session")
    }

    @Test func anotherSessionOrDeviceCannotExecutePhoneTool() async throws {
        for field in ["sessionId", "deviceId", "agentId", "hostId"] {
            let fixture = try Fixture()
            fixture.http.request[field] = .string("another")
            let session = fixture.session()
            try await session.connect()
            await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
            #expect(fixture.handled == 0)
            #expect(fixture.http.results.isEmpty)
        }
    }

    @Test func ownerRetiredDuringPollCannotExecuteOrDeliverPhoneData() async throws {
        let fixture = try Fixture()
        let session = fixture.session()
        try await session.connect()
        fixture.http.beforePollReply = { fixture.current = false }
        await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
        #expect(fixture.handled == 0 && fixture.http.results.isEmpty)
    }

    @Test func missingCapabilityNeverRegistersPhoneOrChangesAnyPermissions() async throws {
        let fixture = try Fixture()
        fixture.http.features = ["native-context-v1", "serving-profile-v1"]
        await #expect(throws: WorkspaceClientError.self) { try await fixture.session().connect() }
        #expect(fixture.http.paths == ["context"])
        #expect(fixture.handled == 0)
    }

    @Test func olderPluginNeverHearsAboutLocationButKeepsTheOtherTools() async throws {
        let fixture = try Fixture()
        let session = fixture.session(enabled: [.calendar, .location])
        try await session.connect()
        #expect(fixture.http.connectedEnabled == ["calendar"])
        #expect(session.needsNewerPlugin == [.location])
    }

    @Test func locationAloneOnAnOlderPluginAsksForAnUpdate() async throws {
        let fixture = try Fixture()
        let session = fixture.session(enabled: [.location])
        await #expect(throws: WorkspaceClientError.unavailable(.pluginRequired)) { try await session.connect() }
        #expect(fixture.http.paths == ["context"])
        #expect(session.needsNewerPlugin == [.location])
    }

    @Test func newerPluginGetsLocationAndRunsIt() async throws {
        let fixture = try Fixture()
        fixture.http.features.append("native-device-location-v1")
        fixture.http.request["operation"] = .string("location.current")
        let session = fixture.session(enabled: [.calendar, .location])
        try await session.connect()
        #expect(fixture.http.connectedEnabled == ["calendar", "location"])
        try await session.pollOnce()
        #expect(fixture.handled == 1)
        #expect(session.needsNewerPlugin.isEmpty)
    }

    /// A plugin with connect cards hears which tools are off but can ask the person with a card.
    @Test func aPluginWithCardsHearsWhichToolsCanAsk() async throws {
        let fixture = try Fixture()
        fixture.http.features.append(NativeDeviceToolSession.askFeature)
        let session = fixture.session(enabled: [.calendar], askable: [.reminders, .health, .calendar, .appearance])
        try await session.connect()
        #expect(fixture.http.connectedEnabled == ["calendar"])
        #expect(fixture.http.connectedAskable == ["health", "reminders"],
                "Never one that's on, never one that shares nothing")
        #expect(session.askable == [.health, .reminders])
    }

    /// An older plugin refuses a field it doesn't know, so it never hears about tools that can ask.
    @Test func anOlderPluginNeverHearsAboutToolsThatCanAsk() async throws {
        let fixture = try Fixture()
        let session = fixture.session(enabled: [.calendar], askable: [.reminders])
        try await session.connect()
        #expect(fixture.http.connectedEnabled == ["calendar"])
        #expect(fixture.http.connectedAskable == nil)
        #expect(session.askable.isEmpty)
    }

    /// With every switch off, the chat still opens a channel so an agent's call can reach its card, but
    /// only on a plugin with cards.
    @Test func toolsThatCanAskAloneOpenAChannelOnlyOnAPluginWithCards() async throws {
        let fixture = try Fixture()
        let older = fixture.session(enabled: [], askable: [.reminders])
        await #expect(throws: WorkspaceClientError.unavailable(.pluginRequired)) { try await older.connect() }
        #expect(fixture.http.paths == ["context"])
        fixture.http.features.append(NativeDeviceToolSession.askFeature)
        let session = fixture.session(enabled: [], askable: [.reminders])
        try await session.connect()
        #expect(fixture.http.connectedEnabled == [] && fixture.http.connectedAskable == ["reminders"])
    }

    /// A call to a tool that's off may wait five minutes for the person; every other call keeps its
    /// two-minute bound, and a tool the channel never offered is refused.
    @Test func onlyACallThatAsksMayWaitFiveMinutes() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let asking = try Fixture()
        asking.http.features.append(NativeDeviceToolSession.askFeature)
        asking.http.request["operation"] = .string("reminders.list")
        asking.http.request["sentAt"] = .integer(now)
        asking.http.request["expiresAt"] = .integer(now + 300)
        let session = asking.session(enabled: [.calendar], askable: [.reminders])
        try await session.connect()
        try await session.pollOnce()
        #expect(asking.handled == 1)

        for (operation, window) in [("calendar.list", 300), ("contacts.list", 60), ("reminders.list", 301)] {
            let fixture = try Fixture()
            fixture.http.features.append(NativeDeviceToolSession.askFeature)
            fixture.http.request["operation"] = .string(operation)
            fixture.http.request["sentAt"] = .integer(now)
            fixture.http.request["expiresAt"] = .integer(now + window)
            let session = fixture.session(enabled: [.calendar], askable: [.reminders])
            try await session.connect()
            await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
            #expect(fixture.handled == 0, "\(operation) for \(window) s")
        }
    }

    @Test func appearanceAloneOnAnOlderPluginNeverOpensAChannel() async throws {
        let fixture = try Fixture()
        let session = fixture.session(enabled: [.appearance])
        await #expect(throws: WorkspaceClientError.unavailable(.pluginRequired)) { try await session.connect() }
        #expect(fixture.http.paths == ["context"])
        #expect(session.needsNewerPlugin == [.appearance])
    }

    @Test func newerPluginGetsAppearanceAndAQuietChannelPollsLessOften() async throws {
        let fixture = try Fixture()
        fixture.http.features.append("native-device-appearance-v1")
        fixture.http.request["operation"] = .string("appearance.set")
        let quiet = fixture.session(enabled: [.appearance])
        try await quiet.connect()
        #expect(fixture.http.connectedEnabled == ["appearance"])
        #expect(quiet.pollInterval == .seconds(8))
        try await quiet.pollOnce()
        #expect(fixture.handled == 1)
        await quiet.close()
        let busy = fixture.session(enabled: [.calendar, .appearance])
        try await busy.connect()
        #expect(fixture.http.connectedEnabled == ["appearance", "calendar"])
        #expect(busy.pollInterval == .milliseconds(750))
    }

    /// Hermes loads the plugin's phone tools only into the agent it serves, and the plugin refuses any
    /// other agent's channel (`profile_not_served`). Another agent's chat asks the host nothing more.
    @Test func anotherAgentsChatNeverOpensOrClosesAChannel() async throws {
        let fixture = try Fixture()
        fixture.http.features.append("native-device-appearance-v1")
        let session = fixture.session(enabled: [.calendar, .appearance], agentID: "researcher")
        await #expect(throws: WorkspaceClientError.self) { try await session.run() }
        #expect(fixture.http.paths == ["context"])
        #expect(fixture.http.refusals.isEmpty)
        #expect(session.servingAgentID == "default")
        #expect(fixture.handled == 0)
    }

    @Test func theServedAgentsChatStillOpensItsChannel() async throws {
        let fixture = try Fixture()
        let session = fixture.session(agentID: "default")
        try await session.connect()
        #expect(session.servingAgentID == nil)
        #expect(fixture.http.paths == ["context", "device-tools/connect"])
        await session.close()
        #expect(fixture.http.paths == ["context", "device-tools/connect", "device-tools/close"])
        #expect(fixture.http.refusals.isEmpty)
    }

    /// A newer plugin gives every agent on the host the phone's tools: any agent's chat opens its own
    /// channel, and only that agent's calls come through it.
    @Test func withEveryAgentsToolsAnotherAgentsChatOpensItsOwnChannel() async throws {
        let fixture = try Fixture()
        fixture.http.features.append("native-device-tools-agents-v1")
        fixture.http.request["agentId"] = .string("researcher")
        let session = fixture.session(agentID: "researcher")
        try await session.connect()
        #expect(session.servingAgentID == nil)
        #expect(fixture.http.connectedAgents == ["researcher"])
        try await session.pollOnce()
        #expect(fixture.handled == 1)
        #expect(fixture.http.results.first?["agentId"]?.string == "researcher")
        #expect(fixture.http.refusals.isEmpty)
    }

    /// The agent's profile is gone from the host (deleted while its chat was open): nothing opened,
    /// so nothing is closed either.
    @Test func aProfileTheHostDoesNotHaveOpensAndClosesNothing() async throws {
        let fixture = try Fixture()
        fixture.http.features.append("native-device-tools-agents-v1")
        fixture.http.missingProfiles = ["retired"]
        let session = fixture.session(agentID: "retired")
        await #expect(throws: WorkspaceClientError.self) { try await session.run() }
        #expect(fixture.http.paths == ["context", "device-tools/connect"])
        #expect(fixture.http.closeBodies.isEmpty)
    }

    /// Going to the background past the grace tells a newer plugin the phone is only away, so a call
    /// waits for it to come back instead of failing at once (`native-device-tools-wait-v1`).
    @Test func aChannelClosedForTheBackgroundSaysItIsPaused() async throws {
        let fixture = try Fixture()
        fixture.http.features.append("native-device-tools-wait-v1")
        let session = fixture.session()
        try await session.connect()
        fixture.paused = true
        await session.close()
        #expect(fixture.http.closeBodies.count == 1)
        #expect(fixture.http.closeBodies.first?["reason"] == .string("paused"))
    }

    @Test func otherClosesAndOlderPluginsGetAPlainClose() async throws {
        let waiting = try Fixture()
        waiting.http.features.append("native-device-tools-wait-v1")
        let chatChange = waiting.session()
        try await chatChange.connect()
        await chatChange.close()
        #expect(waiting.http.closeBodies.first?["reason"] == nil, "A chat or permission change ends the channel")

        let older = try Fixture()
        let session = older.session()
        try await session.connect()
        older.paused = true
        await session.close()
        #expect(older.http.closeBodies.first?["reason"] == nil, "An older plugin refuses fields it doesn't know")
    }

    @Test func anotherAgentsChatSaysWhichAgentCanUseSharedData() {
        #expect(DeviceToolChannelNote.otherAgent(enabled: [.calendar, .appearance], servingAgentName: "Sol")
            == "Open a chat with Sol to use this iPhone’s shared data.")
        #expect(DeviceToolChannelNote.otherAgent(enabled: [.appearance], servingAgentName: "Sol") == nil)
    }

    @Test func duplicateRequestIDsInOnePollBatchAreRejectedAtomically() async throws {
        let fixture = try Fixture()
        fixture.http.duplicateRequest = true
        let session = fixture.session()
        try await session.connect()
        await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
        #expect(fixture.handled == 0 && fixture.http.results.isEmpty)
    }

    @Test func expiredPollRequestDoesNotInvokeHandler() async throws {
        let fixture = try Fixture()
        fixture.http.request["expiresAt"] = .integer(Int(Date().timeIntervalSince1970) - 1)
        let session = fixture.session()
        try await session.connect()
        await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
        #expect(fixture.handled == 0 && fixture.http.results.isEmpty)
    }

    /// A shortcut out in the Shortcuts app can outlast the next request in its batch. That one is
    /// answered as expired; the host stopped waiting for it at its deadline and refuses the answer
    /// (`result_replay`), and the channel keeps working instead of closing.
    @Test func aRequestThatExpiresBehindASlowOneIsAnsweredAndTheChannelStays() async throws {
        let fixture = try Fixture()
        let now = Int(Date().timeIntervalSince1970)
        var quick = fixture.http.request
        quick["requestId"] = .string("tool-call-2")
        quick["expiresAt"] = .integer(now + 1)
        fixture.http.batch = [fixture.http.request, quick]
        fixture.slowFor = .milliseconds(2_100)
        let session = fixture.session()
        try await session.connect()
        try await session.pollOnce()
        #expect(fixture.handled == 1)
        #expect(fixture.http.results.count == 1)
        #expect(fixture.http.refusals == ["result_replay"])
        var next = fixture.http.request
        next["requestId"] = .string("tool-call-3")
        fixture.http.batch = [next]
        fixture.slowFor = nil
        try await session.pollOnce()
        #expect(fixture.handled == 2)
    }

    @Test func mismatchedHandlerResultCannotAdvanceCursor() async throws {
        let fixture = try Fixture()
        fixture.wrongResult = true
        let session = fixture.session()
        try await session.connect()
        await #expect(throws: WorkspaceClientError.self) { try await session.pollOnce() }
        #expect(fixture.handled == 1 && fixture.http.results.isEmpty)
    }

    /// A tool can run past its call's window: Location's precise-location question, its fix and the
    /// address can take 40 seconds, and the host waits 30. The host has told the agent by then, so it
    /// refuses the late answer (`result_replay`). That answer is lost, not the channel: it takes the
    /// next call (#861).
    @Test func aLateAnswerTheHostNoLongerTakesKeepsTheChannel() async throws {
        let fixture = try Fixture()
        fixture.duringHandle = { fixture.http.giveUpOnDelivered() }
        let session = fixture.session()
        try await session.connect()
        try await session.pollOnce()
        #expect(fixture.handled == 1 && fixture.http.results.isEmpty)
        #expect(fixture.http.refusals == ["result_replay"])
        fixture.duringHandle = nil
        var next = fixture.http.request
        next["requestId"] = .string("tool-call-2")
        fixture.http.batch = [next]
        try await session.pollOnce()
        #expect(fixture.handled == 2)
        #expect(fixture.http.results.map { $0["requestId"] } == [.string("tool-call-2")])
        #expect(fixture.http.paths.filter { $0 == "device-tools/close" }.isEmpty)
    }

    // MARK: A channel the host ended opens again (#861)

    /// What can end a channel the phone still uses while the chat stays open.
    enum ChannelEnd: String, CaseIterable, Sendable {
        /// The plugin retired it: it unloaded the agent, or the same phone opened another (`phone_unavailable`).
        case retired
        /// Its 30-second lease ran out while a slow tool ran, so the answer is refused (`phone_unavailable`).
        case outlastedLease
        /// The plugin started again and never had it (`channel_not_found`).
        case forgotten
        /// The connection dropped under the poll.
        case connectionLost
        /// The poll got no answer in time.
        case timedOut
    }

    /// Before, the chat had no phone tools after any of these until the person left it or quit bighelp:
    /// every later call failed at once with `phone_unavailable`.
    @Test(arguments: ChannelEnd.allCases)
    func aChannelThatEndsWhileTheChatStaysOpenOpensAgain(_ end: ChannelEnd) async throws {
        let fixture = try Fixture()
        var waits: [Duration] = []
        var waiting = 0
        var connected = 0
        try await NativeDeviceToolSession.runReopeningWhileHeld(
            sleep: { waits.append($0); fixture.http.advance($0) },
            makeSession: { fixture.session() },
            onConnected: { _ in
                connected += 1
                // The new channel is open: the person leaves the chat, which ends it for good.
                guard connected == 1 else { fixture.available = false; return }
                switch end {
                case .retired: fixture.http.retireAll()
                case .outlastedLease:
                    fixture.duringHandle = { fixture.http.advance(.seconds(31)); fixture.duringHandle = nil }
                case .forgotten: fixture.http.forgetAll()
                case .connectionLost: fixture.http.pollFailure = { throw DirectHermesError.connectionFailed }
                case .timedOut: fixture.http.pollFailure = { throw DirectHermesError.timedOut(outcomeUnknown: false) }
                }
            },
            onWaiting: { waiting += 1 })
        #expect(connected == 2, "A new channel opens for the chat")
        #expect(waiting == 1, "Device access says it connects again in a moment")
        #expect(waits == [.seconds(1)])
        #expect(fixture.http.connects == 2)
    }

    /// A host that ends every channel at once gets a few tries that wait longer each time, never a
    /// tight loop. The last one fails as before, and Device access says so.
    @Test func theTriesWaitLongerEachTimeAndThenStop() async throws {
        let fixture = try Fixture()
        var waits: [Duration] = []
        var waiting = 0
        await #expect(throws: WorkspaceClientError.rejected(code: "phone_unavailable")) {
            try await NativeDeviceToolSession.runReopeningWhileHeld(
                sleep: { waits.append($0); fixture.http.advance($0) },
                makeSession: { fixture.session() },
                onConnected: { _ in fixture.http.retireAll() },
                onWaiting: { waiting += 1 })
        }
        #expect(waits == NativeDeviceToolSession.reopenWaits)
        #expect(zip(waits, waits.dropFirst()).allSatisfy { $0 < $1 })
        #expect(waiting == waits.count)
        #expect(fixture.http.connects == waits.count + 1)
    }

    /// A channel that worked for a while before it ended starts the waits again: a chat open all
    /// day isn't left without its tools after a few lost connections.
    @Test func aChannelThatWorkedForAWhileStartsTheWaitsAgain() async throws {
        let fixture = try Fixture()
        let start = ContinuousClock.now
        var elapsed = Duration.zero
        var waits: [Duration] = []
        var connected = 0
        try await NativeDeviceToolSession.runReopeningWhileHeld(
            now: { start + elapsed },
            sleep: { waits.append($0); elapsed += $0 },
            makeSession: { fixture.session() },
            onConnected: { _ in
                connected += 1
                guard connected < 4 else { fixture.available = false; return }
                elapsed += .seconds(90)
                fixture.http.retireAll()
            })
        #expect(connected == 4)
        #expect(waits == Array(repeating: .seconds(1), count: 3))
    }

    /// Refusals a new channel can't fix stop at once, as before.
    @Test(arguments: ["profile_not_served", "profile_not_found", "session_not_found", "channel_capacity"])
    func aRefusalANewChannelCannotFixStillStops(_ code: String) async throws {
        let fixture = try Fixture()
        fixture.http.refusesConnect = code
        var waits = 0
        await #expect(throws: WorkspaceClientError.rejected(code: code)) {
            try await NativeDeviceToolSession.runReopeningWhileHeld(
                sleep: { _ in waits += 1 }, makeSession: { fixture.session() })
        }
        #expect(waits == 0)
        #expect(fixture.http.connects == 1)
        #expect(fixture.http.closeBodies.isEmpty)
    }

    /// Another agent's chat on an older plugin never opens a channel, so nothing tries again.
    @Test func anotherAgentsChatOnAnOlderPluginNeverTriesAgain() async throws {
        let fixture = try Fixture()
        var waits = 0
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await NativeDeviceToolSession.runReopeningWhileHeld(
                sleep: { _ in waits += 1 }, makeSession: { fixture.session(agentID: "researcher") })
        }
        #expect(waits == 0 && fixture.http.connects == 0)
    }

    /// The chat stops owning its tools as the channel ends (the person left the chat, the host
    /// changed, or the background grace ran out): nothing opens again.
    @Test(arguments: [false, true])
    func aChannelThatEndsAsTheChatLetsGoIsNotOpenedAgain(_ hostChanged: Bool) async throws {
        let fixture = try Fixture()
        var waits = 0
        fixture.http.pollFailure = {
            if hostChanged { fixture.current = false } else { fixture.available = false }
            throw DirectHermesError.connectionFailed
        }
        await #expect(throws: DirectHermesError.connectionFailed) {
            try await NativeDeviceToolSession.runReopeningWhileHeld(
                sleep: { _ in waits += 1 }, makeSession: { fixture.session() })
        }
        #expect(waits == 0 && fixture.http.connects == 1)
    }

    /// Leaving the chat while the phone waits to open the channel again ends the wait: nothing opens.
    @Test func leavingTheChatDuringTheWaitOpensNothing() async throws {
        let fixture = try Fixture()
        await #expect(throws: WorkspaceClientError.rejected(code: "phone_unavailable")) {
            try await NativeDeviceToolSession.runReopeningWhileHeld(
                sleep: { _ in fixture.available = false },
                makeSession: { fixture.session() },
                onConnected: { _ in fixture.http.retireAll() })
        }
        #expect(fixture.http.connects == 1)

        let cancelled = try Fixture()
        let task = Task { @MainActor in
            try await NativeDeviceToolSession.runReopeningWhileHeld(
                makeSession: { cancelled.session() }, onConnected: { _ in cancelled.http.retireAll() })
        }
        for _ in 0..<1_000 where cancelled.http.refusals.count < 2 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelled.http.connects == 1)
    }

    @Test func connectAcceptedAfterForegroundRetiresStillClosesChannel() async throws {
        let fixture = try Fixture()
        fixture.http.beforeConnectReply = { fixture.available = false }
        await #expect(throws: WorkspaceClientError.self) { try await fixture.session().run() }
        #expect(fixture.http.paths == ["context", "device-tools/connect", "device-tools/close"])
    }

    @Test func acceptedConnectThenOwnerRetiresUsesPreparedCleanupOnce() async throws {
        let fixture = try Fixture()
        fixture.http.beforeConnectReply = { fixture.current = false }
        var cleanupCount = 0
        let session = NativeDeviceToolSession(http: fixture.http, owner: fixture.owner,
            currentOwner: { fixture.current ? fixture.owner : nil }, scope: fixture.scope,
            agentID: "default", sessionID: "session", enabled: [.calendar], isAvailable: { true },
            closeCleanupFactory: { _ in { cleanupCount += 1 } },
            handle: { request, _, _ in DeviceToolResult(request: request, status: "failed", sentAt: 1) })
        await #expect(throws: WorkspaceClientError.self) { try await session.run() }
        await session.close()
        #expect(cleanupCount == 1)
        #expect(fixture.http.paths == ["context", "device-tools/connect"])
    }

    // MARK: One chat, one phone (#461)

    /// The plugin's refusals carry its code and no ETag. A refused connect opened nothing, so the
    /// phone sends no close for it: the plugin would only refuse that too (`channel_not_found`).
    @Test func aRefusedConnectKeepsThePluginsReasonAndSendsNoClose() async throws {
        let fixture = try Fixture()
        fixture.http.hold(device: "f3a1c7d2-0b6e-4c55-9e1a-2d7b8c9e0f13")
        await #expect(throws: WorkspaceClientError.rejected(code: "channel_ambiguous")) { try await fixture.session().run() }
        #expect(fixture.http.paths == ["context", "device-tools/connect"])
        #expect(fixture.http.refusals == ["channel_ambiguous"])
    }

    /// The app closed before its close reached the host, or the close was lost on a reconnect. An older
    /// plugin keeps that channel until its 30-second lease ends and refuses this phone's next
    /// connect for the chat. The chat gets its phone tools back once the lease can have ended, with no
    /// need to leave it and come back.
    @Test func aChannelLeftBehindIsWaitedOutAndTheChatConnectsAgain() async throws {
        let fixture = try Fixture()
        fixture.http.closeFails = true
        let earlier = fixture.session()
        try await earlier.connect()
        await earlier.close()
        #expect(fixture.http.openChannels == 1)
        fixture.http.closeFails = false
        var waits: [Duration] = []
        var waiting = 0
        var connected = 0
        try await NativeDeviceToolSession.runReopeningWhileHeld(
            sleep: { waits.append($0); fixture.http.advance($0) },
            makeSession: { fixture.session() },
            onConnected: { _ in connected += 1; fixture.available = false },
            onWaiting: { waiting += 1 })
        #expect(connected == 1 && waiting == 1)
        #expect(waits.count == 1 && waits.allSatisfy { $0 > .seconds(30) })
        #expect(fixture.http.refusals == ["channel_ambiguous"])
        #expect(fixture.http.openChannels == 0)
    }

    /// A newer plugin lets the same phone replace its own channel, so the chat connects at once.
    @Test func aNewerPluginLetsThisPhoneReplaceItsChannelAtOnce() async throws {
        let fixture = try Fixture()
        fixture.http.replacesSamePhone = true
        fixture.http.closeFails = true
        let earlier = fixture.session()
        try await earlier.connect()
        await earlier.close()
        fixture.http.closeFails = false
        var waits = 0
        try await NativeDeviceToolSession.runReopeningWhileHeld(
            sleep: { _ in waits += 1 }, makeSession: { fixture.session() },
            onConnected: { _ in fixture.available = false })
        #expect(waits == 0)
        #expect(fixture.http.refusals.isEmpty)
    }

    /// Another phone keeps the chat: one chat shares one phone's data, and the plugin never picks one by
    /// which came last. This phone stops after a few tries and never takes the chat from it.
    @Test func anotherPhoneKeepsTheChatSoTheTriesStop() async throws {
        let fixture = try Fixture()
        fixture.http.replacesSamePhone = true
        let other = fixture.http.hold(device: "f3a1c7d2-0b6e-4c55-9e1a-2d7b8c9e0f13")
        var waits = 0
        await #expect(throws: WorkspaceClientError.rejected(code: "channel_ambiguous")) {
            try await NativeDeviceToolSession.runReopeningWhileHeld(
                sleep: { waits += 1; fixture.http.advance($0); fixture.http.keepAlive(other) },
                makeSession: { fixture.session() })
        }
        #expect(waits == 3)
        #expect(fixture.http.refusals == Array(repeating: "channel_ambiguous", count: 4))
        #expect(fixture.http.openChannels == 1)
    }

    /// Leaving the chat, or any other change, cancels the wait; nothing connects after it.
    @Test func leavingTheChatCancelsTheWait() async throws {
        let fixture = try Fixture()
        fixture.http.hold(device: "f3a1c7d2-0b6e-4c55-9e1a-2d7b8c9e0f13")
        let task = Task { @MainActor in
            try await NativeDeviceToolSession.runReopeningWhileHeld(makeSession: { fixture.session() })
        }
        for _ in 0..<1_000 where fixture.http.refusals.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.http.paths.filter { $0 == "device-tools/connect" }.count == 1)
    }

    @Test func deviceAccessSaysAnotherDeviceHasTheChatNotThatThePluginIsMissing() {
        #expect(DeviceToolChannelNote.reconnecting(enabled: [.calendar, .appearance])
            == "Device access connects again in a moment.")
        #expect(DeviceToolChannelNote.heldElsewhere(enabled: [.calendar, .appearance])
            == "Another device uses this chat’s shared data. Close the chat there, then open it again here.")
        #expect(DeviceToolChannelNote.reconnecting(enabled: [.appearance]) == nil)
        #expect(DeviceToolChannelNote.heldElsewhere(enabled: [.appearance]) == nil)
    }

    @MainActor private final class Fixture {
        let http = HTTP()
        let owner: WorkspaceOwner
        let scope = DeviceToolScope(deviceID: "e8cc487e-36ed-442f-a2c5-834f0dc5a953", authorizationEpoch: 1, hostID: "native-host")
        var current = true
        var handled = 0
        var available = true
        /// The app left for the background and its grace ran out (`DeviceToolHandoff`).
        var paused = false
        var wrongResult = false
        /// The first request handled takes this long, like a run out in Shortcuts.
        var slowFor: Duration?
        /// Runs while a tool runs, before its answer goes to the host.
        var duringHandle: (() -> Void)?
        init() throws {
            owner = WorkspaceOwner(authority: try .dashboard(endpointIdentity: "https://host.example:9119"),
                                   authenticationGeneration: UUID(), connectionGeneration: UUID())
            http.request = ["version": .integer(1), "type": .string("device.tool.request"),
                "requestId": .string("tool-call"), "deviceId": .string(scope.deviceID), "hostId": .string(scope.hostID),
                "authorizationEpoch": .integer(1), "sessionId": .string("session"), "agentId": .string("default"),
                "turnId": .string("turn"), "operation": .string("calendar.list"), "arguments": .object([:]),
                "sentAt": .integer(Int(Date().timeIntervalSince1970)), "expiresAt": .integer(Int(Date().timeIntervalSince1970) + 60)]
        }
        func session(enabled: Set<DeviceToolCapability> = [.calendar], askable: Set<DeviceToolCapability> = [],
                     agentID: String = "default") -> NativeDeviceToolSession {
            NativeDeviceToolSession(http: http, owner: owner, currentOwner: { self.current ? self.owner : nil },
                scope: scope, agentID: agentID, sessionID: "session", enabled: enabled, askable: askable,
                isAvailable: { self.available }, isPaused: { self.paused }, handle: { request, _, _ in
                    self.handled += 1
                    if let slowFor = self.slowFor { try? await Task.sleep(for: slowFor) }
                    self.duringHandle?()
                    var resultRequest = request
                    if self.wrongResult {
                        var raw = self.http.request
                        raw["sessionId"] = .string("different-session")
                        resultRequest = try! JSONDecoder().decode(DeviceToolRequest.self, from: JSONEncoder().encode(raw))
                    }
                    return DeviceToolResult(request: resultRequest, status: "completed", payload: ["items": .array([])],
                                            sentAt: Int(Date().timeIntervalSince1970))
                })
        }
    }

    private final class HTTP: DirectHermesNativeHTTP {
        var request: [String: BighelpJSONValue] = [:]
        var features = ["native-context-v1", "serving-profile-v1", "native-device-tools-v1"]
        var paths: [String] = []
        var results: [[String: BighelpJSONValue]] = []
        var connectedEnabled: [String] = []
        /// The connect's `askable`, or nil when it had none.
        var connectedAskable: [String]?
        var beforePollReply: () -> Void = {}
        var beforeConnectReply: () -> Void = {}
        var duplicateRequest = false
        /// Requests the next poll returns, in order, instead of `request`.
        var batch: [[String: BighelpJSONValue]]?
        /// Like the plugin: it serves one Hermes profile and holds one phone's channel per agent and chat,
        /// for 30 seconds after its last poll. A second phone for the chat is refused (`channel_ambiguous`);
        /// a newer plugin lets the same phone replace its own channel.
        let servingProfile = "default"
        struct Held { let device: String; let agent: String; let session: String; var expires: TimeInterval }
        var channels: [String: Held] = [:]
        var retired: Set<String> = []
        var now: TimeInterval = 1_000
        var replacesSamePhone = false
        /// The close never reaches the host (the app was closing, or the connection dropped).
        var closeFails = false
        /// What each close said, in order.
        var closeBodies: [[String: BighelpJSONValue]] = []
        /// The agent each channel opened for.
        var connectedAgents: [String] = []
        /// Profiles the host doesn't have (`profile_not_found`).
        var missingProfiles: Set<String> = []
        /// The codes the plugin would answer and log (`bighelp native request rejected: …`).
        var refusals: [String] = []
        var openChannels: Int { purge(); return channels.count }
        var connects: Int { paths.filter { $0 == "device-tools/connect" }.count }
        /// A connect refusal that opens nothing (`profile_not_found`, `session_not_found`, …).
        var refusesConnect: String?
        /// Runs in place of the next poll's answer, once: a lost connection or a time-out.
        var pollFailure: (() throws -> Void)?
        /// Each request a poll handed the phone, by ID, with its deadline (the plugin's `pending`).
        private var delivered: [String: Int] = [:]
        /// Requests the host stopped waiting for: it told the agent, and marked them done (`_give_up`).
        private var givenUp: Set<String> = []

        /// The plugin retires every channel: it unloaded the agent (`close_profile`).
        func retireAll() { for id in channels.keys { channels[id] = nil; retired.insert(id) } }
        /// The plugin started again: it never had these channels.
        func forgetAll() { channels.removeAll() }
        /// The host's wait for every request the phone has ran out.
        func giveUpOnDelivered() { givenUp.formUnion(delivered.keys) }

        @discardableResult
        func hold(device: String) -> String {
            let id = UUID().uuidString.lowercased()
            channels[id] = Held(device: device, agent: servingProfile, session: "session", expires: now + 30)
            return id
        }
        func keepAlive(_ id: String) { channels[id]?.expires = now + 30 }
        func advance(_ duration: Duration) { now += TimeInterval(duration.components.seconds) }
        private func purge() {
            for (id, held) in channels where held.expires <= now { channels[id] = nil; retired.insert(id) }
        }

        func nativeResponse(_ request: DirectHermesHTTPRequest, requestGuard: DirectHermesNativeRequestGuard?) async throws -> DirectHermesHTTP.Response {
            let path = String(request.path.dropFirst("/api/plugins/loopdy/native/".count))
            paths.append(path)
            let channel = request.body?["channelId"] ?? .null
            let value: [String: BighelpJSONValue]
            purge()
            switch path {
            case "context": value = ["schemaVersion": .integer(1), "pluginVersion": .string("test"),
                "runtimeId": .string("runtime"), "servingProfileId": .string(servingProfile), "principal": .null,
                "features": .array(features.map(BighelpJSONValue.string))]
            case "device-tools/connect":
                // A newer plugin shares one hub with every agent on the host (`native-device-tools-agents-v1`).
                guard let agent = request.body?["agentId"]?.string,
                      features.contains("native-device-tools-agents-v1") || agent == servingProfile else {
                    return try refusal("profile_not_served", status: 403, request: request, requestGuard: requestGuard)
                }
                if missingProfiles.contains(agent) {
                    return try refusal("profile_not_found", status: 404, request: request, requestGuard: requestGuard)
                }
                if let code = refusesConnect {
                    return try refusal(code, status: code == "channel_capacity" ? 503 : 404, request: request,
                                       requestGuard: requestGuard)
                }
                guard let id = channel.string, let device = request.body?["deviceId"]?.string,
                      let session = request.body?["sessionId"]?.string else { throw WorkspaceClientError.invalidRequest }
                connectedAgents.append(agent)
                let held = channels.filter { $0.value.agent == agent && $0.value.session == session }
                if !held.isEmpty {
                    guard replacesSamePhone, held.values.allSatisfy({ $0.device == device }) else {
                        return try refusal("channel_ambiguous", status: 409, request: request, requestGuard: requestGuard)
                    }
                    for old in held.keys { channels[old] = nil; retired.insert(old) }
                }
                // Like the plugin's strict model: a field it doesn't know is refused.
                if request.body?["askable"] != nil, !features.contains(NativeDeviceToolSession.askFeature) {
                    return try refusal("invalid_request", status: 422, request: request, requestGuard: requestGuard)
                }
                connectedEnabled = request.body?["enabled"]?.array?.compactMap(\.string) ?? []
                connectedAskable = request.body?["askable"]?.array?.compactMap(\.string)
                beforeConnectReply()
                channels[id] = Held(device: device, agent: agent, session: session, expires: now + 30)
                value = ["channelId": channel, "connected": .boolean(true)]
            case "device-tools/poll":
                if let failure = pollFailure {
                    pollFailure = nil
                    try failure()
                }
                if let refused = try gone(channel, request: request, requestGuard: requestGuard) { return refused }
                if let id = channel.string { keepAlive(id) }
                beforePollReply()
                let rows = batch ?? Array(repeating: self.request, count: duplicateRequest ? 2 : 1)
                for row in rows {
                    if let id = row["requestId"]?.string { delivered[id] = row["expiresAt"]?.integer ?? 0 }
                }
                // A batch continues after the phone's cursor; the single request always comes as the first.
                let start = batch == nil ? 0 : Int(request.body?["after"]?.integer ?? 0)
                value = ["channelId": channel, "next": .integer(start + rows.count),
                         "requests": .array(rows.enumerated().map {
                             .object(["sequence": .integer(start + $0.offset + 1), "request": .object($0.element)])
                         })]
            case "device-tools/result":
                // The plugin's `accept_result`: a channel it no longer has refuses first; an answer it
                // stopped waiting for at the deadline is done (`result_replay`); a taken one renews the lease.
                if let refused = try gone(channel, request: request, requestGuard: requestGuard) { return refused }
                let result = request.body?["result"]?.object ?? [:]
                if let id = result["requestId"]?.string, let deadline = delivered[id],
                   givenUp.contains(id) || deadline <= Int(Date().timeIntervalSince1970) {
                    return try refusal("result_replay", status: 409, request: request, requestGuard: requestGuard)
                }
                results.append(result)
                if let id = channel.string { keepAlive(id) }
                value = ["accepted": .boolean(true)]
            case "device-tools/close":
                if closeFails { throw URLError(.networkConnectionLost) }
                closeBodies.append(request.body ?? [:])
                if let refused = try gone(channel, request: request, requestGuard: requestGuard) { return refused }
                if let id = channel.string { channels[id] = nil; retired.insert(id) }
                value = ["closed": .boolean(true)]
            default: throw WorkspaceClientError.invalidRequest
            }
            var headers = ["ETag": requestGuard?.etag ?? "\"sha256:\(String(repeating: "a", count: 64))\"", "Cache-Control": "no-store"]
            if let requestGuard { headers["X-Loopdy-Request-ID"] = requestGuard.requestIDHeader }
            let response = try #require(HTTPURLResponse(url: URL(string: "https://host.example:9119" + request.path)!,
                                                       statusCode: 200, httpVersion: nil, headerFields: headers))
            return .init(http: response, body: try JSONEncoder().encode(BighelpJSONValue.object(value)))
        }

        /// The plugin's `_get`: a channel it retired is `phone_unavailable`, one it never had `channel_not_found`.
        private func gone(_ channel: BighelpJSONValue, request: DirectHermesHTTPRequest,
                          requestGuard: DirectHermesNativeRequestGuard?) throws -> DirectHermesHTTP.Response? {
            guard let id = channel.string, channels[id] == nil else { return nil }
            return try refusal(retired.contains(id) ? "phone_unavailable" : "channel_not_found", status: 409,
                               request: request, requestGuard: requestGuard)
        }

        /// The plugin's `_error_response`: no ETag, the request ID echoed.
        private func refusal(_ code: String, status: Int, request: DirectHermesHTTPRequest,
                             requestGuard: DirectHermesNativeRequestGuard?) throws -> DirectHermesHTTP.Response {
            refusals.append(code)
            var headers = ["Cache-Control": "no-store"]
            if let requestGuard { headers["X-Loopdy-Request-ID"] = requestGuard.requestIDHeader }
            let response = try #require(HTTPURLResponse(url: URL(string: "https://host.example:9119" + request.path)!,
                                                       statusCode: status, httpVersion: nil, headerFields: headers))
            let body: BighelpJSONValue = .object(["error": .object(["code": .string(code),
                "message": .string("The native iPhone tool channel is unavailable."),
                "retryable": .boolean(false), "details": .object([:])])])
            return .init(http: response, body: try JSONEncoder().encode(body))
        }
    }
}

@MainActor
struct HostPluginFeatureReadinessTests {
    @Test func staleFeatureCheckAfterHostSwitchCannotPublishReadiness() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hostID = try #require(fixture.registry.selectedHostID)
        let registryGeneration = fixture.registry.generation
        let connectionGeneration = try #require(fixture.registry.selectedWorkspace?.connectionGeneration)
        let token = fixture.registry.deviceToolFeatureReadinessToken
        let ownsCapturedConnection: @MainActor () -> Bool = {
            fixture.registry.selectedHostID == hostID
                && fixture.registry.generation == registryGeneration
                && fixture.registry.selectedWorkspace?.connectionGeneration == connectionGeneration
        }

        fixture.registry.select(fixture.hostB.id)

        let accepted = fixture.registry.recordPluginFeatureReadiness(
            feature: .deviceAccess, hostID: hostID, registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration, contextETag: "etag-a",
            capabilities: ["native-context-v1", "native-device-tools-v1"],
            isCurrent: ownsCapturedConnection
        )

        #expect(!accepted)
        #expect(fixture.registry.deviceToolFeatureReadinessToken == token)
    }

    @Test func repeatedFeatureCheckForSameContextDoesNotChangeReadinessToken() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hostID = try #require(fixture.registry.selectedHostID)
        let registryGeneration = fixture.registry.generation
        let connectionGeneration = try #require(fixture.registry.selectedWorkspace?.connectionGeneration)
        let ownsCapturedConnection: @MainActor () -> Bool = {
            fixture.registry.selectedHostID == hostID
                && fixture.registry.generation == registryGeneration
                && fixture.registry.selectedWorkspace?.connectionGeneration == connectionGeneration
        }
        let first = fixture.registry.recordPluginFeatureReadiness(
            feature: .deviceAccess, hostID: hostID, registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration, contextETag: "etag-a",
            capabilities: ["native-context-v1", "native-device-tools-v1"],
            isCurrent: ownsCapturedConnection
        )
        let token = fixture.registry.deviceToolFeatureReadinessToken
        let repeated = fixture.registry.recordPluginFeatureReadiness(
            feature: .deviceAccess, hostID: hostID, registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration, contextETag: "etag-a",
            capabilities: ["native-context-v1", "native-device-tools-v1"],
            isCurrent: ownsCapturedConnection
        )

        #expect(first)
        #expect(repeated)
        #expect(token == fixture.registry.deviceToolFeatureReadinessToken)
    }

    @Test func newlyAvailableFeatureCapabilityAdvancesReadinessToken() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let hostID = try #require(fixture.registry.selectedHostID)
        let registryGeneration = fixture.registry.generation
        let connectionGeneration = try #require(fixture.registry.selectedWorkspace?.connectionGeneration)
        let ownsCapturedConnection: @MainActor () -> Bool = {
            fixture.registry.selectedHostID == hostID
                && fixture.registry.generation == registryGeneration
                && fixture.registry.selectedWorkspace?.connectionGeneration == connectionGeneration
        }
        let before = fixture.registry.deviceToolFeatureReadinessToken
        let missing = fixture.registry.recordPluginFeatureReadiness(
            feature: .deviceAccess, hostID: hostID, registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration, contextETag: "etag-a",
            capabilities: ["native-context-v1"], isCurrent: ownsCapturedConnection
        )
        let ready = fixture.registry.recordPluginFeatureReadiness(
            feature: .deviceAccess, hostID: hostID, registryGeneration: registryGeneration,
            connectionGeneration: connectionGeneration, contextETag: "etag-b",
            capabilities: ["native-context-v1", "native-device-tools-v1"],
            isCurrent: ownsCapturedConnection
        )

        #expect(!missing)
        #expect(ready)
        #expect(fixture.registry.deviceToolFeatureReadinessToken == before + 1)
    }

    @MainActor
    private final class Fixture {
        let registry: BighelpHostRegistry
        let hostA: BighelpConfiguredHost
        let hostB: BighelpConfiguredHost
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            registry = BighelpHostRegistry(
                root: root,
                keychainService: "app.loopdy.test.feature-readiness." + UUID().uuidString
            )
            registry.bind(deviceID: "readiness-account", authorizationEpoch: 1)
            let scope = try #require(registry.accountScope)
            let endpointA = try DirectHermesEndpoint(address: "https://readiness-a.example")
            let endpointB = try DirectHermesEndpoint(address: "https://readiness-b.example")
            let savedA = DirectHermesSavedConnection(
                endpoint: endpointA,
                authentication: .bearer(accessToken: UUID().uuidString, refreshToken: nil, expiresAt: nil),
                provider: "basic", userID: "readiness-a"
            )
            let savedB = DirectHermesSavedConnection(
                endpoint: endpointB,
                authentication: .bearer(accessToken: UUID().uuidString, refreshToken: nil, expiresAt: nil),
                provider: "basic", userID: "readiness-b"
            )
            hostA = BighelpConfiguredHost(
                id: UUID(), accountScope: scope, accountID: "readiness-account",
                endpoint: endpointA, principalIdentity: savedA.identity, name: "Readiness A"
            )
            hostB = BighelpConfiguredHost(
                id: UUID(), accountScope: scope, accountID: "readiness-account",
                endpoint: endpointB, principalIdentity: savedB.identity, name: "Readiness B"
            )
            struct Snapshot: Encodable {
                let version = 1
                let hosts: [BighelpConfiguredHost]
                let selected: UUID?
            }
            try JSONEncoder().encode(Snapshot(hosts: [hostA, hostB], selected: hostA.id))
                .write(to: root.appending(path: scope + ".json"))
            registry.bind(deviceID: "readiness-account", authorizationEpoch: 1, forceReload: true)
        }

        func cleanup() {
            registry.bind(deviceID: nil, authorizationEpoch: nil)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
