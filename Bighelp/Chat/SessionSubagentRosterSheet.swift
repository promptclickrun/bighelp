import SwiftUI

struct SessionSubagentRosterSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    let subagents: [SessionSubagentSnapshot]
    let nativeSubagents: [NativeSubagentRailItem]
    let sessionCatalog: SessionCatalogStore?

    var body: some View {
        let totalSubagents = subagents.count + nativeSubagents.count
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: BighelpTokens.space12) {
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        Label(
                            totalSubagents == 1 ? "1 subagent" : "\(totalSubagents) subagents",
                            systemImage: "cpu"
                        )
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.primaryText)
                        Text("Open a subagent to follow its persisted session and live activity.")
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BighelpTokens.space16)
                    .bighelpSurface(.card)
                    .accessibilityIdentifier("subagent.roster.summary")
                    ForEach(subagents) { subagent in
                        let card = SessionSubagentRosterPresentation.card(for: subagent)
                        NavigationLink(value: subagent) {
                            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                                BighelpThinkingOrb(scenario: .working, scale: .inline)
                                    .frame(width: 22, height: 22)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                                    Text(card.name)
                                        .bighelpFont(.label)
                                        .foregroundStyle(theme.primaryText)
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                        .truncationMode(.tail)
                                    Text(card.summary)
                                        .bighelpFont(.body)
                                        .foregroundStyle(theme.secondaryText)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                        .truncationMode(.tail)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.bighelp(.caption).weight(.semibold))
                                    .foregroundStyle(theme.tertiaryText)
                                    .accessibilityHidden(true)
                            }
                            .padding(BighelpTokens.space16)
                            .contentShape(.rect)
                            .bighelpSurface(.card)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(card.name), \(card.summary)")
                        .accessibilityIdentifier("subagent.roster.\(subagent.sessionID)")
                    }
                    ForEach(nativeSubagents) { subagent in
                        nativeSubagentRow(subagent)
                    }
                }
                .frame(maxWidth: 680)
                .padding(BighelpTokens.space20)
                .frame(maxWidth: .infinity)
            }
            .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
            .navigationTitle("Subagents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: SessionSubagentSnapshot.self) { subagent in
                SessionSubagentDetailView(
                    subagent: subagent,
                    sessionCatalog: sessionCatalog
                )
            }
        }
    }

    @ViewBuilder
    private func nativeSubagentRow(_ subagent: NativeSubagentRailItem) -> some View {
        if let childSessionID = NativeSubagentNavigation.recordID(
            childStoredID: subagent.childSessionID, records: sessionCatalog?.records ?? []
        ) {
            NavigationLink {
                // startedAt is presentation metadata only; navigation is
                // authorized by the real child session coordinate above.
                SessionSubagentDetailView(
                    subagent: SessionSubagentSnapshot(
                        id: subagent.id,
                        sessionID: childSessionID,
                        parentID: subagent.parentID,
                        role: "subagent",
                        goal: subagent.goal,
                        startedAt: subagent.startedAt ?? 0
                    ),
                    sessionCatalog: sessionCatalog
                )
            } label: {
                nativeSubagentCard(subagent, showsNavigation: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("subagent.native.roster.\(subagent.id)")
        } else {
            nativeSubagentCard(subagent, showsNavigation: false)
                .accessibilityIdentifier("subagent.native.roster.\(subagent.id)")
        }
    }

    private func nativeSubagentCard(
        _ subagent: NativeSubagentRailItem,
        showsNavigation: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            BighelpThinkingOrb(scenario: .working, scale: .inline)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(subagent.goal)
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
                Text(nativeSubagentStatus(subagent))
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsNavigation {
                Image(systemName: "chevron.right")
                    .font(.bighelp(.caption).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(BighelpTokens.space16)
        .contentShape(.rect)
        .bighelpSurface(.card)
        .accessibilityLabel("\(subagent.goal), \(nativeSubagentStatus(subagent))")
    }

    private func nativeSubagentStatus(_ subagent: NativeSubagentRailItem) -> String {
        let state: String = switch subagent.lifecycle {
        case .running: "Active subagent"
        case .succeeded: "Completed subagent"
        case .failed: "Failed subagent"
        case .cancelled: "Cancelled subagent"
        case .recorded: "Saved subagent; outcome unavailable"
        }
        if let toolCount = subagent.toolCount, toolCount > 0 {
            return "\(state) · \(toolCount) \(toolCount == 1 ? "tool" : "tools")"
        }
        return state
    }

    @BighelpThemeReader private var theme

}

private struct SessionSubagentDetailView: View {
    let subagent: SessionSubagentSnapshot
    let sessionCatalog: SessionCatalogStore?

    @State private var availabilityMessage: String?

    private var record: SessionRecord? {
        sessionCatalog?.session(id: subagent.sessionID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                let card = SessionSubagentRosterPresentation.card(for: subagent)
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    HStack(alignment: .top, spacing: BighelpTokens.space12) {
                        subagentStatusIcon
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(card.name)
                                .font(.bighelp(.headline))
                                .foregroundStyle(theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(record.map(SessionSubagentDetailPresentation.statusTitle)
                                ?? "Waiting for child session")
                                .font(.bighelp(.subheadline))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(card.summary)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(BighelpTokens.space16)
                .bighelpSurface(.card)
                .accessibilityIdentifier("subagent.detail.summary.\(subagent.sessionID)")

                Text("Assigned goal")
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(subagent.goal)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BighelpTokens.space16)
                    .bighelpSurface(.card)

                if let subagentStreamAcceptanceFixture,
                   subagentStreamAcceptanceFixture.isControlling(
                       sessionID: subagent.sessionID
                   ) {
                    fixtureControls(subagentStreamAcceptanceFixture)
                }

                if let record {
                    persistedSession(record)
                } else {
                    HStack(spacing: BighelpTokens.space8) {
                        BighelpThinkingOrb(scenario: .working, scale: .inline)
                            .accessibilityHidden(true)
                        Text(availabilityMessage ?? "Loading the persisted child session from Hermes…")
                            .bighelpFont(.metadata)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BighelpTokens.space16)
                    .bighelpSurface(.card)
                    .accessibilityIdentifier("subagent.detail.persistence-placeholder")
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(BighelpTokens.space20)
            .frame(maxWidth: .infinity)
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityIdentifier("subagent.detail.\(subagent.sessionID)")
        .navigationTitle("Subagent session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            subagentStreamAcceptanceFixture?.observeDetail(
                sessionID: subagent.sessionID
            )
        }
        .task(id: subagent.sessionID) {
            await refreshPersistedSession()
        }
    }

    @ViewBuilder
    private var subagentStatusIcon: some View {
        if let record {
            switch SessionSubagentDetailPresentation.state(for: record) {
            case .live:
                BighelpThinkingOrb(scenario: .working, scale: .inline)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.danger)
            case .cancelled:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(theme.secondaryText)
            case .waiting:
                Image(systemName: "clock")
                    .foregroundStyle(theme.secondaryText)
            case .recorded:
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(theme.secondaryText)
            }
        } else {
            BighelpThinkingOrb(scenario: .working, scale: .inline)
        }
    }

    @ViewBuilder
    private func persistedSession(_ record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            HStack(spacing: BighelpTokens.space8) {
                switch SessionSubagentDetailPresentation.state(for: record) {
                case .live:
                    BighelpThinkingOrb(scenario: .working, scale: .inline)
                        .accessibilityHidden(true)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.success)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.danger)
                case .cancelled:
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(theme.secondaryText)
                case .waiting:
                    EmptyView()
                case .recorded:
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(theme.secondaryText)
                }
                Text(SessionSubagentDetailPresentation.statusTitle(for: record))
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("subagent.detail.status.\(subagent.sessionID)")
            }

            if record.items.isEmpty && record.activityEvents.isEmpty {
                Text("No child activity has arrived yet.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BighelpTokens.space16)
                    .bighelpSurface(.card)
            } else {
                let entries = transcriptEntries(for: record)
                LazyVStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .message(let item):
                            TimelineItemView(
                                item: item,
                                onApprovalTap: { _ in }
                            )
                        case .activity(let turn):
                            ChatActivityTurnView(turn: turn, isLive: record.isActive && entry.id == entries.last?.id)
                        }
                    }
                }
            }

            if let availabilityMessage {
                Text(availabilityMessage)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func transcriptEntries(for record: SessionRecord) -> [ChatTranscriptEntry] {
        ChatTranscriptProjection.entries(
            items: record.items,
            activityEvents: record.activityEvents,
            visibility: record.activityVisibility,
            isBotMode: record.kind == .botMode,
            isScheduled: record.isCronSession
        )
    }

    private func fixtureControls(
        _ fixture: SubagentStreamAcceptanceFixtureController
    ) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Button("Test fixture: emit second live event") {
                fixture.emitSecondLiveEvent()
            }
            .accessibilityIdentifier("fixture.subagent-stream.emit-second")
            .disabled(fixture.observedDetailSessionID != subagent.sessionID
                || fixture.didEmitSecondEvent)

            Button("Test fixture: emit terminal catch-up") {
                fixture.emitCanonicalTerminalCatchUp()
            }
            .accessibilityIdentifier("fixture.subagent-stream.emit-terminal")
            .disabled(!fixture.didEmitSecondEvent || fixture.didEmitTerminalEvent)
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fixture.subagent-stream.controls")
    }

    private func refreshPersistedSession() async {
        guard let sessionCatalog else {
            availabilityMessage = "This child session is not available in this preview."
            return
        }

        do {
            _ = try await sessionCatalog.refreshOrPrepareSession(
                id: subagent.sessionID
            )
            try Task.checkCancellation()
            availabilityMessage = nil
        } catch is CancellationError {
            return
        } catch {
            availabilityMessage = record == nil
                ? "Waiting for Hermes to persist this child session…"
                : "The latest child-session update is not available yet."
        }
    }

    @BighelpThemeReader private var theme

    @Environment(\.subagentStreamAcceptanceFixture)
    private var subagentStreamAcceptanceFixture
}
