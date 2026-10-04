import Foundation
import Testing
@testable import Bighelp

/// Template fill-in fields (services/catalog/docs/TEMPLATE_VARIABLES.md): finding `{{key}}`s,
/// cleaning and checking values, and filling the text in one pass.
struct TemplateVariablesTests {
    private let role = TemplateVariable(key: "agent_role", label: "Role", kind: .text, example: "Release coordinator",
                                        help: "What this agent does for you, in a few words.", maxLength: 80)
    private let context = TemplateVariable(key: "operating_context", label: "Where it works", kind: .longText,
                                           isRequired: false, maxLength: 600,
                                           whenEmpty: "General work for the user.")
    private let tone = TemplateVariable(key: "tone", label: "Tone", kind: .choice, defaultValue: "Direct",
                                        options: ["Warm", "Direct", "Playful"])
    private let soul = """
        # {{agent_name}}

        You are {{agent_name}}, a {{agent_role}} for {{user_name}}.

        Operating context: {{operating_context}}

        Tone: {{tone}}. The {{agent_role}} title organizes work.
        """

    // MARK: Placeholders

    @Test func findsEachKeyOnceInOrder() {
        #expect(TemplateVariables.keys(in: soul) == ["agent_name", "agent_role", "user_name", "operating_context", "tone"])
        #expect(TemplateVariables.keys(in: "No fields here.").isEmpty)
    }

    @Test func onlyWellFormedKeysArePlaceholders() {
        let text = "{{ agent_role }} {{Role}} {{1st}} {{a-b}} {{\(String(repeating: "k", count: 41))}} {{ok_2}} {{{inner}}}"
        #expect(TemplateVariables.keys(in: text) == ["ok_2", "inner"])
        #expect(TemplateVariables.isKey("a"))
        #expect(TemplateVariables.isKey(String(repeating: "k", count: 40)))
        #expect(!TemplateVariables.isKey(""))
        #expect(!TemplateVariables.isKey("_a"))
        #expect(!TemplateVariables.isKey("é"))
    }

