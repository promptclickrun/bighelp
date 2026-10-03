import SwiftUI

extension View {
    /// Lets presented content sample what is behind it unless accessibility
    /// requires a fully opaque surface.
    func bighelpTranslucentPresentationBackground(fallback: Color) -> some View {
        modifier(BighelpTranslucentPresentationBackground(fallback: fallback))
    }
}

private struct BighelpTranslucentPresentationBackground: ViewModifier {
    let fallback: Color

    // Ember sheets sit on the warm canvas (cream / after dark) rather than a
    // gray system material, so they read as part of the same surface family.
    func body(content: Content) -> some View {
        content.presentationBackground(fallback)
    }
}

enum BighelpComponentKind: Equatable, Sendable {
    case card
    case iconButton
    case pillControl
    case menuPanel
    case menuRow
    case composer
    case searchField
    case generatedContentInset
}

struct BighelpComponentPresentation: Equatable, Sendable {
    let surfaceRole: BighelpSurfaceRole?
    let cornerRadius: CGFloat
    let minimumHeight: CGFloat?
    let fixedWidth: CGFloat?
    let fixedHeight: CGFloat?
    let usesInteractiveSurface: Bool
    let opaqueBase: BighelpSurfaceOpaqueBase?
    let elevation: BighelpSurfaceElevation

    static func resolve(
        _ kind: BighelpComponentKind,
        isSelected: Bool = false
    ) -> BighelpComponentPresentation {
        switch kind {
        case .card:
            BighelpComponentPresentation(
                surfaceRole: .card,
                cornerRadius: BighelpTokens.cardCornerRadius,
                minimumHeight: nil,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: false,
                opaqueBase: .surface,
                elevation: .low
            )
        case .iconButton:
            BighelpComponentPresentation(
                surfaceRole: .circularControl,
                cornerRadius: BighelpTokens.minimumControlSize / 2,
                minimumHeight: BighelpTokens.minimumControlSize,
                fixedWidth: BighelpTokens.minimumControlSize,
                fixedHeight: BighelpTokens.minimumControlSize,
                usesInteractiveSurface: true,
                opaqueBase: nil,
                elevation: .low
            )
        case .pillControl:
            BighelpComponentPresentation(
                surfaceRole: .capsuleControl,
                cornerRadius: BighelpTokens.radiusPill,
                minimumHeight: BighelpTokens.minimumControlSize,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: true,
                opaqueBase: nil,
                elevation: .low
            )
        case .menuPanel:
            BighelpComponentPresentation(
                surfaceRole: .menu,
                cornerRadius: BighelpTokens.menuCornerRadius,
                minimumHeight: nil,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: false,
                opaqueBase: nil,
                elevation: .high
            )
        case .menuRow:
            BighelpComponentPresentation(
                surfaceRole: isSelected ? .selected : nil,
                cornerRadius: BighelpTokens.menuRowCornerRadius,
                minimumHeight: BighelpTokens.minimumControlSize,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: false,
                opaqueBase: isSelected ? .surface : nil,
                elevation: .none
            )
        case .composer:
            BighelpComponentPresentation(
                surfaceRole: .composer,
                cornerRadius: BighelpTokens.composerCornerRadius,
                minimumHeight: BighelpTokens.composerMinimumHeight,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: false,
                opaqueBase: nil,
                elevation: .medium
            )
        case .searchField:
            BighelpComponentPresentation(
                surfaceRole: .input,
                cornerRadius: BighelpTokens.inputCornerRadius,
                minimumHeight: BighelpTokens.searchMinimumHeight,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: true,
                opaqueBase: nil,
                elevation: .none
            )
        case .generatedContentInset:
            BighelpComponentPresentation(
                surfaceRole: nil,
                cornerRadius: BighelpTokens.generatedContentInsetCornerRadius,
                minimumHeight: nil,
                fixedWidth: nil,
                fixedHeight: nil,
                usesInteractiveSurface: false,
                opaqueBase: .raisedSurface,
                elevation: .none
            )
        }
    }
}

