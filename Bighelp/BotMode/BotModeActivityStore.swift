import Foundation
import Observation
import OSLog

struct BotModeObservedTool: Identifiable, Equatable, Sendable {
    let id: String
    let observation: HermesBotModeToolObservation
}

/// A member Hermes reports writing right now. Transient: never stored, and
/// gone once its message or turn end reaches the room log, or the reports stop.
struct BotModeTypingMember: Equatable, Sendable {
    let memberID: String
    let taskID: String
    let executionGeneration: Int
    var lastSeen: Date
}

struct BotModeActivitySnapshot: Equatable, Sendable {
    var tools: [BotModeObservedTool] = []
    var message = "Live tool observations may be incomplete. Source loss cannot be measured."
    var page: HermesBotModeActivityPage?
}

@MainActor
@Observable
final class BotModeActivityStore {
    private(set) var configurationGeneration = UUID()
    private(set) var snapshots: [String: BotModeActivitySnapshot] = [:]
    private(set) var expandedToolIDs: Set<String> = []
    /// Who is writing in each room, in the order they started.
    private(set) var typing: [String: [BotModeTypingMember]] = [:]
    private var client: (any HermesBotModeActivityClient)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]
    private var viewers: [String: Set<UUID>] = [:]
    private let pollInterval: Duration
    /// The plugin repeats a writing report every 2 seconds at most; a member
    /// that goes quiet (a long tool call, a pass) stops showing as typing.
    private let typingTimeout: TimeInterval
    private let now: @MainActor () -> Date

    init(pollInterval: Duration = .seconds(1), typingTimeout: TimeInterval = 6,
         now: @escaping @MainActor () -> Date = Date.init) {
        self.pollInterval = pollInterval
        self.typingTimeout = typingTimeout
        self.now = now
    }

    func configure(_ client: (any HermesBotModeActivityClient)?) {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        tokens = [:]
        viewers = [:]
        snapshots = [:]
        typing = [:]
        expandedToolIDs = []
        configurationGeneration = UUID()
        self.client = client
    }

    func begin(
        roomID: String, viewerID: UUID, memberIDs: Set<String>,
        isRetired: @escaping @MainActor (any HermesBotModeObservationCoordinates) -> Bool,
        reconcile: @escaping @MainActor () async throws -> Void
    ) {
        guard let client else { return }
        guard viewers[roomID] != nil || viewers.count < 16 else {
            snapshots[roomID] = .init(message: "Close another live room before opening more tool observations.")
            return
        }
        viewers[roomID, default: []].insert(viewerID)
        guard tasks[roomID] == nil else { return }
        let token = UUID()
        let generation = configurationGeneration
        tokens[roomID] = token
        snapshots[roomID] = .init(message: "Opening live tool observations.")
        tasks[roomID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var opened: HermesBotModeActivityPage?
            defer {
                if let opened {
                    Task { @MainActor in
                        do { try await client.close(roomID: roomID, streamID: opened.streamId) }
                        catch {
                            Logger(subsystem: "app.loopdy.mobile", category: "BotMode")
                                .notice("Activity close unconfirmed; the bounded host lease will expire.")
                        }
                    }
                }
                if self.tokens[roomID] == token { self.tasks[roomID] = nil }
            }
            do {
                var page = try await client.open(roomID: roomID)
                opened = page
                guard self.isCurrent(roomID: roomID, token: token, generation: generation) else { return }
                self.snapshots[roomID] = .init(
                    message: Self.sourceMessage(page), page: page
                )
                while !Task.isCancelled {
                    let next = try await client.poll(roomID: roomID, streamID: page.streamId, after: page.cursor, limit: 8)
                    guard self.isCurrent(roomID: roomID, token: token, generation: generation) else { return }
                    guard next.runtimeId == page.runtimeId, next.streamId == page.streamId,
                          next.openedAt == page.openedAt,
                          next.droppedTotal >= page.droppedTotal,
                          next.projectionDrops >= page.projectionDrops else {
                        throw WorkspaceClientError.invalidResponse
                    }
                    if next.resetRequired || next.droppedTotal != page.droppedTotal
                        || next.projectionDrops != page.projectionDrops {
                        self.clearTools(roomID: roomID)
                        self.typing[roomID] = nil
                        self.snapshots[roomID] = .init(
                            message: "Live activity was interrupted. Reopen this room to start new observations; history is being reconciled.",
                            page: next
                        )
                        try await reconcile()
                        return
                    }
                    var snapshot = self.snapshots[roomID] ?? .init()
                    for observation in next.events {
                        guard memberIDs.contains(observation.memberId) else {
                            throw WorkspaceClientError.invalidResponse
                        }
                        guard !isRetired(observation) else { continue }
                        let id = "\(page.runtimeId):\(page.streamId):\(observation.attemptID)"
                        let row = BotModeObservedTool(id: id, observation: observation)
                        if let index = snapshot.tools.firstIndex(where: { $0.id == id }) {
                            let previous = snapshot.tools[index].observation
                            guard previous.tool.name == observation.tool.name else {
                                throw WorkspaceClientError.invalidResponse
                            }
                            if previous.kind == .completed && observation.kind == .started { continue }
                            snapshot.tools[index] = row
                        } else {
                            snapshot.tools.append(row)
                        }
                    }
                    for observation in next.responding {
                        guard memberIDs.contains(observation.memberId) else {
                            throw WorkspaceClientError.invalidResponse
                        }
                        guard !isRetired(observation) else { continue }
                        self.noteTyping(roomID: roomID, observation: observation)
                    }
                    self.expireTyping(roomID: roomID)
                    if snapshot.tools.count > 128 {
                        let removed = snapshot.tools.prefix(snapshot.tools.count - 128)
                        self.expandedToolIDs.subtract(removed.map(\.id))
                        snapshot.tools = Array(snapshot.tools.suffix(128))
                    }
                    snapshot.page = next
                    snapshot.message = Self.sourceMessage(next)
                    self.snapshots[roomID] = snapshot
                    page = next
                    if !next.hasMore { try await Task.sleep(for: self.pollInterval) }
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrent(roomID: roomID, token: token, generation: generation) else { return }
                self.clearTools(roomID: roomID)
                self.typing[roomID] = nil
                self.snapshots[roomID] = .init(
                    message: "Live tool observations are unavailable. Reopen this room to reconnect; Hermes history is separate."
                )
                do { try await reconcile() }
                catch {
                    Logger(subsystem: "app.loopdy.mobile", category: "BotMode")
                        .notice("Room history reconciliation after activity loss was not confirmed.")
                }
            }
        }
    }

    func end(roomID: String, viewerID: UUID) {
        viewers[roomID]?.remove(viewerID)
        guard viewers[roomID]?.isEmpty != false else { return }
        tasks[roomID]?.cancel()
        tasks[roomID] = nil
        tokens[roomID] = nil
        viewers[roomID] = nil
        clearTools(roomID: roomID)
        snapshots[roomID] = nil
        typing[roomID] = nil
    }

    /// Members typing in a room now, oldest first.
    func typingMemberIDs(roomID: String) -> [String] {
        (typing[roomID] ?? []).map(\.memberID)
    }

    /// The room log has the member's message or the end of its turn.
    func finishTyping(roomID: String, memberID: String, taskID: String?) {
        guard let members = typing[roomID] else { return }
        let remaining = members.filter { member in
            member.memberID != memberID || (taskID != nil && member.taskID != taskID)
        }
        if remaining != members { typing[roomID] = remaining.isEmpty ? nil : remaining }
    }

    private func noteTyping(roomID: String, observation: HermesBotModeRespondingObservation) {
        var members = typing[roomID] ?? []
        let member = BotModeTypingMember(
            memberID: observation.memberId, taskID: observation.taskId,
            executionGeneration: observation.executionGeneration, lastSeen: now()
        )
        if let index = members.firstIndex(where: { $0.memberID == observation.memberId }) {
            members[index] = member
        } else {
            members.append(member)
        }
        typing[roomID] = members
    }

    private func expireTyping(roomID: String) {
        guard let members = typing[roomID] else { return }
        let cutoff = now().addingTimeInterval(-typingTimeout)
        let fresh = members.filter { $0.lastSeen > cutoff }
        if fresh != members { typing[roomID] = fresh.isEmpty ? nil : fresh }
    }

    func toggleTool(_ id: String) {
        guard snapshots.values.contains(where: { $0.tools.contains { $0.id == id } }) else { return }
        if expandedToolIDs.contains(id) { expandedToolIDs.remove(id) }
        else { expandedToolIDs.insert(id) }
    }

    private func clearTools(roomID: String) {
        expandedToolIDs.subtract(snapshots[roomID]?.tools.map(\.id) ?? [])
    }

    private func isCurrent(roomID: String, token: UUID, generation: UUID) -> Bool {
        !Task.isCancelled && configurationGeneration == generation
            && tokens[roomID] == token && viewers[roomID]?.isEmpty == false
    }

    private static func sourceMessage(_ page: HermesBotModeActivityPage) -> String {
        switch page.sourceState {
        case .registeredUnobserved:
            "The host registered tool observations; none have been received. Source loss cannot be measured."
        case .observed:
            "Recent live tool observations may be incomplete; source loss cannot be measured. Finished does not establish success."
        case .unsupportedPayload:
            "Some host tool activity could not be read. Source loss cannot be measured."
        }
    }
}
