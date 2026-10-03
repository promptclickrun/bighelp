import Foundation

extension ChatModel {
    var isBotMode: Bool {
        botModeRoom != nil
    }

    /// Existing Bot Mode rooms remain readable when execution is unavailable.
    /// Hermes execution is available only after the verified host negotiates
    /// its official groups contract. Local fixture execution remains separate.
    var botModeExecutionEnabled: Bool {
        guard !referenceOwnerRetired else { return false }
        if let botModeRoomID, botModeRoomStore?.nativeRoomSyncErrors[botModeRoomID] != nil {
            return false
        }
        if let state = botModeRoom?.nativeState, !state.members.isEmpty {
            return HermesBotModeRoomSummary(
                room: state, capabilities: botModeRoomStore?.nativeCapabilities
            ).canExecute
        }
        if botModeRoom?.hasNativeRoom == true || botModeRoom?.nativePendingCreation != nil {
            return botModeRoomStore?.nativeExecutionAvailable == true
        }
        if botModeRoomStore?.usesNativeRooms == true {
            return botModeRoomStore?.nativeExecutionAvailable == true
        }
        return botModeRoomStore?.executionEnabled == true
    }

    /// Hermes queues a message sent while members work behind the room's
    /// drive, so a running hosted room still takes new messages.
    var acceptsBotModeFollowUp: Bool {
        guard !referenceOwnerRetired, !isStopping, let room = botModeRoom, room.isNativeWorking,
              botModeRoomStore?.nativeClient != nil, botModeExecutionEnabled,
              room.nativePendingCancelID == nil, room.nativeRetryJournal == nil,
              room.nativeFollowUps.count < HermesBotModeFollowUp.maximumPending else { return false }
        return true
    }

    /// Sends the draft to a room whose agents are still working. The running
    /// turn keeps its own state; Stop still stops everything.
    func sendBotModeFollowUp() async {
        guard let roomID = botModeRoomID, let botModeRoomStore, acceptsBotModeFollowUp else { return }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let message = outgoingDraftText
        guard orderedDraftAttachments.isEmpty else {
            failureMessage = "This Hermes room accepts text only. Remove the attachments before sending."
            return
        }
        draft = ""
        replyDraft = nil
        failureMessage = nil
        do {
            try await botModeRoomStore.send(text: message, roomID: roomID, senderSnapshot: currentUserSnapshot)
        } catch is CancellationError {
            if draft.isEmpty { draft = message }
        } catch {
            let unconfirmed = botModeRoomStore.room(id: roomID)?.nativeFollowUps.contains {
                $0.text == message && $0.discussionEventID == nil
            } == true
            if unconfirmed {
                // The room's recovery sends it again under the same key, so
                // the draft stays empty: sending it by hand could double it.
                failureMessage = "Delivery is unconfirmed. bighelp will retry this same message."
            } else {
                if draft.isEmpty { draft = message }
                failureMessage = "Message could not be delivered. Try again."
            }
        }
        flushPersistence()
    }

    var canEditBotModeMembership: Bool {
        botModeExecutionEnabled && (botModeRoom?.canEditMembership ?? true)
    }

    var canInteractWithBotMode: Bool {
        isBotMode && botModeExecutionEnabled
    }

    var memberIDs: [String] {
        botModeRoom?.profileIDs ?? [agentID]
    }

    var botModeMemberCountLabel: String {
        let count = botModeRoom?.members.count ?? memberIDs.count
        return "\(count) \(count == 1 ? "agent" : "agents")"
    }

    var memberProfiles: [AgentProfile] {
        guard let agentDirectory else { return [] }
        let profiles = Dictionary(uniqueKeysWithValues: agentDirectory.profiles.map { ($0.id, $0) })
        return memberIDs.compactMap { profiles[$0] }
    }

    var nativeRoomParticipants: [HermesBotModeParticipant] {
        guard let room = botModeRoom else { return [] }
        let members: [HermesBotModeRoomMember]
        if let state = room.nativeState, !state.members.isEmpty {
            members = state.members
        } else {
            members = room.members.map(HermesBotModeRoomMember.init(member:))
        }
        return members.map {
            HermesBotModeParticipant(member: $0, profiles: agentDirectory?.profiles ?? [])
        }
    }

