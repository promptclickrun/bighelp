import Foundation

extension ChatModel {
    func nativeMessageReactionPresentation(for item: TimelineItem) -> NativeMessageReactionPresentation {
        _ = nativeMessageReactionRevision
        guard let retainedIndex = itemIndexByID[item.id], items.indices.contains(retainedIndex),
              items[retainedIndex].id.utf8.elementsEqual(item.id.utf8) else {
            return NativeMessageReactionPresentation(
                rowID: nil, reactions: [], availability: .foreignSession,
                isUpdating: false, errorMessage: nil
            )
        }
        guard item.sender.kind != .system,
              let rowID = NativeMessageReactionRowIdentity.rowID(from: item.id) else {
            return unsavedMessageReactionPresentation(for: item)
        }
        let exactItemIDs = NativeMessageReactionRowIdentity.exactItemIDs(for: rowID, in: items)
        guard exactItemIDs.count == 1, exactItemIDs[0].utf8.elementsEqual(item.id.utf8) else {
            return NativeMessageReactionPresentation(
                rowID: rowID, reactions: [], availability: .conflictingCanonicalRow,
                isUpdating: false, errorMessage: nil
            )
        }

        let snapshot = nativeMessageReactionSnapshots[rowID]
        let reactions = snapshot?.role == item.role ? (snapshot?.reactions ?? []) : []
        let availability: NativeMessageReactionAvailability
        if uncertainNativeMessageReactionRows.contains(rowID) {
            availability = .outcomeUnknown
        } else if let native = nativeConversationClient {
            if unsupportedNativeReactionGeneration == native.sessionActionsConnectionGeneration {
                availability = .unsupportedHost
            } else if native.canSetMessageReaction {
                availability = .available
            } else {
                availability = .reconnectRequired
            }
        } else {
            availability = .unsupportedHost
        }
        return NativeMessageReactionPresentation(
            rowID: rowID,
            reactions: reactions,
            availability: availability,
            isUpdating: pendingNativeMessageReactionRows.contains(rowID),
            errorMessage: nativeMessageReactionErrors[rowID]
        )
    }

    func setNativeMessageReaction(_ emoji: String?, for itemID: String) async {
        guard let itemIndex = itemIndexByID[itemID], items.indices.contains(itemIndex),
              items[itemIndex].id.utf8.elementsEqual(itemID.utf8) else { return }
        let item = items[itemIndex]
        guard item.sender.kind != .system else { return }
        guard let rowID = NativeMessageReactionRowIdentity.rowID(from: item.id) else {
            await setUnsavedMessageReaction(emoji, for: item)
            return
        }
        let exactItemIDs = NativeMessageReactionRowIdentity.exactItemIDs(for: rowID, in: items)
        guard exactItemIDs.count == 1, exactItemIDs[0].utf8.elementsEqual(itemID.utf8),
              let native = nativeConversationClient, native.canSetMessageReaction,
              unsupportedNativeReactionGeneration != native.sessionActionsConnectionGeneration,
              !uncertainNativeMessageReactionRows.contains(rowID),
              !pendingNativeMessageReactionRows.contains(rowID) else { return }

        let connectionGeneration = native.sessionActionsConnectionGeneration
        pendingNativeMessageReactionRows.insert(rowID)
        nativeMessageReactionErrors[rowID] = nil
        advanceNativeMessageReactionRevision()
        defer {
            if nativeConversationClient === native,
               native.sessionActionsConnectionGeneration == connectionGeneration {
                pendingNativeMessageReactionRows.remove(rowID)
                advanceNativeMessageReactionRevision()
            }
        }

        do {
            let result = try await native.sessionActions.setReaction(
                target: .row(rowID),
                emoji: emoji,
                author: .user
            )
            guard nativeConversationClient === native,
                  native.sessionActionsConnectionGeneration == connectionGeneration,
                  result.rowID == rowID,
                  NativeMessageReactionRowIdentity.exactItemIDs(for: rowID, in: items).count == 1,
                  NativeMessageReactionRowIdentity.rowID(from: itemID) == rowID,
                  let currentIndex = itemIndexByID[itemID], items.indices.contains(currentIndex),
                  items[currentIndex].id.utf8.elementsEqual(itemID.utf8),
                  items[currentIndex].role == item.role else { return }
            let role: DirectHermesReactionRole = item.role == .human ? .user : .assistant
            // Hermes tells the agent about the reaction at its next turn
            // (display.message_reactions); the app sends nothing of its own.
            _ = native.publishMessageReactionReadback(
                result,
                role: role,
                connectionGeneration: connectionGeneration
            )
        } catch is CancellationError {
            return
        } catch {
            guard nativeConversationClient === native,
                  native.sessionActionsConnectionGeneration == connectionGeneration else { return }
            if let direct = error as? DirectHermesError,
               case .rpcRejected(let code) = direct, code == -32601 {
                unsupportedNativeReactionGeneration = connectionGeneration
                nativeMessageReactionErrors[rowID] =
                    NativeMessageReactionAvailability.unsupportedHost.accessibilityDescription
            } else {
                nativeMessageReactionErrors[rowID] = Self.nativeMessageReactionErrorMessage(error)
                if let direct = error as? DirectHermesError, direct.outcomeIsUnknown {
                    uncertainNativeMessageReactionRows.insert(rowID)
                }
            }
            advanceNativeMessageReactionRevision()
        }
    }

