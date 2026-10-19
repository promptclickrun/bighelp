import Foundation
import Testing
@testable import Bighelp

/// My Templates: bots saved as templates on the person's computer (plugin `native-my-templates-v1`),
/// listed with the Template Catalog, and the Templates button in Simple Bot mode's New Bot.
@MainActor
struct MyTemplatesTests {
    private static let tripID = "6f1c2a8e-3b4d-4c5e-8f9a-0b1c2d3e4f5a"

    private func object(_ text: String) throws -> [String: BighelpJSONValue] {
        try JSONDecoder().decode([String: BighelpJSONValue].self, from: Data(text.utf8))
    }

    private var listWithBrokenEntries: String {
        """
        {"templates": [
          {"id": "\(Self.tripID)", "name": "Trip Planner", "role": "Travel helper",
           "vibe": "Organized, upbeat", "description": "Saved from Juniper",
           "instructions": "# {{agent_name}}\\n\\nYou are {{agent_name}}. Plan trips from {{home_city}}.",
           "source": "mine", "updatedAt": "2026-10-14T17:46:40Z",
           "variables": [{"key": "home_city", "label": "Home city", "type": "text"}]},
          {"id": "not-a-uuid", "name": "Bad ID", "instructions": "x"},
          {"id": "7a1c2a8e-3b4d-4c5e-8f9a-0b1c2d3e4f5a", "name": "No instructions"},
          {"id": "8b1c2a8e-3b4d-4c5e-8f9a-0b1c2d3e4f5a", "instructions": "No name"},
          {"id": "9c1c2a8e-3b4d-4c5e-8f9a-0b1c2d3e4f5a", "name": 7, "instructions": "x"},
          {"id": "AD1C2A8E-3B4D-4C5E-8F9A-0B1C2D3E4F5A", "name": "Upper-case ID", "instructions": "x"},
          "not an object", null, 42, [],
          {"id": "\(Self.tripID)", "name": "Same ID again", "instructions": "x"},
          {"id": "bd1c2a8e-3b4d-4c5e-8f9a-0b1c2d3e4f5a", "name": "Plain", "instructions": "Be kind.",
           "variables": "not a list", "updatedAt": "yesterday", "future": {"deep": [1, 2]}}
        ], "skipped": 2, "future": true}
        """
    }

    // MARK: Reading the computer's list

    @Test func aCorruptOrIncompleteTemplateIsSkippedAlone() throws {
        let page = try MyTemplatesWire.page(object(listWithBrokenEntries))
        #expect(page.templates.map(\.title) == ["Trip Planner", "Plain"])
        #expect(page.skipped == 2 + 10, "The computer's own count plus each row the app couldn't read")

        let trip = try #require(page.templates.first)
        #expect(trip.id == "mine-\(Self.tripID)")
        #expect(trip.savedTemplateID == Self.tripID)
        #expect(trip.isMine && !trip.isCommunity)
        #expect(trip.profile == "Travel helper")
        #expect(trip.voice == "Organized, upbeat")
        #expect(trip.strength == "Saved from Juniper")
        #expect(trip.soul?.hasPrefix("# {{agent_name}}\n\nYou are {{agent_name}}.") == true)
        #expect(trip.variables.map(\.key) == ["home_city"])
        #expect(trip.updatedAt != nil)

        let plain = try #require(page.templates.last)
        #expect(plain.profile.isEmpty && plain.voice.isEmpty)
        #expect(plain.variables.isEmpty && plain.updatedAt == nil)
    }

