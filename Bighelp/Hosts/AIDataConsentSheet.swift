import SwiftUI

/// The one-time agreement to share data with AI providers (App Review 5.1.1(i), 5.1.2(i)).
/// First setup asks before any computer is connected. Anyone else who hasn't agreed (a
/// bighelp set up before the agreement existed, which App Review's device can be) is asked
/// once when bighelp opens (`AIDataConsentGate`), and Shortcuts, the Watch, CarPlay and the
/// agent in the room send nothing until then. After agreeing, it's never asked again: not
/// after an update, not for another host.
enum AIDataConsent {
    /// Never rename: a new key would ask everyone again.
    static let key = "bighelp.privacy.ai-data-agreed"
    static let privacyPolicy = URL(string: "https://bighelp.app/privacy")!

    static func isAgreed(_ defaults: UserDefaults = .standard) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return defaults.bool(forKey: key)
            || arguments.contains("-use-demo-fixtures") || arguments.contains("-disable-demo-delays")
    }

    /// Outside first setup (which asks in its own flow) and demo data.
    static func needsAsking(agreed: Bool, inFirstSetup: Bool, usesDemoData: Bool) -> Bool {
        !agreed && !inFirstSetup && !usesDemoData
    }
}

/// Asks anyone who hasn't agreed, once, before bighelp shares anything. It can't be dismissed
/// any other way: until then, nothing goes to a computer or an AI provider.
struct AIDataConsentGate: ViewModifier {
    let inFirstSetup: Bool
    let usesDemoData: Bool
    @AppStorage(AIDataConsent.key) private var agreed = false

    func body(content: Content) -> some View {
        let asks = AIDataConsent.needsAsking(agreed: agreed, inFirstSetup: inFirstSetup, usesDemoData: usesDemoData)
        content.bighelpSheet(isPresented: Binding(get: { asks }, set: { _ in })) {
            AIDataConsentSheet { agreed = true }
                .interactiveDismissDisabled()
                .presentationDetents([.medium])
                .bighelpSheetSize(.compact)
        }
    }
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