    @Test func fillsEveryPlaceholderInOnePass() {
        let text = "{{a}} then {{b}}, {{a}} again, {{missing}} stays."
        #expect(TemplateVariables.fill(text, values: ["a": "{{b}}", "b": "B"]) == "b then B, b again, {{missing}} stays.",
                "A value is never read as a placeholder, and loses its braces")
        #expect(TemplateVariables.fill("{{a}}{{b}}", values: ["a": "{", "b": "x"]) == "{x")
        #expect(TemplateVariables.fill("Hi {{agent_name}}", values: ["agent_name": "$1 \\(Kai)"]) == "Hi $1 \\(Kai)",
                "Values go in exactly as typed")
    }

    @Test func cleaningTrimsJoinsLinesAndDropsBraces() {
        #expect(TemplateVariables.clean("  Release\ncoordinator\r\n ", kind: .text) == "Release coordinator")
        #expect(TemplateVariables.clean(" Line one\r\nLine two \n", kind: .longText) == "Line one\nLine two")
        #expect(TemplateVariables.clean("Warm\n", kind: .choice) == "Warm")
        #expect(TemplateVariables.clean("{{{{x}}}}", kind: .text) == "x")
        #expect(TemplateVariables.clean("a{{b}}c", kind: .longText) == "abc")
        #expect(TemplateVariables.clean("{{", kind: .text).isEmpty)
    }

    @Test func undeclaredKeysGetALabelFromTheirName() {
        #expect(TemplateVariables.label(forKey: "operating_context") == "Operating context")
        #expect(TemplateVariables.label(forKey: "goal") == "Goal")
    }

    // MARK: The form's fields

    @Test func nameFirstThenTheTemplatesFieldsThenUndeclaredOnes() {
        let unused = TemplateVariable(key: "budget", label: "Budget", kind: .number)
        let fields = TemplateVariables.fields(texts: [soul + " {{deadline}}", "{{extra}} role"],
                                              declared: [tone, role, unused, context], asksForUserName: true)
        #expect(fields.map(\.key) == ["agent_name", "user_name", "tone", "agent_role", "operating_context",
                                      "deadline", "extra"])
        #expect(fields[0].label == "Name" && fields[0].isRequired)
        #expect(fields[1].label == "Your name")
        #expect(fields[5] == TemplateVariable(key: "deadline", label: "Deadline", kind: .text),
                "An undeclared key is a required one-line field")
        #expect(fields[5].isRequired && fields[5].lengthLimit == 80)

        let saved = TemplateVariables.fields(texts: [soul], declared: [role, context, tone], asksForUserName: false)
        #expect(saved.map(\.key) == ["agent_name", "agent_role", "operating_context", "tone"])
        let noUserName = TemplateVariables.fields(texts: ["You are {{agent_name}}."], declared: [], asksForUserName: true)
        #expect(noUserName.map(\.key) == ["agent_name"], "Only asks for the person's name when the text uses it")
    }

    @Test func cardsShowLabelsWhereTheFieldsGo() {
        #expect(TemplateVariables.preview("{{agent_role}} for {{user_name}} at {{site}}", variables: [role])
                == "[Role] for [Your name] at [Site]")
        #expect(TemplateVariables.preview("Plain role", variables: [role]) == "Plain role")
    }

    // MARK: Checking values

    @Test func requiredFieldsKeepContinueOffUntilFilled() throws {
        var form = try #require(TemplateForm(texts: [soul], declared: [role, context, tone], agentName: "",
                                             savedUserName: ""))
        #expect(form.fields.map(\.key) == ["agent_name", "user_name", "agent_role", "operating_context", "tone"])
        #expect(form.values["tone"] == "Direct", "Defaults are filled in")
        #expect(form.values["agent_role"] == "", "Examples are never values")
        #expect(!form.canContinue)
        form.values["agent_name"] = "  Kai "
        form.values["user_name"] = "Sam"
        #expect(!form.canContinue)
        form.values["agent_role"] = "   "
        #expect(!form.canContinue, "Spaces don't count")
        form.values["agent_role"] = "Release coordinator"
        #expect(form.canContinue, "The optional field can stay empty")
        let values = form.filledValues()
        #expect(values == ["agent_name": "Kai", "user_name": "Sam", "agent_role": "Release coordinator",
                           "operating_context": "General work for the user.", "tone": "Direct"])
        let filled = TemplateVariables.fill(soul, values: values)
        #expect(!filled.contains("{{") && !filled.contains("}}"))
        #expect(filled.contains("You are Kai, a Release coordinator for Sam."))
    }

    @Test func limitsNumbersAndChoicesAreChecked() throws {
        let size = TemplateVariable(key: "team_size", label: "Team size", kind: .number, minimum: 1, maximum: 50)
        let other = TemplateVariable(key: "tone", label: "Tone", kind: .choice, options: ["Warm", "Direct"],
                                     allowsOther: true)
        #expect(role.problem(with: String(repeating: "x", count: 81)) == .tooLong(80))
        #expect(role.problem(with: String(repeating: "x", count: 80)) == nil)
        #expect(size.problem(with: "lots") == .notANumber)
        #expect(size.problem(with: "0") == .belowMinimum(1))
        #expect(size.problem(with: "51") == .aboveMaximum(50))
        #expect(size.problem(with: "12") == nil)
        #expect(tone.problem(with: "Grumpy") == .notAChoice)
        #expect(other.problem(with: "Grumpy") == nil)
        #expect(context.problem(with: "") == nil)
        #expect(role.problem(with: "") == .missing)
        #expect(TemplateVariable.Problem.missing.message == nil)
        #expect(TemplateVariable.Problem.tooLong(80).message == "Keep it to 80 characters or fewer.")
        #expect(TemplateVariable.Problem.belowMinimum(1).message == "Enter 1 or more.")

        var form = try #require(TemplateForm(texts: ["{{agent_name}} {{agent_role}}"], declared: [role],
                                             agentName: "Kai", savedUserName: ""))
        form.values["agent_role"] = String(repeating: "x", count: 81)
        #expect(!form.canContinue)
        form.values["agent_name"] = String(repeating: "n", count: 41)
        #expect(form.problem(for: form.fields[0]) == .tooLong(40))
    }

    @Test func aSavedNameFillsUserNameWithoutAsking() throws {
        let form = try #require(TemplateForm(texts: [soul], declared: [role, context, tone], agentName: "Kai",
                                             savedUserName: " Sam Rivera "))
        #expect(!form.fields.contains { $0.key == "user_name" })
        #expect(form.filledValues()["user_name"] == "Sam Rivera")
        #expect(TemplateForm(texts: ["You are {{agent_name}} for {{user_name}}."], declared: [], agentName: "",
                             savedUserName: "Sam") == nil, "Nothing else to ask: no form")
        #expect(TemplateForm(texts: ["You are {{agent_name}}."], declared: [], agentName: "", savedUserName: "") == nil)
    }

    @Test func emptyOptionalFieldsWithoutWhenEmptyBecomeEmptyText() throws {
        let note = TemplateVariable(key: "note", label: "Note", kind: .longText, isRequired: false)
        var form = try #require(TemplateForm(texts: ["Note: {{note}}."], declared: [note], agentName: "Kai",
                                             savedUserName: ""))
        #expect(form.canContinue)
        #expect(TemplateVariables.fill("Note: {{note}}.", values: form.filledValues()) == "Note: .")
        form.values["note"] = " First line\nSecond {{line}} "
        #expect(TemplateVariables.fill("Note: {{note}}.", values: form.filledValues()) == "Note: First line\nSecond line.")
    }

    // MARK: Reading the catalog

    @Test func catalogVariablesAreReadLeniently() throws {
        let rows: [Any] = [
            ["key": "agent_role", "label": "Role", "type": "text", "required": true, "example": "Release coordinator",
             "help": "What this agent does for you, in a few words.", "maxLength": 80],
            ["key": "operating_context", "label": "Where it works", "type": "long_text", "required": false,
             "maxLength": 9_999, "whenEmpty": "General work for the user."],
            ["key": "tone", "label": "Tone", "type": "choice", "options": ["Warm", "Direct", "Playful", "Warm", 3],
             "default": "Grumpy"],
            ["key": "team_size", "label": "Team size", "type": "number", "min": 1, "max": 50, "default": 4],
            ["key": "agent_name", "label": "Name", "type": "text"],
            ["key": "agent_role", "label": "Again", "type": "text"],
            ["key": "Bad Key", "label": "Bad", "type": "text"],
            ["key": "kind", "label": "Kind", "type": "date"],
            ["key": "one", "label": "One", "type": "choice", "options": ["Only"]],
            ["key": "nolabel", "type": "text"],
            "not a field",
        ]
        let variables = TemplateVariables.parse(rows)
        #expect(variables.map(\.key) == ["agent_role", "operating_context", "tone", "team_size"])
        #expect(variables[0] == role)
        #expect(variables[1].maxLength == 4_000 && variables[1].whenEmpty == "General work for the user.")
        #expect(variables[2].options == ["Warm", "Direct", "Playful"])
        #expect(variables[2].defaultValue == nil, "A default that isn't a choice is dropped")
        #expect(variables[3].minimum == 1 && variables[3].maximum == 50 && variables[3].defaultValue == "4")
        #expect(TemplateVariables.parse("text").isEmpty)
        #expect(TemplateVariables.parse(nil).isEmpty)

        let many = (0..<20).map { ["key": "v\($0)", "label": "V\($0)", "type": "text"] as [String: Any] }
        #expect(TemplateVariables.parse(many).count == 12)
    }

    @MainActor
    @Test func remoteTemplatesCarryTheirVariables() throws {
        let rows: [Any] = [[
            "id": "field-lead", "name": "Field Lead", "role": "{{agent_role}}", "vibe": "Confident, practical",
            "description": "Runs {{agent_role}} work.", "instructions": soul, "category": "work", "source": "community",
            "variables": [
                ["key": "agent_role", "label": "Role", "type": "text"],
                ["key": "tone", "label": "Tone", "type": "choice", "options": ["Warm", "Direct"], "default": "Direct"],
            ],
        ], [
            "id": "plain", "name": "Plain", "role": "Helper", "instructions": "You are {{agent_name}}.",
            "variables": "nonsense",
        ]]
        let templates = AgentSoulTemplate.remote(rows: rows)
        #expect(templates.map(\.id) == ["field-lead", "plain"])
        #expect(templates[0].variables.map(\.key) == ["agent_role", "tone"])
        #expect(templates[0].cardRole == "[Role]")
        #expect(templates[0].cardStrength == "Runs [Role] work.")
        #expect(templates[1].variables.isEmpty)
        #expect(templates[1].form(agentName: "", savedUserName: "") == nil)

        let form = try #require(templates[0].form(agentName: "Kai", savedUserName: ""))
        #expect(form.fields.map(\.key) == ["agent_name", "user_name", "agent_role", "tone", "operating_context"],
                "operating_context isn't declared, so it's asked as text")
    }
}
