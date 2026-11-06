import Foundation

/// Who a speaker note names: this person's ID and the name they saved (empty until they save one).
struct ChatSpeaker: Equatable, Sendable {
    let personID: String
    let name: String
}

/// Tells the host who is about to send in a chat, so the agent knows who it's
/// talking with when several people share one host.
@MainActor
protocol ChatSpeakerNoting: AnyObject, Sendable {
    /// Who a note sent now would name; nil while there's no one to name (no person ID yet).
    var speaker: ChatSpeaker? { get }
    /// Says who's about to send. Returns who the host took the note for, or nil when it didn't.
    @discardableResult
    func note(agentID: String, storedSessionID: String) async -> ChatSpeaker?
}

/// The bighelp plugin's `native-people-v1` route. Sends the name you saved
/// (never the "You" placeholder) and your person ID. Older plugins, no
/// connection or a slow host all just mean the message goes without a name.
///
/// When the plugin's `/native/context` lists `native-card-objects-v1`, the note
/// also says which object cards this app draws (`renders`), so the plugin lets
/// the agent send them in this chat; with `native-image-drafts-v1` too, the list
/// adds the photo drafts. Without that feature the note is exactly what older
/// plugins accept: they refuse fields they don't know.
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

    var speaker: ChatSpeaker? {
        guard let person = personID(), BighelpPersonID.isValid(person) else { return nil }
        return ChatSpeaker(personID: person, name: UserIdentity.savedName(name()))
    }

    @discardableResult
    func note(agentID: String, storedSessionID: String) async -> ChatSpeaker? {
        guard let speaker, let workspace = currentWorkspace(), let owner = workspace.owner else { return nil }
        let payload = Self.payload(agentID: agentID, storedSessionID: storedSessionID,
                                   personID: speaker.personID, name: speaker.name, pluginFeatures: pluginFeatures())
        do {
            _ = try await workspace.perform(.peopleSpeaking, payload: payload, owner: owner)
        } catch WorkspaceClientError.conflict {
            // The plugin's context changed (412): the next call loads it again. Once.
            guard (try? await workspace.perform(.peopleSpeaking, payload: payload, owner: owner)) != nil else { return nil }
        } catch {
            return nil
        }
        return speaker
    }

    static func payload(agentID: String, storedSessionID: String, personID: String, name: String,
                        pluginFeatures: Set<String> = []) -> [String: BighelpJSONValue] {
        var payload: [String: BighelpJSONValue] = [
            "agentId": .string(agentID), "sessionId": .string(storedSessionID),
            "personId": .string(personID), "name": .string(UserIdentity.savedName(name)),
        ]
        if pluginFeatures.contains(BighelpCardObjects.feature) {
            // Drafts only with the plugin that knows them: older ones refuse names they don't know.
            let drafts = pluginFeatures.contains(ImageDraftWire.feature) ? ImageDraftWire.renders : []
            payload["renders"] = .array((BighelpCardObjects.renders + drafts).map(BighelpJSONValue.string))
        }
        return payload
    }
}

extension DirectHermesConversationClient {
    /// How long a chat's first message waits to say who's sending. The plugin writes the
    /// name into the chat's brief once, as the first turn starts; a slow host sends the
    /// message anyway and the agent just doesn't get the name.
    static let speakerNoteWait: Duration = .milliseconds(1_200)

    /// Says who's sending, for every message: the plugin names each message's writer from the
    /// latest note. Nothing is noted before Send, since a note makes this person the chat's speaker
    /// at once. A chat's first message waits for it (the plugin records the brief's person once),
    /// and so does any message until the host has taken a note naming this person, as they are
    /// now, in this stored session on this connection: the host may still have someone else as
    /// the speaker. Later turns read the note when they reach the model, well after the message
    /// lands, so they go at once (a far host added round trips to each).
    func noteSpeaker() async {
        guard let speakerNote, let speaker = speakerNote.speaker else { return }
        let agentID = profile, storedID = storedID, generation = generation
        let note = Task { @MainActor [weak self] in
            // A failed or refused note, or one that lands after the chat moved to another
            // connection or stored session, doesn't count: the next message waits for its own.
            guard let noted = await speakerNote.note(agentID: agentID, storedSessionID: storedID),
                  let self, self.generation == generation, self.storedID == storedID else { return }
            self.notedSpeaker = (storedID, noted)
        }
        let known = notedSpeaker.map { $0.storedID == storedID && $0.speaker == speaker } ?? false
        guard projection.items.isEmpty || !known else { return }
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
                await note.value
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
