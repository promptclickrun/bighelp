import SwiftUI

/// An approval or a question: what the agent wants, and the answer buttons.
/// Wider approvals ask again; anything too big for the Watch opens on the iPhone.
struct WatchNeedView: View {
    @Bindable var store: WatchStore
    let needID: String
    @State private var need: WatchNeed?
    @State private var isSending = false
    @State private var notice: String?
    @State private var confirming: WatchDecision?
    @State private var isDone = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let need {
                    WatchNeedRow(need: need)
                    Text(need.detail)
                        .font(need.kind == .approval ? .system(.caption, design: .monospaced) : .body)
                        .foregroundStyle(WatchDesign.Color.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(WatchDesign.Color.surface))
                    if isDone {
                        Label("Sent", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(WatchDesign.Color.done)
                            .font(.headline)
                    } else if need.answerOnPhone {
                        Text("This one has more than your Watch can show. Answer it on your iPhone.")
                            .font(.caption)
                            .foregroundStyle(WatchDesign.Color.secondaryText)
                    } else if need.kind == .approval {
                        approvalButtons(need)
                    } else {
                        answerButtons(need)
                    }
                    if isSending { ProgressView().frame(maxWidth: .infinity) }
                    if let notice { WatchNotice(text: notice) }
                    if let link = need.link {
                        Button {
                            Task { notice = await store.openOnPhone(link) ?? "Check your iPhone." }
                        } label: {
                            Label("Open on iPhone", systemImage: "iphone")
                        }
                        .accessibilityIdentifier("watch.open-on-iphone")
                    }
                } else {
                    WatchNotice(text: "This was already answered or expired.")
                }
            }
        }
        .navigationTitle(need?.kind == .question ? "Question" : "Approval")
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let decision = confirming {
                Button(decision.title) { Task { await decide(decision) } }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text(confirming == .always
                 ? "Your bot won't ask again for this kind of action."
                 : "Your bot won't ask again in this chat.")
        }
        .userActivity(WatchPhoneLink.handoffActivityType, element: need?.link) { link, activity in
            activity.title = link.title
            activity.userInfo = ["url": link.url]
            activity.isEligibleForHandoff = true
        }
        .onAppear { if need == nil { need = store.home?.needs.first { $0.id == needID } } }
    }

    @ViewBuilder
    private func approvalButtons(_ need: WatchNeed) -> some View {
        ForEach(need.decisions.filter { $0 != .deny }, id: \.self) { decision in
            Button {
                if decision.needsConfirmation { confirming = decision } else { Task { await decide(decision) } }
            } label: {
                Text(decision.title).frame(maxWidth: .infinity)
            }
            .tint(decision == .once ? WatchDesign.Color.done : WatchDesign.Color.accent)
            .disabled(isSending)
            .accessibilityIdentifier("watch.decide.\(decision.rawValue)")
        }
        if need.decisions.contains(.deny) {
            Button(role: .destructive) {
                Task { await decide(.deny) }
            } label: {
                Text("Deny").frame(maxWidth: .infinity)
            }
            .disabled(isSending)
            .accessibilityIdentifier("watch.decide.deny")
        }
    }

    @ViewBuilder
    private func answerButtons(_ need: WatchNeed) -> some View {
        ForEach(need.choices, id: \.self) { choice in
            Button {
                Task { await answer(choice) }
            } label: {
                Text(choice).frame(maxWidth: .infinity)
            }
            .disabled(isSending)
        }
        if need.allowsTyping {
            TextFieldLink(prompt: Text("Your answer")) {
                Label("Answer", systemImage: "mic.fill").frame(maxWidth: .infinity)
            } onSubmit: { text in
                Task { await answer(text) }
            }
            .disabled(isSending)
            .accessibilityIdentifier("watch.answer")
        }
    }

    private func decide(_ decision: WatchDecision) async {
        guard let need else { return }
        await finish { await store.decide(need, decision) }
    }

    private func answer(_ text: String) async {
        guard let need else { return }
        await finish { await store.answer(need, text) }
    }

    private func finish(_ send: () async -> String?) async {
        isSending = true
        notice = nil
        let problem = await send()
        isSending = false
        if let problem {
            notice = problem
            return
        }
        isDone = true
        try? await Task.sleep(for: .seconds(1))
        dismiss()
    }

}
