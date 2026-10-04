import SwiftUI

/// One kit character, animated with the display while `isAnimating`;
/// otherwise a still frame (also used for saved pictures).
struct AvatarKitView: View {
    let kit: AvatarKit
    let art: AvatarKit.Character
    /// Bundled characters wear headwear; catalog ones don't have a head anchor.
    var headwear: CompanionCharacter?
    let colors: AvatarKitColors
    var look = BuddyLook()
    /// A Bit's face; nil draws its own.
    var face: AvatarKitFace?
    var mood: String?
    var isAnimating: Bool
    var showsBackground = true
    var showsQuestion = false

    var body: some View {
        if isAnimating {
            TimelineView(.animation) { timeline in
                canvas(time: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
            }
        } else {
            canvas(time: nil)
        }
    }

    private func canvas(time: Double?) -> some View {
        Canvas { context, size in
            AvatarKitScene.draw(
                art, kit: kit, headwear: headwear, colors: colors, look: look, face: face, mood: mood, time: time,
                showsBackground: showsBackground, showsQuestion: showsQuestion,
                in: context, size: size
            )
        }
    }
}

enum AvatarKitScene {
    /// The moment a still frame shows.
    static let stillTime: Double = 0.6

    /// Kit state for an app mood, plus extra motion the kit doesn't have itself.
    static func states(for mood: String?) -> (state: String, extra: String?) {
        switch mood ?? "idle" {
        case "listening": ("listening", nil)
        case "thinking", "squint": ("thinking", nil)
        case "bounce": ("talking", nil)
        case "curious": ("listening", "curious")
        case "excited", "happy": ("happy", nil)
        case "alert": ("waiting", nil)
        case "sad": ("idle", "sad")
        case "dance": ("happy", "dance")
        case "lookAround": ("idle", "lookAround")
        case "sleepy", "meditate": ("sleeping", nil)
        case "spin": ("happy", "spin")
        case "scan": ("idle", "scan")
        case "nod": ("talking", "nod")
        case "peek": ("idle", "peek")
        default: ("idle", nil)
        }
    }

    /// Where headwear sits on each character: head top and width, in 100×100 units.
    /// Bits wear the kit's own accessories instead.
    static func headwearAnchor(_ character: CompanionCharacter) -> (x: CGFloat, y: CGFloat, width: CGFloat)? {
        switch character {
        case .lobster: (50, 22, 30)
        case .messenger: (50, 20, 34)
        case .dog: (50, 27, 34)
        case .cat: (50, 31, 30)
        case .zeus: (50, 16, 34)
        case .robot: (50, 29, 34)
        case .owl: (50, 27, 30)
        case .octopus: (50, 21, 34)
        case .fox: (50, 31, 30)
        case .dragon: (50, 29, 32)
        default: nil
        }
    }

    static func draw(
        _ art: AvatarKit.Character,
        kit: AvatarKit,
        headwear: CompanionCharacter?,
        colors: AvatarKitColors,
        look: BuddyLook,
        face: AvatarKitFace? = nil,
        mood: String?,
        time: Double?,
        showsBackground: Bool,
        showsQuestion: Bool,
        in context: GraphicsContext,
        size: CGSize
    ) {
        let (state, extra) = states(for: mood)
        let seconds = time ?? stillTime
        var pose = BuddyPose.make(mood: extra, time: seconds, breathes: false)
        if extra == nil { pose.effect = nil }
        if showsQuestion { pose.effect = .question }

        var frame = AvatarKitFrame()
        frame.state = state
        frame.time = seconds
        frame.animates = time != nil
        frame.showsBackground = showsBackground
        frame.face = face
        if extra != nil {
            frame.offset = CGSize(width: pose.offset.width * 2, height: pose.offset.height * 2)
            frame.rotation = pose.rotation
            frame.squash = pose.squash
            switch pose.eyes {
            case let .open(_, gaze), let .wide(gaze), let .squint(gaze): frame.look = gaze
            default: break
            }
        }

        let palette = BuddyPalette(bodyHex: colors.primary, eyeHex: colors.ink)
        AvatarKitRenderer.draw(
            art, kit: kit, colors: colors, frame: frame, in: context, size: size,
            decorateBody: { body in
                guard look.topper != .none, let headwear, let anchor = headwearAnchor(headwear) else { return }
                BuddyPainter(ctx: body, u: 2, palette: palette, look: look, pose: pose)
                    .topper(anchor.x, anchor.y, width: anchor.width)
            },
            decorateShape: look.pattern == .none ? nil : { shape, path, fill in
                guard fill == "@p" else { return }
                var inside = shape
                inside.clip(to: path)
                BuddyPainter(ctx: inside, u: 2, palette: palette, look: look, pose: pose)
                    .drawPattern(in: inside, bounds: path.boundingRect)
            }
        )

        guard pose.effect != nil else { return }
        let side = min(size.width, size.height)
        var overlay = context
        overlay.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
        overlay.scaleBy(x: side / 200, y: side / 200)
        BuddyPainter(ctx: overlay, u: 2, palette: palette, look: look, pose: pose).effect(70, 26)
    }
}

extension CompanionAppearance {
    /// The kit and character this look draws: the picked catalog pack, else the bundled kit.
    /// nil while a catalog pack isn't on the phone yet.
    var kitArt: (kit: AvatarKit, art: AvatarKit.Character)? {
        if let catalogAvatar {
            guard let kit = AvatarKitLibrary.shared.kit(for: catalogAvatar),
                  let art = kit.character(catalogAvatar.id) else { return nil }
            return (kit, art)
        }
        guard let kit = AvatarKit.bundled, let art = kit.character(character.rawValue) else { return nil }
        return (kit, art)
    }

    /// The name people see: the catalog character's, else the bundled one's.
    var displayName: String { catalogAvatar?.name ?? character.displayName }

    /// The face a Bit draws with; nil for characters and untouched Bits.
    var avatarKitFace: AvatarKitFace? {
        guard catalogAvatar == nil, character.isBit, bitEyes != nil || bitMouth != nil || bitAccessory != nil || !showsCheeks,
              let art = AvatarKit.bundled?.character(character.rawValue) else { return nil }
        var face = AvatarKitFace(art.face)
        if let bitEyes { face.eyes = bitEyes.rawValue }
        if let bitMouth { face.mouth = bitMouth.rawValue }
        if let bitAccessory { face.accessory = bitAccessory.rawValue }
        face.cheeks = showsCheeks
        return face
    }

    /// The kit colors this look draws with.
    func avatarKitColors(themeHex: String) -> AvatarKitColors? {
        guard let (kit, art) = kitArt else { return nil }
        var colors = AvatarKitColors(character: art)
        if let colorway, let theme = kit.theme(colorway) { colors.apply(theme) }
        if !usesCharacterColors {
            let main = matchesTheme ? themeHex : colorHex
            colors.primary = CompanionAppearance.validatedColorHex(main) ?? colors.primary
            if colorway == nil { colors.background = CompanionColor.shade(colors.primary, by: 0.86) }
        }
        return colors
    }
}
