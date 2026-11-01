import Foundation

/// A finished blob face in one tap: a locked seed and a silhouette, nothing
/// drawn new. Each seed was picked because the color blobatar gives it fits the
/// name, so Hermes Desktop (which draws a face's own color) shows the same face.
struct AvatarFacePreset: Identifiable, Equatable, Sendable {
    let name: String
    let shape: HermesBlobShape

    var id: String { shape.string }

    init(_ name: String, seed: String, kind: HermesBlobFace.Kind, edits: HermesBlobEdits? = nil) {
        self.name = name
        shape = HermesBlobShape(seedPart: seed, kind: kind, edits: edits)
    }
}

struct AvatarFacePresetSet: Identifiable, Sendable {
    let title: String
    let presets: [AvatarFacePreset]

    var id: String { title }

    static let all: [AvatarFacePresetSet] = [harvestNight, everyday]

    /// Autumn's set: lanterns, moonlight and night owls.
    static let harvestNight = AvatarFacePresetSet(title: "Harvest night", presets: [
        AvatarFacePreset("Lantern", seed: "lantern-759", kind: .round),
        AvatarFacePreset("Moonlit", seed: "moonlit-549", kind: .droplet),
        AvatarFacePreset("Night owl", seed: "night-owl-1519", kind: .cloud),
        AvatarFacePreset("Bramble", seed: "bramble-3984", kind: .sun),
        AvatarFacePreset("Ember", seed: "ember-335", kind: .hexagon),
        AvatarFacePreset("Wisp", seed: "wisp-2583", kind: .organic),
    ])

    static let everyday = AvatarFacePresetSet(title: "Everyday", presets: [
        AvatarFacePreset("Pebble", seed: "pebble-2220", kind: .boxy),
        AvatarFacePreset("Bean", seed: "bean-765", kind: .capsule),
        AvatarFacePreset("Sunny", seed: "sunny-2633", kind: .sun),
        AvatarFacePreset("Bubble", seed: "bubble-1810", kind: .round),
        AvatarFacePreset("Petal", seed: "petal-2472", kind: .organic),
        AvatarFacePreset("Puff", seed: "puff-2739", kind: .cloud),
    ])
}

/// Named colors for faces and shapes. Hermes Desktop keeps a shape's color;
/// a face's shows in bighelp and in the picture other apps get.
struct AvatarFacePalette: Identifiable, Equatable, Sendable {
    let name: String
    let hex: String

    var id: String { name }

    static let all: [AvatarFacePalette] = [
        AvatarFacePalette(name: "Fog", hex: "#C9CED6"),
        AvatarFacePalette(name: "Clay", hex: "#D98E6A"),
        AvatarFacePalette(name: "Marigold", hex: "#F2B33D"),
        AvatarFacePalette(name: "Moss", hex: "#8DB36B"),
        AvatarFacePalette(name: "Sea glass", hex: "#7CC7B8"),
        AvatarFacePalette(name: "Sky", hex: "#7FB2EE"),
        AvatarFacePalette(name: "Iris", hex: "#8F86E8"),
        AvatarFacePalette(name: "Plum", hex: "#B26BC0"),
        AvatarFacePalette(name: "Berry", hex: "#D9587A"),
        AvatarFacePalette(name: "Coral", hex: "#F28B74"),
        AvatarFacePalette(name: "Sand", hex: "#E3CFA8"),
        AvatarFacePalette(name: "Night", hex: "#2E3550"),
    ]
}
