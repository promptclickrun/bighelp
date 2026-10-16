import Foundation

enum HermesBotModeActivityOperation: String, Sendable {
    case open, poll, close
    var path: String { "/api/plugins/loopdy/native/groups/activity/\(rawValue)" }

    var workspaceOperation: WorkspaceOperation {
        switch self {
        case .open: .groupActivityOpen
        case .poll: .groupActivityPoll
        case .close: .groupActivityClose
        }
    }
}

struct HermesBotModeActivityDetail: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case available, unavailable
        case omittedSize = "omitted_size"
        case omittedSensitive = "omitted_sensitive"
    }
    let state: State
    let text: String?
}

struct HermesBotModeToolObservation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case started = "tool.started"
        case completed = "tool.completed"
    }
    struct Tool: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let durationMs: Int?
    }
    let observationSequence: Int
    let observedAt: Int
    let roomId: String
    let memberId: String
    let threadId: String
    let turnId: String
    let taskId: String
    let executionGeneration: Int
    let sourceSequence: Int?
    let kind: Kind
    let tool: Tool
    let arguments: HermesBotModeActivityDetail
    let result: HermesBotModeActivityDetail

    var attemptID: String {
        [roomId, memberId, threadId, turnId, taskId, String(executionGeneration), tool.id]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}

protocol HermesBotModeObservationCoordinates {
    var observationSequence: Int { get }
    var observedAt: Int { get }
    var roomId: String { get }
    var memberId: String { get }
    var threadId: String { get }
    var turnId: String { get }
    var taskId: String { get }
    var executionGeneration: Int { get }
    var sourceSequence: Int? { get }
}

extension HermesBotModeToolObservation: HermesBotModeObservationCoordinates {}
extension HermesBotModeRespondingObservation: HermesBotModeObservationCoordinates {}

/// A member is writing in its current turn (plugin `native-room-typing-v1`).
/// Only coordinates: never the text, and never stored.
struct HermesBotModeRespondingObservation: Codable, Equatable, Sendable {
    let observationSequence: Int
    let observedAt: Int
    let roomId: String
    let memberId: String
    let threadId: String
    let turnId: String
    let taskId: String
    let executionGeneration: Int
    let sourceSequence: Int?
}

struct HermesBotModeActivityPage: Codable, Equatable, Sendable {
    enum SourceState: String, Codable, Sendable {
        case registeredUnobserved = "registered_unobserved"
        case observed
        case unsupportedPayload = "unsupported_payload"
    }
    enum ResetReason: String, Codable, Sendable {
        case bufferLoss = "buffer_loss"
        case projectionLoss = "projection_loss"
    }
    let schemaVersion: Int
    let runtimeId: String
    let roomId: String
    let streamId: String
    let sourceState: SourceState
    let upstreamLoss: String
    let openedAt: Int
    let expiresAt: Int
    let cursor: Int
    let highWater: Int
    let hasMore: Bool
    let resetRequired: Bool
    let resetReason: ResetReason?
    let droppedTotal: Int
    let projectionDrops: Int
    let events: [HermesBotModeToolObservation]
    var responding: [HermesBotModeRespondingObservation] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, runtimeId, roomId, streamId, sourceState, upstreamLoss, openedAt, expiresAt
        case cursor, highWater, hasMore, resetRequired, resetReason, droppedTotal, projectionDrops, events
    }
}

@MainActor
protocol HermesBotModeActivityClient: AnyObject {
    func open(roomID: String) async throws -> HermesBotModeActivityPage
    func poll(roomID: String, streamID: String, after: Int, limit: Int) async throws -> HermesBotModeActivityPage
    func close(roomID: String, streamID: String) async throws
}

/// The injected request owns native authentication, context If-Match and exact
/// request-ID validation. This feature client has no networking or credentials.
@MainActor
final class NativeHermesBotModeActivityClient: HermesBotModeActivityClient {
    typealias Request = @MainActor (
        HermesBotModeActivityOperation, [String: BighelpJSONValue]
    ) async throws -> [String: BighelpJSONValue]

    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let request: Request
    private let includesResponding: Bool