    /// A reply that just finished streaming has no saved row yet. Hermes can
    /// still address it as the newest message of its role.
    private func isNewestUnsaved(_ item: TimelineItem) -> Bool {
        guard item.sender.kind != .system, item.role == .assistant || item.role == .human,
              item.metadata.delivery != "Streaming", !(item.role == .assistant && isSending),
              case .message = item.content else { return false }
        return items.last(where: { $0.role == item.role && $0.sender.kind != .system })?.id == item.id
    }

    func unsavedMessageReactionPresentation(for item: TimelineItem) -> NativeMessageReactionPresentation {
        let mapped = newestReactionRowByItemID[item.id]
        guard mapped != nil || isNewestUnsaved(item) else {
            return NativeMessageReactionPresentation(
                rowID: nil, reactions: [], availability: .canonicalMessageRequired,
                isUpdating: false, errorMessage: nil
            )
        }
        let snapshot = mapped.flatMap { nativeMessageReactionSnapshots[$0] }
        let availability: NativeMessageReactionAvailability
        if let native = nativeConversationClient, native.canSetMessageReaction,
           unsupportedNativeReactionGeneration != native.sessionActionsConnectionGeneration {
            availability = .available
        } else {
            availability = nativeConversationClient == nil ? .unsupportedHost : .reconnectRequired
        }
        return NativeMessageReactionPresentation(
            rowID: mapped,
            reactions: snapshot?.role == item.role ? (snapshot?.reactions ?? []) : [],
            availability: availability,
            isUpdating: pendingUnsavedReactionItemIDs.contains(item.id),
            errorMessage: mapped.flatMap { nativeMessageReactionErrors[$0] }
        )
    }

