#if os(visionOS)
import RealityKit
import SwiftUI
import UIKit

/// What the agent in the room is made of.
enum SpatialAvatarLook: Equatable {
    /// One of the avatar kit's characters, built in 3D from the same art,
    /// wearing the creator's headwear and pattern.
    /// `packSHA256` names a catalog pack; nil is the bundled kit.
    case kit(characterID: String, colors: AvatarKitColors, face: AvatarKitFace,
             topper: CompanionTopper = .none, pattern: CompanionPattern = .none, packSHA256: String? = nil)
    /// The default agent: a glossy body with two eyes, in the agent's color.
    case persona(colorHex: String, isOrb: Bool)
    /// A picture can't be 3D; it floats as a clean disc with no backdrop.
    case photo(URL)
}

extension SpatialAvatarLook {
    /// The 3D look for an Agent Studio appearance.
    init?(appearance: CompanionAppearance, themeHex: String) {
        guard let (_, art) = appearance.kitArt, let colors = appearance.avatarKitColors(themeHex: themeHex) else { return nil }
        let isCatalog = appearance.catalogAvatar != nil
        self = .kit(characterID: art.id, colors: colors,
                    face: appearance.avatarKitFace ?? AvatarKitFace(art.face),
                    topper: isCatalog || appearance.character.isBit ? .none : appearance.topper ?? .none,
                    pattern: appearance.pattern ?? .none,
                    packSHA256: appearance.catalogAvatar?.kitSHA256)
    }
}

/// A 3D agent for the room. Kit characters are sculpted from the kit's own
/// shapes (see SpatialAvatarSculpt) and move with the kit's own keyframes
/// (blink, bob, hop, talk), so they match the 2D art. The colored disc
/// behind the 2D avatar is left out.
@MainActor
final class SpatialAvatarRig {
    /// Stands at the feet; the volume places it.
    let root = Entity()
    /// Everything that moves as one (bob, hop, spin).
    private let body = Entity()
    private var parts: [KitPart] = []
    /// The body group's nodes, so headwear moves with the body; and the solids, to seat it.
    private var bodyChain: [AvatarKit.Node] = []
    private var solids: [SpatialAvatarSculpt.Solid] = []
    private var personaEyes: [Entity] = []
    private var kit: AvatarKit?
    private var character: AvatarKit.Character?
    private var face = AvatarKitFace()
    private var startTime = Date.now
    /// A tap hops for a moment.
    private var hopUntil = Date.distantPast
    private var look: SpatialAvatarLook?
    /// Read every frame: what the agent is doing (an engine mood like "thinking"
    /// or "dance"), or nil to idle. The kit plays its state; extra moves (dance,
    /// spin, bounce…) move the whole character.
    var mood: String?
    var reduceMotion = false
    var updates: EventSubscription?

    /// Standing height with headwear, and how far it reaches in front of its
    /// middle, in meters at scale 1. Previews use these to fit it in a window.
    static let standingHeight: Float = 0.33
    static let reach: Float = 0.09

    /// Art is 200×200 units with the feet at (100, 182); this is about 28 cm tall.
    static let metersPerArtUnit: Float = 0.0016

    init() {
        root.addChild(body)
        // Real shadows on the table or floor under it.
        root.components.set(GroundingShadowComponent(castsShadow: true))
    }

    func show(_ look: SpatialAvatarLook) {
        guard look != self.look else { return }
        self.look = look
        body.children.removeAll()
        parts = []
        bodyChain = []
        solids = []
        personaEyes = []
        switch look {
        case .kit(let id, let colors, let face, let topper, let pattern, let packSHA256):
            let source = packSHA256.map { sha in
                AvatarKitLibrary.shared.kit(sha256: sha) ?? AvatarKitLibrary.bundledKit.flatMap { $0.character(id) == nil ? nil : $0 }
            } ?? AvatarKit.bundled
            guard let kit = source, let character = kit.character(id) else {
                buildPersona(colorHex: colors.primary, isOrb: false)
                return
            }
            self.kit = kit
            self.character = character
            self.face = face
            buildKit(character, colors: colors, face: face, pattern: pattern)
            if packSHA256 == nil, let companion = CompanionCharacter(rawValue: id) { buildTopper(topper, on: companion, colors: colors) }
        case .persona(let hex, let isOrb):
            buildPersona(colorHex: hex, isOrb: isOrb)
        case .photo(let url):
            buildPhoto(url)
        }
    }

