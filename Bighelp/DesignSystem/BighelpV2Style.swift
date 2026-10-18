import SwiftUI

/// Applied by the existing shell theme modifier, including the account gate.
/// Child controls with explicit styles keep ownership of their own geometry.
struct BighelpV2DefaultsModifier: ViewModifier {
    let theme: BighelpTheme

    func body(content: Content) -> some View {
        // Keep the root's structural identity stable when the opt-in changes.
        // Native toggles, menus and navigation links retain their platform
        // interaction styles; V2's own button components opt in explicitly.
        content
            #if !os(visionOS) // visionOS fills tinted toolbar buttons; keep its glass.
            .tint(theme.action)
            #endif
            .foregroundStyle(theme.primaryText)
    }
}

enum BighelpActionEmphasis {
    case primary
    case secondary
    case quiet
}

/// Use for text actions in V2 branches. Shared icon/pill/menu components already
/// adopt V2 automatically. Labels retain their native Button accessibility.
struct BighelpV2ButtonStyle: ButtonStyle {
    var emphasis: BighelpActionEmphasis = .secondary

    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let theme = BighelpTheme.resolve(
            appearance: appearance, colorScheme: colorScheme, contrast: contrast
        )
        // Destructive actions remain explicitly red and outlined, rather than
        // borrowing an action-ink color that may not contrast with danger.
        let filled = emphasis == .primary && configuration.role != .destructive
        let quiet = emphasis == .quiet
        configuration.label
            .bighelpFont(.label, weight: .semibold)
            .foregroundStyle(configuration.role == .destructive
                ? theme.danger : filled ? theme.actionForeground : theme.primaryText)
            .padding(.horizontal, quiet ? BighelpTokens.space8 : BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space8)
            .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
            .background(filled ? theme.action : quiet ? .clear : theme.raisedSurface, in: .capsule)
            .overlay {
                if !quiet {
                    Capsule().strokeBorder(
                        filled ? theme.action : contrast == .increased ? theme.primaryText : theme.border,
                        lineWidth: contrast == .increased ? 2 : BighelpTokens.hairline
                    )
                    .allowsHitTesting(false)
                }
            }
            .contentShape(.capsule)
            .opacity(!isEnabled ? 0.48 : 1)
            .bighelpPressFeedback(isPressed: configuration.isPressed)
    }
}

extension View {
    /// A quiet, theme-owned surface for preference pages and modal editors.
    func bighelpFormSurface() -> some View {
        modifier(BighelpFormSurfaceModifier())
    }

    /// Replaces native bordered styles only while V2 is enabled. Use at each
    /// explicit action site; a root style cannot override a child's own style.
    func bighelpActionStyle(_ emphasis: BighelpActionEmphasis = .secondary) -> some View {
        modifier(BighelpActionStyleModifier(emphasis: emphasis))
    }
}

private struct BighelpFormSurfaceModifier: ViewModifier {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let theme = BighelpTheme.resolve(appearance: appearance, colorScheme: colorScheme, contrast: contrast)
        let form = content
            .formStyle(.grouped)
            .bighelpFont(.body)
            .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .tint(theme.action)
        if appearance.simpleBots {
            form.toggleStyle(SimpleBotsSwitchStyle())
        } else {
            form
        }
    }
}

/// Simple Bot mode tints with the page's ink, which is white after dark: a switch would be white on
/// white. Its switches are green, as on its own Settings page.
private struct SimpleBotsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.automatic).tint(SimpleBotColor.green.color)
    }
}

private struct BighelpActionStyleModifier: ViewModifier {
    let emphasis: BighelpActionEmphasis
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if uiV3Enabled {
            content.buttonStyle(BighelpV3ButtonStyle(emphasis: emphasis))
        } else if uiV2Enabled {
            content.buttonStyle(BighelpV2ButtonStyle(emphasis: emphasis))
        } else {
            switch emphasis {
            case .primary: content.bighelpProminentButtonStyle()
            case .secondary: content.buttonStyle(.bordered)
            case .quiet: content.buttonStyle(.plain)
            }
        }
    }
}

// V3 keeps content on the canvas. Only navigation chrome receives glass;
// collection sections deliberately do not become another layer of cards.
struct BighelpShellSection<Content: View>: View {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if uiV3Enabled {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, BighelpTokens.space8)
        } else {
            BighelpCard { content }
        }
    }
}

extension View {
    /// Applied inside the scroll view, so wide layouts keep one readable column.
    func bighelpShellContentWidth() -> some View {
        modifier(BighelpShellContentWidthModifier())
    }
}

private struct BighelpShellContentWidthModifier: ViewModifier {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled

    func body(content: Content) -> some View {
        if uiV3Enabled {
            content
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            content
        }
    }
}

private struct BighelpV3ButtonStyle: ButtonStyle {
    let emphasis: BighelpActionEmphasis
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        styled(configuration).bighelpPressFeedback(isPressed: configuration.isPressed)
    }

    @ViewBuilder
    private func styled(_ configuration: Configuration) -> some View {
        let theme = BighelpTheme.resolve(appearance: appearance, colorScheme: colorScheme, contrast: contrast)
        let filled = emphasis == .primary && configuration.role != .destructive
        let quiet = emphasis == .quiet
        let label = configuration.label
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(configuration.role == .destructive ? theme.danger
                : filled ? theme.actionForeground : theme.primaryText)
            .padding(.horizontal, quiet ? BighelpTokens.space8 : BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space8)
            .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect(cornerRadius: BighelpTokens.radius12))
            .opacity(!isEnabled ? 0.48 : 1)

        if quiet {
            label
        } else {
            let fallback = label
                .background(filled ? theme.action : theme.raisedSurface,
                            in: .rect(cornerRadius: BighelpTokens.radius12))
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                            .strokeBorder(theme.primaryText, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
            #if compiler(>=6.2) && !os(visionOS) // visionOS has no glassEffect.
            if #available(iOS 26.0, *), !reduceTransparency {
                let glass: Glass = filled
                    ? .regular.tint(theme.action).interactive()
                    : .regular.interactive()
                label.glassEffect(
                    glass,
                    in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
                )
            } else {
                fallback
            }
            #else
            fallback
            #endif
        }
    }
}