struct BighelpHeaderActionPresentation: Equatable, Sendable {
    let iconPointSize: CGFloat
    let hitTarget: CGFloat
    let renderingMode: BighelpIconRenderingMode
    let showsBackground: Bool
    let showsBorder: Bool
    let usesTintFill: Bool

    static let standard = BighelpHeaderActionPresentation(
        iconPointSize: 17,
        hitTarget: BighelpTokens.hitTarget,
        renderingMode: .monochrome,
        showsBackground: false,
        showsBorder: false,
        usesTintFill: false
    )

    static let chatPrimary = BighelpHeaderActionPresentation(
        iconPointSize: 22,
        hitTarget: BighelpTokens.controlHeight,
        renderingMode: .monochrome,
        showsBackground: false,
        showsBorder: false,
        usesTintFill: false
    )
}

extension BighelpHeaderActionPresentation {
    static let compactGlass = BighelpHeaderActionPresentation(
        iconPointSize: 18,
        hitTarget: 48,
        renderingMode: .monochrome,
        showsBackground: true,
        showsBorder: false,
        usesTintFill: false
    )
}

struct SpectrumActionHitTargetPresentation: Equatable, Sendable {
    let visualSize: CGFloat
    let minimumHeight: CGFloat
    let expandsHorizontally: Bool
}

struct SpectrumAction: View {
    static let hitTargetPresentation = SpectrumActionHitTargetPresentation(
        visualSize: BighelpTokens.primaryActionSize,
        minimumHeight: BighelpTokens.primaryActionSize,
        expandsHorizontally: true
    )

    let accessibilityLabel: String
    let isAvailable: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        accessibilityLabel: String,
        isAvailable: Bool = true,
        action: @escaping () -> Void
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.isAvailable = isAvailable
        self.action = action
    }

    var body: some View {
        let presentation = FloatingTabBar.newChatPresentation(for: theme.themeID)
        let hitTarget = Self.hitTargetPresentation
        Button(action: action) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(presentation.foreground == .themeAccent
                        ? theme.action
                        : theme.primaryText)
                    .frame(width: hitTarget.visualSize, height: hitTarget.visualSize)
                    .modifier(
                        FloatingTabBarActionSurfaceModifier(
                            theme: theme,
                            reduceTransparency: reduceTransparency
                        )
                    )
                    .opacity(isAvailable ? 1 : 0.48)
                Spacer(minLength: 0)
            }
            .frame(
                maxWidth: hitTarget.expandsHorizontally ? .infinity : hitTarget.visualSize,
                minHeight: hitTarget.minimumHeight
            )
            .contentShape(.rect)
        }
        .buttonStyle(SpectrumPressStyle())
        .frame(
            maxWidth: hitTarget.expandsHorizontally ? .infinity : hitTarget.visualSize,
            minHeight: hitTarget.minimumHeight
        )
        .contentShape(.rect)
        .disabled(!isAvailable)
        .bighelpIconLabel(accessibilityLabel)
        .accessibilityValue(isAvailable ? "Available" : "Unavailable")
    }

    @BighelpThemeReader private var theme
}

struct FloatingTabBarActionSurfaceModifier: ViewModifier {
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled
    let theme: BighelpTheme
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if uiV2Enabled {
            content.bighelpSurface(.circularControl, isInteractive: true)
        } else if reduceTransparency {
            content.background(theme.raisedSurface, in: .circle)
        } else {
            #if os(visionOS)
            content.glassBackgroundEffect(in: .circle)
            #else
            if #available(iOS 26, *) {
                content
                    .glassEffect(.regular.interactive(), in: .circle)
            } else {
                content.background(.ultraThinMaterial, in: .circle)
            }
            #endif
        }
    }
}

private struct SpectrumPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(
                .easeOut(duration: BighelpTokens.pressDuration),
                value: configuration.isPressed
            )
    }
}

