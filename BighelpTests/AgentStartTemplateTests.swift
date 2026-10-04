import Foundation
import Testing
import UIKit
@testable import Bighelp

/// A new agent starts from scratch, a built-in personality, or a saved template,
/// and the name the person types goes wherever the template says `{{agent_name}}`.
@MainActor
struct AgentStartTemplateTests {
    private func model(profiles: [AgentProfile] = [.defaultFixture, .financeFixture]) async throws -> AgentEditorModel {
        let store = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: profiles),
                                        defaults: isolatedDefaults())
        try await store.load()
        return AgentEditorModel.creating(store: store, processor: AvatarImageProcessor())
    }

    private func type(_ name: String, into model: AgentEditorModel) {
        model.draft.name = name
        model.nameDidChange()
    }

    // MARK: The built-in library

    @Test func all15PersonalitiesShipWithTheirNameSpots() throws {
        #expect(AgentSoulTemplate.all.count == 15)
        #expect(Set(AgentSoulTemplate.all.map(\.id)).count == 15)
        for template in AgentSoulTemplate.all {
            let soul = try #require(template.soul, "\(template.id) is bundled")
            #expect(soul.hasPrefix("# {{agent_name}}\n"), "\(template.id)")
            #expect(soul.components(separatedBy: AgentNamePlaceholder.token).count - 1 == 4, "\(template.id)")
            #expect(!template.profile.isEmpty && !template.voice.isEmpty && !template.strength.isEmpty)
            #expect(UIImage(systemName: template.systemImage) != nil, "\(template.systemImage) exists")
        }
    }

    @Test func fillingTheNameReplacesEverySpot() {
        let text = "# {{agent_name}}\n\nYou are {{agent_name}}.\n\n**{{agent_name}}:** Hi."
        #expect(AgentNamePlaceholder.fill(text, name: "  Kai ") == "# Kai\n\nYou are Kai.\n\n**Kai:** Hi.")
        #expect(AgentNamePlaceholder.fill(text, name: "   ") == text, "No name yet keeps the spots visible")
    }

    @Test func aSavedAgentsOwnNameBecomesTheSpot() {
        #expect(AgentNamePlaceholder.generalize("You are Finley. Finley's notes; Finleyish; finley.", name: "Finley")
                == "You are {{agent_name}}. {{agent_name}}'s notes; Finleyish; finley.")
        #expect(AgentNamePlaceholder.generalize("You are A.", name: "A") == "You are A.", "Too short to swap safely")
        #expect(AgentNamePlaceholder.generalize("You are {{agent_name}}. Finley.", name: "Finley")
                == "You are {{agent_name}}. Finley.", "A template that already has spots is left alone")
        #expect(AgentNamePlaceholder.generalize("Call C++ (not C).", name: "C++") == "Call {{agent_name}} (not C).")
    }

    // MARK: Starting a new agent

    @Test func aBuiltInPersonalityFillsTheDraftAndTakesTheName() async throws {
        let model = try await model()
        #expect(model.startChoice == .scratch)
        let anchor = try #require(AgentSoulTemplate.template("anchor"))
        model.startFrom(anchor)
        #expect(model.startChoice == .builtIn)
        #expect(model.appliedTemplateID == "builtin:anchor")
        #expect(model.draft.name.isEmpty, "A personality doesn't name the agent")
        #expect(model.draft.role == "Everyday generalist")
        #expect(model.draft.summary == "Warm, direct, adaptable.")
        #expect(model.draft.instructions.hasPrefix("# {{agent_name}}\n"))

        type("Kai", into: model)
        #expect(model.draft.instructions.hasPrefix("# Kai\n\nYou are Kai, a practical, warm AI assistant"))
        #expect(!model.draft.instructions.contains(AgentNamePlaceholder.token))
        type("Rio", into: model)
        #expect(model.draft.instructions.contains("You are Rio,"))
        #expect(!model.draft.instructions.contains("Kai"))

        // Another personality swaps in, keeping the name.
        model.startFrom(try #require(AgentSoulTemplate.template("forge")))
        #expect(model.draft.role == "Engineering partner")
        #expect(model.draft.instructions.hasPrefix("# Rio\n"))
        #expect(model.draft.name == "Rio")
    }

    @Test func whatThePersonTypedIsNeverReplaced() async throws {
        let model = try await model()
        model.draft.role = "My own role"
        model.startFrom(try #require(AgentSoulTemplate.template("lens")))
        #expect(model.draft.role == "My own role")
        #expect(model.draft.summary == "Measured, precise, inquisitive.")

        // Once the instructions are edited, the name no longer rewrites them...
        model.draft.instructions += "\nAlso: be brief."
        type("Ada", into: model)
        #expect(model.draft.instructions.contains("{{agent_name}}"))
        // ...and neither another template nor Scratch takes them away.
        model.startFrom(try #require(AgentSoulTemplate.template("muse")))
        #expect(model.draft.instructions.hasSuffix("Also: be brief."))
        model.showStartChoice(.scratch)
        #expect(model.appliedTemplateID == nil)
        #expect(model.draft.role == "My own role")
        #expect(model.draft.summary.isEmpty, "Scratch clears what the template filled in")
        #expect(model.draft.instructions.hasSuffix("Also: be brief."))
        #expect(model.draft.name == "Ada")
    }

    @Test func switchingToTemplatesWaitsForAPick() async throws {
        let model = try await model()
        model.showStartChoice(.builtIn)
        #expect(model.startChoice == .builtIn)
        #expect(model.appliedTemplateID == nil)
        #expect(model.draft.role.isEmpty && model.draft.instructions.isEmpty)
    }

    @Test func aSavedTemplateGetsTheNewAgentsName() async throws {
        let model = try await model()
        let template = SavedAgentTemplate(
            id: UUID(), title: "Finley", role: "Finance", summary: "A finance specialist.",
            instructions: "# Finley\n\nYou are Finley. Keep Finley's answers short.", avatar: nil,
            sourceAgentName: "Finley", createdAt: .now)
        model.startFrom(template)
        #expect(model.startChoice == .saved)
        #expect(model.draft.name == "Finley 2", "Finley is taken")
        #expect(model.draft.instructions == "# Finley 2\n\nYou are Finley 2. Keep Finley 2's answers short.")
        type("Penny", into: model)
        #expect(model.draft.instructions == "# Penny\n\nYou are Penny. Keep Penny's answers short.")

        // A built-in replaces the saved template's name only if it's untouched.
        model.startFrom(try #require(AgentSoulTemplate.template("anchor")))
        #expect(model.draft.name == "Penny")
        #expect(model.draft.instructions.hasPrefix("# Penny\n"))
    }

    @Test func savingFillsAnyNameSpotLeftInTheInstructions() async throws {
        let client = AgentDirectoryFixtureClient(profiles: [.defaultFixture])
        let store = AgentDirectoryStore(client: client, defaults: isolatedDefaults())
        try await store.load()
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor())
        model.startFrom(try #require(AgentSoulTemplate.template("quill")))
        model.draft.instructions += "\n"
        model.draft.name = "Wren"
        let saved = try await model.save()
        #expect(saved.instructions.hasPrefix("# Wren\n\nYou are Wren,"))
        #expect(!saved.instructions.contains(AgentNamePlaceholder.token))
    }

    @Test func editingAnAgentIgnoresStartChoices() async throws {
        let store = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.defaultFixture, .financeFixture]),
                                        defaults: isolatedDefaults())
        try await store.load()
        let model = AgentEditorModel.editing(.financeFixture, store: store, processor: AvatarImageProcessor())
        model.startFrom(try #require(AgentSoulTemplate.template("anchor")))
        model.showStartChoice(.scratch)
        #expect(model.draft.instructions == "Help with budgets.")
        #expect(model.draft.role == "Finance")
    }

    // MARK: Templates with fill-in fields

    @Test func aTemplateWithFieldsAsksBeforeItFillsTheEditor() async throws {
        let model = try await model()
        model.savedUserName = { "" }
        model.draft.role = ""
        model.startFrom(.demoFieldLead)
        let request = try #require(model.templateForm, "Its form opens first")
        #expect(model.startChoice == .builtIn)
        #expect(model.appliedTemplateID == nil, "Nothing is filled until Continue")
        #expect(model.draft.instructions.isEmpty && model.draft.role.isEmpty)
        #expect(request.form.fields.map(\.key) == ["agent_name", "agent_role", "operating_context", "tone"])

        var form = request.form
        form.values["agent_role"] = "Release coordinator"
        model.finishTemplateForm(form)
        #expect(model.templateForm != nil, "Continue waits for the name")

        form.values["agent_name"] = " Kai "
        model.finishTemplateForm(form)
        #expect(model.templateForm == nil)
        #expect(model.appliedTemplateID == "builtin:field-lead")
        #expect(model.draft.name == "Kai")
        #expect(model.draft.role == "Release coordinator")
        #expect(model.draft.summary == "Confident, practical, quick.")
        let instructions = model.draft.instructions
        #expect(instructions.hasPrefix("# Kai\n\nYou are Kai, a Hermes Agent profile"))
        #expect(instructions.contains("Role: Release coordinator"))
        #expect(instructions.contains("Operating context: General work for the user."))
        #expect(instructions.contains("Tone: Direct."))
        #expect(!instructions.contains("{{") && !instructions.contains("}}"))

        // The name still follows the Name field afterwards, and the fields keep their values.
        type("Rio", into: model)
        #expect(model.draft.instructions.hasPrefix("# Rio\n\nYou are Rio,"))
        #expect(model.draft.instructions.contains("Role: Release coordinator"))
        // Scratch clears what the template filled in, but not the name the person gave.
        model.showStartChoice(.scratch)
        #expect(model.draft.instructions.isEmpty && model.draft.role.isEmpty)
        #expect(model.draft.name == "Rio")
    }

    @Test func cancellingTheFormLeavesTheEditorAsItWas() async throws {
        let model = try await model()
        model.savedUserName = { "" }
        model.startFrom(try #require(AgentSoulTemplate.template("anchor")))
        type("Kai", into: model)
        let before = model.draft
        model.startFrom(.demoFieldLead)
        let form = try #require(model.templateForm?.form)
        #expect(form.values["agent_name"] == "Kai", "The name typed so far is filled in")
        model.cancelTemplateForm()
        #expect(model.templateForm == nil)
        #expect(model.draft == before)
        #expect(model.appliedTemplateID == "builtin:anchor")
    }

    @Test func theSavedNameFillsUserNameOrTheFormAsksForIt() async throws {
        let asking = AgentSoulTemplate(id: "host", title: "Host", profile: "Household host", voice: "Warm",
                                   strength: "", systemImage: "house",
                                   inlineSoul: "# {{agent_name}}\n\nYou are {{agent_name}}. You help {{user_name}}.")
        let model = try await model()
        model.savedUserName = { "Sam" }
        model.startFrom(asking)
        #expect(model.templateForm == nil, "Nothing to ask but the name: no form, as before")
        #expect(model.draft.instructions == "# {{agent_name}}\n\nYou are {{agent_name}}. You help Sam.")
        type("Kai", into: model)
        #expect(model.draft.instructions == "# Kai\n\nYou are Kai. You help Sam.")

        let unnamed = try await self.model()
        unnamed.savedUserName = { "" }
        unnamed.startFrom(asking)
        var form = try #require(unnamed.templateForm?.form)
        #expect(form.fields.map(\.key) == ["agent_name", "user_name"])
        form.values = ["agent_name": "Kai", "user_name": "Sam Rivera"]
        unnamed.finishTemplateForm(form)
        #expect(unnamed.draft.instructions == "# Kai\n\nYou are Kai. You help Sam Rivera.")
    }
}