    @Test func aReplyWithoutAListIsAnError() throws {
        #expect(throws: WorkspaceClientError.invalidResponse) { try MyTemplatesWire.page(object(#"{"skipped": 0}"#)) }
        #expect(throws: WorkspaceClientError.invalidResponse) {
            try MyTemplatesWire.page(object(#"{"templates": {"a": 1}}"#))
        }
        let empty = try MyTemplatesWire.page(object(#"{"templates": []}"#))
        #expect(empty.templates.isEmpty && empty.skipped == 0)
    }

    @Test func theStoreShowsTheGoodOnesAndCountsTheRest() async throws {
        let client = FakeMyTemplatesClient(list: try object(listWithBrokenEntries))
        let store = MyTemplatesStore(connection: { ("computer-a", client) })
        await store.refresh()
        #expect(store.load == .loaded)
        #expect(store.templates.map(\.title) == ["Trip Planner", "Plain"])
        #expect(store.skipped == 12)
    }

    // MARK: Older plugins

    @Test func anOlderPluginAsksForAnUpdate() async throws {
        for error in [WorkspaceClientError.unavailable(.unsupportedOperation), .unavailable(.pluginRequired)] {
            let client = FakeMyTemplatesClient(list: [:])
            client.failure = error
            let store = MyTemplatesStore(connection: { ("computer-a", client) })
            await store.refresh()
            #expect(store.load == .needsPluginUpdate)
            #expect(store.templates.isEmpty)
            await #expect(throws: MyTemplatesSaveError.needsPluginUpdate) {
                try await store.save(name: "Budget Buddy", from: .financeFixture)
            }
            #expect(MyTemplatesSaveError.needsPluginUpdate.message == "Update the bighelp plugin to save templates.")
        }
    }

    @Test func noConnectionSavesNothing() async {
        let store = MyTemplatesStore(connection: { nil })
        await store.refresh()
        #expect(store.load == .unavailable)
        await #expect(throws: MyTemplatesSaveError.noConnection) {
            try await store.save(name: "Budget Buddy", from: .financeFixture)
        }
    }

    @Test func aFailedCheckDuringAReconnectKeepsTheList() async throws {
        let client = FakeMyTemplatesClient(list: try object(listWithBrokenEntries))
        let store = MyTemplatesStore(connection: { ("computer-a", client) })
        await store.refresh()
        client.failure = .transportUnavailable
        await store.refresh()
        #expect(store.load == .loaded)
        #expect(store.templates.count == 2)
    }

    @Test func anotherComputerStartsFromItsOwnList() async throws {
        let computer = ComputerInUse()
        let client = FakeMyTemplatesClient(list: try object(listWithBrokenEntries))
        let store = MyTemplatesStore(connection: { (computer.scope, client) })
        await store.refresh()
        computer.scope = "computer-b"
        client.failure = .transportUnavailable
        await store.refresh()
        #expect(store.templates.isEmpty, "Computer A's templates never show for computer B")
        #expect(store.load == .unavailable)
    }

    // MARK: Saving a bot as a template

    @Test func aBotBecomesATemplateWithoutItsName() throws {
        let profile = AgentProfile(id: "finance", name: "Finley", role: "Finance\nhelper",
                                   summary: "A finance specialist.",
                                   instructions: "# Finley\n\nYou are Finley. Keep Finley's answers short.",
                                   avatarFileName: "finance.png", isDefault: false)
        let payload = try MyTemplatesWire.savePayload(name: "  Budget Buddy ", from: profile)
        let template = try #require(payload["template"]?.object)
        #expect(Set(template.keys) == ["name", "role", "vibe", "description", "instructions"],
                "No ID, picture or settings")
        #expect(template["name"]?.string == "Budget Buddy")
        #expect(template["role"]?.string == "Finance helper")
        #expect(template["vibe"]?.string == "A finance specialist.")
        #expect(template["description"]?.string == "Saved from Finley")
        #expect(template["instructions"]?.string
                == "# {{agent_name}}\n\nYou are {{agent_name}}. Keep {{agent_name}}'s answers short.")
    }

    @Test func savingChecksTheNameAndLength() throws {
        #expect(throws: MyTemplatesSaveError.needsName) {
            try MyTemplatesWire.savePayload(name: "   ", from: .financeFixture)
        }
        #expect(throws: MyTemplatesSaveError.needsName) {
            try MyTemplatesWire.savePayload(name: "{{agent_name}}'s twin", from: .financeFixture)
        }
        let long = String(repeating: "x", count: MyTemplatesWire.maximumNameLength + 5)
        let payload = try MyTemplatesWire.savePayload(name: long, from: .financeFixture)
        #expect(payload["template"]?.object?["name"]?.string?.count == MyTemplatesWire.maximumNameLength)
        var empty = AgentProfile.financeFixture
        empty.instructions = "  "
        #expect(throws: MyTemplatesSaveError.noInstructions) { try MyTemplatesWire.savePayload(name: "A", from: empty) }
        var huge = AgentProfile.financeFixture
        huge.instructions = String(repeating: "y", count: MyTemplatesWire.maximumInstructions + 1)
        #expect(throws: MyTemplatesSaveError.tooLong) { try MyTemplatesWire.savePayload(name: "A", from: huge) }
    }

    @Test func aSavedTemplateShowsFirst() async throws {
        let client = FakeMyTemplatesClient(list: try object(listWithBrokenEntries))
        let store = MyTemplatesStore(connection: { ("computer-a", client) })
        await store.refresh()
        let saved = try await store.save(name: "Budget Buddy", from: .financeFixture)
        #expect(saved.title == "Budget Buddy" && saved.isMine)
        #expect(store.templates.first?.id == saved.id)
        #expect(client.sent.last?.0 == .save)
        #expect(client.sent.last?.1["template"]?.object?["name"]?.string == "Budget Buddy")
    }

    @Test func refusalsSayWhatToDo() async throws {
        let cases: [(WorkspaceClientError, MyTemplatesSaveError)] = [
            (.rejected(code: "secret_scan_blocked"), .holdsSecret),
            (.rejected(code: "store_full"), .full),
            (.rejected(code: "template_too_large"), .tooLong),
            (.capacityExceeded, .tooLong),
            (.transportUnavailable, .failed),
        ]
        for (thrown, expected) in cases {
            let client = FakeMyTemplatesClient(list: try object(#"{"templates": []}"#))
            let store = MyTemplatesStore(connection: { ("computer-a", client) })
            client.saveFailure = thrown
            await #expect(throws: expected) { try await store.save(name: "Budget Buddy", from: .financeFixture) }
            #expect(!expected.message.isEmpty)
        }
    }

    @Test func deletingRemovesItAfterTheComputerSaysSo() async throws {
        let client = FakeMyTemplatesClient(list: try object(listWithBrokenEntries))
        let store = MyTemplatesStore(connection: { ("computer-a", client) })
        await store.refresh()
        let trip = try #require(store.templates.first)
        await store.delete(trip)
        #expect(store.templates.map(\.title) == ["Plain"])
        #expect(client.sent.last?.1["id"]?.string == Self.tripID)
    }

    @Test func theRoutesNeedTheirFeature() {
        #expect(MyTemplatesWire.feature == "native-my-templates-v1")
        for operation in [WorkspaceOperation.myTemplatesList, .myTemplatesSave, .myTemplatesDelete] {
            #expect(DirectHermesNativePluginClient.supports(operation))
        }
    }

    @Test func theDemoComputerHasOneAndHidesItsBrokenOne() async throws {
        let demo = DemoMyTemplatesClient()
        let store = MyTemplatesStore(connection: { ("demo", demo) })
        await store.refresh()
        #expect(store.load == .loaded)
        #expect(store.templates.count == 1)
        #expect(store.skipped == 1)
        _ = try await store.save(name: "Budget Buddy", from: .financeFixture)
        await store.refresh()
        #expect(store.templates.map(\.title).first == "Budget Buddy")
    }

    // MARK: New Bot's Templates button

    private func creator() async throws -> AgentEditorModel {
        let store = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture]),
                                        defaults: isolatedDefaults())
        try await store.load()
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor())
        model.savedUserName = { "" }
        return model
    }

    @Test func withoutATemplateANewBotIsAnEverydayHelper() async throws {
        let model = try await creator()
        SimpleBotCreation.prepare(model, name: " Juniper ")
        #expect(model.draft.name == "Juniper")
        #expect(model.draft.role == "Everyday generalist")
        #expect(model.draft.summary == "Warm, direct, adaptable.")
        #expect(model.draft.instructions.contains("{{agent_name}}") || model.draft.instructions.contains("Juniper"))
    }

    @Test func anAttachedTemplateFillsTheBotAndTheNameGoesIn() async throws {
        let model = try await creator()
        let template = try #require(try MyTemplatesWire.page(object(listWithBrokenEntries)).templates.last)
        SimpleBotCreation.attach(template, to: model, name: "")
        #expect(SimpleBotCreation.attachedID(model) == template.id)
        SimpleBotCreation.prepare(model, name: "Juniper")
        #expect(model.draft.name == "Juniper")
        #expect(model.draft.instructions == "Be kind.")
        #expect(model.draft.role == "Everyday generalist", "A bot needs a role and vibe, so empty ones get the usual")
        #expect(model.draft.summary == "Warm, direct, adaptable.")

        let catalog = try #require(AgentSoulTemplate.template("lens"))
        SimpleBotCreation.attach(catalog, to: model, name: "Juniper")
        SimpleBotCreation.prepare(model, name: "Juniper")
        #expect(model.draft.role == "Research partner")
        #expect(model.draft.summary == "Measured, precise, inquisitive.")
        #expect(model.draft.instructions.hasPrefix("# Juniper\n"))
        #expect(!model.draft.instructions.contains("{{agent_name}}"))

        // Removing it goes back to the everyday helper.
        SimpleBotCreation.detach(model)
        #expect(SimpleBotCreation.attachedID(model) == nil)
        SimpleBotCreation.prepare(model, name: "Juniper")
        #expect(model.draft.role == "Everyday generalist")
    }

    @Test func aTemplateWithFieldsAsksForThemFirst() async throws {
        let model = try await creator()
        let trip = try #require(try MyTemplatesWire.page(object(listWithBrokenEntries)).templates.first)
        SimpleBotCreation.attach(trip, to: model, name: "Juniper")
        let request = try #require(model.templateForm)
        #expect(SimpleBotCreation.attachedID(model) == nil, "Nothing is attached until Continue")
        #expect(request.form.values["agent_name"] == "Juniper", "The name typed so far is filled in")
        var form = request.form
        form.values["home_city"] = "Lisbon"
        model.finishTemplateForm(form)
        #expect(SimpleBotCreation.attachedID(model) == trip.id)
        SimpleBotCreation.prepare(model, name: model.draft.name)
        #expect(model.draft.instructions == "# Juniper\n\nYou are Juniper. Plan trips from Lisbon.")
        #expect(model.draft.role == "Travel helper")
        #expect(model.draft.summary == "Organized, upbeat.")
    }

    @Test func aVibeThatEndsASentenceKeepsOneStop() {
        let template = AgentSoulTemplate(id: "x", title: "X", profile: "", voice: "Calm and kind.", strength: "",
                                         systemImage: "star")
        #expect(template.about == "Calm and kind.")
        #expect(AgentSoulTemplate.bundled.first?.about == "Warm, direct, adaptable.")
    }
}

@MainActor
private final class ComputerInUse {
    var scope = "computer-a"
}

/// Answers like the plugin: list, save (with a new ID) and delete.
@MainActor
private final class FakeMyTemplatesClient: MyTemplatesClient {
    var list: [String: BighelpJSONValue]
    var failure: WorkspaceClientError?
    var saveFailure: WorkspaceClientError?
    private(set) var sent: [(MyTemplatesOperation, [String: BighelpJSONValue])] = []

    init(list: [String: BighelpJSONValue]) { self.list = list }

    func perform(_ operation: MyTemplatesOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        sent.append((operation, payload))
        if let failure { throw failure }
        switch operation {
        case .list:
            return list
        case .save:
            if let saveFailure { throw saveFailure }
            var template = payload["template"]?.object ?? [:]
            template["id"] = .string(UUID().uuidString.lowercased())
            template["source"] = .string("mine")
            template["updatedAt"] = .string("2026-10-19T09:00:00Z")
            return ["template": .object(template)]
        case .delete:
            return ["id": payload["id"] ?? .null, "deleted": .boolean(true)]
        }
    }
}