struct BighelpHeaderActionButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let presentation: BighelpHeaderActionPresentation
    let symbolVerticalOffset: CGFloat
    let role: ButtonRole?
    let isEnabled: Bool
    let action: () -> Void


    init(
        systemImage: String,
        accessibilityLabel: String,
        presentation: BighelpHeaderActionPresentation = .standard,
        symbolVerticalOffset: CGFloat = 0,
        role: ButtonRole? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.presentation = presentation
        self.symbolVerticalOffset = symbolVerticalOffset
        self.role = role
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: presentation.iconPointSize, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .symbolVariant(.none)
                .foregroundStyle(theme.primaryText)
                .offset(y: symbolVerticalOffset)
                .frame(width: presentation.hitTarget, height: presentation.hitTarget)
                .contentShape(.rect)
                .reflectiveVisionIcon()
                .accessibilityHidden(true)
                .modifier(BighelpHeaderSurfaceModifier())
        }
        .buttonStyle(SpectrumPressStyle())
        .frame(width: presentation.hitTarget, height: presentation.hitTarget)
        .contentShape(.rect)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .bighelpIconLabel(accessibilityLabel)
        .accessibilityValue(isEnabled ? "Available" : "Unavailable")
    }

    @BighelpThemeReader private var theme
}

private struct BighelpHeaderSurfaceModifier: ViewModifier {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled

    func body(content: Content) -> some View {
        if uiV3Enabled {
            content.bighelpNavigationGlass(in: Circle(), isInteractive: true)
        } else if uiV2Enabled {
            content.bighelpSurface(.circularControl, isInteractive: true).bighelpHover(in: Circle())
        } else {
            content.bighelpHover(in: Circle())
        }
    }
}

struct BighelpCard<Content: View>: View {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if uiV3Enabled {
            content
                .padding(BighelpTokens.space16)
                .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius16))
        } else {
            content
                .padding(BighelpTokens.space16)
                .bighelpSurface(.card)
        }
    }

    @BighelpThemeReader private var theme
}

enum BighelpIconButtonStyle: Equatable, Sendable {
    case themed
    case neutralGlass
}

struct BighelpIconButtonPresentation: Equatable, Sendable {
    enum Foreground: Equatable, Sendable {
        case themed
        case primaryText
    }

    let surfaceRole: BighelpSurfaceRole
    let foreground: Foreground
    let usesThemedIconWell: Bool
    let usesAccentTint: Bool

    static func resolve(_ style: BighelpIconButtonStyle) -> Self {
        switch style {
        case .themed:
            BighelpIconButtonPresentation(
                surfaceRole: .circularControl,
                foreground: .themed,
                usesThemedIconWell: true,
                usesAccentTint: true
            )
        case .neutralGlass:
            BighelpIconButtonPresentation(
                surfaceRole: .circularControl,
                foreground: .primaryText,
                usesThemedIconWell: false,
                usesAccentTint: false
            )
        }
    }
}

struct BighelpIconButton: View {
    @Environment(\.bighelpUIV2Enabled) private var uiV2Enabled
    let systemImage: String
    let accessibilityLabel: String
    let role: ButtonRole?
    let isEnabled: Bool
    let style: BighelpIconButtonStyle
    let action: () -> Void


    init(
        systemImage: String,
        accessibilityLabel: String,
        role: ButtonRole? = nil,
        isEnabled: Bool = true,
        style: BighelpIconButtonStyle = .themed,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.role = role
        self.isEnabled = isEnabled
        self.style = style
        self.action = action
    }

    var body: some View {
        let presentation = BighelpIconButtonPresentation.resolve(style)
        Button(role: role, action: action) {
            presentedIcon
                .frame(
                    width: BighelpTokens.minimumControlSize,
                    height: BighelpTokens.minimumControlSize
                )
                .contentShape(.circle)
                .bighelpHover(in: Circle())
        }
        .buttonStyle(SpectrumPressStyle())
        .frame(
            width: BighelpTokens.minimumControlSize,
            height: BighelpTokens.minimumControlSize
        )
        .bighelpSurface(presentation.surfaceRole, isInteractive: true)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .bighelpIconLabel(accessibilityLabel)
        .accessibilityValue(isEnabled ? "Available" : "Unavailable")
    }

    @ViewBuilder
    private var presentedIcon: some View {
        if uiV2Enabled {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .symbolVariant(.none)
                .foregroundStyle(role == .destructive ? theme.danger : theme.primaryText)
                .reflectiveVisionIcon()
                .accessibilityHidden(true)
        } else {
            legacyIcon
        }
    }