    var botModeRoomTitle: String { botModeRoom?.title ?? sessionTitle }

    var botModeActivityScope: String {
        guard !referenceOwnerRetired, let roomID = botModeRoom?.nativeRoomID else { return "" }
        return "\(botModeRoomStore?.activity.configurationGeneration.uuidString ?? ""):\(roomID)"
    }

    var botModeActivitySnapshot: BotModeActivitySnapshot? {
        guard !referenceOwnerRetired, let botModeRoomID, activityVisibility.showToolCalls else { return nil }
        return botModeRoomStore?.activity.snapshots[botModeRoomID]
    }

    func renameBotModeRoom(_ name: String) async throws {
        guard !referenceOwnerRetired else { throw WorkspaceClientError.ownerChanged }
        guard let botModeRoomID, let botModeRoomStore else { throw BotModeRoomError.roomNotFound }
        try await botModeRoomStore.renameNativeRoom(roomID: botModeRoomID, name: name)
    }

    var botModeRoom: BotModeRoom? {
        guard !referenceOwnerRetired, let botModeRoomStore, let botModeRoomID else { return nil }
        return botModeRoomStore.room(id: botModeRoomID)
    }

    var timelineEvents: [BotModeEvent] {
        botModeRoom?.visibleEvents ?? []
    }

    var botModeStatus: String? {
        guard isBotMode else { return nil }
        if let botModeRoomID, let error = botModeRoomStore?.nativeRoomSyncErrors[botModeRoomID] {
            return error
        }
        guard botModeExecutionEnabled else {
            guard let capabilities = botModeRoomStore?.nativeCapabilities else {
                return "Connect to the selected Hermes host to run this room."
            }
            if capabilities.protocolVersion != 2 {
                return "This host's room protocol is not supported."
            }
            if !capabilities.driver {
                return "The Hermes room driver is not running on this host."
            }
            return "This room's capabilities, authority or member routing are unavailable on this connection."
        }
        if botModeRoom?.nativeRetryJournal?.awaitingReceipt.isEmpty == false {
            return "Hermes has not confirmed a retry. Refresh this room's status or explicitly stop it before sending again."
        }
        if botModeRoom?.nativePendingCancelID != nil {
            return "The stop request is unconfirmed. Check this room before continuing."
        }
        return isSending || botModeRoom?.isRunning == true || botModeRoom?.nativeFollowUps.isEmpty == false
            ? "Agents are collaborating" : nil
    }

    var pendingBotModeApprovals: [HermesBotModePendingApproval] {
        guard !referenceOwnerRetired, let botModeRoomID else { return [] }
        return botModeRoomStore?.pendingApprovals(roomID: botModeRoomID) ?? []
    }

    var hasNativeBotModeRetryActions: Bool {
        guard let botModeRoomID, botModeExecutionEnabled else { return false }
        guard botModeRoom?.nativeRetryJournal?.awaitingReceipt.isEmpty != false else { return false }
        return botModeRoomStore?.pendingNativeRetryTaskIDs(roomID: botModeRoomID).isEmpty == false
    }