    private func setUnsavedMessageReaction(_ emoji: String?, for item: TimelineItem) async {
        let mapped = newestReactionRowByItemID[item.id]
        guard mapped != nil || isNewestUnsaved(item),
              let native = nativeConversationClient, native.canSetMessageReaction,
              unsupportedNativeReactionGeneration != native.sessionActionsConnectionGeneration,
              !pendingUnsavedReactionItemIDs.contains(item.id) else { return }
        let role: DirectHermesReactionRole = item.role == .human ? .user : .assistant
        let connectionGeneration = native.sessionActionsConnectionGeneration
        pendingUnsavedReactionItemIDs.insert(item.id)
        advanceNativeMessageReactionRevision()
        defer {
            pendingUnsavedReactionItemIDs.remove(item.id)
            advanceNativeMessageReactionRevision()
        }
        do {
            let result = try await native.sessionActions.setReaction(
                target: mapped.map { .row($0) } ?? .newest(role: role), emoji: emoji, author: .user)
            guard nativeConversationClient === native,
                  native.sessionActionsConnectionGeneration == connectionGeneration,
                  itemIndexByID[item.id] != nil else { return }
            newestReactionRowByItemID[item.id] = result.rowID
            _ = native.publishMessageReactionReadback(result, role: role,
                                                      connectionGeneration: connectionGeneration)
        } catch {
            guard nativeConversationClient === native, let mapped else { return }
            nativeMessageReactionErrors[mapped] = Self.nativeMessageReactionErrorMessage(error)
        }
    }

    func reconcileNativeMessageReaction(
        _ value: DirectHermesMessageReaction,
        from owner: DirectHermesConversationClient
    ) {
        guard nativeConversationClient === owner,
              let role = NativeMessageReactionRowIdentity.timelineRole(from: value.role) else { return }
        let matches = NativeMessageReactionRowIdentity.exactItemIDs(for: value.rowID, in: items)
        guard matches.count <= 1 else {
            nativeMessageReactionErrors[value.rowID] =
                NativeMessageReactionAvailability.conflictingCanonicalRow.accessibilityDescription
            advanceNativeMessageReactionRevision()
            return
        }
        if let itemID = matches.first,
           let index = itemIndexByID[itemID], items.indices.contains(index),
           items[index].role != role {
            nativeMessageReactionErrors[value.rowID] =
                NativeMessageReactionAvailability.conflictingCanonicalRow.accessibilityDescription
            advanceNativeMessageReactionRevision()
            return
        }
        applyNativeMessageReaction(
            rowID: value.rowID,
            role: role,
            reactions: Self.nativeMessageReactions(value.reactions)
        )
    }

    /// Hermes saves a sent message before the agent answers and reports its
    /// row (prompt.submit's `user_row_id`, message.complete's
    /// `persisted_turn`). The message keeps its local ID until a reload, so
    /// bind that row to it; an agent's reaction then shows right away.
    func bindNewestUnsavedMessage(role: TimelineRole, toRow rowID: Int, from owner: DirectHermesConversationClient) {
        guard nativeConversationClient === owner, rowID > 0,
              NativeMessageReactionRowIdentity.exactItemIDs(for: rowID, in: items).isEmpty,
              !newestReactionRowByItemID.values.contains(rowID),
              let item = items.last(where: { $0.role == role && $0.sender.kind != .system }),
              NativeMessageReactionRowIdentity.rowID(from: item.id) == nil,
              newestReactionRowByItemID[item.id] == nil else { return }
        newestReactionRowByItemID[item.id] = rowID
        advanceNativeMessageReactionRevision()
    }

    func reconcileNativeReactionConnectionState(from owner: DirectHermesConversationClient) {
        guard nativeConversationClient === owner else { return }
        pendingNativeMessageReactionRows.removeAll()
        nativeMessageReactionErrors = nativeMessageReactionErrors.filter {
            uncertainNativeMessageReactionRows.contains($0.key)
        }
        advanceNativeMessageReactionRevision()
    }

    func reconcileAuthoritativeNativeMessageReactions(
        _ reactionsByRowID: [Int: DirectHermesMessageReaction],
        from owner: DirectHermesConversationClient
    ) {
        guard nativeConversationClient === owner else { return }
        nativeMessageReactionSnapshots.removeAll()
        nativeMessageReactionErrors.removeAll()
        pendingNativeMessageReactionRows.removeAll()
        uncertainNativeMessageReactionRows.removeAll()
        unsupportedNativeReactionGeneration = nil
        advanceNativeMessageReactionRevision()
        for rowID in reactionsByRowID.keys.sorted() {
            if let reaction = reactionsByRowID[rowID] {
                reconcileNativeMessageReaction(reaction, from: owner)
            }
        }
    }