    @ViewBuilder
    private var legacyIcon: some View {
        switch style {
        case .themed:
            BighelpPresentedIcon(systemName: systemImage)
        case .neutralGlass:
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .symbolVariant(.none)
                .foregroundStyle(theme.primaryText)
                .reflectiveVisionIcon()
                .accessibilityHidden(true)
        }
    }

    @BighelpThemeReader private var theme
}

struct BighelpPillControl<Label: View>: View {
    let role: ButtonRole?
    let usesNavigationGlass: Bool
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    private let label: Label


    init(
        role: ButtonRole? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        usesNavigationGlass: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.role = role
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.usesNavigationGlass = usesNavigationGlass
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(role: role, action: action) {
            label
                .bighelpFont(.label)
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minHeight: BighelpTokens.minimumControlSize)
                .contentShape(.capsule)
                .bighelpHover(in: Capsule())
        }
        .buttonStyle(SpectrumPressStyle())
        .modifier(BighelpPillSurfaceModifier(usesNavigationGlass: usesNavigationGlass))
        .overlay {
            if isSelected {
                Capsule()
                    .fill(theme.action.opacity(0.12))
                    .allowsHitTesting(false)
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @BighelpThemeReader private var theme
}

struct BighelpPillSurfaceModifier: ViewModifier {
    let usesNavigationGlass: Bool

    func body(content: Content) -> some View {
        if usesNavigationGlass {
            content.bighelpNavigationGlass(in: Capsule(), isInteractive: true)
        } else {
            content.bighelpSurface(.capsuleControl, isInteractive: true)
        }
    }
}

struct BighelpMenuPanel<Content: View>: View {
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if uiV3Enabled {
            content
                .padding(BighelpTokens.space8)
                .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius12))
        } else {
            content
                .padding(BighelpTokens.space8)
                .bighelpSurface(.menu)
        }
    }

    @BighelpThemeReader private var theme
}

struct BighelpMenuRow<Label: View>: View {
    let role: ButtonRole?
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    private let label: Label

    init(
        role: ButtonRole? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.role = role
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(role: role, action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: BighelpTokens.minimumControlSize)
                .padding(.horizontal, BighelpTokens.space12)
                .contentShape(.rect)
                .bighelpHover(in: RoundedRectangle(cornerRadius: BighelpTokens.menuRowCornerRadius, style: .continuous))
        }
        .buttonStyle(SpectrumPressStyle())
        .modifier(BighelpMenuRowSurfaceModifier(isSelected: isSelected))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct BighelpSearchField: View {
    @Binding var text: String

    let prompt: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String?
    let onSubmit: () -> Void


    init(
        text: Binding<String>,
        prompt: String = "Search",
        accessibilityLabel: String = "Search",
        accessibilityIdentifier: String? = nil,
        onSubmit: @escaping () -> Void = {}
    ) {
        _text = text
        self.prompt = prompt
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(theme.secondaryText)
                .reflectiveVisionIcon()
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .bighelpFont(.body)
                .foregroundStyle(theme.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(.isSearchField)
                .modifier(BighelpSearchIdentifier(identifier: accessibilityIdentifier))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(theme.secondaryText)
                        .frame(
                            width: BighelpTokens.minimumControlSize,
                            height: BighelpTokens.minimumControlSize
                        )
                        .contentShape(.rect)
                        .reflectiveVisionIcon()
                        .accessibilityHidden(true)
                }
                .bighelpPlainButtonStyle(.circle)
                .bighelpIconLabel("Clear search")
                .accessibilityHint("Removes the current search text")
                .modifier(BighelpSearchIdentifier(identifier: accessibilityIdentifier.map { "\($0).clear" }))
            }
        }
        .padding(.leading, BighelpTokens.space12)
        .padding(.trailing, text.isEmpty ? BighelpTokens.space12 : 0)
        .frame(minHeight: BighelpTokens.searchMinimumHeight)
        .bighelpSurface(.input, isInteractive: true)
        // Mac: a click anywhere on the field (the glass, the padding) puts the caret in it.
        .bighelpMacFieldArea()
    }

    @BighelpThemeReader private var theme
}

