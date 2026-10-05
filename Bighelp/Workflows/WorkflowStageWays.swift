import SwiftUI

/// A delivery stage's setup: where it sends, what, and the message's first line.
/// The computer sends it with Hermes (`hermes send`); no agent runs.
struct WorkflowDeliverySection: View {
    struct Choice: Identifiable, Equatable {
        var id: String { reference }
        var reference: String
        var title: String
        var type: String
    }

    @Binding var stage: WorkflowStage
    /// Earlier stages' outputs it can send.
    let choices: [Choice]
    let client: any WorkflowsClient
    @State private var targets: [ScheduledTaskDeliveryTarget] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var isTypingOther = false
    @State private var other = ""
    @BighelpThemeReader private var theme

    private static let otherTag = "__other__"

    /// Places `hermes send` can reach. "Local" sends nothing, and Bot Chat is for scheduled tasks only.
    private var places: [ScheduledTaskDeliveryTarget] {
        targets.filter { $0.id != ScheduledTaskDeliveryTarget.local.id && WorkflowDeliveryPlace.isValid($0.id) }
    }

    var body: some View {
        Section {
            Picker("Send to", selection: placeSelection) {
                if (stage.to ?? "").isEmpty, !isTypingOther { Text("Choose a place").tag("") }
                ForEach(places) { target in
                    let name = ScheduledTaskDeliverySelection.displayName(id: target.id, name: target.name)
                    Text(target.homeTargetSet ? name : "\(name), no home channel yet")
                        .tag(target.id)
                        .disabled(!target.homeTargetSet)
                }
                if let to = stage.to, !to.isEmpty, !places.contains(where: { $0.id == to }) {
                    Text(WorkflowDeliveryPlace.title(to)).tag(to)
                }
                Text("Another channel…").tag(Self.otherTag)
            }
            .accessibilityIdentifier("workflows.stage.delivery.to")
            if isTypingOther {
                TextField("Channel", text: $other, prompt: Text("discord:#news").bighelpFieldHint(theme))
                    .font(.bighelp(.callout).monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .bighelpMacField()
                    .onChange(of: other) { _, value in
                        let target = value.trimmingCharacters(in: .whitespaces)
                        if WorkflowDeliveryPlace.isValid(target) { stage.to = target }
                    }
                    .accessibilityIdentifier("workflows.stage.delivery.other")
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            } else if failed {
                Text("Couldn't load the places this computer can send to. You can still type a channel.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.danger)
            } else if places.isEmpty {
                Text("This computer has no messaging set up in Hermes yet. You can still type a channel.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
        } header: {
            Text("Where it goes")
        } footer: {
            Text(isTypingOther
                 ? "A platform, then a colon and the channel: discord:#news, telegram:-1001234567890 or slack:C0123ABCD."
                 : "The computer sends it with Hermes, like a scheduled task's results. No agent runs.")
                .font(.bighelp(.footnote))
        }
        Section {
            if choices.isEmpty {
                Text("Add an agent stage before this one: a delivery sends what earlier stages made.")
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(choices) { choice in
                Toggle(isOn: Binding(get: { stage.deliver.contains(choice.reference) }, set: { on in
                    if on {
                        if stage.deliver.count < 10 { stage.deliver.append(choice.reference) }
                    } else {
                        stage.deliver.removeAll { $0 == choice.reference }
                    }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.title).font(.bighelp(.body))
                        Text(choice.reference).font(.bighelp(.caption).monospaced()).foregroundStyle(theme.secondaryText)
                    }
                }
                .accessibilityIdentifier("workflows.stage.delivery.output.\(choice.reference)")
            }
        } header: {
            Text("What it sends")
        } footer: {
            Text("Text, numbers and notes go in the message. Files, pictures and long Markdown go as attachments. Up to 10.")
                .font(.bighelp(.footnote))
        }
        Section {
            TextField("First line", text: Binding(get: { stage.message ?? "" }, set: { stage.message = String($0.prefix(2_000)) }),
                      prompt: Text("The workflow's name and run number").bighelpFieldHint(theme), axis: .vertical)
                .lineLimit(1...4)
                .bighelpMacField()
                .accessibilityIdentifier("workflows.stage.delivery.message")
        } header: {
            Text("First line")
        }
        .task { await loadTargets() }
    }

    private var placeSelection: Binding<String> {
        Binding(get: { isTypingOther ? Self.otherTag : stage.to ?? "" }, set: { value in
            if value == Self.otherTag {
                isTypingOther = true
                other = places.contains { $0.id == stage.to } ? "" : stage.to ?? ""
            } else {
                isTypingOther = false
                stage.to = value.isEmpty ? nil : value
            }
        })
    }

    private func loadTargets() async {
        isLoading = true
        do {
            targets = try await client.deliveryTargets()
            failed = false
        } catch {
            failed = true
        }
        isLoading = false
        // A new delivery goes to the first place that is ready, unless one is chosen.
        if (stage.to ?? "").isEmpty, let ready = places.first(where: \.homeTargetSet) {
            stage.to = ready.id
        }
    }
}

/// A decision's two ways: on when it passes, back for changes when it doesn't.
/// With `native-workflows-outcomes-v1` either can end the run instead: succeeded,
/// cancelled or failed, with a note. Not passing isn't always a failure.
struct WorkflowDecisionWays: View {
    @Binding var stage: WorkflowStage
    let canEnd: Bool
    /// Where pass goes now, in words.
    let passTarget: String
    /// Stages changes can go back to.
    let backTargets: [WorkflowStage]
    @BighelpThemeReader private var theme

    private static let goOn = "go"
    private static let end = "end:"
    private static let back = "back:"

    var body: some View {
        Section {
            Picker("Then", selection: passSelection) {
                Text("Go on to \(passTarget)").tag(Self.goOn)
                if canEnd || stage.passEnd != nil { endings }
            }
            .accessibilityIdentifier("workflows.stage.pass-way")
            if stage.passEnd != nil { note(for: \.passEnd) }
        } header: {
            Text("When it passes")
        }
        Section {
            Picker("Then", selection: changesSelection) {
                ForEach(backTargets) { Text("Send back to \($0.title)").tag(Self.back + $0.key) }
                if let goTo = stage.changesGoTo, !backTargets.contains(where: { $0.key == goTo }) {
                    Text("Send back to \(goTo)").tag(Self.back + goTo)
                }
                if stage.changesGoTo == nil && stage.changesEnd == nil { Text("Choose").tag("") }
                if canEnd || stage.changesEnd != nil { endings }
            }
            .accessibilityIdentifier("workflows.stage.changes-way")
            if stage.changesEnd != nil { note(for: \.changesEnd) }
        } header: {
            Text("When it doesn't pass")
        } footer: {
            Text(stage.changesEnd == nil
                 ? "Sending back runs that stage again with the notes, a few times at most."
                 : "Not passing isn't always a failure: with nothing new to do, the run can end as succeeded.")
                .font(.bighelp(.footnote))
        }
    }

    @ViewBuilder
    private var endings: some View {
        ForEach(WorkflowStage.Ending.Outcome.allCases, id: \.self) { outcome in
            Text("End the run: \(outcome.title.lowercased())").tag(Self.end + outcome.rawValue)
        }
    }

    private func note(for way: WritableKeyPath<WorkflowStage, WorkflowStage.Ending?>) -> some View {
        TextField("Note", text: Binding(get: { stage[keyPath: way]?.message ?? "" }, set: { text in
            stage[keyPath: way]?.message = String(text.prefix(WorkflowStage.Ending.messageLimit))
        }), prompt: Text("Why it ended, for example: No new pull requests").bighelpFieldHint(theme), axis: .vertical)
            .lineLimit(1...3)
            .bighelpMacField()
            .accessibilityIdentifier(way == \.passEnd ? "workflows.stage.pass-note" : "workflows.stage.changes-note")
    }

    private var passSelection: Binding<String> {
        Binding(get: { stage.passEnd.map { Self.end + $0.outcome.rawValue } ?? Self.goOn }, set: { value in
            if let outcome = Self.outcome(value) {
                stage.passEnd = .init(outcome: outcome, message: stage.passEnd?.message ?? "")
            } else {
                stage.passEnd = nil
            }
        })
    }

    private var changesSelection: Binding<String> {
        Binding(get: {
            if let ending = stage.changesEnd { return Self.end + ending.outcome.rawValue }
            return stage.changesGoTo.map { Self.back + $0 } ?? ""
        }, set: { value in
            if let outcome = Self.outcome(value) {
                stage.changesEnd = .init(outcome: outcome, message: stage.changesEnd?.message ?? "")
            } else if value.hasPrefix(Self.back) {
                stage.changesEnd = nil
                stage.changesGoTo = String(value.dropFirst(Self.back.count))
            }
        })
    }

    private static func outcome(_ tag: String) -> WorkflowStage.Ending.Outcome? {
        tag.hasPrefix(end) ? WorkflowStage.Ending.Outcome(rawValue: String(tag.dropFirst(end.count))) : nil
    }
}
