import Foundation

extension BotModeRoomStore {
    /// Keeps the settings a `groups.state` read returned. A room without `context` has none.
    func recordNativeRoomSettings(roomID: String, state: HermesBotModeRoomState) {
        guard state.roomID == roomID, let context = state.context else {
            if nativeRoomSettings[roomID] != nil { nativeRoomSettings[roomID] = nil }
            return
        }
        let settings = HermesBotModeRoomSettings(context: context, support: .init(driverStatus: state.driverStatus))
        if nativeRoomSettings[roomID] != settings { nativeRoomSettings[roomID] = settings }
    }

    /// Reads the room's settings for Group Settings. Nil when the read worked, else why not.
    func refreshNativeRoomSettings(roomID: String) async -> String? {
        guard let nativeClient, let room = room(id: roomID), room.hasNativeRoom else { return nil }
        let boundary = nativeBoundaryGeneration
        do {
            let capabilities = try await negotiatedNativeCapabilities(using: nativeClient, boundary: boundary)
            guard capabilities.supports("groups.state") else { return nil }
            let state = try await nativeClient.groupsState(roomID: roomID, includeDisbanded: false)
            try requireNativeBoundary(boundary)
            guard let current = self.room(id: roomID) else { return nil }
            try validateNativeState(state, previous: current)
            recordNativeRoomSettings(roomID: roomID, state: state)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return "The settings couldn’t be loaded. Check the connection, then try again."
        }
    }

    /// A room on this connection whose runtime picks who answers automatically, so New Group
    /// Chat can offer it before its own room exists.
    var offersAutomaticRoutingForNewRooms: Bool {
        nativeRoomSettings.values.contains { $0.support.modes.contains(.auto) }
    }

    /// Saves a room's settings. What happens shows on the room: Hermes' settings once saved,
    /// or the edit with why it didn't save (`nativePendingContext`). Saves for one room go one
    /// at a time; an edit made meanwhile goes next, and only the newest.
    func saveNativeRoomContext(roomID: String, _ edit: HermesBotModeRoomContext) async {
        nativeRoomSettingsQueued[roomID] = edit
        guard !nativeRoomSettingsSaving.contains(roomID) else { return }
        nativeRoomSettingsSaving.insert(roomID)
        defer { nativeRoomSettingsSaving.remove(roomID) }
        while let next = nativeRoomSettingsQueued.removeValue(forKey: roomID) {
            await writeNativeRoomContext(roomID: roomID, next)
        }
    }

    /// Drops an edit Hermes didn't save, so the page shows Hermes' settings again.
    func discardNativeRoomContextEdit(roomID: String) throws {
        try updateNativeRoom(roomID) { room in
            guard room.nativePendingContext != nil else { return false }
            room.setNativeContextIntent(nil)
            return true
        }
    }

    /// Gives a discussion Hermes paused at its cap one more budget, then reads the room so the
    /// card loses its buttons. A problem shows on the card (`nativeContinueProblems`).
    func continueNativeDiscussion(roomID: String, discussionEventID: String) async {
        guard !nativeContinuesInFlight.contains(discussionEventID) else { return }
        guard let client = nativeClient as? any HermesBotModeRoomSettingsClient,
              nativeCapabilities?.supports("groups.continue") == true else {
            nativeContinueProblems[discussionEventID] = "This computer can’t continue the discussion."
            return
        }
        let boundary = nativeBoundaryGeneration
        nativeContinuesInFlight.insert(discussionEventID)
        nativeContinueProblems[discussionEventID] = nil
        defer { nativeContinuesInFlight.remove(discussionEventID) }
        do {
            _ = try await client.groupsContinue(roomID: roomID, discussionEventID: discussionEventID)
            try requireNativeBoundary(boundary)
        } catch is CancellationError {
            return
        } catch {
            guard boundary == nativeBoundaryGeneration else { return }
            nativeContinueProblems[discussionEventID] = Self.continueProblem(error)
        }
        // The bots answer again in the room, and the log shows the Continue (or no change).
        try? await syncNativeRoom(roomID: roomID, boundary: boundary)
        beginNativeRoomObservation(roomID: roomID)
    }

    private func writeNativeRoomContext(roomID: String, _ edit: HermesBotModeRoomContext) async {
        guard let current = room(id: roomID), current.hasNativeRoom else { return }
        // The same edit goes again under its first `event_id`: Hermes answers a repeat with
        // the save it already made.
        let eventID = current.nativePendingContext.flatMap { $0.isSameEdit(as: edit) ? $0.eventID : nil }
            ?? "context-\(UUID().uuidString.lowercased())"
        var intent = HermesBotModeContextIntent(eventID: eventID, context: edit)
        guard let client = nativeClient as? any HermesBotModeRoomSettingsClient,
              nativeCapabilities?.supports("groups.context") == true, edit.isSavable else {
            intent.problem = "This computer can’t save these settings."
            try? keepNativeContextIntent(intent, roomID: roomID)
            return
        }
        let boundary = nativeBoundaryGeneration
        do {
            try keepNativeContextIntent(intent, roomID: roomID)
            let saved = try await client.groupsContext(roomID: roomID, intent: intent)
            try requireNativeBoundary(boundary)
            try updateNativeRoom(roomID) { room in
                guard room.nativePendingContext?.eventID == eventID else { return false }
                room.setNativeContextIntent(nil)
                return true
            }
            nativeRoomSettings[roomID] = HermesBotModeRoomSettings(
                context: saved, support: nativeRoomSettings[roomID]?.support ?? .init())
        } catch is CancellationError {
            return
        } catch {
            guard boundary == nativeBoundaryGeneration else { return }
            intent.problem = Self.contextProblem(error)
            try? keepNativeContextIntent(intent, roomID: roomID)
        }
    }

    /// Saves this edit with the room, unless a newer one took its place.
    private func keepNativeContextIntent(_ intent: HermesBotModeContextIntent, roomID: String) throws {
        try updateNativeRoom(roomID) { room in
            guard room.nativePendingContext != intent else { return false }
            if let pending = room.nativePendingContext, pending.eventID != intent.eventID, intent.problem != nil {
                return false
            }
            room.setNativeContextIntent(intent)
            return true
        }
    }

    static func continueProblem(_ error: any Error) -> String {
        guard case WorkspaceClientError.rejected(_, let message) = error else {
            return "Continue wasn’t confirmed. If the bots don’t answer, try again."
        }
        return message.sentence.map { "This discussion can’t continue. \($0)" } ?? "This discussion can’t continue."
    }

    static func contextProblem(_ error: any Error) -> String {
        guard case WorkspaceClientError.rejected(_, let message) = error else {
            return "Your changes weren’t confirmed. Check the connection, then try again."
        }
        if message.text?.localizedCaseInsensitiveContains("managed by another gateway") == true {
            return "Another computer runs this group chat. Change its settings there."
        }
        return message.sentence.map { "Hermes didn’t save these settings. \($0)" } ?? "Hermes didn’t save these settings."
    }
}
