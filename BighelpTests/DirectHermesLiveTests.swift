import Foundation
import XCTest
@testable import Bighelp

final class DirectHermesLiveTests: XCTestCase {
    private func configuration() throws -> [String: String] {
        guard let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"] else {
            throw XCTSkip("Requires the isolated stock Hermes fixture started by the native probe driver")
        }
        // The live driver supplies a private named pipe, not a plaintext
        // credential file. FileHandle supports both it and isolated fixtures.
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? input.close() }
        return try JSONDecoder().decode([String: String].self, from: input.readToEnd() ?? Data())
    }

    @MainActor
    func testRealHostedRoomStoreSendAndRestoredReply() async throws {
        let config = try configuration()
        guard config["real_host_acceptance"] == "true" else {
            throw XCTSkip("Requires explicit real-host acceptance configuration")
        }
        let vault = DirectHermesKeychainVault(service: "app.loopdy.group-proof." + UUID().uuidString)
        defer { try? vault.delete() }
        let transport = try await DirectHermesClient.connect(
            address: XCTUnwrap(config["address"]),
            auth: .token(XCTUnwrap(config["token"])), allowPrivateHTTP: false, vault: vault
        )
        let owner = WorkspaceOwner(authority: try XCTUnwrap(transport.savedConnection.workspaceAuthority),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        let workspace = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
            capabilities: .init(owner: owner, values: Dictionary(uniqueKeysWithValues:
                WorkspaceCapability.allCases.map { ($0, .available) })), currentOwner: { owner })
        let client = HermesHostedRoomClient(workspace: workspace, owner: owner)
        let store = BotModeRoomStore(client: NativeWorkspaceUnavailableClient(),
            executionEnabled: false, nativeClient: client)
        let roomID = "loopdy-swift-acceptance-" + UUID().uuidString
        var creationAttempted = false
        var failure: Error?
        do {
            let capabilities = try await client.groupsCapabilities()
            XCTAssertTrue(capabilities.supportsNativeExecution)
            let template = try await client.groupsState(roomID: XCTUnwrap(config["template_room_id"]), includeDisbanded: false)
            let members = template.members.filter { ["default", "doofy"].contains($0.memberID) }
            XCTAssertEqual(members.count, 2)
            creationAttempted = true
            _ = try await client.groupsCreate(roomID: roomID, name: "bighelp temporary Swift acceptance", members: members)
            _ = try await store.openNativeRoom(roomID: roomID)
            print("NATIVE_GROUP_STAGE opened")
            let target = try XCTUnwrap(members.first { $0.memberID == "default" })
            let marker = "BIGHELP_SWIFT_GROUP_OK"
            var finished = false
            let send = Task { @MainActor in
                defer { finished = true }
                try await store.send(text: "@\(target.handle) Reply with exactly \(marker). No tools or other work.", roomID: roomID)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(90))
            while !finished && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if !finished {
                send.cancel()
                try await client.groupsStop(roomID: roomID, cancelID: "timeout-" + roomID)
            }
            try await send.value
            let completed = try XCTUnwrap(store.room(id: roomID))
            XCTAssertTrue(completed.visibleEvents.contains { $0.kind == .agent && $0.text?.contains(marker) == true })
            XCTAssertFalse(completed.isRunning)
            XCTAssertNil(completed.nativePendingEventID)
            print("NATIVE_GROUP_STAGE real_reply_settled")

            // Recreate the presentation store, keeping the same authenticated
            // transport and cached canonical room, as navigation does.
            store.configureNativeClient(nil)
            let reopened = BotModeRoomStore(client: NativeWorkspaceUnavailableClient(),
                rooms: [completed], executionEnabled: false, nativeClient: client)
            let start = ContinuousClock.now
            let restored = try await reopened.openNativeRoom(roomID: roomID)
            let elapsed = start.duration(to: .now)
            XCTAssertLessThan(elapsed, .seconds(2))
            XCTAssertEqual(restored.visibleEvents, completed.visibleEvents)
            XCTAssertFalse(restored.isRunning)
            print("NATIVE_GROUP_REOPEN_DURATION \(elapsed)")
            let allMarker = "BIGHELP_SWIFT_EXISTING_ROOM_ALL_OK"
            var allFinished = false
            let allSend = Task { @MainActor in
                defer { allFinished = true }
                try await reopened.send(text: "@all Each addressed member must reply with exactly \(allMarker). No tools or other work.", roomID: roomID)
            }
            let allDeadline = ContinuousClock.now.advanced(by: .seconds(120))
            while !allFinished && ContinuousClock.now < allDeadline { try await Task.sleep(for: .milliseconds(50)) }
            if !allFinished {
                allSend.cancel()
                try await client.groupsStop(roomID: roomID, cancelID: "all-timeout-" + roomID)
            }
            try await allSend.value
            let afterAll = try XCTUnwrap(reopened.room(id: roomID))
            let responders = Set(afterAll.visibleEvents.filter { $0.kind == .agent && $0.text?.contains(allMarker) == true }.compactMap(\.memberID))
            XCTAssertEqual(responders, Set(members.map(\.memberID)))
            XCTAssertFalse(afterAll.isRunning)
            XCTAssertNil(afterAll.nativePendingEventID)
            print("NATIVE_GROUP_EXISTING_ROOM_ALL_VERIFIED members=\(responders.count)")
            let stopPrompt = "@\(target.handle) For this cancellation test, use terminal once to run python3 -c 'import time; time.sleep(15)'. Then reply BIGHELP_STOP_TEST_DONE. Do not read or modify files or use other tools."
            let stoppable = Task { @MainActor in try await reopened.send(text: stopPrompt, roomID: roomID) }
            let stopDeadline = ContinuousClock.now.advanced(by: .seconds(45))
            while ContinuousClock.now < stopDeadline {
                if let current = reopened.room(id: roomID), current.isRunning,
                   current.visibleEvents.contains(where: { $0.kind == .human && $0.nativeEvent != nil && $0.text == stopPrompt }) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(reopened.room(id: roomID)?.isRunning == true)
            try await reopened.stopNativeRoom(roomID: roomID, cancelID: "stop-proof-" + roomID)
            _ = await stoppable.result
            _ = try await reopened.openNativeRoom(roomID: roomID)
            XCTAssertFalse(try XCTUnwrap(reopened.room(id: roomID)).isRunning)
            XCTAssertNil(reopened.room(id: roomID)?.nativePendingEventID)
            print("NATIVE_GROUP_EXPLICIT_STOP_VERIFIED")
            reopened.configureNativeClient(nil)
        } catch { failure = error }
        store.configureNativeClient(nil)
        if creationAttempted {
            // Raw public RPC cleanup still works if the typed decoder is the
            // failure being reproduced. Only this test's unique room is touched.
            _ = try await transport.request("groups.stop", params: ["room_id": .string(roomID), "cancel_id": .string("cleanup-" + roomID)])
            _ = try await transport.request("groups.disband", params: ["room_id": .string(roomID)])
            let state = try await transport.request("groups.state", params: ["room_id": .string(roomID), "include_disbanded": .boolean(true)])
            XCTAssertNotNil(state.object?["room"]?.object?["disbanded_at"]?.number)
            print("NATIVE_GROUP_STAGE cleanup_verified")
        }
        await transport.disconnect()
        if let failure { throw failure }
    }

    /// #517 on a real host: Hermes applies a stop whose answer the app never
    /// sees, and the room log settles it; Stop again with the saved cancel ID
    /// is still one stop; a saved stop never holds the next message.
    /// `BIGHELP_LIVE_ROOM_NO_TURNS=1` (a host whose agents must not run) uses
    /// two existing profiles and skips the message, the only step that starts
    /// member turns.
    @MainActor
    func testRealHostedRoomStopWithALostAnswerSettlesFromTheLog() async throws {
        let config = try configuration()
        let environment = ProcessInfo.processInfo.environment
        guard environment["BIGHELP_LIVE_ROOM_STOP"] == "1" else {
            throw XCTSkip("Run explicitly against a disposable host")
        }
        let startsNoTurns = environment["BIGHELP_LIVE_ROOM_NO_TURNS"] == "1"
        let vault = DirectHermesKeychainVault(service: "app.loopdy.room-stop-proof." + UUID().uuidString)
        defer { try? vault.delete() }
        let auth: DirectHermesAuthInput = config["auth_mode"] == "dashboard"
            ? .dashboard : .token(try XCTUnwrap(config["token"]))
        let transport = try await DirectHermesClient.connect(
            address: XCTUnwrap(config["address"]), auth: auth, allowPrivateHTTP: true, vault: vault
        )
        let owner = WorkspaceOwner(authority: try XCTUnwrap(transport.savedConnection.workspaceAuthority),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        let workspace = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
            capabilities: .init(owner: owner, values: Dictionary(uniqueKeysWithValues:
                WorkspaceCapability.allCases.map { ($0, .available) })), currentOwner: { owner })
        let client = HermesHostedRoomClient(workspace: workspace, owner: owner)
        let store = BotModeRoomStore(client: NativeWorkspaceUnavailableClient(), executionEnabled: false, nativeClient: client)
        let roomID = "bighelp-stop-proof-" + UUID().uuidString.lowercased()
        var created = false
        var failure: Error?
        do {
            let profiles: [String]
            if startsNoTurns {
                let listed = try await transport.request("profiles.list", params: ["include_sessions": .boolean(false)])
                let names = (listed.object?["profiles"]?.array ?? []).compactMap { $0.object?["name"]?.string }
                profiles = ["default", try XCTUnwrap(names.first { $0 != "default" && HermesBotModeWireCodec.identifier($0) })]
            } else {
                _ = try? await transport.request("profiles.create", params: ["name": .string("stopcheck")])
                profiles = ["default", "stopcheck"]
            }
            print("ROOM_STOP_PROFILES \(profiles)")
            let capabilities = try await client.groupsCapabilities()
            XCTAssertTrue(capabilities.supportsNativeExecution)
            let members = profiles.map {
                HermesBotModeRoomMember(memberID: $0, profile: $0, handle: $0,
                                        target: ["kind": .string("local"), "profile": .string($0)])
            }
            created = true
            _ = try await client.groupsCreate(roomID: roomID, name: "bighelp temporary stop check", members: members)
            _ = try await store.openNativeRoom(roomID: roomID)

            // Hermes applies the stop; the app never sees its answer.
            var room = try XCTUnwrap(store.room(id: roomID))
            room.setNativeCancelIntent("loopdy-stop-lost-answer")
            try store.persist(room: room)
            let answer = try await transport.request("groups.stop", params: [
                "room_id": .string(roomID), "cancel_id": .string("loopdy-stop-lost-answer"),
            ])
            print("ROOM_STOP_ANSWER \(liveJSON(answer))")
            try await store.syncNativeRoom(roomID: roomID)
            XCTAssertNil(store.room(id: roomID)?.nativePendingCancelID, "The room log settles the lost answer")
            print("ROOM_STOP_STAGE settled_from_log")

            // An older app read past that stop without settling it. Stop
            // again sends the same cancel ID, and Hermes keeps one stop.
            room = try XCTUnwrap(store.room(id: roomID))
            room.setNativeCancelIntent("loopdy-stop-lost-answer")
            try store.persist(room: room)
            try await store.stopNativeRoom(roomID: roomID)
            XCTAssertNil(store.room(id: roomID)?.nativePendingCancelID)
            let log = try await transport.request("groups.log", params: [
                "room_id": .string(roomID), "since_seq": .integer(0), "limit": .integer(500),
                "include_disbanded": .boolean(false),
            ])
            let stops = (log.object?["events"]?.array ?? []).filter {
                $0.object?["kind"]?.string == "room.stop_requested"
                    && $0.object?["payload"]?.object?["cancel_id"]?.string == "loopdy-stop-lost-answer"
            }
            XCTAssertEqual(stops.count, 1, "Stop again with the saved cancel ID is the same stop")
            print("ROOM_STOP_EVENT \(liveJSON(stops.first ?? .null))")
            print("ROOM_STOP_STAGE stop_again_same_event")
            if startsNoTurns { throw LiveRoomStopDone() }

            // A stop that never reached Hermes doesn't hold the next message.
            room = try XCTUnwrap(store.room(id: roomID))
            room.setNativeCancelIntent("loopdy-stop-never-sent")
            try store.persist(room: room)
            let marker = "BIGHELP_STOP_PROOF_NEXT_MESSAGE"
            let sending = Task { @MainActor in try await store.send(text: "@default \(marker)", roomID: roomID) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while ContinuousClock.now < deadline, store.room(id: roomID)?.nativePendingDiscussionEventID == nil,
                  store.room(id: roomID)?.visibleEvents.contains(where: { $0.text?.contains(marker) == true }) != true {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(store.room(id: roomID)?.nativePendingCancelID)
            try await store.stopNativeRoom(roomID: roomID)
            _ = await sending.result
            let afterSend = try await transport.request("groups.log", params: [
                "room_id": .string(roomID), "since_seq": .integer(0), "limit": .integer(500),
                "include_disbanded": .boolean(false),
            ])
            let delivered = (afterSend.object?["events"]?.array ?? []).contains {
                $0.object?["kind"]?.string == "message.user"
                    && $0.object?["payload"]?.object?["text"]?.string?.contains(marker) == true
            }
            XCTAssertTrue(delivered, "The next message reached Hermes")
            XCTAssertNil(store.room(id: roomID)?.nativePendingCancelID)
            XCTAssertEqual(store.room(id: roomID)?.isRunning, false)
            print("ROOM_STOP_STAGE next_message_sent")
        } catch is LiveRoomStopDone {
        } catch { failure = error }
        store.configureNativeClient(nil)
        if created {
            if !startsNoTurns {
                _ = try? await transport.request("groups.stop", params: ["room_id": .string(roomID), "cancel_id": .string("cleanup-" + roomID)])
            }
            _ = try? await transport.request("groups.disband", params: ["room_id": .string(roomID)])
            let state = try? await transport.request("groups.state", params: ["room_id": .string(roomID), "include_disbanded": .boolean(true)])
            print("ROOM_STOP_CLEANUP room=\(roomID) disbanded=\(state?.object?["room"]?.object?["disbanded_at"]?.number != nil)")
        }
        await transport.disconnect()
        if let failure { throw failure }
    }

    private struct LiveRoomStopDone: Error {}

    private func liveJSON(_ value: BighelpJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    @MainActor
    func testRealNativeMediaBytesAndRestoredDelivery() async throws {
        let config = try configuration()
        guard config["real_host_acceptance"] == "true" else { throw XCTSkip("Explicit live acceptance required") }
        let imagePath = try XCTUnwrap(config["image_path"])
        let videoPath = try XCTUnwrap(config["video_path"])
        let vault = DirectHermesKeychainVault(service: "app.loopdy.media-proof." + UUID().uuidString)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? vault.delete(); try? FileManager.default.removeItem(at: root) }
        let workspace = DirectHermesWorkspaceStore(vault: vault, drafts: .init(root: root.appending(path: "live")))
        defer { workspace.suspendForPresentationExit() }
        try await workspace.connect(address: XCTUnwrap(config["address"]), auth: .token(XCTUnwrap(config["token"])), allowPrivateHTTP: false)
        XCTAssertTrue(workspace.isConnected)
        workspace.selectedProfile = "default"
        await workspace.newChat()
        let chat = try XCTUnwrap(workspace.selectedChat)
        let text = "BIGHELP_NATIVE_MEDIA_OK\nMEDIA:\(imagePath)\nMEDIA:\(videoPath)"
        _ = try await sendForVoiceWithTimeout(chat.client,
            message: "App delivery verification. Reply with exactly the following three lines, without code fences. Do not call any tools or inspect any files.\n" + text)
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while chat.model.items.flatMap(\.attachments).count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let attachments = chat.model.items.flatMap(\.attachments)
        XCTAssertEqual(attachments.count, 2, "The real native final must acquire both media attachments")
        XCTAssertTrue(attachments.contains { $0.kind == .image && !$0.data.isEmpty })
        XCTAssertTrue(attachments.contains { $0.mimeType.hasPrefix("video/") && !$0.data.isEmpty })
        XCTAssertTrue(chat.model.items.contains { $0.role == .assistant && $0.content == .message("BIGHELP_NATIVE_MEDIA_OK") })
        print("NATIVE_MEDIA_LIVE_DELIVERY_VERIFIED attachments=\(attachments.count)")

        // Stock-shaped terminal generator records use the same actual public
        // byte services. This does not claim a new provider generation ran.
        let transport = try XCTUnwrap(workspace.nativeClient)
        let owner = WorkspaceOwner(authority: try XCTUnwrap(transport.savedConnection.workspaceAuthority),
            authenticationGeneration: UUID(), connectionGeneration: UUID())
        let native = DirectHermesWorkspaceClient(rpc: transport, http: transport, owner: owner,
            capabilities: .init(owner: owner), currentOwner: { owner })
        let resolver = DirectHermesGeneratedMediaClient(workspace: native, owner: owner, currentOwner: { owner })
        for (kind, path) in [("image", imagePath), ("video", videoPath)] {
            let result = try String(decoding: JSONSerialization.data(withJSONObject: ["success": true, kind: path]), as: UTF8.self)
            let event = ChatActivityEvent(eventID: kind, sessionID: chat.id, turnID: "media-proof", kind: .tool,
                lifecycle: .succeeded, title: kind + "_generate", summary: nil, detail: nil, occurredAt: 1,
                toolCallID: kind, toolName: kind + "_generate", result: result, sourceOrder: 1)
            let resolved = try await resolver.resolve(agentID: "default", storedID: chat.client.storedID, event: event)
            XCTAssertEqual(resolved.attachments.count, 1)
            XCTAssertEqual(resolved.attachments.first?.data, attachments.first { $0.fileName == URL(fileURLWithPath: path).lastPathComponent }?.data)
        }
        print("NATIVE_MEDIA_GENERATOR_BYTE_PATHS_VERIFIED")

        let stored = chat.client.storedID
        await workspace.suspend()
        let reopened = DirectHermesWorkspaceStore(vault: vault, drafts: .init(root: root.appending(path: "reopened")))
        defer { reopened.suspendForPresentationExit() }
        try await reopened.connect(address: XCTUnwrap(config["address"]), auth: .token(XCTUnwrap(config["token"])), allowPrivateHTTP: false)
        XCTAssertTrue(reopened.isConnected)
        reopened.selectedProfile = "default"
        await reopened.loadSessions()
        let summary = try XCTUnwrap(reopened.sessions.first { $0.id == stored })
        await reopened.openSession(summary)
        let restored = try XCTUnwrap(reopened.selectedChat)
        let restoreDeadline = ContinuousClock.now.advanced(by: .seconds(90))
        while restored.model.items.flatMap(\.attachments).count < 2 && ContinuousClock.now < restoreDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(restored.model.items.flatMap(\.attachments), attachments)
        XCTAssertEqual(restored.model.items.filter { $0.role == .assistant && !$0.attachments.isEmpty }.count, 1)
        XCTAssertTrue(restored.client.journal.unresolved.isEmpty)
        print("NATIVE_MEDIA_COLD_HISTORY_VERIFIED")
        await reopened.suspend()
    }

    @MainActor
    func testRealNativeFollowupWithoutReopening() async throws {
        let config = try configuration()
        guard config["real_host_acceptance"] == "true" else { throw XCTSkip("Explicit live acceptance required") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "app.loopdy.followup-proof." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let hosts = BighelpHostRegistry(root: root.appending(path: "hosts"), keychainService: suite,
            independentRoot: root.appending(path: "independent"), defaults: preferences)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        hosts.useIndependentWorkspace()
        let (pendingID, workspace) = try hosts.makePendingWorkspace()
        defer { hosts.discardPending(pendingID) }
        try await workspace.connect(address: XCTUnwrap(config["address"]),
            auth: .token(XCTUnwrap(config["token"])), allowPrivateHTTP: false)
        let configured = try hosts.commit(pendingID, workspace: workspace, name: "Temporary follow-up proof")
        defer { try? hosts.remove(configured) }
        let connections = WorkspaceConnectionStore(hosts: hosts)
        let owner = try XCTUnwrap(connections.owner)
        try connections.installCapabilities(.init(owner: owner, values: Dictionary(uniqueKeysWithValues:
            WorkspaceCapability.allCases.map { ($0, .available) })))
        let runtimeSuite = "app.loopdy.native-workspace." + owner.authority.cacheScopeID
        let runtimePreferences = try XCTUnwrap(UserDefaults(suiteName: runtimeSuite))
        let previousPreferences = runtimePreferences.persistentDomain(forName: runtimeSuite)
        defer {
            if let previousPreferences {
                runtimePreferences.setPersistentDomain(previousPreferences, forName: runtimeSuite)
            } else {
                runtimePreferences.removePersistentDomain(forName: runtimeSuite)
            }
        }
        let runtime = try NativeWorkspaceRuntime(connections: connections, authority: owner.authority,
            settings: SettingsStore(defaults: preferences, legacyThemeLogoDirectory: root.appending(path: "logos")),
            userIdentity: UserIdentityStore(defaults: preferences, avatarDirectory: root.appending(path: "avatars")),
            directory: root.appending(path: "runtime"))
        defer { runtime.retire() }
        hosts.onNativeEvent = { _, event in runtime.receive(event) }
        await runtime.refresh()
        XCTAssertTrue(runtime.isReady)
        let bridge = runtime.bridge
        let catalog = runtime.sessions
        let features = runtime.features
        let record = try await catalog.createDirect(agentID: "default")
        let route = AppRoute.chat(conversationID: record.id)
        XCTAssertTrue(features.prepareNewChat(route))
        let client = try XCTUnwrap(bridge.conversationClient(for: record) as? DirectHermesConversationClient)
        hosts.onNativeEvent = { _, event in
            if event.sessionID == client.runtimeID,
               ["message.start", "message.complete", "session.info", "error"].contains(event.type) {
                print("FOLLOWUP_EVENT type=\(event.type) seq=\(event.sequence ?? -1) idle=\(event.payload["running"]?.boolean == false)")
            }
            runtime.receive(event)
        }
        var failure: Error?
        do {
            // A newly created chat is already prepared. Empty native chats may
            // not appear in history until their first accepted turn.
            guard case .chat(let model)? = features.preparedModel(for: route) else {
                throw DirectHermesError.invalidResponse
            }
            for turn in 1...2 {
                let marker = "BIGHELP_FOLLOWUP_\(turn)_OK"
                model.draft = "Reply with exactly \(marker). No tools, memory changes, or other work."
                print("FOLLOWUP_BEFORE turn=\(turn) ready=\(client.isReadyForSubmission) recovery=\(client.needsRecovery) sending=\(model.isSending) canSend=\(model.canSend)")
                XCTAssertTrue(model.canSend)
                var finished = false
                let send = Task { @MainActor in
                    defer { finished = true }
                    await model.send()
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(90))
                while !finished && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                let hasReply = model.items.contains { item in
                    guard item.role == .assistant, case .message(let text) = item.content else { return false }
                    return text.contains(marker)
                }
                model.draft = "Unsent follow-up"
                print("FOLLOWUP_AFTER turn=\(turn) finished=\(finished) reply=\(hasReply) ready=\(client.isReadyForSubmission) recovery=\(client.needsRecovery) running=\(client.projection.running) sending=\(model.isSending) canSend=\(model.canSend) unresolved=\(client.journal.unresolved.count) warm=\(features.canReturnToWarmSession(id: record.id))")
                if !finished { send.cancel() }
                await send.value
                XCTAssertTrue(finished && hasReply)
                XCTAssertTrue(model.canSend)
                XCTAssertFalse(client.needsRecovery)
                XCTAssertTrue(client.journal.unresolved.isEmpty)
                guard hasReply, model.canSend, client.journal.unresolved.isEmpty else {
                    throw DirectHermesError.invalidResponse
                }
            }
        } catch { failure = error }
        if client.projection.running {
            _ = try await workspace.nativeClient?.request("session.interrupt", params: ["session_id": .string(client.runtimeID)])
        }
        _ = try await workspace.nativeClient?.request("session.close", params: ["session_id": .string(client.runtimeID)])
        let active = try await workspace.nativeClient?.request("session.active_list", params: [:])
        XCTAssertFalse(active?.object?["sessions"]?.array?.contains { $0.object?["id"]?.string == client.runtimeID } == true)
        print("FOLLOWUP_CLEANUP runtime_closed")
        if let failure { throw failure }
    }

    @MainActor
    func testRealNativeOffscreenStreamingAndWarmReturn() async throws {
        let config = try configuration()
        guard config["real_host_acceptance"] == "true" else { throw XCTSkip("Explicit live acceptance required") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "app.loopdy.navigation-proof." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let hosts = BighelpHostRegistry(root: root.appending(path: "hosts"), keychainService: suite,
            independentRoot: root.appending(path: "independent"), defaults: preferences)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        hosts.useIndependentWorkspace()
        let (pendingID, hostWorkspace) = try hosts.makePendingWorkspace()
        defer { hosts.discardPending(pendingID) }
        try await hostWorkspace.connect(address: XCTUnwrap(config["address"]),
            auth: .token(XCTUnwrap(config["token"])), allowPrivateHTTP: false)
        XCTAssertTrue(hostWorkspace.isConnected)
        print("NATIVE_NAV_STAGE connected")
        let configured = try hosts.commit(pendingID, workspace: hostWorkspace, name: "Temporary navigation proof")
        defer { try? hosts.remove(configured) }
        let connections = WorkspaceConnectionStore(hosts: hosts)
        let owner = try XCTUnwrap(connections.owner)
        try connections.installCapabilities(.init(owner: owner, values: Dictionary(uniqueKeysWithValues:
            WorkspaceCapability.allCases.map { ($0, .available) })))
        let bridge = try NativeWorkspaceSessionBridge(connections: connections, authority: owner.authority,
            directory: root.appending(path: "sessions"))
        let catalog = SessionCatalogStore(client: bridge, defaults: preferences)
        bridge.onSessionContextChange = { observedOwner, snapshot in
            guard connections.owner == observedOwner else { return }
            catalog.reconcileSessionContext(snapshot)
        }
        hosts.onNativeEvent = { _, event in bridge.receive(event) }
        let features = ShellFeatureStore(timing: .immediate, catalog: catalog,
            allowsNewChatAgentDefaults: false, dashboardSource: NativeWorkspaceUnavailableClient(),
            conversationClient: { record, _ in bridge.conversationClient(for: record) },
            conversationPrepared: { model, client in bridge.bind(model, client: client) },
            navigationWorkspaceOwner: { connections.owner },
            nativeWarmSessionIsCurrent: { record, model in bridge.isWarmSession(record, model: model) })
        bridge.onSessionRetired = {
            print("NATIVE_NAV_STAGE bridge_retired")
            features.retireNavigationSession(id: $0)
        }
        defer { features.resetForAccountBoundary(); bridge.resetForAccountBoundary() }
        let record = try await catalog.createDirect(agentID: "default")
        print("NATIVE_NAV_STAGE created")
        let route = AppRoute.chat(conversationID: record.id)
        XCTAssertTrue(features.prepareNewChat(route))
        print("NATIVE_NAV_STAGE cached")
        let seededClient = try XCTUnwrap(bridge.conversationClient(for: record) as? DirectHermesConversationClient)
        _ = try await sendForVoiceWithTimeout(seededClient, message: "Reply with exactly BIGHELP_NAVIGATION_SEED. No tools.")
        print("NATIVE_NAV_STAGE seed_completed")
        do {
            _ = try await features.startNavigationHydration(id: record.id).value()
        } catch {
            let current = catalog.session(id: record.id)
            print("NATIVE_NAV_FAILURE owner=\(connections.owner == owner) stored=\(current?.remoteStoredID == record.remoteStoredID) source=\(current?.remoteSource == record.remoteSource) agents=\(current?.agentIDs == record.agentIDs) model=\(features.preparedModel(for: route) != nil)")
            throw error
        }
        print("NATIVE_NAV_STAGE hydrated")
        guard case .chat(let model)? = features.preparedModel(for: route) else { return XCTFail("Missing real native model") }
        let client = try XCTUnwrap(bridge.conversationClient(for: record) as? DirectHermesConversationClient)
        XCTAssertTrue(client.isReadyForSubmission)
        let marker = "BIGHELP_OFFSCREEN_STREAM_OK"
        model.draft = "For this app verification, use terminal once to run python3 -c 'import time; time.sleep(8); print(\"BIGHELP_TOOL_DONE\")'. Then reply with exactly \(marker). Do not read or modify files or use any other tools."
        let send = Task { await model.send() }
        let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(45))
        while !client.projection.running && ContinuousClock.now < admissionDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(client.projection.running)
        print("NATIVE_NAV_STAGE admitted")
        let priorSequence = client.projection.lastSequence
        model.draft = "Unsent navigation draft"
        features.retainModels(ownedBy: [])
        let offscreenDeadline = ContinuousClock.now.advanced(by: .seconds(45))
        while client.projection.lastSequence <= priorSequence && ContinuousClock.now < offscreenDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(client.projection.lastSequence, priorSequence)
        XCTAssertEqual(connections.owner, owner)
        XCTAssertTrue(features.canReturnToWarmSession(id: record.id))
        print("NATIVE_NAV_STAGE offscreen_warm")
        let start = ContinuousClock.now
        XCTAssertTrue(try features.prepareCachedForUserNavigation(route))
        _ = try await features.startNavigationHydration(id: record.id).value()
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(2))
        guard case .chat(let retained)? = features.preparedModel(for: route) else { return XCTFail("Lost live owner") }
        XCTAssertTrue(retained === model)
        XCTAssertEqual(model.draft, "Unsent navigation draft")
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(90))
        while client.projection.running && ContinuousClock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if client.projection.running {
            send.cancel()
            _ = try await hostWorkspace.nativeClient?.request("session.interrupt", params: ["session_id": .string(client.runtimeID)])
        }
        await send.value
        XCTAssertTrue(model.items.contains { item in
            guard item.role == .assistant, case .message(let text) = item.content else { return false }
            return text.contains(marker)
        })
        XCTAssertTrue(catalog.session(id: record.id)?.items.contains { item in
            guard item.role == .assistant, case .message(let text) = item.content else { return false }
            return text.contains(marker)
        } == true)
        XCTAssertFalse(model.isSending)
        XCTAssertTrue(client.journal.unresolved.isEmpty)
        XCTAssertEqual(connections.owner, owner)
        print("NATIVE_DIRECT_WARM_RETURN_DURATION \(elapsed)")
        print("NATIVE_DIRECT_OFFSCREEN_AND_FINAL_VERIFIED")
    }

    @MainActor
    func testRealNativeSteerQueueAndInterruptSend() async throws {
        let config = try configuration()
        guard config["real_host_acceptance"] == "true" else { throw XCTSkip("Explicit live acceptance required") }
        let vault = DirectHermesKeychainVault(service: "app.loopdy.send-proof." + UUID().uuidString)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? vault.delete(); try? FileManager.default.removeItem(at: root) }
        let transport = try await DirectHermesClient.connect(address: XCTUnwrap(config["address"]),
            auth: .token(XCTUnwrap(config["token"])), allowPrivateHTTP: false, vault: vault)
        defer { Task { await transport.disconnect() } }
        for behavior in [MidSessionChatBehavior.steer, .queued, .interruptAndSend] {
            let created = try await transport.request("session.create", params: [
                "source": .string("desktop"), "profile": .string("default"),
                "close_on_disconnect": .boolean(true),
            ])
            let runtime = try XCTUnwrap(created.object?["session_id"]?.string)
            let stored = try XCTUnwrap(created.object?["stored_session_id"]?.string)
            let replay = try await transport.request("session.events.since", params: [
                "session_id": .string(runtime), "last_seen": .integer(0),
            ])
            let epoch = try XCTUnwrap(replay.object?["epoch"]?.string)
            let client = try DirectHermesConversationClient(rpc: transport,
                hostIdentity: transport.savedConnection.identity, profile: "default",
                runtimeID: runtime, storedID: stored, title: "Native send verification", epoch: epoch,
                drafts: DirectHermesDraftStore(root: root))
            var toolStarted = false
            transport.onEvent = { event in
                if event.sessionID == runtime && event.type == "tool.start" { toolStarted = true }
                client.receive(event)
            }
            try await client.recover(epoch: epoch)
            let first = Task {
                try await client.send(message: "Use terminal once to run python3 -c 'import time; time.sleep(6); print(\"BIGHELP_MODE_TOOL_DONE\")'. Then reply BASE_TURN_DONE. Do not read or modify any files or use other tools.", conversationID: client.conversationID)
            }
            let startDeadline = ContinuousClock.now.advanced(by: .seconds(60))
            while !toolStarted && ContinuousClock.now < startDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(toolStarted, "The live tool phase must precede the mid-session request")
            XCTAssertTrue(client.projection.running)
            let marker = "BIGHELP_MODE_" + behavior.rawValue.uppercased() + "_OK"
            var submissionFailure: Error?
            do {
                let outcome = try await client.sendMidSession(message: "Reply with exactly \(marker). No tools or other work.",
                    attachments: [], conversationID: client.conversationID, behavior: behavior, onDraft: { _ in })
                XCTAssertEqual(outcome, .accepted)
                // The original running prompt can still own its journal row.
                // Only this acknowledged mid-session intent must be retired.
                XCTAssertFalse(client.journal.unresolved.contains { $0.text.contains(marker) })
                XCTAssertFalse(client.needsRecovery)
                let completionDeadline = ContinuousClock.now.advanced(by: .seconds(90))
                var containsReply = false
                repeat {
                    containsReply = client.projection.items.contains { item in
                        guard item.role == .assistant, case .message(let text) = item.content else { return false }
                        return text.contains(marker)
                    }
                    if containsReply && !client.projection.running { break }
                    try await Task.sleep(for: .milliseconds(50))
                } while ContinuousClock.now < completionDeadline
                XCTAssertTrue(containsReply, "The accepted \(behavior.rawValue) must produce its real reply")
                XCTAssertFalse(client.projection.running)
                XCTAssertTrue(client.journal.unresolved.isEmpty)
                print("NATIVE_SEND_MODE_COMPLETED \(behavior.rawValue) reply=\(containsReply)")
            } catch { submissionFailure = error }
            if client.projection.running || submissionFailure != nil {
                first.cancel()
                _ = try await transport.request("session.interrupt", params: ["session_id": .string(runtime)])
            }
            _ = await first.result
            client.suspend()
            if let submissionFailure { throw submissionFailure }
        }
        await transport.disconnect()
    }

    @MainActor
    func testDashboardNativeCronLifecycleAndRoomDiscovery() async throws {
        let config = try configuration()
        let vault = DirectHermesKeychainVault(service: "app.loopdy.direct-cron." + UUID().uuidString)
        defer { try? vault.delete() }
        let client = try await DirectHermesClient.connect(address: XCTUnwrap(config["address"]),
            auth: .dashboard, allowPrivateHTTP: true, vault: vault)
        let authority = try XCTUnwrap(client.savedConnection.workspaceAuthority)
        let owner = WorkspaceOwner(authority: authority, authenticationGeneration: UUID(), connectionGeneration: UUID())
        let workspace = DirectHermesWorkspaceClient(rpc: client, http: client, owner: owner,
            capabilities: .init(owner: owner, values: Dictionary(uniqueKeysWithValues: WorkspaceCapability.allCases.map { ($0, .available) })),
            currentOwner: { owner })
        let context = try await workspace.perform(.nativeContext, payload: [:], owner: owner)
        XCTAssertEqual(context["principal"], .null)
        let tasks = DirectHermesScheduledTasksClient(workspace: workspace, owner: owner, currentOwner: { owner }, servingProfileID: "default")
        let schedule = ScheduleInput.once(date: Date.now.addingTimeInterval(86400), timeZoneID: TimeZone.current.identifier)
        let created = try await tasks.create(.init(agentID: "default", name: "Isolated native cron", instructions: "Synthetic fixture only", schedule: schedule, deliveryTarget: "local"))
        let listed = try await tasks.list(agentID: "default")
        XCTAssertTrue(listed.contains { $0.id == created.id })
        let edited = try await tasks.update(id: created.id, agentID: "default", changes: .init(name: "Edited native cron", instructions: "Synthetic fixture only", schedule: schedule, deliveryTarget: "local"))
        XCTAssertEqual(edited.name, "Edited native cron")
        let paused = try await tasks.setPaused(true, id: created.id, agentID: "default")
        XCTAssertTrue(paused.isPaused)
        let resumed = try await tasks.setPaused(false, id: created.id, agentID: "default")
        XCTAssertFalse(resumed.isPaused)
        try await tasks.delete(id: created.id, agentID: "default")
        let remaining = try await tasks.list(agentID: "default")
        XCTAssertFalse(remaining.contains { $0.id == created.id })
        let rooms = HermesHostedRoomClient(workspace: workspace, owner: owner)
        let capabilities = try await rooms.groupsCapabilities()
        XCTAssertTrue(capabilities.supports("groups.list"))
        _ = try await rooms.groupsList(offset: 0, limit: 50)
        await client.disconnect()
    }

    @MainActor
    func testNativePasswordBearerStreamingAndReconnectAgainstStockHost() async throws {
        let config = try configuration()
        let address = try XCTUnwrap(config["address"])
        let username = try XCTUnwrap(config["username"])
        let password = try XCTUnwrap(config["password"])
        let vault = DirectHermesKeychainVault(service: "app.loopdy.direct-proof." + UUID().uuidString)
        defer { try? vault.delete() }
        let client = try await DirectHermesClient.connect(address: address,
            auth: .password(username: username, password: password), allowPrivateHTTP: true, vault: vault)
        try vault.save(client.savedConnection)
        XCTAssertEqual(try vault.load(), client.savedConnection)
        guard case .bearer(let accessToken, _, _) = client.savedConnection.authentication else { return XCTFail("No provider bearer") }
        let tokenClient = try await DirectHermesClient.connect(address: address, auth: .token(accessToken), allowPrivateHTTP: true, vault: vault)
        await tokenClient.disconnect()
        var kinds = Set<String>()
        var content = ""
        var terminal = false
        client.onEvent = { event in
            kinds.insert(event.type)
            if event.type == "message.complete" { content = event.payload["text"]?.string ?? content }
            if event.type == "session.info", event.payload["running"]?.boolean == false { terminal = true }
        }
        let created = try await client.request("session.create", params: ["source": .string("desktop"), "profile": .string("default")])
        let sid = try XCTUnwrap(created.object?["session_id"]?.string)
        terminal = false
        let submitted = try await client.request("prompt.submit", params: ["session_id": .string(sid), "text": .string("Run pwd once, then finish the direct streaming fixture.")])
        XCTAssertEqual(submitted.object?["status"]?.string, "streaming")
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !terminal && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(terminal)
        XCTAssertTrue(kinds.isSuperset(of: ["tool.start", "tool.complete", "message.delta", "reasoning.delta"]))
        XCTAssertEqual(content, "Direct streaming fixture complete.")
        let saved = client.savedConnection
        await client.disconnect()
        let restored = try await DirectHermesClient.restore(saved, vault: vault)
        let resumed = try await restored.request("session.activate", params: ["session_id": .string(sid)])
        XCTAssertEqual(resumed.object?["session_id"]?.string, sid)
        await restored.disconnect()
    }

    @MainActor
    func testActiveReconnectRetainsTimelineDraftAndKnownAdmission() async throws {
        let config = try configuration()
        let vault = DirectHermesKeychainVault(service: "app.loopdy.direct-active." + UUID().uuidString)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? vault.delete(); try? FileManager.default.removeItem(at: root) }
        let client = try await DirectHermesClient.connect(address: XCTUnwrap(config["address"]),
            auth: .password(username: XCTUnwrap(config["username"]), password: XCTUnwrap(config["password"])),
            allowPrivateHTTP: true, vault: vault)
        try vault.save(client.savedConnection)
        var epoch = ""
        client.onEvent = { if $0.type == "gateway.ready" { epoch = $0.payload["replay_epoch"]?.string ?? "" } }
        let created = try await client.request("session.create", params: ["source": .string("desktop"), "profile": .string("default")])
        let observed = AdmissionObservedRPC(client)
        let adapter = try DirectHermesConversationClient(rpc: observed, hostIdentity: client.savedConnection.identity,
            profile: "default", runtimeID: XCTUnwrap(created.object?["session_id"]?.string),
            storedID: XCTUnwrap(created.object?["stored_session_id"]?.string), title: "Live", epoch: epoch,
            drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: adapter.conversationID, client: adapter, initialItems: [])
        adapter.model = model
        client.onEvent = { adapter.receive($0) }
        model.draft = "Run pwd and hold direct streaming for the reconnect test."
        let send = Task { await model.send() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        // A local assistant placeholder is not proof of host admission.
        while (!observed.streamingAdmitted || !adapter.projection.running || !adapter.projection.items.contains(where: { $0.role == .assistant })) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(observed.streamingAdmitted)
        XCTAssertTrue(adapter.projection.running)
        XCTAssertTrue(model.isSending)
        let acceptedIDs = model.items.map(\.id)
        model.draft = "Unsent draft survives reconnect"
        adapter.suspend()
        let saved = client.savedConnection
        await client.disconnect()
        let restored = try await DirectHermesClient.restore(saved, vault: vault)
        adapter.rebind(restored)
        restored.onEvent = { adapter.receive($0) }
        try await adapter.recover(epoch: epoch)
        let finished = ContinuousClock.now.advanced(by: .seconds(20))
        while model.isSending && ContinuousClock.now < finished { try await Task.sleep(for: .milliseconds(20)) }
        await send.value
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.draft, "Unsent draft survives reconnect")
        XCTAssertEqual(model.items.filter { $0.role == .human }.count, 1)
        XCTAssertEqual(model.items.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(Array(model.items.map(\.id).prefix(acceptedIDs.count)), acceptedIDs)
        XCTAssertFalse(adapter.needsRecovery, "A known accepted turn settling on replay must not require manual receipt cleanup")
        await restored.disconnect()
    }

    /// Opt-in live proof for the path used by native live voice delegation:
    /// both submissions use the production DirectHermesConversationClient,
    /// receive the host's actual websocket events, and must settle their own
    /// voice reply waiter before the next submission starts.
    @MainActor
    func testRealSendForVoiceSettlesTwoSequentialNativeTurns() async throws {
        let config = try configuration()
        let address = try XCTUnwrap(config["address"])
        let vault = DirectHermesKeychainVault(service: "app.loopdy.direct-voice." + UUID().uuidString)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? vault.delete(); try? FileManager.default.removeItem(at: root) }

        let auth: DirectHermesAuthInput
        if let token = config["token"], !token.isEmpty {
            auth = .token(token)
        } else {
            // The official dashboard host owns the bootstrap cookie/session flow.
            // A token is optional so this test can run against its address-only
            // probe configuration without changing host authentication policy.
            auth = .dashboard
        }
        let transport = try await DirectHermesClient.connect(
            address: address, auth: auth, allowPrivateHTTP: true, vault: vault
        )
        defer { Task { await transport.disconnect() } }

        let created = try await transport.request("session.create", params: [
            "profile": .string("default"), "source": .string("desktop"),
        ])
        let runtime = try XCTUnwrap(created.object?["session_id"]?.string)
        let stored = try XCTUnwrap(created.object?["stored_session_id"]?.string)
        let replay = try await transport.request("session.events.since", params: [
            "session_id": .string(runtime), "last_seen": .integer(0),
        ])
        let epoch = try XCTUnwrap(replay.object?["epoch"]?.string)
        let conversation = try DirectHermesConversationClient(
            rpc: transport, hostIdentity: transport.savedConnection.identity, profile: "default",
            runtimeID: runtime, storedID: stored, title: "Live voice proof", epoch: epoch,
            drafts: DirectHermesDraftStore(root: root)
        )
        transport.onEvent = { [weak conversation] event in conversation?.receive(event) }
        defer { conversation.suspend() }

        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let firstToken = "VOICE_ROUND_A_\(nonce)"
        let secondToken = "VOICE_ROUND_B_\(nonce)"
        let first = try await sendForVoiceWithTimeout(conversation,
            message: "Reply with exactly \(firstToken), with no punctuation."
        )
        let firstText = first.items.compactMap { item -> String? in
            guard item.role == .assistant, case .message(let text) = item.content else { return nil }
            return text
        }.joined(separator: "\n")
        XCTAssertTrue(firstText.contains(firstToken))

        let second = try await sendForVoiceWithTimeout(conversation,
            message: "Reply with exactly \(secondToken), with no punctuation."
        )
        let secondText = second.items.compactMap { item -> String? in
            guard item.role == .assistant, case .message(let text) = item.content else { return nil }
            return text
        }.joined(separator: "\n")
        XCTAssertTrue(secondText.contains(secondToken))
        XCTAssertTrue(conversation.journal.unresolved.isEmpty)
    }

    @MainActor
    private func sendForVoiceWithTimeout(
        _ conversation: DirectHermesConversationClient,
        message: String
    ) async throws -> ConversationResponse {
        try await withThrowingTaskGroup(of: ConversationResponse.self) { group in
            group.addTask { try await conversation.sendForVoice(message: message) }
            group.addTask {
                try await Task.sleep(for: .seconds(75))
                throw DirectHermesError.timedOut(outcomeUnknown: true)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw DirectHermesError.timedOut(outcomeUnknown: true)
            }
            return result
        }
    }

    @MainActor
    private final class AdmissionObservedRPC: DirectHermesRPC {
        let base: DirectHermesClient
        private(set) var streamingAdmitted = false
        init(_ base: DirectHermesClient) { self.base = base }
        var onEvent: ((DirectHermesEvent) -> Void)? {
            get { base.onEvent }
            set { base.onEvent = newValue }
        }
        func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
            let result = try await base.request(method, params: params)
            if method == "prompt.submit", result.object?["status"]?.string == "streaming" { streamingAdmitted = true }
            return result
        }
        func disconnect() async { await base.disconnect() }
    }

    @MainActor
    func testWrongPasswordAndBearerAreRejectedWithoutPersistence() async throws {
        let config = try configuration()
        let address = try XCTUnwrap(config["address"])
        let vault = DirectHermesKeychainVault(service: "app.loopdy.direct-negative." + UUID().uuidString)
        defer { try? vault.delete() }
        for auth in [DirectHermesAuthInput.token(UUID().uuidString), .password(username: "direct-fixture", password: UUID().uuidString)] {
            do {
                let client = try await DirectHermesClient.connect(address: address, auth: auth, allowPrivateHTTP: true, vault: vault)
                await client.disconnect()
                XCTFail("Invalid credentials accepted")
            } catch { XCTAssertEqual(error as? DirectHermesError, .invalidCredentials) }
            XCTAssertNil(try vault.load())
        }
    }
}