    /// `includesResponding` asks for `member.responding` events; pass it only
    /// when native context lists `native-room-typing-v1`.
    init(owner: WorkspaceOwner, currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
         includesResponding: Bool = false, request: @escaping Request) {
        self.owner = owner
        self.currentOwner = currentOwner
        self.includesResponding = includesResponding
        self.request = request
    }

    func open(roomID: String) async throws -> HermesBotModeActivityPage {
        var body: [String: BighelpJSONValue] = ["roomId": .string(roomID)]
        if includesResponding { body["include"] = .array([.string("member.responding")]) }
        let value = try await perform(.open, roomID: roomID, body: body)
        let page = try Self.decodePage(value, roomID: roomID, streamID: nil, after: 0, limit: 8)
        guard page.events.isEmpty, page.cursor == 0, page.highWater == 0, !page.resetRequired else {
            throw WorkspaceClientError.invalidResponse
        }
        return page
    }

    func poll(roomID: String, streamID: String, after: Int, limit: Int = 8) async throws -> HermesBotModeActivityPage {
        guard HermesBotModeWireCodec.identifier(streamID), after >= 0, (1...8).contains(limit) else {
            throw WorkspaceClientError.invalidRequest
        }
        let value = try await perform(.poll, roomID: roomID, body: [
            "roomId": .string(roomID), "streamId": .string(streamID),
            "after": .integer(after), "limit": .integer(limit),
        ])
        return try Self.decodePage(value, roomID: roomID, streamID: streamID, after: after, limit: limit)
    }

    func close(roomID: String, streamID: String) async throws {
        guard HermesBotModeWireCodec.identifier(streamID) else { throw WorkspaceClientError.invalidRequest }
        let value = try await perform(.close, roomID: roomID, body: [
            "roomId": .string(roomID), "streamId": .string(streamID),
        ])
        guard Set(value.keys) == ["schemaVersion", "roomId", "streamId", "closed"],
              value["schemaVersion"] == .integer(1), value["roomId"] == .string(roomID),
              value["streamId"] == .string(streamID), value["closed"] == .boolean(true) else {
            throw WorkspaceClientError.invalidResponse
        }
    }

    private func perform(_ operation: HermesBotModeActivityOperation, roomID: String,
                         body: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        guard HermesBotModeWireCodec.identifier(roomID) else { throw WorkspaceClientError.invalidRequest }
        try Task.checkCancellation()
        guard currentOwner() == owner else { throw WorkspaceClientError.ownerChanged }
        let response = try await request(operation, body)
        try Task.checkCancellation()
        guard currentOwner() == owner else { throw WorkspaceClientError.ownerChanged }
        return response
    }

