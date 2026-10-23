import Foundation

/// Tells the host who is about to send in a chat, so the agent knows who it's
/// talking with when several people share one host.
@MainActor
protocol ChatSpeakerNoting: AnyObject, Sendable {
    func note(agentID: String, storedSessionID: String) async
}

/// The bighelp plugin's `native-people-v1` route. Sends the name you saved
/// (never the "You" placeholder) and your person ID. Older plugins, no
/// connection or a slow host all just mean the message goes without a name.
///
/// When the plugin's `/native/context` lists `native-card-objects-v1`, the note
/// also says which object cards this app draws (`renders`), so the plugin lets
/// the agent send them in this chat. Without that feature the note is exactly
/// what older plugins accept: they refuse fields they don't know.
@MainActor
final class DirectHermesChatSpeakerNote: ChatSpeakerNoting {
    private let currentWorkspace: @MainActor () -> (any WorkspaceOperationPerforming)?
    private let name: @MainActor () -> String
    private let personID: @MainActor () -> String?
    /// The features the plugin's context listed, read when the app connected; no request per turn.
    private let pluginFeatures: @MainActor () -> Set<String>

    init(currentWorkspace: @escaping @MainActor () -> (any WorkspaceOperationPerforming)?,
         name: @escaping @MainActor () -> String,
         personID: @escaping @MainActor () -> String? = { BighelpPersonID.current() },
         pluginFeatures: @escaping @MainActor () -> Set<String> = { [] }) {
        self.currentWorkspace = currentWorkspace
        self.name = name
        self.personID = personID
        self.pluginFeatures = pluginFeatures
    }

    func note(agentID: String, storedSessionID: String) async {
        guard let person = personID(), BighelpPersonID.isValid(person),
              let workspace = currentWorkspace(), let owner = workspace.owner else { return }
        let payload = Self.payload(agentID: agentID, storedSessionID: storedSessionID,
                                   personID: person, name: name(), pluginFeatures: pluginFeatures())
        do {
            _ = try await workspace.perform(.peopleSpeaking, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            _ = try? await workspace.perform(.peopleSpeaking, payload: payload, owner: owner)
        } catch {}
    }

    static func payload(agentID: String, storedSessionID: String, personID: String, name: String,
                        pluginFeatures: Set<String> = []) -> [String: BighelpJSONValue] {
        var payload: [String: BighelpJSONValue] = [
            "agentId": .string(agentID), "sessionId": .string(storedSessionID),
            "personId": .string(personID), "name": .string(UserIdentity.savedName(name)),
        ]
        if pluginFeatures.contains(BighelpCardObjects.feature) {
            payload["renders"] = .array(BighelpCardObjects.renders.map(BighelpJSONValue.string))
        }
        return payload
    }
}

extension DirectHermesConversationClient {
    /// How long a send waits to say who's sending. The note is small; a slow
    /// host sends the message anyway and the agent just doesn't get the name.
    static let speakerNoteWait: Duration = .milliseconds(1_200)

    func noteSpeaker() async {
        guard let speakerNote else { return }
        let agentID = profile, storedID = storedID
        let wait = Self.speakerNoteWait
        // Whichever ends first lets the message go: the note, or the wait. A note
        // still running after that finishes on its own.
        let race = SpeakerNoteRace()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            race.continuation = continuation
            race.timer = Task { @MainActor in
                try? await Task.sleep(for: wait)
                race.finish()
            }
            Task { @MainActor in
                await speakerNote.note(agentID: agentID, storedSessionID: storedID)
                race.finish()
            }
        }
    }
}

@MainActor
private final class SpeakerNoteRace {
    var continuation: CheckedContinuation<Void, Never>?
    var timer: Task<Void, Never>?

    func finish() {
        timer?.cancel()
        continuation?.resume()
        continuation = nil
    }
}