    /// A tap from the person: a happy hop.
    func poke() { hopUntil = Date.now.addingTimeInterval(1.1) }

    /// Called every frame with the kit state (idle, listening, thinking,
    /// waiting, talking, happy, sleeping) and whether motion is reduced.
    func update() { update(mood: mood, reduceMotion: reduceMotion) }

    private func update(mood requested: String?, reduceMotion: Bool) {
        let time = Date.now.timeIntervalSince(startTime)
        let hopping = Date.now < hopUntil
        let (state, extra) = AvatarKitScene.states(for: hopping ? "excited" : requested)
        switch look {
        case .kit:
            updateKit(state: state, extra: extra, time: reduceMotion ? 0 : time)
        case .persona:
            updatePersona(state: state, time: reduceMotion ? 0 : time)
        case .photo:
            let bob = reduceMotion ? 0 : Float(sin(time * 2 * .pi / 3.2)) * 0.008
            body.position = [0, bob, 0]
        case nil:
            break
        }
    }

    // MARK: Kit characters

    private struct KitPart {
        /// Nodes from the tree's root down to the drawn shape.
        let chain: [AvatarKit.Node]
        let entity: ModelEntity
        /// The part's plane, front to back, in art units.
        let z: Float
        /// Places the mesh within the part: leans a shape laid on a curved surface
        /// to face the way the surface does, or puts headwear on the head.
        var lean = matrix_identity_float4x4
        /// Bobs gently on its own (a halo).
        var floats = false
    }

    /// A shape already laid on a solid, so the next one can sit on top of it.
    private struct Cap {
        let outline: SpatialAvatarSculpt.Outline
        let apex: CGFloat
        let radius: CGFloat

        func surface(at point: CGPoint) -> CGFloat? {
            guard outline.contains(point) else { return nil }
            let r = min(hypot(point.x - outline.center.x, point.y - outline.center.y), radius)
            return apex - (radius - sqrt(radius * radius - r * r))
        }
    }

    /// One drawn shape, at rest, before it's built.
    private struct Drawing {
        let chain: [AvatarKit.Node]
        let path: Path
        let token: String
        let opacity: Double
        let outline: SpatialAvatarSculpt.Outline
        let isBody: Bool
        let isStroke: Bool
        let hasFill: Bool
        var lineWidth: CGFloat = 0
    }

