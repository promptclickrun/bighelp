import Foundation

@MainActor
@discardableResult
func routeUnsolicitedAssistantMessage(
    _ message: BighelpLinkAssistantMessage,
    featureStore: ShellFeatureStore,
    agentDirectory: AgentDirectoryStore?,
    attachmentResolver: (any AgentAttachmentResolving)? = nil
) -> Task<Void, Never>? {
    featureStore.acceptAssistantLiveness(message)
    let agent = agentDirectory?.profiles.first { $0.id == message.agentID }
    let item = TimelineItem(
        id: message.messageID,
        role: .assistant,
        sender: .agent(
            id: message.agentID,
            snapshot: .init(
                name: message.agentName,
                avatarFileName: agent?.avatarFileName
            )
        ),
        content: .message(message.text),
        metadata: TimelineMetadata(
            source: "Hermes · Bighelp",
            freshness: "Just now",
            delivery: message.delivery == .draft ? "Streaming" : "Delivered",
            timestamp: Date(timeIntervalSince1970: TimeInterval(message.sentAt))
        )
    )
    guard
        message.delivery == .final,
        let attachmentResolver,
        message.text.contains("MEDIA:")
            || message.text.contains("FILE:")
            || message.text.contains("](file://")
            || message.text.contains("](/")
    else {
        featureStore.acceptExternal(
            [item], conversationID: message.sessionID, isLiveAssistantText: true
        )
        return nil
    }
    let placeholder = TimelineItem(
        id: item.id,
        role: item.role,
        sender: item.sender,
        content: .message("Preparing attachment…"),
        metadata: TimelineMetadata(
            source: item.metadata.source,
            freshness: item.metadata.freshness,
            delivery: "Streaming",
            timestamp: item.metadata.timestamp,
            sourceOrder: item.metadata.sourceOrder,
            platformMessageID: item.metadata.platformMessageID,
            turnDurationMilliseconds: item.metadata.turnDurationMilliseconds,
            contentReference: item.metadata.contentReference
        )
    )
    featureStore.acceptExternal([placeholder], conversationID: message.sessionID)
    return Task { @MainActor in
        do {
            let resolved = try await attachmentResolver.resolve(
                agentID: message.agentID,
                storedID: message.sessionID,
                items: [.init(id: message.messageID, text: message.text)]
            )
            guard
                resolved.count == 1,
                let value = resolved.first,
                value.id == message.messageID
            else { throw BighelpLinkConversationError.invalidMessage }
            featureStore.acceptExternal(
                [
                    TimelineItem(
                        id: item.id,
                        role: item.role,
                        sender: item.sender,
                        content: .message(value.text),
                        metadata: item.metadata,
                        attachments: value.attachments
                    ),
                ],
                conversationID: message.sessionID
            )
        } catch {
            featureStore.acceptExternal(
                [
                    TimelineItem(
                        id: item.id,
                        role: item.role,
                        sender: item.sender,
                        content: .message("The attachment could not be delivered."),
                        metadata: item.metadata
                    ),
                ],
                conversationID: message.sessionID
            )
        }
    }
}
