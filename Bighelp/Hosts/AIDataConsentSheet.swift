import SwiftUI

/// The one-time agreement to share data with AI providers (App Review 5.1.1(i), 5.1.2(i)).
/// It's asked the very first time someone sets bighelp up, before any computer is
/// connected, and never again: not after an update, not for another host. People who
/// set bighelp up before it existed aren't asked.
enum AIDataConsent {
    /// Never rename: a new key would ask everyone again.
    static let key = "bighelp.privacy.ai-data-agreed"
    static let privacyPolicy = URL(string: "https://bighelp.app/privacy")!
}

struct AIDataConsentSheet: View {
    let onAgree: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: BighelpTokens.space16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(theme.action)
                .accessibilityHidden(true)
            Text("Your data and AI")
                .bighelpFont(.sectionTitle, weight: .semibold)
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("bighelp sends what you share (messages, files, photos, voice, and location if you turn it on) to your Hermes computer and the AI providers you set up on it.")
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onAgree) {
                Text("Agree and continue")
                    .bighelpFont(.label, weight: .semibold)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.controlHeight)
                    .contentShape(.rect)
            }
            .controlSize(.large)
            .bighelpActionStyle(.primary)
            .accessibilityIdentifier("onboarding.ai-consent.agree")
            Button("Privacy policy") { openURL(AIDataConsent.privacyPolicy) }
                .bighelpFont(.label)
                .foregroundStyle(theme.secondaryText)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("onboarding.ai-consent.privacy")
        }
        .padding(.horizontal, BighelpTokens.space24)
        .padding(.vertical, BighelpTokens.space16)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Solid, so what's behind doesn't show through the sheet around the text.
        .presentationBackground(theme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.ai-consent")
    }

    @BighelpThemeReader private var theme
}
