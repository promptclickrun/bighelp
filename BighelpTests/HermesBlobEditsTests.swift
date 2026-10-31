import Foundation
import Testing
@testable import Bighelp

/// Hand edits on a blob face ride in the shape string's fourth part, which
/// Hermes Desktop ignores: it reads `blobatar:<seed>:<kind>` and draws the seed face.
@MainActor
struct HermesBlobEditsTests {
    private let edited = HermesBlobEdits(ratio: 0.75, size: 0.25, bumps: 8,
                                         wobble: [0.5, 0.62, 0.38, 0.5, 0.62, 0.38, 0.5, 0.62])

    @Test func editsRoundTripThroughTheShapeString() throws {
        let shape = HermesBlobShape(seedPart: "nova", kind: .organic, edits: edited)
        #expect(shape.string == "blobatar:nova:organic:e1,h75,s25,n8,w50.62.38.50.62.38.50.62")
        #expect(HermesBlobShape(shape.string) == shape)
        let followsName = HermesBlobShape(edits: HermesBlobEdits(ratio: 0.1))
        #expect(followsName.string == "blobatar:::e1,h10")
        #expect(HermesBlobShape(followsName.string) == followsName)
    }

    @Test func hermesDesktopStillReadsTheSeedAndSilhouette() {
        let plain = HermesBlobShape(seedPart: "nova", kind: .organic)
        var withEdits = plain
        withEdits.edits = edited
        // Desktop splits on ":" and reads parts 1 and 2 only.
        let parts = withEdits.string.split(separator: ":", omittingEmptySubsequences: false)
        #expect(parts.prefix(3).joined(separator: ":") == plain.string)
    }