    static func decodePage(_ value: [String: BighelpJSONValue], roomID: String, streamID: String?,
                           after: Int, limit: Int) throws -> HermesBotModeActivityPage {
        guard Set(value.keys) == [
            "schemaVersion", "runtimeId", "roomId", "streamId", "sourceState", "upstreamLoss",
            "openedAt", "expiresAt", "cursor", "highWater", "hasMore", "resetRequired", "resetReason",
            "droppedTotal", "projectionDrops", "events",
        ] else { throw WorkspaceClientError.invalidResponse }
        guard let rawEvents = value["events"]?.array else { throw WorkspaceClientError.invalidResponse }
        let coordinates: Set<String> = [
            "observationSequence", "observedAt", "roomId", "memberId", "threadId", "turnId",
            "taskId", "executionGeneration", "sourceSequence", "kind",
        ]
        var toolEvents: [BighelpJSONValue] = []
        var respondingEvents: [BighelpJSONValue] = []
        for raw in rawEvents {
            guard try JSONEncoder().encode(raw).count <= 20_480 else {
                throw WorkspaceClientError.capacityExceeded
            }
            guard let event = raw.object else { throw WorkspaceClientError.invalidResponse }
            if event["kind"] == .string("member.responding") {
                guard Set(event.keys) == coordinates else { throw WorkspaceClientError.invalidResponse }
                respondingEvents.append(raw)
                continue
            }
            guard Set(event.keys) == coordinates.union(["tool", "arguments", "result"]),
                  let tool = event["tool"]?.object, Set(tool.keys) == ["id", "name", "durationMs"] else {
                throw WorkspaceClientError.invalidResponse
            }
            for field in ["arguments", "result"] {
                guard let detail = event[field]?.object, Set(detail.keys) == ["state", "text"] else {
                    throw WorkspaceClientError.invalidResponse
                }
            }
            toolEvents.append(raw)
        }
        let data = try JSONEncoder().encode(BighelpJSONValue.object(value))
        guard data.count <= 196_608 else { throw WorkspaceClientError.capacityExceeded }
        var page: HermesBotModeActivityPage
        do {
            var tools = value
            tools["events"] = .array(toolEvents)
            page = try JSONDecoder().decode(HermesBotModeActivityPage.self,
                                            from: JSONEncoder().encode(BighelpJSONValue.object(tools)))
            page.responding = try JSONDecoder().decode([HermesBotModeRespondingObservation].self,
                                                       from: JSONEncoder().encode(BighelpJSONValue.array(respondingEvents)))
        } catch { throw WorkspaceClientError.invalidResponse }
        guard page.schemaVersion == 1, page.roomId == roomID,
              streamID.map({ $0 == page.streamId }) ?? true,
              HermesBotModeWireCodec.identifier(page.runtimeId),
              HermesBotModeWireCodec.identifier(page.streamId),
              page.upstreamLoss == "unobservable",
              page.openedAt > 0, page.expiresAt > page.openedAt,
              page.expiresAt <= 9_007_199_254_740_991,
              page.cursor >= after, page.highWater >= page.cursor,
              page.highWater <= 9_007_199_254_740_991,
              page.hasMore == (page.cursor < page.highWater),
              page.droppedTotal >= 0, page.projectionDrops >= 0,
              page.droppedTotal <= 9_007_199_254_740_991, page.projectionDrops <= 9_007_199_254_740_991,
              rawEvents.count <= limit else { throw WorkspaceClientError.invalidResponse }
        if page.resetRequired {
            guard page.resetReason != nil, rawEvents.isEmpty,
                  page.cursor == page.highWater else { throw WorkspaceClientError.invalidResponse }
            return page
        }
        guard page.resetReason == nil else { throw WorkspaceClientError.invalidResponse }
        for observation in page.events {
            guard safeText(observation.tool.id, maximumBytes: 512),
                  safeText(observation.tool.name, maximumBytes: 128),
                  observation.tool.durationMs.map({ (0...9_007_199_254_740_991).contains($0) }) ?? true,
                  detailIsValid(observation.arguments), detailIsValid(observation.result) else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        // Both kinds share one observation sequence.
        let observations = ((page.events as [any HermesBotModeObservationCoordinates]) + page.responding)
            .sorted { $0.observationSequence < $1.observationSequence }
        var sequence = after
        for observation in observations {
            let next = sequence.addingReportingOverflow(1)
            guard !next.overflow, observation.observationSequence == next.partialValue,
                  observation.roomId == roomID,
                  [observation.memberId, observation.threadId, observation.turnId, observation.taskId]
                    .allSatisfy(HermesBotModeWireCodec.identifier),
                  observation.executionGeneration > 0, observation.observedAt >= page.openedAt,
                  observation.observedAt <= page.expiresAt,
                  observation.sourceSequence.map({ $0 >= 0 }) ?? true else {
                throw WorkspaceClientError.invalidResponse
            }
            sequence = observation.observationSequence
        }
        guard page.cursor == sequence, !page.hasMore || !rawEvents.isEmpty else {
            throw WorkspaceClientError.invalidResponse
        }
        return page
    }

    private static func safeText(_ text: String, maximumBytes: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= maximumBytes
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func detailIsValid(_ detail: HermesBotModeActivityDetail) -> Bool {
        if detail.state != .available { return detail.text == nil }
        guard let text = detail.text, text.utf8.count <= 8192 else { return false }
        return !text.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && !"\n\r\t".unicodeScalars.contains($0)
        }
    }
}
