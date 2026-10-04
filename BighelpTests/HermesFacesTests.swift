import CryptoKit
import Foundation
import Testing
@testable import Bighelp

/// Parity with Hermes Desktop. The vectors come from running the originals in
/// Node: blobatar 2.0.0's `blobatar(seed, { traits: { shape } })` for the blob
/// faces, and Bot Mode's `avatar.tsx` helpers for the geometric faces.
@MainActor
struct HermesFacesTests {
    @Test(arguments: HermesFaceVectors.fullSVGs)
    func blobFaceMarkupMatchesBlobatar(_ vector: (seed: String, kind: String, svg: String)) {
        #expect(HermesBlobFace.render(seed: vector.seed, kind: HermesBlobFace.Kind(rawValue: vector.kind)).svg == vector.svg)
    }

    @Test func everySeedAndSilhouetteMatchesBlobatar() {
        var mismatches: [String] = []
        for vector in HermesFaceVectors.hashes {
            let svg = HermesBlobFace.render(seed: vector.seed, kind: HermesBlobFace.Kind(rawValue: vector.kind)).svg
            let digest = SHA256.hash(data: Data(svg.utf8)).map { String(format: "%02x", $0) }.joined()
            if digest != vector.sha256 { mismatches.append("\(vector.seed)/\(vector.kind)") }
        }
        #expect(mismatches.isEmpty, "Faces that differ from blobatar: \(mismatches)")
    }

    @Test func blobShapeStringsReadAndWriteLikeHermesDesktop() {
        #expect(HermesBlobShape("blobatar") == HermesBlobShape())
        #expect(HermesBlobShape("blobatar:k3j2h1zq") == HermesBlobShape(seedPart: "k3j2h1zq"))
        #expect(HermesBlobShape("blobatar::sun") == HermesBlobShape(kind: .sun))
        #expect(HermesBlobShape("blobatar:x:unknown") == HermesBlobShape(seedPart: "x"))
        #expect(HermesBlobShape("circle") == nil)
        #expect(HermesBlobShape(kind: .sun).string == "blobatar::sun")
        #expect(HermesBlobShape(seedPart: "nova", kind: .cloud).string == "blobatar:nova:cloud")
        #expect(HermesBlobShape(seedPart: "nova").string == "blobatar:nova")
        #expect(HermesBlobShape().seed(name: "") == "agent")
        #expect(HermesBlobShape.randomSeed().count == 8)
    }

    @Test func namesGetHermesDesktopsColorAndShape() {
        for vector in HermesFaceVectors.names {
            #expect(HermesShapeFace.profileColor(vector.name) == vector.color, "\(vector.name)")
            #expect(HermesShapeFace.defaultShape(for: vector.name) == vector.shape, "\(vector.name)")
        }
        #expect(HermesShapeFace.color(nil, name: "default") == "#8b5cf6")
        #expect(HermesShapeFace.swatches.first == "hsl(0 68% 58%)")
        #expect(HermesShapeFace.swatches.last == "hsl(330 68% 58%)")
    }

    @Test func eyeColorsFollowHermesDesktopIncludingHSLColors() {
        for vector in HermesFaceVectors.darkness {
            #expect(HermesShapeFace.isDark(vector.color) == vector.isDark, "\(vector.color)")
        }
    }

    @Test func geometricOutlinesMatchHermesDesktop() {
        for vector in HermesFaceVectors.rings {
            let ring = HermesShapeFace.ring(vector.shape)
            #expect(ring.count == vector.count, "\(vector.shape)")
            for sample in vector.samples where sample.index < ring.count {
                #expect(abs(ring[sample.index].0 - sample.x) < 1e-9, "\(vector.shape) x \(sample.index)")
                #expect(abs(ring[sample.index].1 - sample.y) < 1e-9, "\(vector.shape) y \(sample.index)")
            }
        }
    }

    @Test func savedLooksReadBackTheWayHermesDesktopWroteThem() {
        func look(_ fields: [String: BighelpJSONValue]) -> AgentAvatarLook? { AgentAvatarLook(namespace: fields) }
        #expect(look(["shape": .string("blobatar"), "imageKind": .string("shape")]) == AgentAvatarLook(style: .face, shape: "blobatar"))
        #expect(look(["shape": .string("blobatar:k3j2:cloud")]) == AgentAvatarLook(style: .face, shape: "blobatar:k3j2:cloud"))
        #expect(look(["shape": .string("drop"), "color": .string("hsl(90 68% 58%)")])
            == AgentAvatarLook(style: .shape, shape: "drop", color: "hsl(90 68% 58%)"))
        #expect(look(["shape": .string("hexagon"), "imageKind": .string("photo")]) == .photo)
        #expect(look(["shape": .string("sigil-3")]) == nil)
        #expect(look(["title": .string("Only a title")]) == nil)
        #expect(look(["shape": .integer(4)]) == nil)
    }

    @Test func lookWritesKeepDesktopsOtherSettings() {
        let namespace: [String: BighelpJSONValue] = [
            "title": .string("Garden"), "pinned": .boolean(true), "color": .string("#abc"), "image": .string("x")
        ]
        let face = AgentAvatarLook(style: .face, shape: "blobatar::sun", faceSeed: "garden")
            .applied(to: namespace, profileID: "garden")
        #expect(face["shape"] == .string("blobatar::sun"))
        #expect(face["imageKind"] == .string("shape"))
        #expect(face["custom"] == .boolean(true))
        #expect(face["title"] == .string("Garden") && face["pinned"] == .boolean(true) && face["image"] == .string("x"))

        let shape = AgentAvatarLook(style: .shape, shape: "pill", color: nil).applied(to: namespace, profileID: "garden")
        #expect(shape["shape"] == .string("pill"))
        #expect(shape["color"] == nil, "No color means the name's color, as in Desktop")

        let photo = AgentAvatarLook.photo.applied(to: namespace, profileID: "garden")
        #expect(photo["imageKind"] == .string("photo"))
        #expect(photo["color"] == .string("#abc"))
    }

    @Test func aFaceDrawnFromAnotherNameIsLockedToThatName() {
        // A new agent's face follows the name it was drawn with; if the host
        // picks a different profile name, Desktop must still draw that face.
        let look = AgentAvatarLook(style: .face, shape: "blobatar::nub", faceSeed: "garden-guide")
        #expect(look.savedShape(profileID: "garden-guide") == "blobatar::nub")
        #expect(look.savedShape(profileID: "Garden-Guide ") == "blobatar::nub")
        #expect(look.savedShape(profileID: "garden-guide-2") == "blobatar:garden-guide:nub")
        let locked = AgentAvatarLook(style: .face, shape: "blobatar:abc123", faceSeed: nil)
        #expect(locked.savedShape(profileID: "anything") == "blobatar:abc123")
    }

    @Test func creatorOpensOnTheSavedLookAndHandsBackTheChoice() {
        let face = AvatarCreatorModel(appearance: CompanionAppearance(character: .lobster),
                                      look: AgentAvatarLook(style: .face, shape: "blobatar::cloud"))
        #expect(face.style == .face)
        #expect(face.blobShape == HermesBlobShape(kind: .cloud))
        guard case .look(let picked)? = face.result(faceName: "nova") else {
            Issue.record("A face hands back a look")
            return
        }
        #expect(picked == AgentAvatarLook(style: .face, shape: "blobatar::cloud", faceSeed: "nova"))
        face.toggleFaceLock(name: "nova")
        #expect(face.blobShape == HermesBlobShape(seedPart: "nova", kind: .cloud))
        face.randomizeFace()
        #expect(face.blobShape.isLocked && face.blobShape.seedPart != "nova")
        face.toggleFaceLock(name: "nova")
        #expect(!face.blobShape.isLocked)

        let shape = AvatarCreatorModel(appearance: CompanionAppearance(character: .lobster),
                                       look: AgentAvatarLook(style: .shape, shape: "triangle", color: "hsl(60 68% 58%)"))
        #expect(shape.style == .shapes && shape.shape == "triangle" && shape.shapeColor == "hsl(60 68% 58%)")

        let pets = AvatarCreatorModel(appearance: CompanionAppearance(character: .lobster))
        #expect(pets.style == .catalog)
        pets.style = .pets
        #expect(pets.result(faceName: "nova") == nil, "Nothing to use until a pet is picked")
        pets.style = .photo
        #expect(pets.result(faceName: "nova") == nil)
    }

    @Test func cssColorsParse() throws {
        let violet = try #require(HermesCSSColor.rgb("#8b5cf6"))
        #expect(abs(violet.red - 139 / 255) < 1e-9 && abs(violet.blue - 246 / 255) < 1e-9)
        let red = try #require(HermesCSSColor.rgb("hsl(0 68% 58%)"))
        #expect(abs(red.red - 0.8656) < 1e-3 && abs(red.green - 0.2944) < 1e-3 && abs(red.blue - 0.2944) < 1e-3)
        #expect(HermesCSSColor.rgb("rgb(1,2,3)") == nil)
    }
}

