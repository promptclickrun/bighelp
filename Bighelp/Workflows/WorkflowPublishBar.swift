import SwiftUI

/// A draft isn't what runs use until it's published. Says so above the flow, with Publish.
/// Run publishes too, but schedules, Shortcuts and agents only ever run the published version.
struct WorkflowPublishBar: View {
    let model: WorkflowEditorModel
    var onPublished: () -> Void = {}
    @State private var isPublishing = false
    @BighelpThemeReader private var theme

    var body: some View {
        if model.needsPublish {
            HStack(spacing: BighelpTokens.space12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "Draft" : "Changes not published")
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text(detail)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button {
                    isPublishing = true
                    Task {
                        defer { isPublishing = false }
                        if await model.publish() { onPublished() }
                    }
                } label: {
                    Text(isPublishing ? "Publishing…" : "Publish")
                        .font(.bighelp(.body).weight(.semibold))
                        .frame(minHeight: BighelpTokens.hitTarget - 8)
                }
                .workflowProminent(theme)
                .disabled(!model.canRun || isPublishing)
                .accessibilityHint(model.canRun ? "Makes this the version that runs."
                                                : "Fix the problems in this workflow first.")
                .accessibilityIdentifier("workflows.publish")
            }
            .padding(BighelpTokens.space12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous).strokeBorder(theme.border)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workflows.publish-bar")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var isNew: Bool { model.detail?.latestRevision == nil }

    /// What publishing does here, or what stands in its way.
    private var detail: String {
        switch (isNew, model.canRun) {
        case (true, true): "Not live yet. Publish it so schedules and your agents can run it."
        case (true, false): "Not live yet. Fix what's marked in the flow, then publish."
        case (false, true): "Runs use the last published version until you publish."
        case (false, false): "Runs use the last published version. Fix what's marked in the flow, then publish."
        }
    }
}