    func resetNativeMessageReactions(from owner: DirectHermesConversationClient) {
        guard nativeConversationClient === owner else { return }
        nativeMessageReactionSnapshots.removeAll()
        pendingNativeMessageReactionRows.removeAll()
        nativeMessageReactionErrors = nativeMessageReactionErrors.filter {
            uncertainNativeMessageReactionRows.contains($0.key)
        }
        unsupportedNativeReactionGeneration = nil
        advanceNativeMessageReactionRevision()
    }

    func acceptNativeAffectionReaction(
        _ value: DirectHermesAffectionReaction,
        isLive: Bool,
        from owner: DirectHermesConversationClient
    ) {
        guard nativeConversationClient === owner, isLive,
              value.kind.utf8.elementsEqual("vibe".utf8) else { return }
        nativeAffectionRevision &+= 1
        nativeAffectionReaction = NativeAffectionReactionSignal(
            revision: nativeAffectionRevision,
            kind: value.kind
        )
    }

    private func applyNativeMessageReaction(
        rowID: Int,
        role: TimelineRole,
        reactions: [NativeMessageReaction]
    ) {
        if nativeMessageReactionSnapshots[rowID] == nil,
           nativeMessageReactionSnapshots.count >= 4_096,
           let oldestRowID = nativeMessageReactionSnapshots.keys.min() {
            nativeMessageReactionSnapshots[oldestRowID] = nil
            nativeMessageReactionErrors[oldestRowID] = nil
            pendingNativeMessageReactionRows.remove(oldestRowID)
            uncertainNativeMessageReactionRows.remove(oldestRowID)
        }
        nativeMessageReactionSnapshots[rowID] = NativeMessageReactionSnapshot(
            rowID: rowID,
            role: role,
            reactions: reactions
        )
        nativeMessageReactionErrors[rowID] = nil
        uncertainNativeMessageReactionRows.remove(rowID)
        advanceNativeMessageReactionRevision()
        // A reaction that lands after the agent's silence marker still makes it the reply.
        if role == .human, reactions.contains(where: { $0.author == .agent }),
           items.contains(where: { item in
               guard item.role == .assistant, case .message(let text) = item.content else { return false }
               return ChatSilentReply.isMarker(text)
           }) {
            rebuildTranscript()
        }
    }

    func advanceNativeMessageReactionRevision() {
        nativeMessageReactionRevision &+= 1
    }

    private static func nativeMessageReactions(
        _ values: [DirectHermesMessageReaction.Reaction]
    ) -> [NativeMessageReaction] {
        values.compactMap { value in
            let author: NativeMessageReactionAuthor
            if value.author.utf8.elementsEqual("user".utf8) {
                author = .user
            } else if value.author.utf8.elementsEqual("agent".utf8) {
                author = .agent
            } else {
                return nil
            }
            return NativeMessageReaction(
                emoji: value.emoji,
                author: author,
                occurredAt: value.at,
                isSeen: value.seen
            )
        }
    }

    private static func nativeMessageReactionErrorMessage(_ error: Error) -> String {
        guard let direct = error as? DirectHermesError else {
            return "The reaction could not be confirmed. Reopen this chat before trying again."
        }
        if direct.outcomeIsUnknown {
            return "Hermes may have received this reaction. Reopen the chat to read the authoritative state."
        }
        switch direct {
        case .notConnected, .connectionFailed, .serverUnavailable,
             .disconnected(_), .timedOut(_), .cancelled(_):
            return "Reconnect to Hermes before changing this reaction."
        default:
            return "Hermes did not accept this reaction. The previous reaction is unchanged."
        }
    }

    /// A saved canvas can be presented before its native history/socket is attached.
    /// Replace only that waiting client, retaining this route's draft and UI state.
}