private struct BighelpSearchIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private struct BighelpMenuRowSurfaceModifier: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content.bighelpSurface(.selected)
        } else {
            content
        }
    }
}

private struct BighelpPresentedIcon: View {
    let systemName: String


    var body: some View {
        let presentation = BighelpIconPresentation.resolve(style: theme.iconStyle)

        ZStack {
            iconWell(for: presentation)
            icon(for: presentation)
        }
    }

    @ViewBuilder
    private func iconWell(for presentation: BighelpIconPresentation) -> some View {
        switch presentation.innerWell {
        case .tintedCircle:
            Circle()
                .fill(theme.action.opacity(0.12))
                .frame(width: 30, height: 30)
        case .outlinedRoundedRectangle:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.primaryText.opacity(0.55), lineWidth: BighelpTokens.hairline)
                .frame(width: 30, height: 28)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func icon(for presentation: BighelpIconPresentation) -> some View {
        let image = Image(systemName: systemName)
            .font(.system(size: 17, weight: fontWeight(for: presentation.glyphWeight)))
            .symbolRenderingMode(
                presentation.renderingMode == .hierarchical ? .hierarchical : .monochrome
            )
            .foregroundStyle(
                presentation.renderingMode == .hierarchical ? theme.action : theme.primaryText
            )
            .reflectiveVisionIcon()
            .accessibilityHidden(true)

        if presentation.symbolVariant == .filled {
            image.symbolVariant(.fill)
        } else {
            image.symbolVariant(.none)
        }
    }

    private func fontWeight(for weight: BighelpIconGlyphWeight) -> Font.Weight {
        switch weight {
        case .regular: .regular
        case .semibold: .semibold
        }
    }

    @BighelpThemeReader private var theme
}

struct StatusBadge: View {
    enum Status {
        case success
        case warning
        case danger
        case information
    }

    let title: String
    let status: Status


    var body: some View {
        Label(title, systemImage: status.systemImage)
            .bighelpFont(.metadata, weight: .semibold)
            .foregroundStyle(status.color(in: theme))
            .padding(.horizontal, BighelpTokens.space8)
            .padding(.vertical, BighelpTokens.space4)
            .background(status.color(in: theme).opacity(0.12), in: .capsule)
            .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

private extension StatusBadge.Status {
    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .information: "info.circle.fill"
        }
    }

    func color(in theme: BighelpTheme) -> Color {
        switch self {
        case .success: theme.success
        case .warning: theme.warning
        case .danger: theme.danger
        case .information: theme.information
        }
    }
}

/// The token breakdown for a chat's context window, from the chat's ⋯ menu.
struct SessionContextTokenPopover: View {
    let snapshot: SessionContextSnapshot
    /// Opens Provider Usage (the plans and limits behind this context).
    var onShowProviderUsage: (() -> Void)? = nil
    /// The chat's model and reasoning, first: what this context belongs to.
    var runtimeControls: SessionRuntimeControlModel? = nil
    var onChangeModel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if let runtimeControls {
                ChatModelSummaryRow(controls: runtimeControls, onChange: onChangeModel)
                Divider()
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context window")
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: BighelpTokens.space12)
                    if let onShowProviderUsage {
                        Button(action: onShowProviderUsage) {
                            Image(systemName: "gauge.with.dots.needle.50percent")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(theme.action)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(theme.action.opacity(0.12)))
                        }
                        .bighelpPlainButtonStyle(.circle)
                        .bighelpIconLabel("Provider usage")
                        .accessibilityHint("Shows the plans and limits of the AI providers on your computer.")
                        .accessibilityIdentifier("chat.session-context.provider-usage")
                    }
                }
                Text(SessionContextPresentation.summary(for: snapshot))
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: BighelpTokens.space8) {
                ForEach(SessionContextPresentation.tokenRows(for: snapshot)) { row in
                    HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space12) {
                        Text(row.title)
                            .bighelpFont(.body)
                            .foregroundStyle(theme.secondaryText)
                        Spacer(minLength: BighelpTokens.space12)
                        Text(row.value)
                            .bighelpFont(.body, weight: .semibold)
                            .foregroundStyle(theme.primaryText)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("chat.session-context.\(row.id)")
                }
            }

            if !snapshot.hasTokenAccounting {
                Text("Detailed token usage is unavailable.")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.session-context.unavailable")
            }

            if snapshot.isCompacting {
                Label("Compacting the context window", systemImage: "arrow.down.right.and.arrow.up.left")
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.session-context.compacting")
            }
        }
        .padding(BighelpTokens.space20)
        .frame(minWidth: 260, alignment: .leading)
        .background(theme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.session-context.popover")
    }

    @BighelpThemeReader private var theme

}

