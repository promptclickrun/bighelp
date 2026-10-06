import SwiftUI
import UIKit

/// How many images of a set are done, from real counts ("2 of 4").
struct BighelpImageCount: Equatable, Sendable {
    let completed: Int
    let total: Int

    /// Nil unless the numbers make sense for a set of several images.
    init?(completed: Int, total: Int) {
        guard (2...64).contains(total), (0...total).contains(completed) else { return nil }
        self.completed = completed
        self.total = total
    }

    var label: String { "\(completed) of \(total)" }
}

/// Soft warm glows drifting where an image will appear, with a light grain, and
/// either a slow sheen (`glow`) or a dot scan (`develop`). Honest by design: the
/// caption is the caller's words, there's no time estimate, the progress bar
/// shows only with a real fraction, and "2 of 4" only with real counts.
///
/// Cheap enough for several in a scrolling chat: one mesh gradient (iOS 18 and
/// later) or three radial gradients (iOS 17), no blur filters, static grain and
/// dot textures drawn once, and one shared clock that stops when it should.
struct BighelpImageGeneratingView: View {
    enum Variant: Sendable { case glow, develop }
    enum Size: Sendable {
        /// A caption pill at the bottom.
        case regular
        /// For grids: a breathing sparkle in the middle, no caption.
        case compact
    }

    var caption: String = "Making your image"
    var variant: Variant = .glow
    var size: Size = .regular
    /// Width over height.
    var aspectRatio: CGFloat = 1
    /// Real progress, 0...1. Nil hides the bar.
    var progress: Double?
    var count: BighelpImageCount?
    /// Seconds to shift this copy's loops, so tiles in a grid don't move as one.
    var phaseOffset: TimeInterval = 0

    @BighelpThemeReader private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size == .compact ? 14 : BighelpTokens.cardCornerRadius,
                                     style: .continuous)
        GeometryReader { proxy in
            ZStack {
                theme.incomingMessageSolid
                let colors = BighelpImageGlowColors(palette: palette, theme: theme)
                BighelpLoaderClock(cadence: .ambient) { time in
                    BighelpImageGeneratingLayers(time: time, offset: phaseOffset, variant: variant, size: proxy.size,
                                                 colors: colors)
                }
                // The dot scan's mask runs taller than the frame; it mustn't size the stack.
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                BighelpImageGeneratingTextures.grain
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(0.18)
                if size == .compact {
                    let sparkle = theme.primaryText.opacity(0.55)
                    BighelpLoaderClock(cadence: .soft) { time in
                        let breath = time.pingPong(BighelpLoaderTiming.breathe / 2, offset: phaseOffset, rest: 0.5)
                        Image(BighelpGlyph.sparkles.assetName)
                            .resizable().renderingMode(.template)
                            .frame(width: 22, height: 22)
                            .foregroundStyle(sparkle)
                            .scaleEffect(time.isStill ? 1 : 0.92 + 0.14 * breath)
                            .opacity(time.isStill ? 1 : 0.6 + 0.4 * breath)
                    }
                } else {
                    VStack {
                        Spacer(minLength: 0)
                        captionPill
                            .padding(10)
                    }
                }
                if let fraction = BighelpImageGeneratingView.visibleProgress(progress) {
                    VStack {
                        Spacer(minLength: 0)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(theme.action.opacity(0.14))
                            UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                                .fill(theme.action)
                                .frame(width: proxy.size.width * fraction)
                        }
                        .frame(height: 3)
                        .animation(BighelpLoaderCurve.site.animation(duration: 0.6), value: fraction)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(BighelpImageGeneratingView.visibleProgress(progress).map {
            "\(Int(($0 * 100).rounded())) percent"
        } ?? "")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("image-generating")
    }

    /// The bar's fraction, or nil when there's no real number to show.
    static func visibleProgress(_ progress: Double?) -> Double? {
        guard let progress, progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }

    private var accessibilityText: String {
        [caption, count.map { "\($0.label) done" }].compactMap { $0 }.joined(separator: ", ")
    }

    private var palette: BighelpImageGlowPalette {
        theme.isDarkPalette ? .dark : .light
    }

    private var captionPill: some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(BighelpGlyph.sparkles.assetName)
                .resizable().renderingMode(.template)
                .frame(width: 16, height: 16)
                .foregroundStyle(theme.action)
            Text(caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .bighelpShimmer(isActive: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let count {
                Text(count.label)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize()
            }
        }
        .font(.bighelp(.footnote, weight: .semibold))
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.vertical, BighelpTokens.space8)
        // A translucent fill, not a live blur: the glows behind move every
        // frame and are soft already, so a blur would only cost redraws.
        .background(Capsule().fill(theme.raisedSurface.opacity(theme.isDarkPalette ? 0.88 : 0.78)))
        .overlay(Capsule().strokeBorder(theme.isDarkPalette ? Color.white.opacity(0.1)
                                                            : theme.primaryText.opacity(0.11), lineWidth: 1))
        .shadow(color: theme.elevationShadow.opacity(0.05), radius: 7, y: 6)
    }
}