    func resolveBotModeApproval(
        _ approval: HermesBotModePendingApproval,
        choice: HermesBotModeApprovalChoice
    ) async {
        guard !referenceOwnerRetired, let botModeRoomStore, let botModeRoomID,
              approval.roomID == botModeRoomID,
              pendingBotModeApprovals.contains(approval),
              approval.choices.contains(choice),
              !botModeApprovalSubmissions.contains(approval.id) else { return }
        let generation = ownerGeneration
        botModeApprovalSubmissions.insert(approval.id)
        botModeApprovalErrors[approval.id] = nil
        defer { botModeApprovalSubmissions.remove(approval.id) }
        do {
            try await botModeRoomStore.resolveNativeApproval(
                roomID: botModeRoomID, approval: approval, choice: choice
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentOwner(generation) else { return }
            botModeApprovalErrors[approval.id] = "The decision could not be confirmed. Check the connection and try again."
        }
    }

    var hasRetryableBotModeFailures: Bool {
        if hasNativeBotModeRetryActions { return true }
        guard let room = botModeRoom else { return false }
        guard room.hasNativeRoom else { return !room.memberFailures.isEmpty }
        return room.memberFailures.contains {
            $0.taskID != nil && ["indeterminate", "deferred"].contains($0.status)
        }
    }

    var memberFailures: [BotModeMemberFailure] {
        botModeRoom?.memberFailures ?? []
    }

    func memberHandle(for agentID: String) -> String? {
        if let members = botModeRoom?.nativeState?.members, !members.isEmpty {
            if let member = members.first(where: { $0.memberID == agentID }) { return member.handle }
            let matches = members.filter { $0.profile == agentID }
            return matches.count == 1 ? matches.first?.handle : nil
        }
        guard let agent = agentDirectory?.profiles.first(where: { $0.id == agentID }) else { return nil }
        return botModeRoom?.handle(for: agent, nativeHandles: botModeRoomStore?.usesNativeRooms == true)
            ?? AgentHandle.normalized(agent.name)
    }

    func setMentionCursor(offset: Int?) {
        guard let offset else {
            mentionCursorOffset = nil
            return
        }
        mentionCursorOffset = max(0, min(offset, draft.count))
    }

    var mentionToken: String? {
        activeMentionContext?.token
    }

    var mentionSuggestions: [MentionSuggestion] {
        guard let token = mentionToken, let agentDirectory else { return [] }
        let query = String(token.dropFirst())
        if let nativeMembers = botModeRoom?.nativeState?.members, !nativeMembers.isEmpty {
            var suggestions: [MentionSuggestion] = []
            if matches(query: query, handle: "all", name: "Everyone")
                || matches(query: query, handle: "everyone", name: "Everyone") {
                suggestions.append(.init(kind: .everyone, agentID: nil, title: "Everyone", handle: "all", isEnabled: true))
            }
            suggestions += nativeMembers.compactMap { member in
                let name = member.displayName ?? member.handle
                guard matches(query: query, handle: member.handle, name: name) else { return nil }
                return MentionSuggestion(kind: .member, agentID: member.memberID, title: name, handle: member.handle, isEnabled: true)
            }
            return suggestions
        }
        let members = Set(memberIDs)
        let profilesByID = Dictionary(uniqueKeysWithValues: agentDirectory.profiles.map { ($0.id, $0) })
        var suggestions: [MentionSuggestion] = []
        if matches(query: query, handle: "everyone", name: "Everyone") {
            suggestions.append(.everyone)
        }
        suggestions.append(contentsOf: memberIDs.compactMap { id in
            guard let profile = profilesByID[id] else { return nil }
            let handle = memberHandle(for: id) ?? AgentHandle.normalized(profile.name)
            guard matches(query: query, handle: handle, name: profile.name) else { return nil }
            return MentionSuggestion.member(profile: profile, handle: handle)
        })
        suggestions.append(contentsOf: agentDirectory.profiles.filter {
            canEditBotModeMembership && !members.contains($0.id)
        }.map {
            let handle = prospectiveHandle(for: $0)
            return (profile: $0, handle: handle)
        }.filter { matches(query: query, handle: $0.handle, name: $0.profile.name) }.map {
            MentionSuggestion.outsideAgent(
                profile: $0.profile,
                handle: $0.handle,
                isEnabled: memberIDs.count < BotModeRoom.maximumMembers
            )
        })
        return suggestions
    }

    var botModeTimelineItems: [TimelineItem] {
        timelineEvents.compactMap { event -> TimelineItem? in
            guard let text = event.text else { return nil }
            switch event.kind {
            case .human:
                let ownSender = botModeRoom?.nativeOwnEventSenders[event.id]
                let nativeActor = event.nativeEvent?.actor
                let sender = if let ownSender {
                    TimelineSender(id: "loopdy-sent:\(event.id)", kind: .user, snapshot: ownSender)
                } else if let nativeActor {
                    TimelineSender(
                        id: "hermes-human:\(nativeActor["id"]?.string ?? event.id)",
                        kind: .user,
                        snapshot: .init(name: nativeActor["display_name"]?.string ?? "Human participant")
                    )
                } else if botModeRoom?.hasNativeRoom == true {
                    TimelineSender(
                        id: "hermes-human:unknown:\(event.id)", kind: .user,
                        snapshot: .init(name: "Human participant")
                    )
                } else {
                    TimelineSender.user(snapshot: currentUserSnapshot)
                }
                return TimelineItem(
                    id: event.id,
                    role: .human,
                    sender: sender,
                    content: .message(text),
                    metadata: TimelineMetadata(
                        delivery: "Sent",
                        timestamp: event.timestamp,
                        sourceOrder: event.sourceOrder
                    )
                )
            case .agent:
                guard let memberID = event.memberID,
                      botModeRoom?.memberIDs.contains(memberID) == true else { return nil }
                let nativeMember = botModeRoom?.nativeState?.members.first { $0.memberID == memberID }
                let profileID = nativeMember?.profile ?? memberID
                let profile = agentDirectory?.profiles.first { $0.id == profileID }
                return TimelineItem(
                    id: event.id,
                    role: .assistant,
                    sender: .agent(
                        id: memberID,
                        snapshot: .init(
                            name: profile?.name ?? nativeMember?.displayName ?? nativeMember?.handle ?? "Unavailable agent",
                            avatarFileName: profile?.avatarFileName
                        )
                    ),
                    content: .message(text),
                    metadata: TimelineMetadata(
                        delivery: "Delivered",
                        timestamp: event.timestamp,
                        sourceOrder: event.sourceOrder
                    )
                )
            case .botModeStarted:
                return nil
            }
        }
    }

    func selectMention(agentID: String, replacing token: String) throws {
        do {
            guard !referenceOwnerRetired else { throw WorkspaceClientError.ownerChanged }
            guard activeMentionContext?.token == token else { return }
            if let nativeMember = botModeRoom?.nativeState?.members.first(where: { $0.memberID == agentID }) {
                replaceMention(token, with: "@\(nativeMember.handle)")
                return
            }
            guard let agent = agentDirectory?.profiles.first(where: { $0.id == agentID }) else {
                throw MentionError.unknown(agentID)
            }

            if !memberIDs.contains(agentID) {
                guard botModeExecutionEnabled else { throw BotModeRoomError.executionUnavailable }
                guard canEditBotModeMembership else { throw BotModeRoomError.nativeMembershipImmutable }
            }
            var room: BotModeRoom
            if let existing = botModeRoom {
                room = existing
            } else if agentID == self.agentID {
                replaceMention(token, with: "@\(AgentHandle.normalized(agent.name))")
                return
            } else if let sourceSession {
                room = try makeBotModeRoom(from: sourceSession, adding: agentID)
                try botModesPersist(room)
                activateBotModeRoom(room.id)
            } else {
                throw BotModeRoomError.roomNotFound
            }

            if room.member(id: agentID) == nil {
                let change = try room.add(profile: agent, nativeHandles: botModeRoomStore?.usesNativeRooms == true)
                guard change == .added else { throw BotModeRoomError.roomNotFound }
                try botModesPersist(room)
            }

            replaceMention(token, with: "@\(room.member(id: agentID)?.handle ?? AgentHandle.normalized(agent.name))")
            flushPersistence()
        } catch {
            failureMessage = "Agent could not be added. Try again."
            throw error
        }
    }

    func insertMention(handle: String, replacing token: String) {
        replaceMention(token, with: "@\(handle)")
    }

    func addMember(agentID: String) throws {
        guard botModeExecutionEnabled else { throw BotModeRoomError.executionUnavailable }
        guard canEditBotModeMembership else { throw BotModeRoomError.nativeMembershipImmutable }
        guard let profile = agentDirectory?.profiles.first(where: { $0.id == agentID }) else {
            throw MentionError.unknown(agentID)
        }
        var room: BotModeRoom
        if let existing = botModeRoom {
            room = existing
        } else {
            guard let sourceSession else { throw BotModeRoomError.roomNotFound }
            room = try makeBotModeRoom(from: sourceSession, adding: agentID)
            try botModesPersist(room)
            activateBotModeRoom(room.id)
            return
        }
        let change = try room.add(profile: profile, nativeHandles: botModeRoomStore?.usesNativeRooms == true)
        guard change == .added || change == .alreadyMember else { throw BotModeRoomError.invalidMember }
        if change == .added {
            try botModesPersist(room)
        }
    }

    func removeMember(agentID: String) throws {
        guard botModeExecutionEnabled else { throw BotModeRoomError.executionUnavailable }
        guard canEditBotModeMembership else { throw BotModeRoomError.nativeMembershipImmutable }
        guard var room = botModeRoom else { throw BotModeRoomError.roomNotFound }
        guard !room.isRunning, room.runOwner == nil else { throw BotModeRoomError.runAlreadyActive }
        guard let removedHandle = room.member(id: agentID)?.handle else {
            throw BotModeRoomError.invalidMember
        }
        let change = try room.remove(memberID: agentID)
        guard change == .removed else { throw BotModeRoomError.invalidMember }
        if room.memberIDs.count == 1 {
            guard !room.hasSharedConversation else {
                throw BotModeRoomError.sharedHistoryRequiresBotMode
            }
            guard room.memberIDs == [self.agentID] else {
                throw BotModeRoomError.invalidMember
            }
            try collapseBotMode(previous: botModeRoom, remaining: room)
        } else {
            try botModesPersist(room)
        }
        removeDraftMentions(handle: removedHandle)
    }

    func clearMemberFailure(memberID: String) throws {
        guard var room = botModeRoom else { throw BotModeRoomError.roomNotFound }
        room.replaceFailures(with: room.memberFailures.filter { $0.memberID != memberID })
        do {
            try botModesPersist(room)
        } catch {
            failureMessage = "Failure status could not be cleared. Try again."
            throw error
        }
        if room.memberFailures.isEmpty {
            failureMessage = nil
            retryRequest = nil
        }
    }

    func presentMentionError(_ error: MentionError, restoring message: String) {
        draft = message
        retryRequest = nil
        failureMessage = mentionErrorMessage(error)
    }

    func mentionErrorMessage(_ error: MentionError) -> String {
        switch error {
        case .unknown(let handle):
            "No agent named @\(displayHandle(handle)) in this chat. Edit the mention and try again."
        case .ambiguous(let handle):
            "More than one agent is named @\(displayHandle(handle)) in this chat. Edit the mention and try again."
        }
    }

    private func displayHandle(_ handle: String) -> String {
        let excludedScalars = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        let visibleScalars = handle.unicodeScalars.filter { !excludedScalars.contains($0) }
        let singleLine = String(String.UnicodeScalarView(visibleScalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
            .drop(while: { $0 == "@" })
        guard !singleLine.isEmpty else { return "unknown" }
        let limit = 48
        let prefix = String(singleLine.prefix(limit))
        return singleLine.count > limit ? "\(prefix)…" : prefix
    }

    func acceptBotModeActivity(_ activity: BotModeRunActivity) {
        let memberName = nativeRoomParticipants.first(where: { $0.memberID == activity.memberID })?.displayName
            ?? agentDirectory?.profiles
            .first(where: { $0.id == activity.memberID })?
            .name ?? "@\(activity.memberHandle)"
        acceptActivity(ChatActivityEvent(
            eventID: activity.eventID,
            sessionID: conversationID,
            turnID: activity.turnID,
            kind: .botHandoff,
            lifecycle: activity.lifecycle,
            title: "\(memberName) joined the turn",
            summary: activity.summary,
            detail: activity.detail,
            occurredAt: activity.occurredAt,
            botRunID: activity.runID,
            memberID: activity.memberID,
            fromMemberID: activity.fromMemberID,
            sourceOrder: activity.sourceOrder
        ))
    }

    private func replaceMention(_ token: String, with replacement: String) {
        guard let range = mentionRange(for: token) else { return }
        var end = range.upperBound
        while end < draft.endIndex, draft[end].isWhitespace {
            end = draft.index(after: end)
        }
        let punctuation: Character? = if end < draft.endIndex, ".,;:!?)]}\"'".contains(draft[end]) {
            draft[end]
        } else {
            nil
        }
        if punctuation != nil {
            end = draft.index(after: end)
        }
        let replacementRange = range.lowerBound..<end
        let cursor = draft.distance(from: draft.startIndex, to: replacementRange.lowerBound)
        let suffix = punctuation.map { "\($0) " } ?? " "
        mentionCursorOffset = cursor + replacement.count + suffix.count
        draft.replaceSubrange(replacementRange, with: "\(replacement)\(suffix)")
    }

    private func removeDraftMentions(handle: String) {
        var ranges: [Range<String.Index>] = []
        var index = draft.startIndex
        let normalizedHandle = MentionParser.normalizedForMatching(handle)

        while index < draft.endIndex {
            guard draft[index] == "@",
                  validMentionBoundary(before: index),
                  !insideCode(before: index) else {
                index = draft.index(after: index)
                continue
            }

            let handleStart = draft.index(after: index)
            var end = handleStart
            while end < draft.endIndex, MentionParser.isHandleCharacter(draft[end]) {
                end = draft.index(after: end)
            }
            let candidate = MentionParser.normalizedForMatching(String(draft[handleStart..<end]))
            guard candidate == normalizedHandle else {
                index = end
                continue
            }

            var removalEnd = end
            if removalEnd < draft.endIndex, draft[removalEnd].isWhitespace {
                removalEnd = draft.index(after: removalEnd)
            }
            ranges.append(index..<removalEnd)
            index = removalEnd
        }

        guard !ranges.isEmpty else { return }
        var result = ""
        var cursor = draft.startIndex
        for range in ranges {
            result.append(contentsOf: draft[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        result.append(contentsOf: draft[cursor...])
        mentionCursorOffset = nil
        draft = result
    }

    private func botModesPersist(_ room: BotModeRoom) throws {
        guard let botModeRoomStore else { throw BotModeRoomError.roomNotFound }
        let previous = botModeRoomStore.room(id: room.id)
        try botModeRoomStore.persist(room: room)
        let catalogAccepted = onBotModeChangeWithHistory?(room.id, room.memberIDs, room.privateHistory)
            ?? onBotModeChange?(room.id, room.memberIDs)
            ?? true
        guard catalogAccepted else {
            try? botModeRoomStore.restore(room: previous, roomID: room.id)
            throw BotModeRoomError.persistenceConflict
        }
    }

    private func collapseBotMode(previous: BotModeRoom?, remaining room: BotModeRoom) throws {
        guard let botModeRoomStore, let previous else { throw BotModeRoomError.roomNotFound }
        try botModeRoomStore.remove(roomID: room.id)
        let catalogAccepted = onBotModeCollapse?(
            room.id,
            room.memberIDs[0],
            room.privateHistory
        ) ?? true
        guard catalogAccepted else {
            try? botModeRoomStore.restore(room: previous, roomID: room.id)
            throw BotModeRoomError.persistenceConflict
        }
        botModeRoomID = nil
        if let botModeRoomObservation {
            botModeRoomStore.removeRoomObserver(botModeRoomObservation)
            self.botModeRoomObservation = nil
        }
        items = room.privateHistory
        rebuildItemIndexes()
        rebuildTranscript()
        if var sourceSession {
            sourceSession.kind = .direct
            sourceSession.agentIDs = room.memberIDs
            sourceSession.items = room.privateHistory
            sourceSession.botModeRoomID = nil
            sourceSession.botModePrivateHistory = []
            self.sourceSession = sourceSession
        }
        persistSession()
    }

    private func mentionRange(for token: String) -> Range<String.Index>? {
        if let context = activeMentionContext, context.token == token {
            return context.range
        }
        return nil
    }

    private var activeMentionContext: MentionContext? {
        let cursorOffset = mentionCursorOffset ?? draft.count
        let cursor = draft.index(draft.startIndex, offsetBy: min(cursorOffset, draft.count))
        var index = draft.startIndex
        while index < cursor {
            guard draft[index] == "@",
                  validMentionBoundary(before: index),
                  !insideCode(before: index) else {
                index = draft.index(after: index)
                continue
            }
            var end = draft.index(after: index)
            while end < draft.endIndex, MentionParser.isHandleCharacter(draft[end]) {
                end = draft.index(after: end)
            }
            if cursor <= end {
                return MentionContext(token: String(draft[index..<end]), range: index..<end)
            }
            index = end
        }
        return nil
    }

    private func validMentionBoundary(before index: String.Index) -> Bool {
        guard index > draft.startIndex else { return true }
        let previous = draft[draft.index(before: index)]
        return previous.isWhitespace || "([{'\"".contains(previous)
    }

    private func insideCode(before index: String.Index) -> Bool {
        draft[..<index].reduce(0) { count, character in count + (character == "`" ? 1 : 0) }.isMultiple(of: 2) == false
    }

    private func matches(query: String, handle: String, name: String) -> Bool {
        guard !query.isEmpty else { return true }
        let normalizedQuery = MentionParser.normalizedForMatching(query)
        return MentionParser.normalizedForMatching(handle).contains(normalizedQuery)
            || MentionParser.normalizedForMatching(name).contains(normalizedQuery)
    }

    private func makeBotModeRoom(from source: SessionRecord, adding agentID: String) throws -> BotModeRoom {
        var session = source
        session.items = items
        session.draft = draft
        return try BotModeRoom.fromDirect(
            session: session,
            adding: agentID,
            profiles: agentDirectory?.profiles ?? [],
            nativeHandles: botModeRoomStore?.usesNativeRooms == true
        )
    }

    private func prospectiveHandle(for profile: AgentProfile) -> String {
        if let botModeRoom {
            return botModeRoom.handle(for: profile, nativeHandles: botModeRoomStore?.usesNativeRooms == true)
        }
        guard let sourceSession else { return AgentHandle.normalized(profile.name) }
        return (try? makeBotModeRoom(from: sourceSession, adding: profile.id))?
            .member(id: profile.id)?.handle ?? AgentHandle.normalized(profile.name)
    }

    func rememberNativeBotModeSendRecovery(message: String, roomID: String) {
        guard let botModeRoomStore,
              let eventID = botModeRoomStore.room(id: roomID)?.nativePendingEventID else { return }
        nativeBotModeSendRecovery = NativeBotModeSendRecovery(
            roomID: roomID, eventID: eventID, message: message,
            ownerGeneration: ownerGeneration, nativeOwnerID: botModeRoomStore.nativePresentationOwnerID,
            failureMessage: failureMessage
        )
        reconcileNativeBotModeSendRecovery()
    }

    private func reconcileNativeBotModeSendRecovery() {
        guard let recovery = nativeBotModeSendRecovery else { return }
        guard isCurrentOwner(recovery.ownerGeneration),
              botModeRoomID == recovery.roomID,
              let botModeRoomStore,
              botModeRoomStore.nativePresentationOwnerID == recovery.nativeOwnerID else {
            nativeBotModeSendRecovery = nil
            return
        }
        guard let room = botModeRoomStore.room(id: recovery.roomID),
              room.nativePendingEventID == recovery.eventID,
              room.nativePendingDiscussionEventID != nil else { return }
        // The store has validated this exact client's canonical send receipt.
        // Retire only its delivery error/retry, not the still-running turn or
        // an unrelated error/draft entered while the receipt was unavailable.
        if case .botModeSend(let message, let roomID) = retryRequest,
           roomID == recovery.roomID, message.utf8.elementsEqual(recovery.message.utf8) {
            retryRequest = nil
        }
        if failureMessage == recovery.failureMessage { failureMessage = nil }
        if outgoingDraftText.utf8.elementsEqual(recovery.message.utf8) {
            draft = ""
            replyDraft = nil
        }
        nativeBotModeSendRecovery = nil
    }

    func observeBotModeRoomIfNeeded() {
        guard botModeRoomObservation == nil,
              let botModeRoomStore,
              let botModeRoomID else { return }
        if botModeRoom?.hasNativeRoom == true {
            isSending = botModeRoomStore.nativeRoomIsWorking(roomID: botModeRoomID)
            botModeRoomStore.beginNativeRoomObservation(roomID: botModeRoomID)
        }
        botModeRoomObservation = botModeRoomStore.observeRoom(
            id: botModeRoomID,
            owner: self
        ) { model in
            if model.botModeRoom?.hasNativeRoom == true {
                model.isSending = model.botModeRoomStore?.nativeRoomIsWorking(roomID: botModeRoomID) == true
                model.reconcileNativeBotModeSendRecovery()
            }
            model.rebuildTranscript()
        }
    }

    private func activateBotModeRoom(_ roomID: String) {
        botModeRoomID = roomID
        observeBotModeRoomIfNeeded()
        rebuildTranscript()
    }
}

private struct MentionContext {
    let token: String
    let range: Range<String.Index>
}