    @Test(arguments: [
        "blobatar:nova:organic:%%%",
        "blobatar:nova:organic:e9,h75",
        "blobatar:nova:organic:e1,h999",
        "blobatar:nova:organic:e1,w50.x",
        "blobatar:nova:organic:e1,n12",
        "blobatar:nova:organic:",
    ])
    func unreadableEditsFallBackToTheSeedFace(_ string: String) throws {
        let shape = try #require(HermesBlobShape(string))
        #expect(shape.seedPart == "nova")
        #expect(shape.kind == .organic)
        #expect(shape.edits == nil)
        #expect(HermesBlobFace.render(seed: "nova", kind: .organic, edits: shape.edits)
                == HermesBlobFace.render(seed: "nova", kind: .organic))
    }

    @Test func aLookWithUnreadableEditsStillDrawsAFace() throws {
        let look = try #require(AgentAvatarLook(namespace: ["shape": .string("blobatar:nova:boxy:e1,zz,h")]))
        #expect(look.style == .face)
        let blob = try #require(HermesBlobShape(look.shape))
        #expect(blob.edits == nil)
        #expect(blob.kind == .boxy)
        #expect(!HermesBlobFace.render(seed: blob.seed(name: "Nova"), kind: blob.kind, edits: blob.edits).body.isEmpty)
    }

    @Test func unknownEditKeysAreSkipped() throws {
        let shape = try #require(HermesBlobShape("blobatar:nova::e1,h60,q42"))
        #expect(shape.edits == HermesBlobEdits(ratio: 0.6))
    }

    @Test func noEditsDrawsExactlyBlobatar() {
        #expect(HermesBlobFace.render(seed: "nova", kind: .cloud, edits: nil) == HermesBlobFace.render(seed: "nova", kind: .cloud))
        #expect(HermesBlobFace.render(seed: "nova", kind: .cloud, edits: HermesBlobEdits())
                == HermesBlobFace.render(seed: "nova", kind: .cloud))
    }

    @Test func editsChangeTheDrawnBody() {
        let plain = HermesBlobFace.render(seed: "nova", kind: .organic)
        let tall = HermesBlobFace.render(seed: "nova", kind: .organic, edits: HermesBlobEdits(ratio: 0.99))
        let wide = HermesBlobFace.render(seed: "nova", kind: .organic, edits: HermesBlobEdits(ratio: 0))
        #expect(tall != plain)
        #expect(Self.aspect(tall) > Self.aspect(wide))
        let smooth = HermesBlobFace.render(seed: "nova", kind: .organic, edits: HermesBlobEdits(wobble: Array(repeating: 0.5, count: 8)))
        #expect(smooth != plain)
    }

    @Test func tallerWiderAndSmallerStepFromTheSeed() {
        var shape = HermesBlobShape(seedPart: "nova", kind: .organic)
        let start = shape.position("body.ratio", seed: "nova")
        shape.taller(seed: "nova")
        #expect(abs((shape.edits?.ratio ?? 0) - min(0.99, start + HermesBlobShape.sizeStep)) < 0.011)
        shape.wider(seed: "nova")
        #expect(abs((shape.edits?.ratio ?? 0) - start) < 0.011)
        let size = shape.position("body.r", seed: "nova")
        shape.smaller(seed: "nova")
        #expect(abs((shape.edits?.size ?? 1) - max(0, size - HermesBlobShape.sizeStep)) < 0.011)
        for _ in 0..<10 { shape.smaller(seed: "nova") }
        #expect(shape.edits?.size == 0)
        #expect(!shape.canShrink(seed: "nova"))
    }

    @Test func wobbleStrengthScalesTheSeedsBumps() throws {
        var shape = HermesBlobShape(seedPart: "nova", kind: .organic)
        shape.setWobble(0, seed: "nova")
        let flat = try #require(shape.edits?.wobble)
        #expect(flat.allSatisfy { $0 == 0.5 })
        shape.setWobble(0.5, seed: "nova")
        #expect(abs(shape.wobble(seed: "nova") - 0.5) < 0.05)
        shape.setWobble(1, seed: "nova")
        #expect(shape.wobble(seed: "nova") > 0.8)
    }

    @Test func bumpsChangeThePointCount() {
        var shape = HermesBlobShape(seedPart: "nova", kind: .organic)
        shape.setBumps(6, seed: "nova")
        #expect(shape.bumps(seed: "nova") == 6)
        #expect(shape.edits?.wobble?.count == 6)
        shape.setBumps(8, seed: "nova")
        #expect(shape.bumps(seed: "nova") == 8)
    }

    @Test func mirrorMakesTheOutlineMatchLeftAndRight() throws {
        var shape = HermesBlobShape(seedPart: "nova", kind: .organic)
        shape.setBumps(7, seed: "nova")
        #expect(!shape.isMirrored(seed: "nova"))
        shape.setMirrored(true, seed: "nova")
        #expect(shape.isMirrored(seed: "nova"))
        let wobble = try #require(shape.edits?.wobble)
        // Odd counts can't mirror, so the face takes the next even count.
        #expect(wobble.count == 8)
        for index in 0..<wobble.count {
            #expect(wobble[index] == wobble[(wobble.count / 2 - index + wobble.count) % wobble.count])
        }
        shape.setMirrored(false, seed: "nova")
        #expect(!shape.isMirrored(seed: "nova"))
    }

    @Test func aSavedEditedLookReadsBackTheSame() throws {
        let shape = HermesBlobShape(kind: .organic, edits: edited)
        let look = AgentAvatarLook(style: .face, shape: shape.string, color: "#8f86e8", faceSeed: "nova")
        let namespace = look.applied(to: ["pinned": .boolean(true)], profileID: "nova-2")
        // A face drawn from another name is locked to it, and its edits stay.
        #expect(namespace["shape"] == .string("blobatar:nova:organic:e1,h75,s25,n8,w50.62.38.50.62.38.50.62"))
        let read = try #require(AgentAvatarLook(namespace: namespace))
        #expect(read.style == .face)
        #expect(HermesBlobShape(read.shape) == HermesBlobShape(seedPart: "nova", kind: .organic, edits: edited))
    }

    @Test func presetsAreSeedFacesHermesDesktopDrawsTheSame() {
        let presets = AvatarFacePresetSet.all.flatMap(\.presets)
        #expect(Set(presets.map(\.id)).count == presets.count)
        for preset in presets {
            // Locked seed and silhouette only: Desktop reads all of it.
            #expect(preset.shape.isLocked)
            #expect(preset.shape.kind != nil)
            #expect(preset.shape.string.split(separator: ":").count == 3, "\(preset.name)")
            #expect(HermesBlobShape(preset.shape.string) == preset.shape)
        }
        #expect(AvatarFacePresetSet.harvestNight.presets.count == 6)
    }

    @Test func eyesStayVisibleOnAPickedDarkColor() {
        let seedEye = HermesBlobFace.render(seed: "wisp-2583", kind: .organic).eye
        #expect(HermesFaceColor.eye(seedEye, on: "#CFC9FF") == seedEye)
        #expect(HermesFaceColor.eye(seedEye, on: "#2E3550") == "#F4F1EA")
        let lightEye = HermesBlobFace.render(seed: "night-owl-1519", kind: .cloud).eye
        #expect(HermesFaceColor.eye(lightEye, on: "#F2B33D") == "#17141F")
        #expect(HermesFaceColor.eye(lightEye, on: "hsl(230 30% 25%)") == lightEye)
    }

    @Test func undoStepsBackThroughFaceEdits() {
        let model = AvatarCreatorModel(start: .look(AgentAvatarLook(style: .face, shape: "blobatar:nova:organic")),
                                       characters: AvatarCreatorModel.surprise())
        #expect(!model.canUndoFace)
        model.editFace { shape, _ in shape.taller(seed: "nova") }
        model.editFace { _, color in color = "#7CC7B8" }
        model.apply(AvatarFacePresetSet.harvestNight.presets[0])
        #expect(model.blobShape == AvatarFacePresetSet.harvestNight.presets[0].shape)
        #expect(model.faceColor == nil)
        model.undoFace()
        #expect(model.faceColor == "#7CC7B8")
        #expect(model.blobShape.edits?.ratio != nil)
        model.undoFace()
        #expect(model.faceColor == nil)
        model.undoFace()
        #expect(model.blobShape == HermesBlobShape(seedPart: "nova", kind: .organic))
        #expect(!model.canUndoFace)
        #expect(!model.hasChanges)
    }

    @Test func oneSliderDragIsOneUndo() {
        let model = AvatarCreatorModel(start: .look(AgentAvatarLook(style: .face, shape: "blobatar:nova:organic")),
                                       characters: AvatarCreatorModel.surprise())
        model.recordFaceUndo()
        for strength in stride(from: 0.5, through: 1, by: 0.1) { model.blobShape.setWobble(strength, seed: "nova") }
        model.recordFaceUndo()
        model.undoFace()
        #expect(model.blobShape == HermesBlobShape(seedPart: "nova", kind: .organic))
        #expect(!model.canUndoFace)
    }

    @Test func noChangeLeavesNothingToUndo() {
        let model = AvatarCreatorModel(start: .look(AgentAvatarLook(style: .face, shape: "blobatar:nova")),
                                       characters: AvatarCreatorModel.surprise())
        model.editFace { _, _ in }
        #expect(!model.canUndoFace)
    }

    @Test func aSavedEditedFaceReopensWithItsEdits() throws {
        let model = AvatarCreatorModel(start: .look(AgentAvatarLook(style: .face, shape: "blobatar:nova:organic")),
                                       characters: AvatarCreatorModel.surprise())
        model.editFace { shape, _ in shape.setMirrored(true, seed: "nova") }
        guard case .look(let look) = try #require(model.result(faceName: "nova")) else { Issue.record("not a look"); return }
        let saved = look.applied(to: [:], profileID: "nova")
        let reopened = AvatarCreatorModel(start: .look(try #require(AgentAvatarLook(namespace: saved))),
                                          characters: AvatarCreatorModel.surprise())
        #expect(reopened.blobShape == model.blobShape)
        #expect(reopened.blobShape.isMirrored(seed: "nova"))
    }

    private static func aspect(_ rendering: HermesBlobFace.Rendering) -> CGFloat {
        guard case .path(let d) = rendering.body.last else { return 0 }
        let box = SVGPathData.path(d).boundingRect
        return box.height / max(box.width, 1)
    }
}