/// A row under a grid of image tiles: "Making 4 versions · 2 of 4".
struct BighelpImageGeneratingCaption: View {
    var text: String
    var count: BighelpImageCount?

    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(BighelpGlyph.sparkles.assetName)
                .resizable().renderingMode(.template)
                .frame(width: 16, height: 16)
                .foregroundStyle(theme.action)
            Text(text)
                .lineLimit(1)
                .bighelpShimmer(isActive: true)
            if let count {
                Text("· \(count.label)")
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize()
            }
        }
        .font(.bighelp(.subheadline, weight: .medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([text, count.map { "\($0.label) done" }].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The design's glow colors. Lavender, violet and the deep violet are bighelp's
/// action purples; peach and gold warm them like the site's glows.
struct BighelpImageGlowPalette: Equatable, Sendable {
    let colors: [Color]
    /// How strongly each glow shows over the placeholder's base; the violet
    /// one at 60%, as in the design.
    let strengths: [Double]

    static let light = Self(colors: [Color(hex: BighelpTheme.dark.actionHex), Color(hex: "FFC9B2"),
                                     BighelpTokens.Palette.violet, Color(hex: "F7D98A")],
                            strengths: [0.8, 0.8, 0.48, 0.8])
    static let dark = Self(colors: [Color(hex: BighelpTheme.lightHighContrast.actionHex), Color(hex: "7A4A3C"),
                                    Color(hex: "9474E7"), Color(hex: "6B5520")],
                           strengths: [0.7, 0.7, 0.42, 0.7])
}

/// The glow colors laid over the placeholder's base, mixed once per look
/// rather than on every frame.
private struct BighelpImageGlowColors {
    let base: Color
    /// Each glow over the base, for the radial fallback.
    let glows: [Color]
    /// The 3×3 mesh, row by row: lavender top left, peach on the right, violet
    /// low on the left, gold bottom right, a soft mix in the middle.
    let mesh: [Color]

    /// The `glow` sheen's bright middle and the `develop` dots.
    let sheen: Color
    let dots: Color

    init(palette: BighelpImageGlowPalette, theme: BighelpTheme) {
        let base = theme.incomingMessageSolid
        self.base = base
        sheen = Color.white.opacity(theme.isDarkPalette ? 0.08 : 0.35)
        dots = theme.primaryText.opacity(0.3)
        let glows = zip(palette.colors, palette.strengths).map { BighelpLoaderColor.mix(base, $0, by: $1) }
        let mix = BighelpLoaderColor.mix
        self.glows = glows
        mesh = [
            glows[0], mix(glows[0], glows[1], 0.5), mix(base, glows[1], 0.7),
            mix(glows[0], glows[2], 0.5), mix(base, mix(glows[0], glows[1], 0.5), 0.6), glows[1],
            glows[2], mix(glows[2], glows[3], 0.5), glows[3],
        ]
    }
}

enum BighelpLoaderColor {
    /// `a` moved `amount` of the way to `b`. (`Color.mix` needs iOS 18; these
    /// are fixed theme colors, so their sRGB values are enough.)
    static func mix(_ a: Color, _ b: Color, by amount: Double) -> Color {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        UIColor(a).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(b).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(min(max(amount, 0), 1))
        return Color(.sRGB, red: Double(r1 + (r2 - r1) * t), green: Double(g1 + (g2 - g1) * t),
                     blue: Double(b1 + (b2 - b1) * t), opacity: Double(a1 + (a2 - a1) * t))
    }
}

/// The moving layers of one placeholder at one moment.
private struct BighelpImageGeneratingLayers: View {
    let time: BighelpLoaderTime
    let offset: TimeInterval
    let variant: BighelpImageGeneratingView.Variant
    let size: CGSize
    let colors: BighelpImageGlowColors

    var body: some View {
        ZStack {
            glows
            switch variant {
            case .glow: sheen
            case .develop: dotScan
            }
        }
    }

    /// Where each glow sits, 0...1 in the frame, drifting on its own long loop.
    private var drift: [CGPoint] {
        let d = BighelpLoaderTiming.glowDrifts
        let a = time.pingPong(d[0], offset: offset, rest: 0.3)
        let b = time.pingPong(d[1], offset: offset, rest: 0.4)
        let c = time.pingPong(d[2], offset: offset, rest: 0.5)
        let e = 1 - time.pingPong(d[3], offset: offset, rest: 0.6)
        return [
            CGPoint(x: 0.22 + 0.26 * a, y: 0.2 + 0.22 * a),
            CGPoint(x: 0.82 - 0.3 * b, y: 0.36 + 0.18 * b),
            CGPoint(x: 0.42 + 0.18 * c, y: 0.82 - 0.3 * c),
            CGPoint(x: 0.78 + 0.1 * e, y: 0.82 + 0.06 * e),
        ]
    }

    @ViewBuilder
    private var glows: some View {
        let points = drift
        if #available(iOS 18.0, macCatalyst 18.0, visionOS 2.0, *) {
            MeshGradient(width: 3, height: 3, points: meshPoints, colors: colors.mesh)
        } else {
            ZStack {
                colors.base
                ForEach(0..<3, id: \.self) { index in
                    RadialGradient(colors: [colors.glows[index], colors.glows[index].opacity(0)],
                                   center: UnitPoint(x: points[index].x, y: points[index].y),
                                   startRadius: 0, endRadius: max(size.width, size.height) * [0.62, 0.55, 0.48][index])
                }
            }
        }
    }

    /// The 3×3 mesh's points: corners pinned, the edge midpoints sliding along
    /// their edges and the middle wandering, each on its own long loop. Kept
    /// within ±0.2 so the mesh never folds.
    private var meshPoints: [SIMD2<Float>] {
        let d = BighelpLoaderTiming.glowDrifts
        func swing(_ period: TimeInterval) -> Float {
            Float(time.pingPong(period, offset: offset, rest: 0.5) - 0.5) * 2
        }
        let a = swing(d[0]), b = swing(d[1]), c = swing(d[2]), e = swing(d[3])
        return [
            [0, 0], [0.5 + 0.2 * c, 0], [1, 0],
            [0, 0.5 + 0.15 * b], [0.5 + 0.18 * a, 0.5 + 0.15 * c], [1, 0.5 + 0.15 * a],
            [0, 1], [0.5 + 0.2 * e, 1], [1, 1],
        ]
    }

    /// The `glow` variant's slow sheen, across and slightly down. The band
    /// moves through the gradient's own end points rather than an oversized,
    /// offset frame, so the placeholder's frame (and the VoiceOver frame that
    /// follows it) stays exactly the picture's.
    private var sheen: some View {
        let lift = colors.sheen
        let p = BighelpLoaderCurve.site(time.phase(BighelpLoaderTiming.glowSweep, offset: offset))
        // The same path as a band 1.4 times the frame sliding from -0.6 to 0.6
        // of its width: its left edge in the frame's unit space.
        let leading = -1.04 + 1.68 * p
        return LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: lift, location: 0.5),
                                      .init(color: .clear, location: 0.6)],
                              startPoint: UnitPoint(x: leading, y: 0.22), endPoint: UnitPoint(x: leading + 1.4, y: 0.78))
            .opacity(time.isStill ? 0 : 1)
    }

    /// The `develop` variant: a dot grid revealed by a soft band moving down.
    private var dotScan: some View {
        let p = 1 - BighelpLoaderCurve.site(time.phase(BighelpLoaderTiming.developScan, offset: offset))
        return BighelpImageGeneratingTextures.dots
            .resizable(resizingMode: .tile)
            .foregroundStyle(colors.dots)
            .mask(alignment: .top) {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45),
                                       .init(color: .clear, location: 0.7), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: size.height * 3)
                    .offset(y: time.isStill ? -size.height : -2 * size.height * p)
            }
    }
}

/// Textures drawn once and shared by every placeholder.
@MainActor
enum BighelpImageGeneratingTextures {
    /// Film grain in half-point specks: fixed noise, so it never shimmers on its own.
    static let grain: Image = {
        let side = 96
        var generator = SplitMix(seed: 0x6269_6768_656C_70)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: side / 2, height: side / 2), format: format).image { context in
            for y in 0..<side {
                for x in 0..<side {
                    let value = CGFloat(generator.next() % 256) / 255
                    context.cgContext.setFillColor(gray: value, alpha: 1)
                    context.cgContext.fill(CGRect(x: CGFloat(x) / 2, y: CGFloat(y) / 2, width: 0.5, height: 0.5))
                }
            }
        }
        return Image(uiImage: image)
    }()

    /// One dot on an 11-point cell, drawn as a template so it takes any color.
    static let dots: Image = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: 11, height: 11), format: format).image { context in
            UIColor.black.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 5.5 - 1.3, y: 5.5 - 1.3, width: 2.6, height: 2.6))
        }
        return Image(uiImage: image.withRenderingMode(.alwaysTemplate)).renderingMode(.template)
    }()

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