enum HermesFaceVectors {
    static let fullSVGs: [(seed: String, kind: String, svg: String)] = [
        ("nova", "", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#d1dcc9\"><circle cx=\"30.29\" cy=\"45.58\" r=\"12.15\"/><circle cx=\"37.52\" cy=\"39.37\" r=\"13.01\"/><circle cx=\"49.22\" cy=\"36.99\" r=\"11.25\"/><circle cx=\"60.91\" cy=\"39.37\" r=\"12.26\"/><circle cx=\"68.14\" cy=\"45.58\" r=\"14.68\"/><path d=\"M74.55 49.43C74.43 57.18 67.98 68.09 61.61 71.99C55.25 75.88 43.25 76.55 36.38 72.79C29.51 69.03 20.56 57.54 20.39 49.43C20.21 41.32 28.33 28.13 35.32 24.14C42.32 20.15 55.84 21.27 62.37 25.48C68.91 29.7 74.68 41.68 74.55 49.43Z\"/></g><g fill=\"#0c1108\"><path d=\"M44.28 49.25C45.53 55.92 45.53 55.92 43.34 56.33C41.14 56.75 41.14 56.75 39.89 50.08C38.63 43.4 38.63 43.4 40.83 42.99C43.02 42.58 43.02 42.58 44.28 49.25Z\"/><path d=\"M56.23 49.89C57.04 55.77 57.04 55.77 55.19 56.03C53.33 56.28 53.33 56.28 52.53 50.39C51.73 44.51 51.73 44.51 53.58 44.26C55.43 44 55.43 44 56.23 49.89Z\"/></g></svg>"),
        ("nova", "capsule", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#d1dcc9\"><circle cx=\"38.88\" cy=\"49.43\" r=\"22.18\"/><circle cx=\"59.56\" cy=\"49.43\" r=\"22.18\"/><path d=\"M38.88 27.24H59.56V71.61H38.88Z\"/></g><g fill=\"#0c1108\"><path d=\"M42.77 49.09C44.41 57.81 44.41 57.81 41.54 58.35C38.67 58.89 38.67 58.89 37.03 50.17C35.39 41.44 35.39 41.44 38.26 40.9C41.12 40.36 41.12 40.36 42.77 49.09Z\"/><path d=\"M58.4 49.7C59.45 57.39 59.45 57.39 57.03 57.73C54.61 58.06 54.61 58.06 53.56 50.36C52.51 42.66 52.51 42.66 54.93 42.33C57.35 42 57.35 42 58.4 49.7Z\"/></g></svg>"),
        ("nova", "droplet", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#d1dcc9\"><path d=\"M30.05 38.52L46.53 17.58Q49.22 14.17 51.9 17.58L68.39 38.52Z\"/><path d=\"M74.09 55.18C74.09 69.61 62.96 81.31 49.22 81.31C35.48 81.31 24.34 69.61 24.34 55.18C24.34 40.74 35.48 29.04 49.22 29.04C62.96 29.04 74.09 40.74 74.09 55.18Z\"/></g><g fill=\"#0c1108\"><path d=\"M44.35 56.29C45.6 62.96 45.6 62.96 43.41 63.37C41.21 63.79 41.21 63.79 39.96 57.12C38.7 50.44 38.7 50.44 40.9 50.03C43.09 49.62 43.09 49.62 44.35 56.29Z\"/><path d=\"M56.3 56.9C57.11 62.78 57.11 62.78 55.26 63.03C53.4 63.29 53.4 63.29 52.6 57.4C51.8 51.52 51.8 51.52 53.65 51.26C55.5 51.01 55.5 51.01 56.3 56.9Z\"/></g></svg>"),
        ("nova", "hexagon", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#d1dcc9\"><path d=\"M41.81 17.87Q46.75 14.34 52.13 17.07L71.52 26.91Q76.9 29.64 77.34 35.9L78.93 58.47Q79.37 64.73 74.43 68.26L56.62 80.99Q51.68 84.52 46.3 81.79L26.91 71.95Q21.53 69.22 21.09 62.95L19.51 40.39Q19.07 34.13 24.01 30.6L41.81 17.87Z\"/></g><g fill=\"#0c1108\"><path d=\"M42.72 49.15C44.4 58.13 44.4 58.13 41.45 58.69C38.5 59.24 38.5 59.24 36.81 50.26C35.12 41.28 35.12 41.28 38.07 40.73C41.03 40.17 41.03 40.17 42.72 49.15Z\"/><path d=\"M58.81 49.94C59.89 57.86 59.89 57.86 57.4 58.2C54.91 58.54 54.91 58.54 53.83 50.62C52.74 42.7 52.74 42.7 55.24 42.36C57.73 42.02 57.73 42.02 58.81 49.94Z\"/></g></svg>"),
        ("nova", "sun", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#d1dcc9\"><circle cx=\"26\" cy=\"43.77\" r=\"5.41\"/><circle cx=\"36.8\" cy=\"29.01\" r=\"5.41\"/><circle cx=\"54.87\" cy=\"26.21\" r=\"5.41\"/><circle cx=\"69.63\" cy=\"37.01\" r=\"5.41\"/><circle cx=\"72.44\" cy=\"55.08\" r=\"5.41\"/><circle cx=\"61.64\" cy=\"69.84\" r=\"5.41\"/><circle cx=\"43.56\" cy=\"72.64\" r=\"5.41\"/><circle cx=\"28.8\" cy=\"61.85\" r=\"5.41\"/><path d=\"M71.54 49.43C71.54 64.77 63.82 72.88 49.22 72.88C34.62 72.88 26.9 64.77 26.9 49.43C26.9 34.08 34.62 25.97 49.22 25.97C63.82 25.97 71.54 34.08 71.54 49.43Z\"/></g><g fill=\"#0c1108\"><path d=\"M44.73 49.28C45.86 55.27 45.86 55.27 43.89 55.64C41.92 56.01 41.92 56.01 40.8 50.02C39.67 44.03 39.67 44.03 41.64 43.66C43.61 43.29 43.61 43.29 44.73 49.28Z\"/><path d=\"M55.46 49.88C56.19 55.16 56.19 55.16 54.52 55.39C52.86 55.61 52.86 55.61 52.14 50.33C51.42 45.05 51.42 45.05 53.08 44.82C54.74 44.6 54.74 44.6 55.46 49.88Z\"/></g></svg>"),
        ("nova", "triangle", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#d1dcc9\"><path d=\"M42.73 21.4Q48.09 10.91 54.06 21.04L75.56 57.54Q81.53 67.66 70.2 68.03L29.37 69.34Q18.04 69.71 23.4 59.22L42.73 21.4Z\"/></g><g fill=\"#0c1108\"><path d=\"M44.6 52.95C45.88 59.77 45.88 59.77 43.64 60.19C41.4 60.61 41.4 60.61 40.12 53.79C38.84 46.98 38.84 46.98 41.08 46.55C43.32 46.13 43.32 46.13 44.6 52.95Z\"/><path d=\"M56.82 53.3C57.64 59.31 57.64 59.31 55.75 59.57C53.86 59.83 53.86 59.83 53.04 53.82C52.21 47.8 52.21 47.8 54.11 47.54C56 47.29 56 47.29 56.82 53.3Z\"/></g></svg>"),
        ("avery-park", "", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#00a060\"><path d=\"M79.83 48.64C79.88 56.15 77.19 65.18 71.99 71.32C66.8 77.45 57.09 84.83 48.67 85.45C40.26 86.07 27.16 81.17 21.53 75.04C15.9 68.9 14.28 56.85 14.88 48.64C15.48 40.43 19.52 31.21 25.15 25.77C30.78 20.32 40.91 15.88 48.67 15.96C56.43 16.04 66.52 20.8 71.71 26.24C76.9 31.69 79.79 41.13 79.83 48.64Z\"/></g><g fill=\"#08120c\"><path d=\"M40.86 45.08C40.39 52.8 40.27 53.1 37.64 52.95C35.01 52.79 34.92 52.48 35.38 44.75C35.84 37.03 35.96 36.73 38.6 36.89C41.23 37.04 41.32 37.35 40.86 45.08Z\"/><path d=\"M60.15 45.76C59.96 55.71 59.83 56.1 56.61 56.04C53.39 55.98 53.27 55.59 53.45 45.63C53.64 35.68 53.77 35.29 56.99 35.35C60.21 35.4 60.33 35.8 60.15 45.76Z\"/></g></svg>"),
        ("avery-park", "organic", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#00a060\"><path d=\"M79.83 48.64C79.88 56.15 77.19 65.18 71.99 71.32C66.8 77.45 57.09 84.83 48.67 85.45C40.26 86.07 27.16 81.17 21.53 75.04C15.9 68.9 14.28 56.85 14.88 48.64C15.48 40.43 19.52 31.21 25.15 25.77C30.78 20.32 40.91 15.88 48.67 15.96C56.43 16.04 66.52 20.8 71.71 26.24C76.9 31.69 79.79 41.13 79.83 48.64Z\"/></g><g fill=\"#08120c\"><path d=\"M40.86 45.08C40.39 52.8 40.27 53.1 37.64 52.95C35.01 52.79 34.92 52.48 35.38 44.75C35.84 37.03 35.96 36.73 38.6 36.89C41.23 37.04 41.32 37.35 40.86 45.08Z\"/><path d=\"M60.15 45.76C59.96 55.71 59.83 56.1 56.61 56.04C53.39 55.98 53.27 55.59 53.45 45.63C53.64 35.68 53.77 35.29 56.99 35.35C60.21 35.4 60.33 35.8 60.15 45.76Z\"/></g></svg>"),
        ("avery-park", "boxy", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#00a060\"><path d=\"M77.12 39.56C85.95 67.22 85.95 67.22 57.5 76.3C29.06 85.38 29.06 85.38 20.23 57.72C11.4 30.07 11.4 30.07 39.84 20.98C68.29 11.9 68.29 11.9 77.12 39.56Z\"/></g><g fill=\"#08120c\"><path d=\"M40.77 44.57C40.32 52.2 40.19 52.5 37.59 52.34C34.99 52.19 34.91 51.88 35.36 44.25C35.82 36.62 35.94 36.32 38.54 36.48C41.14 36.63 41.23 36.94 40.77 44.57Z\"/><path d=\"M59.83 45.36C59.65 55.19 59.51 55.58 56.33 55.52C53.15 55.46 53.04 55.07 53.22 45.24C53.4 35.4 53.53 35.01 56.71 35.07C59.89 35.13 60.01 35.52 59.83 45.36Z\"/></g></svg>"),
        ("avery-park", "nub", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#00a060\"><circle cx=\"21.89\" cy=\"46.32\" r=\"9.78\"/><circle cx=\"25.94\" cy=\"63\" r=\"10.64\"/><path d=\"M79.23 48.64C79.23 68.65 69.26 78.35 48.67 78.35C28.09 78.35 18.12 68.65 18.12 48.64C18.12 28.63 28.09 18.93 48.67 18.93C69.26 18.93 79.23 28.63 79.23 48.64Z\"/></g><g fill=\"#08120c\"><path d=\"M40.59 44.48C40.12 52.29 40 52.59 37.34 52.43C34.67 52.27 34.59 51.96 35.05 44.15C35.52 36.34 35.64 36.04 38.3 36.2C40.97 36.35 41.05 36.67 40.59 44.48Z\"/><path d=\"M60.09 45.28C59.9 55.34 59.77 55.74 56.51 55.68C53.26 55.62 53.14 55.22 53.32 45.16C53.51 35.09 53.64 34.7 56.9 34.76C60.15 34.82 60.27 35.22 60.09 45.28Z\"/></g></svg>"),
        ("avery-park", "cloud", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><g fill=\"#00a060\"><circle cx=\"28.66\" cy=\"43.46\" r=\"16.19\"/><circle cx=\"40.38\" cy=\"36.13\" r=\"15.98\"/><circle cx=\"56.96\" cy=\"36.13\" r=\"13.64\"/><circle cx=\"68.69\" cy=\"43.46\" r=\"16.22\"/><path d=\"M73.48 48.64C73.51 54.62 71.37 61.81 67.23 66.69C63.1 71.57 55.37 77.44 48.67 77.94C41.98 78.43 31.55 74.53 27.07 69.65C22.58 64.77 21.3 55.18 21.78 48.64C22.26 42.11 25.47 34.77 29.95 30.43C34.43 26.1 42.5 22.56 48.67 22.63C54.85 22.69 62.88 26.48 67.01 30.81C71.14 35.15 73.44 42.66 73.48 48.64Z\"/></g><g fill=\"#08120c\"><path d=\"M42.45 45.81C42.08 51.96 41.99 52.19 39.89 52.07C37.79 51.94 37.73 51.7 38.09 45.55C38.46 39.4 38.56 39.16 40.65 39.28C42.75 39.41 42.82 39.66 42.45 45.81Z\"/><path d=\"M57.81 46.35C57.66 54.27 57.55 54.58 54.99 54.53C52.43 54.49 52.33 54.17 52.48 46.25C52.62 38.32 52.73 38.01 55.29 38.06C57.86 38.11 57.95 38.42 57.81 46.35Z\"/></g></svg>"),
    ]

    static let hashes: [(seed: String, kind: String, sha256: String)] = [
        ("nova", "", "6e34ce1fe050f12f6ff17f05d6829323c5caa7bb73754cec669431f911ae99aa"),
        ("nova", "round", "3b4defdedb88e75916f81c914a54047c76822b00370f80b40c0592af98c3e726"),
        ("nova", "organic", "e04c4d4a227ff9408623f3b90e0febcd472e751b0b730ac9ce0a2be6f467d154"),
        ("nova", "boxy", "3de184259ff349bb5b9acf61ba0d906e88c7ff44a03b6c7bd3a14813b7a599fd"),
        ("nova", "capsule", "901a669f81bd2e136a0beda6ff5a68f190387b86cf59a8ef710d1a9c4595ccaf"),
        ("nova", "nub", "603256347dfb81d92f9fc0f80110b884a016ec3b111284dc821e21cd07d9dca1"),
        ("nova", "cloud", "6e34ce1fe050f12f6ff17f05d6829323c5caa7bb73754cec669431f911ae99aa"),
        ("nova", "droplet", "11aa1b16bf39048acb70d1ba7907e61c69168b001dbe37ed89dad4ffe7c1e604"),
        ("nova", "hexagon", "50b1e29bd4a42bb32cd3885c01da928e0960c0e331414c2be6c6918fab9c3a4a"),
        ("nova", "sun", "e9657645168861b5046e1422012aecb6d3081f4793081b8a11f336a5b6a9ee25"),
        ("nova", "triangle", "cefe8433177e8db9a5ac48f73bf8b69f36805e005c3fd5340dff12afd344d118"),
        ("avery-park", "", "5dcd60cdc2f3ccc5fe56f26d2c2eb4bb1ed422a408c72755c2bdf89bfd288881"),
        ("avery-park", "round", "9af3b512cce3e5d0f62d4229574c212a1434cdaa795ed1c40956775160964d28"),
        ("avery-park", "organic", "5dcd60cdc2f3ccc5fe56f26d2c2eb4bb1ed422a408c72755c2bdf89bfd288881"),
        ("avery-park", "boxy", "961f626918497c3fca4a0fb84025274f0fd4bade8fec25fb9260e8ed960146c1"),
        ("avery-park", "capsule", "d5fee97e4ecf26ee010c39cee564be6af7414ba7bad48597c9e3c0d6f179ba7e"),
        ("avery-park", "nub", "4077e81c16a63f0bcf6a83b23576e4bac160a8bc0a86ed37e879c2bef55d779a"),
        ("avery-park", "cloud", "355d36aae23c3edb5ce4b2cb820c96d49422c701c6a6fd5f7b64b6ce7c12e1ed"),
        ("avery-park", "droplet", "692e7ec25a50a3e067abe00db7784f9aebbb4aeccf224095c5b78e0f972359fc"),
        ("avery-park", "hexagon", "30182db09067c602618ac6e2571ee0213119bfa9a2bc74f95dc1b325bb30c7b2"),
        ("avery-park", "sun", "63ed13b3b1f3827e92d5895e35c8c6cf9a33ffee671e78f2811d04c044316248"),
        ("avery-park", "triangle", "d24b50ec5402c33707dc0cae88f0858198f6242b9ff021712c6ca1420d8c7859"),
        ("agent", "", "59632a965834453305c05bf90a73316c13e82d1194714eb799cf4a3c33eea5f2"),
        ("agent", "round", "41d14ecfbb469c82f2374702b7d912de22d37cbb6d10fe67fb857cbb332e831d"),
        ("agent", "organic", "cd7a8cd95eaab8d183869b02d6027ed82dde21dcf920b874ea07324b7bacd4df"),
        ("agent", "boxy", "dd2bf94caa46caff58fe6b2c3e8de6c3b94f200d5ce8e1cfcd691545b163be44"),
        ("agent", "capsule", "2f4a81b03e2c0c4aa17e47caddcb87ee1226c2e7a5bf55f9675b5772f8d911d5"),
        ("agent", "nub", "0042969b6cd1908957ed193ea89745f875b31f74adb4e2bd9ac22c5136868d89"),
        ("agent", "cloud", "59632a965834453305c05bf90a73316c13e82d1194714eb799cf4a3c33eea5f2"),
        ("agent", "droplet", "65de3463c1d6c32472e161c3840c76868f11b08bb3d431db5eb6e96b1229c391"),
        ("agent", "hexagon", "342d063fb228de68752f1bdb40070be059e28d0511f7779036a73d5eaaa9537d"),
        ("agent", "sun", "d4777557dead6ea7598a507cb46c9dbd04c47aa6c3e99a644ac26704fb8ebf0f"),
        ("agent", "triangle", "4a45845ca452efe15f1875066956588d23e1e9cd09bbe22c237261a06b1d045d"),
        ("Mina Shah", "", "6836a6e34fcb25ae7e4b566db385e20994c02cde685f3207346388948c56c7da"),
        ("Mina Shah", "round", "6836a6e34fcb25ae7e4b566db385e20994c02cde685f3207346388948c56c7da"),
        ("Mina Shah", "organic", "28f2662071226c3f4cd9f6fd52b68ccf971aa01da0254fbc24a2b09284adc7e2"),
        ("Mina Shah", "boxy", "b7cc1974633747f16ed08821b5a0abd7110ecf03c136fb772c81918c506f6de6"),
        ("Mina Shah", "capsule", "3eda990d0ff53165b140aa62d9056a71c0f41ad023109da42928ab5fe81378d5"),
        ("Mina Shah", "nub", "f3633b4ec5fc241bcee81a1a0b4665479df6026e2314359da48c993f01657517"),
        ("Mina Shah", "cloud", "a7d123af8ee76fe46c6545a2957c3f25ee2fba12b42b5737b6134ef2bef3d99f"),
        ("Mina Shah", "droplet", "b7fd2d33091d2e5841532d244298c7104f128ebd7d739ec6e6204e7adc2738a6"),
        ("Mina Shah", "hexagon", "9c6b982d7944415697526907ade28cc2e3b025fe0b1bb607be57efa5ca28e264"),
        ("Mina Shah", "sun", "99c38f161b5eddb3339079541b64392fb4b4525b5ae3aa5fb08dd00813f0c791"),
        ("Mina Shah", "triangle", "407b3ff3cda64c2dd0b80d6bc7c2a8c4eb3abb63d3b7d70d24ddba3b67eb1cf8"),
        ("k3j2h1zq", "", "ba391efee4eb79ad1f2f9c243a420f1f0bd85d0d2062e9cd0b8e15477796003a"),
        ("k3j2h1zq", "round", "c4c26929d9e8b01f66178ae63943cf05b441044b65454120c81987122fd88c93"),
        ("k3j2h1zq", "organic", "ba391efee4eb79ad1f2f9c243a420f1f0bd85d0d2062e9cd0b8e15477796003a"),
        ("k3j2h1zq", "boxy", "39a8d1f6853f3c3c25aba332c7789a5c54eb7af58e906798ad9af216592cd9af"),
        ("k3j2h1zq", "capsule", "ae3001e78b76ac187b215ec0399c83e83ab2b0a4b06276737c054829548fba95"),
        ("k3j2h1zq", "nub", "387e4657f93bf8de330b5397a5e5aa8450a3766f91ea21a48e5b2c360c73372a"),
        ("k3j2h1zq", "cloud", "3d70e569714de10805d48d15eef848c604d7d9557b50bfeebf39cb79bbd4e570"),
        ("k3j2h1zq", "droplet", "357b80baf40f80148992fc37762ff59091a03700ce712c374aa9dd607538e2f9"),
        ("k3j2h1zq", "hexagon", "f6f340d100c194bc414b23883fc6fe9586146233b975899cdcf9075c5118a9ba"),
        ("k3j2h1zq", "sun", "21854f66c5efc2cad8010aab70efff0c88a52aca9489daa96e40d003529e83ef"),
        ("k3j2h1zq", "triangle", "04add74a957f7ff1549b8e1ba74d0e6b6d655a9a23afc8b22621587b5f7e13e5"),
        ("travel", "", "b5c79051406302d590d88a48a505ca82059e5eeac7763e99d34d78a134ab8211"),
        ("travel", "round", "b5c79051406302d590d88a48a505ca82059e5eeac7763e99d34d78a134ab8211"),
        ("travel", "organic", "a585d53e85a6aab4480b3f28ae11ecec59588bcf2139a9721a432d8308e05891"),
        ("travel", "boxy", "2de66ebd743031abe64b3b421ddc0b0b6a73a4780c16a875ef110be1c3361a15"),
        ("travel", "capsule", "ac634d6597b7912066bcf35d09b70d13acdc9ee6f7fdb25050d1fada86237bb9"),
        ("travel", "nub", "ef9722486b88b66093ad0c1d81b9477761a55f90ff82c73a883c40b90730dfb2"),
        ("travel", "cloud", "867c11c33a08e9bedd08afc51926b563d7ce13f2d83a436caf5bf98d65d8107f"),
        ("travel", "droplet", "a0621fd05665085a9d4b2340a9f1c1c8f82d9b1f1a8b2488686b813df1a2f342"),
        ("travel", "hexagon", "cc2478d2bd02e644160d354c21458c2e32d406a68e4b2f87fc41381fe9cc0a64"),
        ("travel", "sun", "3e365aae67f2ae1507d7432852d202bdc82502b77be090a6a035e0c21212aa81"),
        ("travel", "triangle", "6f942b6175ecad5db087c360390e164a77677e6b99c3c31acbf6f1edad8c23c5"),
        ("finance", "", "ed3a3d58ea42ca330e22e315d85cacca3f75bc0936b5cd628cd09f6a92a1f4c0"),
        ("finance", "round", "c51b5023c4b8fd212b8584482e177f677b0a94e569498bd3a3fe0f0184f4f70d"),
        ("finance", "organic", "5a9d4d2df00d1628e9e5009229e398553cfbf14f7f6ca84ee9b114e68e990a4c"),
        ("finance", "boxy", "0657aaad6c35c1d45bce0fa33a314b9e5d1b311d9aad7ee74e46448880bd7f19"),
        ("finance", "capsule", "1b700d17f42a3ba09362d328d15bfb7a15215b91a63763e1fd7ca9c01cf3aacf"),
        ("finance", "nub", "ed3a3d58ea42ca330e22e315d85cacca3f75bc0936b5cd628cd09f6a92a1f4c0"),
        ("finance", "cloud", "628f87a8c66e15fb3ba38b5bb8e3a6df1c2ab2f71f0266b95d8def7ece487eb0"),
        ("finance", "droplet", "3883094058cef64feea509962efea677ee6d7d2f46911b943134e2e19ad184e4"),
        ("finance", "hexagon", "906cdaaec55b6d2d421310f5318a44f60e9346d89a198bf71d81f574db233b97"),
        ("finance", "sun", "6e5a67c4b784516db840d8e706c22beb603e2d38517fdc5480a6eb61283b733e"),
        ("finance", "triangle", "b473d8067d86704fd7210988124e5d067e39d9dc1d567edd6cc873a016de0141"),
        ("émile", "", "17b71610481a26647821b2cfe62a8bd85e3f1a9d2064e3fb8e4ae2774d59e7e0"),
        ("émile", "round", "5ffb6c7166fb6036921be13b31b5fba26421a84ee1fa32fd63a890c701160155"),
        ("émile", "organic", "17b71610481a26647821b2cfe62a8bd85e3f1a9d2064e3fb8e4ae2774d59e7e0"),
        ("émile", "boxy", "006a7a1bf437aa7feff6803217bf16907d78c123cc3f165434b90c566f708a69"),
        ("émile", "capsule", "1fc6521a7b8eecadf4ff4b91ae63c6468c04095c3b045a3c2848823f160db742"),
        ("émile", "nub", "045969b434741592d3d675888cbcb9ecc0bd4bf1f826321a5c661a6e1c7707cd"),
        ("émile", "cloud", "d465dc76d44cb27893dfe417cebffbc0afa894084dfdb784886bbf9e895e75f9"),
        ("émile", "droplet", "e058139123e5d1ae7fd1d06decdd5b7df2f6115a5b949177e69d36c4a77a3b06"),
        ("émile", "hexagon", "bd79fd1b748f373eddc0220e28aac3958142856ffa58d8109b5bfe1e3af909aa"),
        ("émile", "sun", "96f52456d7cc235f0a70876cd5f605edc8ea95ac3e8e06a1ba16835221761183"),
        ("émile", "triangle", "9adad32ae325c7a18c151c78913b8438a5afa14e91672ccce88459442769ec61"),
        ("default", "", "17ed6f022527c9b3b3301b214e32f76bdf2ff93e8499db2eab2ef696a868bb80"),
        ("default", "round", "f9025b717c23045a195a54d7c2ce1d77dd215aafc1c861ac5ab6a5eb86f410aa"),
        ("default", "organic", "a974506d680174e846a0b43377366e7e1b0fcfe483bbb5c7987045b96322984c"),
        ("default", "boxy", "f549fa9e955c6ce0d3892dabb5ced112204d8fe4a0ece9f03efefb14de2b9436"),
        ("default", "capsule", "6996a0f61e37950647d6c1afdadf1990fe1661268ddcfeaa70795a2eaebac916"),
        ("default", "nub", "61c98d4bb68b3c1d8574c7e708eceff3e475cc027efb8b4908acc87fb69503a6"),
        ("default", "cloud", "93cd2d21dd179e2a70de38e1bc253db77fd6ac5f8234bcb2601bd1d27f9c7751"),
        ("default", "droplet", "0e1594973cc8a165c3473dc73e32fd6f654addee56503faef8fd323a1d088f8f"),
        ("default", "hexagon", "6aeead4489c6799361ceea7d05bfe94ab9e6408c83b28ac0e3e8d1c947e89351"),
        ("default", "sun", "17ed6f022527c9b3b3301b214e32f76bdf2ff93e8499db2eab2ef696a868bb80"),
        ("default", "triangle", "04b966006adfc488c9829258982692aef06bb5905db57f2cd6ceb2b7445f1445"),
        ("  Spaced Out ", "", "00bd99f64a3ef024c3b5d0d5f3c2a2f247268fd1d53d24199bc5f70439536141"),
        ("  Spaced Out ", "round", "4bf381d2c68ebb6429c1013a693bd7e40683d521b31697ca4213261775c17a0c"),
        ("  Spaced Out ", "organic", "9142d6aedc3c1a9d1e392adf68974e2b492c1fdfb276c2f534033f6f91eb9a6c"),
        ("  Spaced Out ", "boxy", "32521e6d0ef0d3cd49f455f259f5c5ae65695775292ae89794afe45926ec5692"),
        ("  Spaced Out ", "capsule", "00bd99f64a3ef024c3b5d0d5f3c2a2f247268fd1d53d24199bc5f70439536141"),
        ("  Spaced Out ", "nub", "19164b2a1f0d24db19d5d6007acae53528e71203f658a6d9d4b59675464e3275"),
        ("  Spaced Out ", "cloud", "c8cc8b2342364aa40dbc06c35bd6a1643fd3d5b0882e7f6bd0e4235637b4774c"),
        ("  Spaced Out ", "droplet", "7f0fcd63292ed718961504bf124c957d1d5d4ed6a3a4a378d922b023bcd74b77"),
        ("  Spaced Out ", "hexagon", "50d258cb0fb689193c5777ef38820cce6c18f042b4176b01d4ba5bf804704a44"),
        ("  Spaced Out ", "sun", "ff347bf0caa72e7648837523e2d8f6d113eab31508b54552081d3bfe8fe4b4bb"),
        ("  Spaced Out ", "triangle", "9b6d3199bf20f68f4d9093cf88e6232b3cae09a0b4f6a6b913bc1086b6ad292f"),
        ("research-bot-2", "", "7bf293bf9d071368f9eb0ad18c485069a32611044e22a2070fce5a0b175adf92"),
        ("research-bot-2", "round", "cb830c3a99e799fef4cd46c7d0eb7cd250757326dad9f5bcb40ba2bcf212fbe1"),
        ("research-bot-2", "organic", "1116a68e6307c6f45b530dc8b87c5bbf2a5adb4bc7939a3f218e66bf9f6fa31a"),
        ("research-bot-2", "boxy", "de9d1d807bea619905505f128bc348cd5b6682542e5c41766d429283a6ba6f7f"),
        ("research-bot-2", "capsule", "692b020cc85257101f80f5b3cfbd50f4814bec3b805a01256dfc7f1db0d6ba66"),
        ("research-bot-2", "nub", "5ca474324f7a1d35450ffa9c08fd3c570bc54a22dac4d3ac85bfd60a492511cc"),
        ("research-bot-2", "cloud", "6d21b4f696a9132843a356efa22022755ba096dfc8082e0c87c45473cd4ff94c"),
        ("research-bot-2", "droplet", "7bf293bf9d071368f9eb0ad18c485069a32611044e22a2070fce5a0b175adf92"),
        ("research-bot-2", "hexagon", "4d04aa535670b9db72bafc500cf1cb83756ee924ff77915d5267a13d49828a3d"),
        ("research-bot-2", "sun", "8ae7ddc8ef2c9b779e4729bc7dc72cdb71458cfcdefb0c5bc8a1a433f648341e"),
        ("research-bot-2", "triangle", "6d63f977a90f5681c9b4df6de424bfff364a3ea7322ee8153d9662edfe624924"),
        ("zz9plural", "", "103938a75f379d9b881dc1939b992ec955e845c9b22847b27e0cdfac66913910"),
        ("zz9plural", "round", "103938a75f379d9b881dc1939b992ec955e845c9b22847b27e0cdfac66913910"),
        ("zz9plural", "organic", "2cf6a5401b8186d28d6e54a310b3713632bc97f94013e30f8f7011e39d1692b4"),
        ("zz9plural", "boxy", "664c5387ada15e4ade11285c66fbf47d8af682ad6969b7846aa0752028efacf3"),
        ("zz9plural", "capsule", "db8b64bd85460ad6d4defcf01da322ff720fb368c0c2866aba5b3d21c7714151"),
        ("zz9plural", "nub", "df901b2798cd1370830fd50c4605ef647fcb12adc3774ce21a634a66b15aab6c"),
        ("zz9plural", "cloud", "9b6f96d87c16491755b75bc20e1b9ad1523f0a91ac932272c77a6eab1ca9f1b5"),
        ("zz9plural", "droplet", "f73ab178be612467121220a8bc5ddde891116afc1acda93998c61c84fdd23127"),
        ("zz9plural", "hexagon", "19bc27a5a93882b3bf7132efcbc280290bfffcca0550fe08762bd3a163eaa192"),
        ("zz9plural", "sun", "7e0eb3abe9a0256b6633f4da9924a44ee8ce5ff3c9c6d3459c10e5a3f53ae2a8"),
        ("zz9plural", "triangle", "2d155bd4c7ccf3430d0294700a3c9e44913b6592386b28a772c3d85006b150f5"),
        ("a", "", "77ce3da7a3eb0b5f7882d5d424ce817f003b6f969bff3569ad1d973117bfe403"),
        ("a", "round", "098672ea52335a1166f372258652f89cdeda53310d6515e58656c3ff50d27eb3"),
        ("a", "organic", "0dc727ca20db1afab34dfbd0a3ebca58527c7781dc4200c6dd3316650051bced"),
        ("a", "boxy", "77ce3da7a3eb0b5f7882d5d424ce817f003b6f969bff3569ad1d973117bfe403"),
        ("a", "capsule", "206ba3d52f46036347b232ad8d471d2ef62434ca842bd339f51b42b5943d3100"),
        ("a", "nub", "cb975cd1a5e36cc246d8321de9798980a11be3f9a95a390ecb4f6b58b560a5bc"),
        ("a", "cloud", "26c77e3e4671486d7bd02fa40639a1f07dc8b804ae471e6940fbc4a65022dabe"),
        ("a", "droplet", "c93d51ee15ac18de239f940ee96e914351c1add03b9e82d7e6f29ca119d5bb08"),
        ("a", "hexagon", "04929ddef5f153badec7cd5fce7f3996b523cdaaa1aea6f55e82fe2fb694e84f"),
        ("a", "sun", "505bdb9b70626e3d0712702f3b2dab22355f03e057ca79c68ff26efcbe649394"),
        ("a", "triangle", "a18170a9dd52881beeb2263e07a941728900e0782877314c39f610a0fa960351"),
        ("home", "", "a659321f25096fdde14d10f2958374e495129dd43d149c969513a5cd1fbfc1ad"),
        ("home", "round", "63ee49c00ecb198310d2e58620632c6c6056dd50492c4297f67d82c9361d7f59"),
        ("home", "organic", "4d04a6da9b57209793dba66b34f3da18ba80223f58cd04fad5c9c12caa9da71e"),
        ("home", "boxy", "a659321f25096fdde14d10f2958374e495129dd43d149c969513a5cd1fbfc1ad"),
        ("home", "capsule", "d3ee28a9a1533ebb00fd7a4d47b5c55445c371dc5259eb712fdba00a36c32e67"),
        ("home", "nub", "e48ed902449aaa08d0ce07b1f4136ffe86e603933625a244414e4e73f065a348"),
        ("home", "cloud", "85c6414c39272f4a6ba5c58e3ea0fe8a3dfb353a5a695d4511ea43ba5c6b0216"),
        ("home", "droplet", "d192b5368515060a9ae92a7a5238a4522b245b899173c85a2df7cd8ad87b2a82"),
        ("home", "hexagon", "310e8cff8d4c1816519bb2703ea806812ebb506d15456d943eb9e9fc6b419601"),
        ("home", "sun", "b15e4736b0127778518021bea5ea441d86db243aa3cc654a04b04004e1942958"),
        ("home", "triangle", "793b5ed8f755d298467cee117b27cd447fa9ef1435d31c895427e4a274f58839"),
        ("café", "", "4525ae4e8ec3172b93072f60a33f978fd9b3b75e270cda39c9f076dc993e5190"),
        ("café", "round", "0a225793f2d37dd60fe8e10ed2d18771d376bf93a2c026578894904fd9bd8ae5"),
        ("café", "organic", "4525ae4e8ec3172b93072f60a33f978fd9b3b75e270cda39c9f076dc993e5190"),
        ("café", "boxy", "0c089d470c70f5698e71449a113d7b31bad52b1a1f51b9b8b00ea13aa70550eb"),
        ("café", "capsule", "b9b329fe36d3b5c45b64fada1f7ba1ba8db351d2aac443f296dcaf4f994a1ac2"),
        ("café", "nub", "885d08bf462c4319cb0753124626278cc30032db7782fdff77f95a18e71194d5"),
        ("café", "cloud", "bbad086647067f0dd0ea6f4cc147847c5b1da2cf337370b12d0577cfb58aa114"),
        ("café", "droplet", "0418acb2f65a0ae8f9ab131967fff45b1b57ac479c375cc497a42c21744a4b79"),
        ("café", "hexagon", "c84648571e24a15f7a58878f195796bd198d6cb9fffe6766d62fdf59c81cd285"),
        ("café", "sun", "5e884189f1c258c90769b23e5bffcfa6c86037eb9cbe0b6252814d636edd43fc"),
        ("café", "triangle", "70ef3cbc294970dc600d125c83c7cc31617b4a3ace5e00cc83d9b5eb0e986c75"),
        ("x7", "", "b4214d3669124a91bacce1c9fbf7bf086ad60d5ad2605b60b79526b0609572d1"),
        ("x7", "round", "5647752860b41aabe58ffcaf3ee1bec4753c90fb2ed898f0ce50c550b4ae4d1a"),
        ("x7", "organic", "b4214d3669124a91bacce1c9fbf7bf086ad60d5ad2605b60b79526b0609572d1"),
        ("x7", "boxy", "d74cda1c13c32bf358ce28daf98465a821b91c0cf34e93bfa2f70b7fa884d5ec"),
        ("x7", "capsule", "fb5a4019fed2a065805e2022f08b25184b25f4f4edcdf9293d64bc3e4d60bb96"),
        ("x7", "nub", "3e512e3623ff1124665df211aa9b887ad0f4d5444fbbe4fa385059b6d113f674"),
        ("x7", "cloud", "3ee4de092b54169d18f97321f9911f912cafd5a98af3550351e81de1131b470e"),
        ("x7", "droplet", "903d90946063f2a21de4cc41929403990959f15d9da818952b933cbdf5c52c42"),
        ("x7", "hexagon", "bedb417c04f3beac12214d87ff717cb0bfac130cfcd21972f39fe0e463bfb177"),
        ("x7", "sun", "408020d9d039747b5d7369d2e6dddbaf78d86fd0006c021274a374b01f62fa8c"),
        ("x7", "triangle", "250b0a1dad37c9829dc3f2b440cd04c4a083f758b971567859e7f39c9339f612"),
        ("support", "", "fbb685075e53e557d2355b074213aadfa0afb7f6fb3c95a77dbd4dfbfff5aefd"),
        ("support", "round", "a4b4c769c15733d71aa0f2e8584f53d01d3f29aee5ae8aae5bcea0635ae224f3"),
        ("support", "organic", "fbb685075e53e557d2355b074213aadfa0afb7f6fb3c95a77dbd4dfbfff5aefd"),
        ("support", "boxy", "cc0a26979abe672a4cde4572d49b523763c1b51da351e3bbca9bd9935c6b7e95"),
        ("support", "capsule", "e2ec8654373adfcdc71db57133faf0f3d4beb6ea3beb6ba0481dc4530a624018"),
        ("support", "nub", "b5ef2e18093613c1e0f85f2edf04a2fb214cd25994558864e3b451e8fb6e3dce"),
        ("support", "cloud", "f3624348838d12a84901d8cac53000911545b296f2376bac970129d9f7824856"),
        ("support", "droplet", "905e93d02bdb31c706088de06eee65f5e7f903854651dde769359192e75f7770"),
        ("support", "hexagon", "4f36efb2bf8a43cf923932206e6977448b1777ff5452ac101e54d796e1986981"),
        ("support", "sun", "eece0955f99fedc03b3dac5af822016eb2e14b7bb3c2b09b9e897412c708cd57"),
        ("support", "triangle", "f6a015d4ac029b842dd1db15e6f5093a686d4d3c4907079582f10d9dfce100ec"),
        ("writer", "", "1827fd812310f35534fbe22e343b9caf5b6c6173057be8a341544b5ec6455a1e"),
        ("writer", "round", "1827fd812310f35534fbe22e343b9caf5b6c6173057be8a341544b5ec6455a1e"),
        ("writer", "organic", "4c39e904acc8de788f169471d2b4e13c04b55139d805f99100c0e7222157a404"),
        ("writer", "boxy", "edf74ad2acbcdf636dc1324dd085f132a77f40fe15d56446510bce7dafd09f9e"),
        ("writer", "capsule", "14e55125740978add8739ac74d322e672b71ba26d05c7ba7a064602e8b859897"),
        ("writer", "nub", "0c6d6a980c6511d4557da4a0efece4e09b71d5a19cbc51bd56b53395f131de0a"),
        ("writer", "cloud", "d6d258fdc25040824e7b99c8e9b9d5df8628bfef05a15f4ad663818ebabfecbd"),
        ("writer", "droplet", "17e662a0975b652ce96d6ca204a22c094a316f48d951f89a442602282674afd8"),
        ("writer", "hexagon", "449a14e186fd75ad839ef2884ca31a5b09cdc00e0c6cdd245a5fa3f34ca81991"),
        ("writer", "sun", "5502d3aa7e4bdeb5f4461dcba3e86020f32b456cfe4874be48f5786374a5df41"),
        ("writer", "triangle", "5a84c7968ff26464ee22530b4374f0c79373d943d9eed277fb8749a76a82d534"),
        ("coder", "", "a563e80d26365c9cfab3fc9bad7bc9071c1dcbd250b28f00843c71d7ede56793"),
        ("coder", "round", "99db96f484920e7a413f9c28f497d21215f163e0205c6c5a41051062f49a48a4"),
        ("coder", "organic", "60ebfe82e7b84867321f22a4044c42d0a6953aa1174f13cc88baa26183de2fb4"),
        ("coder", "boxy", "5e212cd6f3b1ef80f41ac5452c963134d47583be0102d59db80830fb82e3be74"),
        ("coder", "capsule", "d4a212ed3b0d8c0b1500c0ad94b7413b82c99620a581f402753c4c41781a970b"),
        ("coder", "nub", "a563e80d26365c9cfab3fc9bad7bc9071c1dcbd250b28f00843c71d7ede56793"),
        ("coder", "cloud", "01b633ce6d47056950e71744634676275ad2e326b892de7a35ebd1ec7c3405bc"),
        ("coder", "droplet", "ec67bb9a01873c9ee4012bfbbfcddcc59483f4a8c12cfae0f188c5735c80677c"),
        ("coder", "hexagon", "81c8d7c6aa6d09c50e64d70bb49806bef1d96af48f80e1eedf84bceb81111200"),
        ("coder", "sun", "353652e9b383174434f8c7768271990e76cc1c70dd5ce5ad85fdc912e0bd1125"),
        ("coder", "triangle", "16303fa5ce1f8ba6e198dc3587150272b598627d824652d370e8c48ae36987b5"),
        ("Hermes", "", "2d073be4dd99485f00d8102e74bfde83b469335851d560aed430245ff086b4f0"),
        ("Hermes", "round", "30442abf580effa8e3165c98d812f7de09aa81faba309e1b92182fa4f87c07fd"),
        ("Hermes", "organic", "e68030f22bca95cf0d728e11c0d9922bef19b16ca32f6016e2641e3af9404cc3"),
        ("Hermes", "boxy", "c6d90111ccb8ec1793bd6e6c6147f34a88ba7bd994ed44ce2a0c6cd635eb3771"),
        ("Hermes", "capsule", "2d073be4dd99485f00d8102e74bfde83b469335851d560aed430245ff086b4f0"),
        ("Hermes", "nub", "98caf6b7aafd6961b64ba83d7a04b8160bf702331029b4ee13509bf58dd5049b"),
        ("Hermes", "cloud", "ccb91d93784e528171d4dd7fd12b601ed134e44ecae3468b9947bc85897f5b84"),
        ("Hermes", "droplet", "977ca5ac82cd19171744e12f90df276d935f96b8eea45275e1d14fbd5375d01b"),
        ("Hermes", "hexagon", "cb667e1df637a3b2747091fa220165a8b616dc1bbb1b0d6d0f075f532a430133"),
        ("Hermes", "sun", "2755caa000ea2f38f96531eea15085c06df99abaaf16b03183aabacfe34bfb77"),
        ("Hermes", "triangle", "2528848069dc960db227e863aae43f051eee13e5fca0c2b70fa4dc2d0482b919"),
    ]

    static let names: [(name: String, color: String?, shape: String)] = [
        ("nova", "hsl(196 68% 58%)", "triangle"),
        ("avery-park", "hsl(0 68% 58%)", "pill"),
        ("agent", "hsl(197 68% 58%)", "pill"),
        ("travel", "hsl(354 68% 58%)", "hexagon"),
        ("Mina Shah", "hsl(93 68% 58%)", "cloud"),
        ("default", nil, "squircle"),
        ("", nil, "circle"),
        ("research-bot-2", "hsl(106 68% 58%)", "pill"),
        ("café", "hsl(321 68% 58%)", "hexagon"),
    ]

    static let darkness: [(color: String, isDark: Bool)] = [
        ("#8b5cf6", false),
        ("#2E3238", true),
        ("hsl(120 68% 58%)", true),
        ("#F2F1EC", false),
        ("#abc", true),
    ]

    static let rings: [(shape: String, count: Int, samples: [(index: Int, x: Double, y: Double)])] = [
        ("circle", 52, [(0, 20.0, 3.8000000000000007), (7, 32.12587412037183, 9.257412936499119), (13, 36.2, 20.0), (26, 20.0, 36.2), (40, 3.9181162396115248, 18.047305779863763), (51, 18.04730577986376, 3.9181162396115248)]),
        ("blob", 52, [(0, 20.0, 2.3000000000000007), (7, 30.46500976654584, 10.728810358616986), (13, 36.7, 20.0), (26, 20.0, 34.3), (40, 5.2869793961512705, 18.213515859090702), (51, 17.92774758144078, 2.933465888413366)]),
        ("squircle", 52, [(0, 20.0, 3.8000000000000007), (7, 34.848691872695014, 6.845206899060843), (13, 36.2, 20.0), (26, 20.0, 36.2), (40, 3.8000855115430276, 18.03297425478052), (51, 18.032974254780513, 3.8000855115430276)]),
        ("pill", 52, [(0, 20.0, 8.48), (7, 32.72326309232668, 8.728172489312007), (13, 36.0, 20.0), (26, 20.0, 31.52), (40, 4.000001308423817, 18.057248427315244), (51, 18.601218753876175, 8.480000004913613)]),
        ("triangle", 52, [(0, 20.0, -3.2085137844431166), (7, 30.275905434377087, 10.896342177951569), (13, 35.18060327240656, 20.0), (26, 20.0, 33.5), (40, 5.651215323300148, 18.257742107725917), (51, 17.56099699608763, -0.08699692746584375)]),
        ("hexagon", 52, [(0, 20.0, 3.799999999999997), (7, 31.071071776406722, 10.191886270326089), (13, 34.02961154130791, 20.0), (26, 20.0, 36.2), (40, 5.970388458692094, 18.296496742816476), (51, 18.161825449343226, 4.861270571639205)]),
        ("cloud", 64, [(0, 11.0, 32.0), (7, 3.7205879027916158, 25.00499410048378), (13, 8.47666422388052, 17.516139310767343), (26, 21.209827882896573, 5.1762539200751245), (40, 38.22794204716679, 17.875582995265184), (63, 12.583333333333336, 32.0)]),
        ("drop", 52, [(0, 20.0, 3.0), (7, 14.833706492977814, 9.762059841237534), (13, 7.960512924893141, 20.749643802157543), (26, 21.291757032486228, 40.44241137998297), (40, 29.999185833502946, 17.03826582536128), (51, 20.0, 3.0)]),
    ]
}
