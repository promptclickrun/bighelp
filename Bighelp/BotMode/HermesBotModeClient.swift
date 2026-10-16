import Foundation

/// The identity that owns a Bot Mode transport. Results received after any of
/// these coordinates changes must not be applied to the newly selected host.
struct BighelpLinkHermesBotModeOwner: Equatable, Sendable {
    let accountID: String
    let hostID: String
    let connectionID: String
}

enum BighelpLinkHermesBotModeClientError: Error, Equatable {
    case ownerChanged
}

/// The typed transport for Hermes hosted-room (Bot Mode) operations. The
/// WorkspaceOperationPerforming initializer uses direct Hermes JSON-RPC; the
/// BighelpLinkWorkspaceClient initializer is retained for verified Link.
///
/// This type intentionally stays a thin protocol client. Hermes owns room
/// state, idempotency, fencing, and task lifecycle; bighelp only encodes the
/// official `groups.*` payloads and validates the typed responses.
@MainActor
final class BighelpLinkHermesBotModeClient: HermesBotModeCatalogClient {
    private let workspace: HermesBotModeOperationTransport
    private let validateOwner: @MainActor () throws -> Void

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner) {
        self.workspace = HermesBotModeOperationTransport { operation, payload in
            try await workspace.perform(operation, payload: payload, owner: owner)
        }
        validateOwner = {
            guard workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
        }
    }

    init(
        workspace: BighelpLinkWorkspaceClient,
        owner: BighelpLinkHermesBotModeOwner,
        currentOwner: @escaping @MainActor () -> BighelpLinkHermesBotModeOwner?
    ) {
        self.workspace = HermesBotModeOperationTransport { operation, payload in
            guard let linkOperation = BighelpLinkWorkspaceOperation(rawValue: operation.rawValue) else {
                throw BighelpLinkWorkspaceClientError.invalidRequest
            }
            return try await workspace.perform(linkOperation, payload: payload)
        }
        validateOwner = {
            guard currentOwner() == owner else {
                throw BighelpLinkHermesBotModeClientError.ownerChanged
            }
        }
    }

    func groupsCapabilities() async throws -> HermesBotModeCapabilities {
        try await owned {
            let payload = try await workspace.perform(.groupsCapabilities, payload: [:])
            let result = try decode(HermesBotModeCapabilities.self, from: payload, exactKeys: [
                "protocol_version", "driver", "persistent_process", "authority_gateway_id",
                "room_link", "features", "methods", "max_log_limit",
            ])
            try HermesBotModeWireCodec.capabilities(result)
            return result
        }

    }

    func groupsList(offset: Int, limit: Int) async throws -> HermesBotModeRoomListPage {
        guard offset >= 0, (1...500).contains(limit) else {
            throw BighelpLinkWorkspaceClientError.invalidRequest
        }
        return try await owned {
            let payload = try await workspace.perform(.groupsList, payload: [
                "offset": .integer(offset),
                "limit": .integer(limit),
                "include_disbanded": .boolean(false),
            ])
            let page = try decode(HermesBotModeRoomListPage.self, from: payload, exactKeys: [
                "rooms", "next_offset",
            ])
            try page.rooms.forEach(HermesBotModeWireCodec.room)
            let next = offset.addingReportingOverflow(limit)
            guard !next.overflow, page.rooms.count <= limit,
                  page.nextOffset == nil || page.nextOffset == next.partialValue,
                  page.nextOffset == nil || page.rooms.count == limit,
                  Set(page.rooms.map(\.roomID)).count == page.rooms.count else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return page
        }
    }

    func groupsRename(roomID: String, eventID: String, name: String) async throws -> HermesBotModeRoomState {
        try requireNonEmpty(roomID)
        try requireNonEmpty(eventID)
        guard HermesBotModeWireCodec.label(name) else { throw BighelpLinkWorkspaceClientError.invalidRequest }
        return try await owned {
            let payload = try await workspace.perform(.groupsRename, payload: [
                "room_id": .string(roomID),
                "event_id": .string(eventID),
                "name": .string(name),
            ])
            let room = try decodeRoom(from: payload, allowedKeys: ["room"])
            guard room.roomID == roomID,
                  let eventValue = payload["room"]?.object?["event"] else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            let event: HermesBotModeEvent
            do { event = try JSONDecoder().decode(HermesBotModeEvent.self, from: JSONEncoder().encode(eventValue)) }
            catch { throw BighelpLinkWorkspaceClientError.invalidResponse }
            try HermesBotModeWireCodec.event(event)
            guard event.roomID == roomID, event.eventID == eventID,
                  event.kind == "room.renamed", event.payload["name"]?.string == name else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return room
        }
    }

    func groupsCreate(
        roomID: String,
        name: String,
        members: [HermesBotModeRoomMember]
    ) async throws -> HermesBotModeRoomState {
        try requireNonEmpty(roomID)
        guard HermesBotModeWireCodec.label(name),
              (2...6).contains(members.count),
              Set(members.map(\.memberID)).count == members.count,
              members.allSatisfy(HermesBotModeWireCodec.member) else {
            throw BighelpLinkWorkspaceClientError.invalidRequest
        }
        let memberValues = try members.map { try encode($0) }
        return try await owned {
            let payload = try await workspace.perform(.groupsCreate, payload: [
                "room_id": .string(roomID),
                "name": .string(name),
                "members": .array(memberValues),
            ])
            let room = try decodeRoom(from: payload, allowedKeys: ["room"])
            guard room.roomID == roomID, room.name == name, room.members == members else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return room
        }
    }

    func groupsState(roomID: String, includeDisbanded: Bool) async throws -> HermesBotModeRoomState {
        try requireNonEmpty(roomID)
        return try await owned {
            let payload = try await workspace.perform(.groupsState, payload: [
                "room_id": .string(roomID),
                "include_disbanded": .boolean(includeDisbanded),
            ])
            let room = try decodeRoom(from: payload, allowedKeys: ["room", "driver_status"])
            guard room.roomID == roomID else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return room
        }
    }

    func groupsSend(
        roomID: String,
        eventID: String,
        payload: HermesBotModeUserPayload
    ) async throws -> HermesBotModeSendResult {
        try requireNonEmpty(roomID)
        try requireNonEmpty(eventID)
        guard HermesBotModeWireCodec.identifier(payload.threadID),
              !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.text.utf8.count <= 64 * 1024 else {
            throw BighelpLinkWorkspaceClientError.invalidRequest
        }
        let userPayload = try encode(payload)
        return try await owned {
            let response = try await workspace.perform(.groupsSend, payload: [
                "room_id": .string(roomID),
                // Hermes uses this client supplied value as the idempotency key.
                "event_id": .string(eventID),
                "payload": userPayload,
            ])
            let result = try decode(HermesBotModeSendResult.self, from: response, exactKeys: [
                "event", "client_event_id", "accepted", "driver_started",
            ])
            try HermesBotModeWireCodec.event(result.event)
            guard result.accepted,
                  result.driverStarted,
                  result.event.roomID == roomID,
                  result.clientEventID == eventID,
                  result.event.kind == "message.user",
                  result.event.actor["kind"]?.string == "user",
                  result.event.threadID == payload.threadID,
                  let acceptedText = result.event.text,
                  acceptedText.utf8.elementsEqual(HermesBotModeWireCodec.canonicalUserText(payload.text).utf8) else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return result
        }
    }

    func groupsLog(
        roomID: String,
        sinceSequence: Int,
        limit: Int,
        includeDisbanded: Bool
    ) async throws -> HermesBotModeLogPage {
        try requireNonEmpty(roomID)
        guard sinceSequence >= 0, (1...500).contains(limit) else {
            throw BighelpLinkWorkspaceClientError.invalidRequest
        }
        return try await owned {
            let payload = try await workspace.perform(.groupsLog, payload: [
                "room_id": .string(roomID),
                "since_seq": .integer(sinceSequence),
                "limit": .integer(limit),
                "include_disbanded": .boolean(includeDisbanded),
            ])
            // A read-only page ignores fields it doesn't use; every field it
            // does use is still required and checked below.
            let page = try decode(HermesBotModeLogPage.self, from: payload)
            guard page.events.count <= limit else { throw BighelpLinkWorkspaceClientError.invalidResponse }
            try page.events.forEach(HermesBotModeWireCodec.event)
            guard !page.authority.gatewayID.isEmpty,
                  page.authority.epoch > 0,
                  page.cursor >= sinceSequence,
                  page.latestSequence >= page.cursor,
                  page.hasMore == (page.cursor < page.latestSequence),
                  page.events.allSatisfy({ event in
                      event.roomID == roomID
                          && event.authorityEpoch.map { $0 > 0 && $0 <= page.authority.epoch } ?? true
                  }) else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            var previousSequence = sinceSequence
            for event in page.events {
                let nextSequence = previousSequence.addingReportingOverflow(1)
                guard !nextSequence.overflow,
                      event.sequence == nextSequence.partialValue else {
                    throw BighelpLinkWorkspaceClientError.invalidResponse
                }
                previousSequence = event.sequence
            }
            let lastReturnedSequence = page.events.last?.sequence ?? sinceSequence
            guard page.cursor == lastReturnedSequence,
                  !page.hasMore || !page.events.isEmpty else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return page
        }
    }

    func groupsDisband(roomID: String) async throws {
        try requireNonEmpty(roomID)
        _ = try await owned {
            let payload = try await workspace.perform(.groupsDisband, payload: ["room_id": .string(roomID)])
            guard let tombstone = payload["tombstone"]?.object,
                  tombstone["room_id"]?.string == roomID,
                  let retiredAt = tombstone["disbanded_at"]?.number,
                  retiredAt.isFinite, retiredAt > 0 else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            // Hermes retains the tombstone after its bounded room history expires.
            if tombstone["history_expired"]?.boolean == true { return payload }
            let state = try await groupsState(roomID: roomID, includeDisbanded: true)
            guard state.disbandedAt != nil else { throw BighelpLinkWorkspaceClientError.invalidResponse }
            return payload
        }
    }

    func groupsStop(roomID: String, cancelID: String) async throws {
        try requireNonEmpty(roomID)
        try requireNonEmpty(cancelID)
        _ = try await owned {
            let payload = try await workspace.perform(.groupsStop, payload: [
                "room_id": .string(roomID),
                "cancel_id": .string(cancelID),
            ])
            guard Set(payload.keys) == Set(["cancelled"]),
                  let cancelled = payload["cancelled"]?.integer,
                  cancelled >= 0 else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return payload
        }
    }

    func groupsRetry(roomID: String, taskID: String) async throws -> HermesBotModeRetryResult {
        try requireNonEmpty(roomID)
        try requireNonEmpty(taskID)
        return try await owned {
            let payload = try await workspace.perform(.groupsRetry, payload: [
                "room_id": .string(roomID),
                "task_id": .string(taskID),
            ])
            let result = try decode(HermesBotModeRetryResult.self, from: payload, exactKeys: [
                "retried", "task",
            ])
            guard result.retried,
                  result.task.roomID == roomID,
                  result.task.taskID == taskID,
                  !result.task.threadID.isEmpty,
                  !result.task.turnID.isEmpty,
                  ["queued", "settled", "failed", "cancelled"].contains(result.task.status),
                  result.task.executionGeneration > 0,
                  result.task.cancelGeneration >= 0 else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return result
        }
    }

    func groupsApprove(
        roomID: String,
        memberID: String,
        taskID: String,
        executionGeneration: Int,
        requestID: String,
        choice: HermesBotModeApprovalChoice
    ) async throws -> HermesBotModeApprovalReceipt {
        try requireNonEmpty(roomID)
        try requireNonEmpty(memberID)
        try requireNonEmpty(taskID)
        try requireNonEmpty(requestID)
        guard executionGeneration > 0 else {
            throw BighelpLinkWorkspaceClientError.invalidRequest
        }
        return try await owned {
            let payload = try await workspace.perform(.groupsApprove, payload: [
                "room_id": .string(roomID),
                "member_id": .string(memberID),
                "task_id": .string(taskID),
                "execution_generation": .integer(executionGeneration),
                "request_id": .string(requestID),
                "choice": .string(choice.rawValue),
            ])
            let receipt = try decode(HermesBotModeApprovalReceipt.self, from: payload, exactKeys: [
                "approved", "result",
            ])
            guard receipt.approved else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return receipt
        }
    }

    private func owned<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try requireCurrentOwner()
        let result = try await operation()
        try Task.checkCancellation()
        try requireCurrentOwner()
        return result
    }

    private func requireCurrentOwner() throws {
        try validateOwner()
    }

    private func requireNonEmpty(_ value: String) throws {
        guard HermesBotModeWireCodec.identifier(value) else {
            throw BighelpLinkWorkspaceClientError.invalidRequest
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> BighelpJSONValue {
        do {
            return try JSONDecoder().decode(
                BighelpJSONValue.self,
                from: JSONEncoder().encode(value)
            )
        } catch {
            throw BighelpLinkWorkspaceClientError.invalidRequest
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from payload: [String: BighelpJSONValue],
        exactKeys: Set<String>? = nil
    ) throws -> T {
        if let exactKeys, Set(payload.keys) != exactKeys {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(
                type,
                from: JSONEncoder().encode(BighelpJSONValue.object(payload))
            )
        } catch {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
    }

    private func decodeRoom(
        from payload: [String: BighelpJSONValue],
        allowedKeys: Set<String>
    ) throws -> HermesBotModeRoomState {
        guard Set(payload.keys).isSubset(of: allowedKeys),
              let roomValue = payload["room"] else {
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
        do {
            let room = try JSONDecoder().decode(
                HermesBotModeRoomState.self,
                from: JSONEncoder().encode(roomValue)
            )
            try HermesBotModeWireCodec.room(room)
            guard let rawDriverStatus = payload["driver_status"] else {
                return room
            }
            guard case .object(let driverStatus) = rawDriverStatus else {
                throw BighelpLinkWorkspaceClientError.invalidResponse
            }
            return HermesBotModeRoomState(
                roomID: room.roomID,
                name: room.name,
                members: room.members,
                authorityGatewayID: room.authorityGatewayID,
                authorityEpoch: room.authorityEpoch,
                revision: room.revision,
                createdAt: room.createdAt,
                updatedAt: room.updatedAt,
                latestSequence: room.latestSequence,
                disbandedAt: room.disbandedAt,
                driverStatus: driverStatus
            )
        } catch {
            if let error = error as? BighelpLinkWorkspaceClientError {
                throw error
            }
            throw BighelpLinkWorkspaceClientError.invalidResponse
        }
    }

    @MainActor
    private struct HermesBotModeOperationTransport {
        let invoke: (WorkspaceOperation, [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue]

        func perform(
            _ operation: WorkspaceOperation,
            payload: [String: BighelpJSONValue]
        ) async throws -> [String: BighelpJSONValue] {
            try await invoke(operation, payload)
        }
    }
}
typealias HermesHostedRoomClient = BighelpLinkHermesBotModeClient
