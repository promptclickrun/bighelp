import Foundation
import Testing
@testable import Bighelp

/// Your name reaches agents, so the app must never send its "You" placeholder,
/// and names stay one short line.
@MainActor
struct PeopleTests {
    private static let person = "11111111-1111-4111-8111-111111111111"

    @Test func aNewInstallHasNoNameButStillShowsYou() {
        let defaults = UserDefaults(suiteName: "people-\(UUID().uuidString)")!
        let store = UserIdentityStore(defaults: defaults)
        #expect(store.identity.name.isEmpty)
        #expect(store.identity.displayName == "You")
    }

    @Test func theOldYouDefaultReadsAsNoName() throws {
        let saved = try JSONDecoder().decode(UserIdentity.self, from: Data(#"{"name":"You"}"#.utf8))
        #expect(saved.name.isEmpty)
        #expect(saved.displayName == "You")
        let colt = try JSONDecoder().decode(UserIdentity.self, from: Data(#"{"name":"Colt"}"#.utf8))
        #expect(colt.name == "Colt" && colt.displayName == "Colt")
    }

    @Test func savedNamesAreTrimmedToFortyVisibleCharacters() {
        #expect(UserIdentity.savedName("  Colt  ") == "Colt")
        #expect(UserIdentity.savedName(String(repeating: "👍🏽", count: 45)) == String(repeating: "👍🏽", count: 40))
        let long = "María José Rodríguez Hernández de la Fuente"
        #expect(UserIdentity.savedName(long) == "María José Rodríguez Hernández de la Fue")
        #expect(UserIdentity.savedName(long).count == 40)
    }

    @Test func clearingYourNameRemovesIt() {
        let defaults = UserDefaults(suiteName: "people-\(UUID().uuidString)")!
        let store = UserIdentityStore(defaults: defaults)
        store.saveDisplayName("Colt")
        #expect(store.identity.name == "Colt")
        store.saveDisplayName("   ")
        #expect(store.identity.name.isEmpty && store.identity.displayName == "You")
    }

    @Test func theHostGetsYourSavedNameAndNeverThePlaceholder() async throws {
        let performer = try SpeakingPerformer()
        var name = ""
        let note = DirectHermesChatSpeakerNote(currentWorkspace: { performer }, name: { name },
                                               personID: { Self.person })
        await note.note(agentID: "default", storedSessionID: "20260930_101500_abc123")
        #expect(performer.payloads.first?["name"] == .string(""))
        #expect(performer.payloads.first?["personId"] == .string(Self.person))
        #expect(performer.payloads.first?["sessionId"] == .string("20260930_101500_abc123"))
        #expect(performer.payloads.first?["agentId"] == .string("default"))
        name = "  Colt\n"
        await note.note(agentID: "default", storedSessionID: "s1")
        #expect(performer.payloads.last?["name"] == .string("Colt"))
    }

    /// The name saved in Settings › Profile is what the plugin's people route
    /// gets, the way the native runtime wires it.
    @Test func theNameSavedInSettingsReachesTheHost() async throws {
        let performer = try SpeakingPerformer()
        let store = UserIdentityStore(defaults: UserDefaults(suiteName: "people-\(UUID().uuidString)")!)
        let note = DirectHermesChatSpeakerNote(currentWorkspace: { performer },
                                               name: { store.identity.name }, personID: { Self.person })
        store.saveDisplayName("  Colt ")
        await note.note(agentID: "default", storedSessionID: "s1")
        #expect(performer.payloads.last?["name"] == .string("Colt"))
    }

    /// Phones that once had a bighelp account saved extra profile fields with
    /// the name. The name still loads and still reaches the host.
    @Test func aNameSavedWithTheRetiredAccountStillReachesTheHost() async throws {
        let defaults = UserDefaults(suiteName: "people-\(UUID().uuidString)")!
        defaults.set(Data(#"""
        {"name":"Colt","avatarFileName":"colt.png","accountProfileRevision":3,
         "accountAvatar":{"mimeType":"image/png","byteCount":8,"sha256":"aa","encryptedData":"bb"}}
        """#.utf8), forKey: "loopdy.demo.userIdentity")
        let store = UserIdentityStore(defaults: defaults)
        #expect(store.identity.name == "Colt")
        #expect(store.identity.avatarFileName == "colt.png")
        let performer = try SpeakingPerformer()
        await DirectHermesChatSpeakerNote(currentWorkspace: { performer }, name: { store.identity.name },
                                          personID: { Self.person })
            .note(agentID: "default", storedSessionID: "s1")
        #expect(performer.payloads.last?["name"] == .string("Colt"))
    }

    @Test func noPersonOrNoConnectionSendsNothingAndNeverThrows() async throws {
        let performer = try SpeakingPerformer()
        await DirectHermesChatSpeakerNote(currentWorkspace: { performer }, name: { "Colt" }, personID: { nil })
            .note(agentID: "default", storedSessionID: "s1")
        await DirectHermesChatSpeakerNote(currentWorkspace: { performer }, name: { "Colt" }, personID: { "NOT-A-UUID" })
            .note(agentID: "default", storedSessionID: "s1")
        await DirectHermesChatSpeakerNote(currentWorkspace: { nil }, name: { "Colt" }, personID: { Self.person })
            .note(agentID: "default", storedSessionID: "s1")
        #expect(performer.payloads.isEmpty)
        performer.failure = WorkspaceClientError.unavailable(.unsupportedOperation) // an older plugin
        await DirectHermesChatSpeakerNote(currentWorkspace: { performer }, name: { "Colt" }, personID: { Self.person })
            .note(agentID: "default", storedSessionID: "s1")
        #expect(performer.payloads.count == 1)
    }

    @Test func thePluginRouteNeedsItsFeature() throws {
        #expect(DirectHermesNativePluginClient.supports(.peopleSpeaking))
    }

    @Test func personIDsAreLowercaseUUIDs() {
        #expect(BighelpPersonID.isValid(Self.person))
        #expect(!BighelpPersonID.isValid("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        #expect(BighelpPersonID.isValid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        #expect(!BighelpPersonID.isValid("person"))
    }
}

@MainActor
private final class SpeakingPerformer: WorkspaceOperationPerforming {
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
    var failure: (any Error)?
    private(set) var payloads: [[String: BighelpJSONValue]] = []

    init() throws {
        owner = WorkspaceOwner(authority: try .fixture(id: UUID().uuidString),
                               authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        guard owner == self.owner, operation == .peopleSpeaking else { throw WorkspaceClientError.ownerChanged }
        payloads.append(payload)
        if let failure { throw failure }
        return [:]
    }
}