    private func buildKit(_ character: AvatarKit.Character, colors: AvatarKitColors, face: AvatarKitFace,
                          pattern: CompanionPattern) {
        guard let kit else { return }
        let drawings = Self.drawings(of: character, kit: kit, face: face)
        bodyChain = drawings.first(where: \.isBody).map { Array($0.chain.dropLast()) } ?? []

        // Solids first: bodies, heads, ears, limbs. Shapes drawn within an
        // earlier solid's outline (eyes, mouths, patches, whole face masks) are
        // painted on it instead; anything that sticks out past it is a solid.
        var solids: [(index: Int, solid: SpatialAvatarSculpt.Solid)] = []
        var hosts: [Int: Int] = [:]
        for (index, drawing) in drawings.enumerated() {
            let center = drawing.outline.center
            if let host = solids.last(where: { $0.solid.outline.contains(center) }),
               drawing.isStroke || drawing.outline.share(inside: host.solid.outline) >= 0.85 {
                hosts[index] = host.index
            } else if drawing.isStroke && drawing.hasFill {
                continue // an outline around a solid; the 3D shape doesn't need one
            } else {
                // A line on its own (a stalk, a whisker) becomes a round rod as thick as it's drawn.
                let depth = drawing.isStroke ? drawing.lineWidth / 2 : SpatialAvatarSculpt.halfDepth(for: drawing.outline)
                solids.append((index, SpatialAvatarSculpt.Solid(outline: drawing.outline, halfDepth: depth)))
            }
        }
        Self.stack(&solids, anchor: drawings.firstIndex(where: \.isBody))

        let solidByIndex = Dictionary(uniqueKeysWithValues: solids.map { ($0.index, $0.solid) })
        self.solids = solids.map(\.solid)
        var caps: [Int: [Cap]] = [:]
        for (index, drawing) in drawings.enumerated() {
            let color = UIColor(colors.color(drawing.token))
            let bounds = drawing.path.boundingRect
            let center = CGPoint(x: bounds.midX, y: -bounds.midY)
            if let solid = solidByIndex[index] {
                // A long flat oval out on its own is a halo or a brim seen side-on: lay it flat.
                let lying = drawing.chain.last.map { $0.kind == "ellipse" || $0.kind == "circle" } == true
                    && bounds.width >= bounds.height * 2.5
                let halfDepth = lying ? min(bounds.height * 0.5, 2.5) : solid.halfDepth
                guard var mesh = SpatialAvatarSculpt.mesh(drawing.path, slices: SpatialAvatarSculpt.solidSlices(
                    center: center, halfDepth: halfDepth)) else { continue }
                var material = Self.material(color, opacity: drawing.opacity)
                // The creator's pattern covers the body color, as in the 2D art.
                if pattern != .none, drawing.token == "@p",
                   let texture = SpatialAvatarSculpt.patternTexture(pattern, bodyHex: colors.primary, bounds: bounds),
                   let mapped = SpatialAvatarSculpt.withPlanarMapping(mesh, bounds: bounds) {
                    mesh = mapped
                    material.baseColor = .init(tint: .white, texture: .init(texture))
                }
                var part = KitPart(chain: drawing.chain, entity: ModelEntity(mesh: mesh, materials: [material]),
                                   z: Float(solid.z))
                if lying {
                    // Stretch the thin oval into a disc as deep as it is wide, then tip it over.
                    let pivot = SIMD3(Float(center.x), Float(center.y), 0)
                    part.lean = Self.translation(pivot)
                        * simd_float4x4(simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))
                        * simd_float4x4(diagonal: [1, Float(bounds.width / max(bounds.height, 0.5)), 1, 1])
                        * Self.translation(-pivot)
                }
                add(part)
            } else if hosts[index] != nil {
                // Laid on whichever solid is in front here: several can overlap
                // (a cloud's puffs), and the face must sit on the visible one.
                let point = drawing.outline.center
                let candidates = solids.filter { $0.index < index }
                guard let front = candidates.compactMap({ entry in
                    entry.solid.front(at: point).map { (index: entry.index, top: $0) }
                }).max(by: { $0.top < $1.top }) else { continue }
                let hostIndex = front.index
                guard let host = solidByIndex[hostIndex] else { continue }
                let halfSize = max(drawing.outline.bounds.width, drawing.outline.bounds.height) / 2
                let radius = max(host.halfDepth, halfSize * 1.2)
                let cap = SpatialAvatarSculpt.decalSlices(center: center, halfSize: halfSize, radius: radius)
                guard let mesh = SpatialAvatarSculpt.mesh(drawing.path, slices: cap.slices) else { continue }
                // Sits just above whatever is under it (the solid, or shapes laid
                // on it before), at its middle and all around its edge.
                let laid = caps[hostIndex, default: []]
                func under(_ q: CGPoint) -> CGFloat? {
                    let tops = [host.front(at: q)] + laid.map { $0.surface(at: q) }
                    return tops.compactMap { $0 }.max()
                }
                func drop(_ q: CGPoint) -> CGFloat {
                    let r = min(hypot(q.x - point.x, q.y - point.y), min(halfSize, radius * 0.9))
                    return radius - sqrt(radius * radius - r * r)
                }
                var apex = (under(point) ?? 0) + 0.7
                for q in drawing.outline.samples(inset: 0.12) {
                    if let top = under(q) { apex = max(apex, top + 0.35 + drop(q)) }
                }
                caps[hostIndex, default: []].append(Cap(outline: drawing.outline, apex: apex, radius: radius))
                var part = KitPart(chain: drawing.chain,
                                   entity: ModelEntity(mesh: mesh, materials: [Self.material(color, opacity: drawing.opacity)]),
                                   z: Float(apex - cap.rise))
                part.lean = Self.lean(to: host.normal(at: point),
                                      around: SIMD3(Float(center.x), Float(center.y), Float(cap.rise)))
                add(part)
            }
        }
    }

    /// Headwear sits on the head, centered front to back, and moves with the body.
    private func buildTopper(_ topper: CompanionTopper, on character: CompanionCharacter, colors: AvatarKitColors) {
        guard topper != .none, let anchor = AvatarKitScene.headwearAnchor(character) else { return }
        // Anchors are in 100×100 design units; art is 200×200.
        let x = anchor.x * 2, y = anchor.y * 2, width = anchor.width * 2
        let head = solids.last { $0.outline.contains(CGPoint(x: x, y: y + width * 0.25)) }
        for piece in SpatialAvatarHeadwear.pieces(topper, x: x, y: y, width: width, bodyHex: colors.primary) {
            var part = KitPart(chain: bodyChain, entity: piece.entity, z: Float(head?.z ?? 0))
            part.lean = piece.placement
            part.floats = piece.floats
            add(part)
        }
    }

    private func add(_ part: KitPart) {
        part.entity.components.set(GroundingShadowComponent(castsShadow: true))
        parts.append(part)
        body.addChild(part.entity)
    }

    /// Every shape the character draws, in order, posed at rest.
    private static func drawings(of character: AvatarKit.Character, kit: AvatarKit,
                                 face: AvatarKitFace) -> [Drawing] {
        var drawings: [Drawing] = []
        func visit(_ node: AvatarKit.Node, chain: [AvatarKit.Node], insideBody: Bool) {
            let chain = chain + [node]
            let style = node.style(for: "idle")
            // No backdrop disc, rings or painted floor shadow: the room has real ones.
            if node.isBackground || style.an?.name.contains("shadow") == true || style.an?.name == "bh-ring" { return }
            if !node.when.isEmpty, !face.shows(node.when) { return }
            let insideBody = insideBody || node.isBody
            if let path = node.path {
                let rest = pose(chain, kit: kit, character: character, state: "idle", time: 0).transform
                let hasFill = style.f.map { $0 != "none" } ?? false
                if let fill = style.f, fill != "none",
                   !SpatialAvatarSculpt.isPaintedShading(token: fill, fillOpacity: style.fo, opacity: style.o),
                   let outline = SpatialAvatarSculpt.Outline(path, transform: rest) {
                    // The body group's first shape is the body itself.
                    let isBody = insideBody && !drawings.contains(where: \.isBody)
                    drawings.append(Drawing(chain: chain, path: path, token: fill, opacity: style.fo ?? 1,
                                            outline: outline, isBody: isBody, isStroke: false, hasFill: true))
                }
                if let stroke = style.s, stroke != "none" {
                    let outlinePath = path.strokedPath(StrokeStyle(
                        lineWidth: style.sw ?? 1,
                        lineCap: style.cap == "round" ? .round : style.cap == "square" ? .square : .butt,
                        lineJoin: style.join == "round" ? .round : style.join == "bevel" ? .bevel : .miter))
                    if let outline = SpatialAvatarSculpt.Outline(outlinePath, transform: rest) {
                        drawings.append(Drawing(chain: chain, path: outlinePath, token: stroke,
                                                opacity: style.so ?? 1, outline: outline, isBody: false,
                                                isStroke: true, hasFill: hasFill, lineWidth: style.sw ?? 1))
                    }
                }
            }
            for child in node.children { visit(child, chain: chain, insideBody: insideBody) }
        }
        visit(character.tree, chain: [], insideBody: false)
        return drawings
    }

    /// Front to back: the body sits in the middle. A part drawn over another
    /// sticks out of its front; a part drawn behind one peeks out of its back.
    private static func stack(_ solids: inout [(index: Int, solid: SpatialAvatarSculpt.Solid)], anchor: Int?) {
        guard !solids.isEmpty else { return }
        let anchorPosition = solids.firstIndex { $0.index == anchor } ?? solids.indices.max {
            solids[$0].solid.outline.area < solids[$1].solid.outline.area
        } ?? 0
        solids[anchorPosition].solid.z = 0
        for position in solids.indices where position > anchorPosition {
            let center = solids[position].solid.outline.center
            let depth = solids[position].solid.halfDepth
            // Out of the front of whatever is in front there.
            let top = solids[..<position].compactMap { $0.solid.front(at: center) }.max()
            solids[position].solid.z = top.map { $0 - depth * 0.5 } ?? 0
        }
        for position in solids.indices.reversed() where position < anchorPosition {
            let center = solids[position].solid.outline.center
            let depth = solids[position].solid.halfDepth
            let bottom = solids[(position + 1)...].compactMap { $0.solid.back(at: center) }.min()
            solids[position].solid.z = bottom.map { $0 + depth * 0.5 } ?? -2
        }
    }

    private static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(offset, 1)
        return matrix
    }

    /// Turns a part laid on a surface to face along the surface, around its top.
    private static func lean(to normal: SIMD3<Float>, around pivot: SIMD3<Float>) -> simd_float4x4 {
        // Art space is y down; the mesh is y up.
        var facing = SIMD3(normal.x, -normal.y, normal.z)
        let limit: Float = 0.9
        if simd_dot(facing, [0, 0, 1]) < cos(limit) {
            let side = simd_normalize(SIMD3(facing.x, facing.y, 0))
            facing = SIMD3(side.x * sin(limit), side.y * sin(limit), cos(limit))
        }
        let rotation = simd_float4x4(simd_quatf(from: [0, 0, 1], to: simd_normalize(facing)))
        var toPivot = matrix_identity_float4x4
        toPivot.columns.3 = SIMD4(pivot, 1)
        var fromPivot = matrix_identity_float4x4
        fromPivot.columns.3 = SIMD4(-pivot, 1)
        return toPivot * rotation * fromPivot
    }

    /// Where a part is in art space for a state and moment, as AvatarKitRenderer draws it.
    private static func pose(_ chain: [AvatarKit.Node], kit: AvatarKit, character: AvatarKit.Character,
                             state: String, time: Double) -> (transform: CGAffineTransform, opacity: Double, visible: Bool) {
        var transform = CGAffineTransform.identity
        var opacity = 1.0
        for node in chain {
            let style = node.style(for: state)
            if style.hide == true { return (transform, 0, false) }
            var nodeOpacity = style.o ?? 1
            var tf = style.tf
            var tl = style.tl
            if time > 0, let animation = style.an, let stops = kit.keyframes[animation.name] {
                let sample = AvatarKitTiming.sample(animation, stops: stops, time: time, baseOpacity: nodeOpacity)
                if let animated = sample.transform { tf = animated }
                if let animated = sample.translate { tl = animated }
                if let animated = sample.opacity { nodeOpacity = animated }
            }
            opacity *= nodeOpacity
            if let t = tl, t.count == 8 {
                transform = transform.translatedBy(x: t[0] + t[1] * character.look, y: t[4] + t[5] * character.look)
            }
            if let matrix = node.matrix { transform = matrix.concatenating(transform) }
            if let tf, let origin = style.org, origin.count == 2 {
                transform = transform.translatedBy(x: origin[0] + (tf.tx ?? 0), y: origin[1] + (tf.ty ?? 0))
                transform = transform.rotated(by: (tf.r ?? 0) * .pi / 180)
                transform = transform.scaledBy(x: tf.sx ?? 1, y: tf.sy ?? 1)
                transform = transform.translatedBy(x: -origin[0], y: -origin[1])
            }
            if node.isRig {
                transform = transform.translatedBy(x: 100, y: 182).translatedBy(x: 0, y: -62).translatedBy(x: -100, y: -120)
            }
        }
        return (transform, opacity, true)
    }

    private func updateKit(state: String, extra: String?, time: Double) {
        guard let kit, let character else { return }
        for part in parts {
            let pose = Self.pose(part.chain, kit: kit, character: character, state: state, time: time)
            part.entity.isEnabled = pose.visible && pose.opacity > 0.01
            var matrix = Self.world(pose.transform, z: part.z) * part.lean
            if part.floats {
                var bob = matrix_identity_float4x4
                bob.columns.3.y = Float(sin(time * 2)) * 2.4
                matrix = Self.world(pose.transform, z: part.z) * bob * part.lean
            }
            part.entity.transform = Transform(matrix: matrix)
            if pose.opacity < 0.99 { part.entity.components.set(OpacityComponent(opacity: Float(pose.opacity))) }
            else { part.entity.components.remove(OpacityComponent.self) }
        }
        moveBody(extra: extra, time: time)
    }

    /// The chosen moves (dance, bounce, spin…) move the whole character, as in
    /// the 2D avatar; otherwise it looks around now and then.
    private func moveBody(extra: String?, time: Double) {
        var turn = Self.wander(time: time)
        var position = SIMD3<Float>.zero
        var scale = SIMD3<Float>(1, 1, 1)
        if let extra, time > 0 {
            let pose = BuddyPose.make(mood: extra, time: time, breathes: false)
            // Poses are in 100×100 design units; art is 200×200.
            let unit = Self.metersPerArtUnit * 2
            position = [Float(pose.offset.width) * unit, Float(-pose.offset.height) * unit, 0]
            let degrees = Float(pose.rotation)
            if extra == "spin" {
                // In the room a spin is a real turn, not a cartwheel.
                turn = simd_quatf(angle: degrees * .pi / 180, axis: [0, 1, 0])
            } else {
                turn = turn * simd_quatf(angle: -degrees * .pi / 180, axis: [0, 0, 1])
            }
            let squash = Float(pose.squash)
            scale = [squash, 1 / squash, squash]
        }
        body.position = position
        body.orientation = turn
        body.scale = scale
    }

    /// Looks around now and then, so it reads as alive and shows its sides.
    private static func wander(time: Double) -> simd_quatf {
        let turn = 0.32 * sin(time * 2 * .pi / 9) + 0.1 * sin(time * 2 * .pi / 3.7)
        let nod = 0.04 * sin(time * 2 * .pi / 5.3)
        return simd_quatf(angle: Float(turn), axis: [0, 1, 0]) * simd_quatf(angle: Float(nod), axis: [1, 0, 0])
    }

    /// Art space (y down, feet at 100,182) → the volume (meters, y up, feet at 0).
    private static func world(_ m: CGAffineTransform, z: Float) -> float4x4 {
        let s = metersPerArtUnit
        // The mesh is built from the y-flipped path, so flip the art transform to match.
        let a = Float(m.a), b = Float(-m.b), c = Float(-m.c), d = Float(m.d)
        let tx = Float(m.tx), ty = Float(-m.ty)
        return float4x4(columns: (
            SIMD4(a * s, b * s, 0, 0),
            SIMD4(c * s, d * s, 0, 0),
            SIMD4(0, 0, s, 0),
            SIMD4((tx - 100) * s, (ty + 182) * s, z * s, 1)
        ))
    }

    /// Soft, toy-like vinyl with a little shine.
    private static func material(_ color: UIColor, opacity: Double) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = 0.5
        material.metallic = 0.0
        material.clearcoat = 0.35
        material.clearcoatRoughness = 0.3
        if opacity < 0.99 { material.blending = .transparent(opacity: .init(scale: Float(opacity))) }
        return material
    }

    // MARK: Default persona

    private func buildPersona(colorHex: String, isOrb: Bool) {
        let color = UIColor(Color(hex: colorHex))
        var shell = PhysicallyBasedMaterial()
        shell.baseColor = .init(tint: color)
        shell.roughness = isOrb ? 0.15 : 0.35
        shell.clearcoat = 0.8
        shell.clearcoatRoughness = 0.1
        if isOrb { shell.emissiveColor = .init(color: color); shell.emissiveIntensity = 0.35 }
        let blob = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [shell])
        blob.scale = isOrb ? [1, 1, 1] : [1.08, 0.92, 0.9]
        blob.position = [0, 0.12, 0]
        blob.components.set(GroundingShadowComponent(castsShadow: true))
        body.addChild(blob)
        var white = PhysicallyBasedMaterial()
        white.baseColor = .init(tint: UIColor(Color(hex: "F7F7F5")))
        white.roughness = 0.2
        white.clearcoat = 1.0
        // The brand's eyes: two white ovals, as in the 2D avatar.
        for x: Float in [-0.036, 0.036] {
            let eye = ModelEntity(mesh: .generateSphere(radius: 0.022), materials: [white])
            eye.scale = [0.85, 1.3, 0.55]
            eye.position = [x, 0.145, 0.102]
            body.addChild(eye)
            personaEyes.append(eye)
        }
    }

    private func updatePersona(state: String, time: Double) {
        let hop: Float = state == "happy" ? abs(Float(sin(time * 2 * .pi / 0.55))) * 0.035 : 0
        let bob = Float(sin(time * 2 * .pi / 3.2)) * 0.008
        let breathe = 1 + Float(sin(time * 2 * .pi / 3.2)) * 0.025
        let talk: Float = state == "talking" ? 1 + abs(Float(sin(time * 2 * .pi / 0.4))) * 0.05 : 1
        body.position = [0, bob + hop, 0]
        body.scale = [breathe * talk, 1 / breathe, breathe]
        let tilt: Float = state == "thinking" ? 0.18 : 0
        body.orientation = simd_quatf(angle: tilt + Float(sin(time * 2 * .pi / 7)) * 0.1, axis: [0, 0, 1])
            * simd_quatf(angle: Float(sin(time * 2 * .pi / 9)) * 0.25, axis: [0, 1, 0])
        // Blink every few seconds; sleep closes the eyes.
        let phase = time.truncatingRemainder(dividingBy: 4.2)
        let open: Float = state == "sleeping" ? 0.12 : (phase < 0.14 ? 0.1 : 1)
        for eye in personaEyes { eye.scale = [0.85, 1.3 * open, 0.55] }
    }

    // MARK: Photo

    private func buildPhoto(_ url: URL) {
        guard let image = UIImage(contentsOfFile: url.bighelpFileSystemPath)?.cgImage,
              let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else {
            buildPersona(colorHex: AgentPersona.palette[0], isOrb: true)
            return
        }
        var material = UnlitMaterial()
        material.color = .init(texture: .init(texture))
        let disc = ModelEntity(mesh: .generatePlane(width: 0.26, height: 0.26, cornerRadius: 0.13), materials: [material])
        disc.position = [0, 0.16, 0]
        body.addChild(disc)
        var rim = PhysicallyBasedMaterial()
        rim.baseColor = .init(tint: .white.withAlphaComponent(0.9))
        rim.roughness = 0.1
        rim.clearcoat = 1.0
        let ring = ModelEntity(mesh: .generateCylinder(height: 0.006, radius: 0.136), materials: [rim])
        ring.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        ring.position = [0, 0.16, -0.004]
        body.addChild(ring)
    }
}
#endif
