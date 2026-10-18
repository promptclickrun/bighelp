import SwiftUI

/// Simple Bot mode's building blocks: round glass buttons, gray rounded cards
/// with full-width rows, and quiet section labels, all in the system font.
struct SimpleBotsCircleButton: View {
    let systemImage: String
    let label: String
    let identifier: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.bighelp(.title3, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.circle)
                .bighelpNavigationGlass(in: Circle(), isInteractive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// The person's own circle, top left: their picture or initial.
struct SimpleBotsPersonButton: View {
    let name: String
    let imageURL: URL?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            AvatarView(stableID: UserIdentity.stableID, displayName: name, imageURL: imageURL,
                       size: BighelpTokens.hitTarget - 8, kind: .person)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.circle)
                .bighelpNavigationGlass(in: Circle(), isInteractive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("simple-bots.settings")
    }
}

/// A gray rounded card holding rows; put `SimpleBotsDivider` between them.
struct SimpleBotsCard<Content: View>: View {
    @ViewBuilder let content: Content
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(spacing: 0) { content }
            .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20, style: .continuous))
    }
}

/// The hairline between two rows of a card.
struct SimpleBotsDivider: View {
    @BighelpThemeReader private var theme

    var body: some View {
        Rectangle().fill(theme.separator).frame(height: BighelpTokens.hairline)
            .padding(.leading, BighelpTokens.space20)
    }
}

/// A row in a card: title and optional detail, a value or control at the end.
struct SimpleBotsRow<Accessory: View>: View {
    let title: String
    var detail: String?
    var leading: Image?
    @ViewBuilder var accessory: Accessory
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            if let leading {
                leading
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                if let detail {
                    Text(detail)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            accessory
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.vertical, BighelpTokens.space12)
        .frame(minHeight: 56)
        .contentShape(.rect)
    }
}

extension SimpleBotsRow where Accessory == SimpleBotsDisclosure {
    init(title: String, detail: String? = nil, leading: Image? = nil, value: String? = nil) {
        self.init(title: title, detail: detail, leading: leading) { SimpleBotsDisclosure(value: value) }
    }
}

/// A value, then the gray chevron, at a row's end.
struct SimpleBotsDisclosure: View {
    var value: String?
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            if let value {
                Text(value)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(theme.tertiaryText)
                .accessibilityHidden(true)
        }
    }
}

/// A quiet label above a card.
struct SimpleBotsSectionLabel: View {
    let title: String
    @BighelpThemeReader private var theme

    var body: some View {
        Text(title)
            .font(.bighelp(.subheadline))
            .foregroundStyle(theme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.top, BighelpTokens.space12)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The wide black button at the bottom of a sheet (Create, Next).
struct SimpleBotsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @BighelpThemeReader private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bighelp(.body, weight: .semibold))
            .foregroundStyle(isEnabled ? theme.actionForeground : theme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isEnabled ? theme.action : theme.surface, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// Under a header's buttons: the page color, fading out, so content scrolls away under it.
struct SimpleBotsHeaderFade: View {
    @BighelpThemeReader private var theme

    var body: some View {
        LinearGradient(stops: [.init(color: theme.canvas, location: 0), .init(color: theme.canvas, location: 0.7),
                               .init(color: theme.canvas.opacity(0), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }
}
