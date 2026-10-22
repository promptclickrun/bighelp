import Foundation

/// A member turn Hermes lost track of when its host stopped mid-turn. Hermes'
/// session path lists it in `driver_status.pending_actions` as `discard`, and
/// the room waits on it. Discarding it is the only way out: once Hermes defers
/// the turn, retrying it is refused (`unknown_execution`) and that agent can't
/// answer in this room again.
struct HermesBotModePendingDiscard: Identifiable, Equatable, Sendable {
    let roomID: String
    let memberID: String
    let taskID: String
    let executionGeneration: Int

    var id: String { "\(taskID):\(executionGeneration)" }

    /// The discard actions in `groups.state`'s `driver_status`. Other kinds,
    /// and a discard without its exact coordinates, are left out.
    static func decode(roomID: String, driverStatus: [String: BighelpJSONValue]?) -> [Self] {
        guard case .array(let actions)? = driverStatus?["pending_actions"] else { return [] }
        return actions.prefix(128).compactMap { raw in
            guard case .object(let action) = raw, action["kind"]?.string == "discard",
                  let memberID = action["member_id"]?.string, HermesBotModeWireCodec.identifier(memberID),
                  let taskID = action["task_id"]?.string, HermesBotModeWireCodec.identifier(taskID),
                  let generation = action["execution_generation"]?.integer, generation > 0 else { return nil }
            return Self(roomID: roomID, memberID: memberID, taskID: taskID, executionGeneration: generation)
        }
    }
}

struct HermesBotModeDiscardResult: Codable, Equatable, Sendable {
    let discarded: Bool
    let task: HermesBotModeTaskReceipt
}

@MainActor
protocol HermesBotModeDiscarding: AnyObject {
    func groupsDiscard(roomID: String, discard: HermesBotModePendingDiscard) async throws -> HermesBotModeTaskReceipt
}

extension BighelpLinkHermesBotModeClient: HermesBotModeDiscarding {}