/// A compact, iOS-native inline problem notice: tinted icon, readable text that
/// wraps rather than truncates, and optional recovery and dismissal controls
/// with full-size hit targets. Text stays in the primary color for contrast;
/// only the icon and hairline carry the danger tint.
struct BighelpInlineNotice: View {
    enum Tone { case danger, warning }

    let message: String
    var tone: Tone = .danger
    var actionTitle: String?
    var actionIdentifier: String?
    var isActionEnabled = true
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
            Image(systemName: tone == .danger ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.action)
                    .bighelpPlainButtonStyle(padding: 4)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
                    .disabled(!isActionEnabled)
                    .accessibilityIdentifier(actionIdentifier ?? "")
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.bighelp(.footnote).weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .bighelpPlainButtonStyle(.circle)
                .bighelpIconLabel("Dismiss")
            }
        }
        .padding(.leading, BighelpTokens.space12)
        .padding(.trailing, onDismiss == nil ? BighelpTokens.space12 : BighelpTokens.space4)
        .padding(.vertical, onDismiss == nil && actionTitle == nil ? BighelpTokens.space8 : 0)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: BighelpTokens.hairline)
        }
        .accessibilityElement(children: action == nil && onDismiss == nil ? .combine : .contain)
    }

    private var tint: Color { tone == .danger ? theme.danger : theme.warning }

    @BighelpThemeReader private var theme
}

/// iMessage-style tactile press: a brief scale-down with no color change.
/// Honors Reduce Motion by dimming instead of scaling.
struct BighelpPressFeedbackStyle: ButtonStyle {
    /// Compact glyph controls use the full press; larger tiles use a subtler one.
    var pressedScale: CGFloat = 0.88

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? (reduceMotion ? 0.6 : BighelpButtonPress.opacity) : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BighelpPressFeedbackStyle {
    static var bighelpPress: BighelpPressFeedbackStyle { BighelpPressFeedbackStyle() }
    static var bighelpTilePress: BighelpPressFeedbackStyle { BighelpPressFeedbackStyle(pressedScale: 0.96) }
}

/// iOS Settings-style glyph tile: a white symbol on a small accent square.
struct BighelpIconTile: View {
    let systemName: String
    var tint: Color?

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let color = tint ?? theme.action
        let solid = colorSchemeContrast == .increased
        let shape = RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
        BighelpSymbolImage(systemName: systemName)
            .frame(width: side * 0.72, height: side * 0.72)
            // A soft wash of the accent with the icon in the accent itself.
            // Increased Contrast keeps a solid tile with the accent's own ink.
            .foregroundStyle(solid ? (tint == nil ? theme.actionForeground : .white) : color)
            .frame(width: side, height: side)
            .background(color.opacity(solid ? 1 : (theme.isDarkPalette ? 0.26 : 0.13)), in: shape)
            .overlay { if !solid { shape.strokeBorder(color.opacity(theme.isDarkPalette ? 0.22 : 0.16), lineWidth: 1) } }
            .accessibilityHidden(true)
    }

    @BighelpThemeReader private var theme
}

/// Builds its content in its own SwiftUI update and erases its type.
///
/// Large grouped screens otherwise compile (in Release) into one function that
/// holds every section's view value on the stack at once and one enormous nested
/// generic type. On device the 1 MB main-thread stack can overflow while that
/// type is resolved. Wrapping each section keeps the parent small; List and
/// Form still see the Section inside.
struct BighelpDeferredSection: View {
    private let make: () -> AnyView

    init<Content: View>(@ViewBuilder _ content: @escaping () -> Content) {
        make = { AnyView(content()) }
    }

    var body: some View { make() }
}
