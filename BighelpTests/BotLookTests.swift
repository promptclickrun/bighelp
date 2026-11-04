import Foundation
import SwiftUI
import Testing
@testable import Bighelp

/// Bot Studio avatars: the bundled catalog draws, a look survives the trip through Hermes'
/// profile, and data from a newer app or catalog reads without failing.
@MainActor
struct BotLookTests {
    @Test func bundledCatalogDecodesEveryBodyAndEveryOutlineDraws() throws {
        let catalog = BotBodyCatalog.bundled
        #expect(catalog.sets.map(\.id) == ["shapes", "hermes", "bighelp", "classics", "bits", "pocket-curios",
                                           "bitty-bots", "thanksgiving", "christmas"])
        #expect(catalog.bodies.count == 100)
        for body in catalog.bodies {
            #expect(body.eyeAnchors.count == 2, "\(body.id)")
            for part in body.parts {
                // A line's box has no width or no height, so check the path, then where it reaches.
                let path = AvatarKitPath.parse(part.d)
                let box = path.boundingRect
                #expect(!path.isEmpty && box.minX >= -10 && box.maxX <= 110 && box.minY >= -10 && box.maxY <= 110,
                        "\(body.id): \(part.d.prefix(40))")
            }
        }
    }

    @Test func seasonalSetsHideAfterTheirLastDay() throws {
        let catalog = BotBodyCatalog.bundled
        let christmas = try #require(catalog.sets.first { $0.id == "christmas" }?.expiresAt)
        #expect(catalog.available(at: christmas.addingTimeInterval(-60)).contains { $0.set.id == "christmas" })
        #expect(!catalog.available(at: christmas).contains { $0.set.id == "christmas" })
        #expect(catalog.available(at: christmas).contains { $0.set.id == "shapes" })
    }

    /// Saved in Hermes' profile beside the picture: Desktop shows the picture, this app the avatar.
    @Test func lookSurvivesHermesProfile() throws {
        let body = try #require(BotBodyCatalog.bundled.body(id: "bitty-bots.brew"))
        var look = BotLook(body: body)
        look.eyes = .wide
        look.tilt = 12
        look.main = "#58C47A"
        look.move = .dance
        let saved = AgentAvatarLook(style: .photo, studio: look)
            .applied(to: ["shape": .string("blobatar:old:round"), "custom": .boolean(false)], profileID: "kai")
        #expect(saved["imageKind"] == .string("photo"), "Desktop shows the picture")
        #expect(saved["shape"] == .string("blobatar:old:round"), "Other keys stay")
        let read = try #require(AgentAvatarLook(namespace: saved))
        #expect(read.studio == look)
        #expect(read.drawsLive)

        // Saving a Hermes face over it takes the Bot Studio avatar out.
        let face = AgentAvatarLook(style: .face, shape: "blobatar:new:boxy").applied(to: saved, profileID: "kai")
        #expect(face["studio"] == nil)
        #expect(AgentAvatarLook(namespace: face)?.studio == nil)
    }

    /// A choice a later app adds, or a number out of range, reads as the default or the nearest value.
    @Test func lookFromANewerAppReads() throws {
        let body = try JSONEncoder().encode(BotBodyCatalog.bundled.bodies[0])
        let json = """
        {"body": \(String(decoding: body, as: UTF8.self)), "eyes": "laser", "move": "moonwalk", "tilt": 99,
         "eyeSize": -3, "main": "not a color", "cheeks": true, "sparkle": true}
        """
        let look = try JSONDecoder().decode(BotLook.self, from: Data(json.utf8))
        #expect(look.eyes == .classic)
        #expect(look.move == .calm, "An unknown move is no move")
        #expect(look.tilt == BotLook.tilts.upperBound)
        #expect(look.eyeSize == BotLook.eyeSizes.lowerBound)
        #expect(look.main == look.body.colors.main)
        #expect(look.cheeks)
    }

    @Test func catalogKeepsTheBodiesThatRead() throws {
        let json = """
        {"schemaVersion": 2, "sets": [{"id": "a", "name": "A", "category": "future"}],
         "bodies": [
           {"id": "a.good", "name": "Good", "set": "a", "parts": [{"d": "M10 10H90V90H10Z", "tone": "glow"}],
            "eyes": [[40, 40, 10], [52, 42, 10]], "colors": {"main": "#3B82F6"}},
           {"id": "a.bad", "name": "Bad", "set": "a", "parts": [], "eyes": [[1, 2, 3]], "colors": {"main": "#000000"}}
         ]}
        """
        let catalog = try #require(BotBodyCatalog.decode(Data(json.utf8)))
        #expect(catalog.bodies.map(\.id) == ["a.good"])
        #expect(catalog.bodies[0].parts[0].tone == .main, "A new tone draws in the main color")
        #expect(catalog.sets[0].category == "future")
        #expect(BotBodyCatalog.decode(Data(#"{"schemaVersion": 3, "sets": [], "bodies": []}"#.utf8)) == nil)
    }

    @Test func lookStoreDrawsBotStudioAvatars() throws {
        let scope = "bot-look-tests-\(UUID().uuidString)"
        let body = try #require(BotBodyCatalog.bundled.body(id: "shapes.peak"))
        let profile = AgentProfile(id: "kai", name: "Kai", role: "", summary: "", instructions: "", isDefault: false,
                                   look: AgentAvatarLook(style: .photo, studio: BotLook(body: body)))
        let photo = AgentProfile(id: "ada", name: "Ada", role: "", summary: "", instructions: "", isDefault: false,
                                 look: .photo)
        AgentLookStore.shared.publish(scope: scope, profiles: [profile, photo])
        let key = CompanionStore.agentKey(agentScope: scope, agentID: "kai")
        #expect(AgentLookStore.shared.looks[key]?.look.studio?.body.id == "shapes.peak")
        #expect(AgentLookStore.shared.looks[CompanionStore.agentKey(agentScope: scope, agentID: "ada")] == nil,
                "A photo stays a picture")
        AgentLookStore.shared.publish(scope: scope, profiles: [])
    }

    /// Bot Studio opens on the body nearest the avatar an agent had before it.
    @Test func studioOpensOnTheNearestBody() throws {
        let face = BotLook.studioStart(for: .look(AgentAvatarLook(style: .face, shape: "blobatar:seed:boxy",
                                                                  color: "hsl(210, 68%, 58%)")))
        #expect(face.body.id == "hermes.boxy")
        #expect(face.main == BotLook.hexColor("hsl(210, 68%, 58%)"))
        let shape = BotLook.studioStart(for: .look(AgentAvatarLook(style: .shape, shape: "triangle", color: "#E5484D")))
        #expect(shape.body.id == "shapes.peak")
        #expect(shape.main == "#E5484D")
        let pinch = BotLook.studioStart(for: .character(CompanionAppearance(character: .lobster, colorHex: "#4FA8F0")))
        #expect(pinch.body.id == "classics.pinch")
        #expect(pinch.main == "#4FA8F0")
        let bit = BotLook.studioStart(for: .character(CompanionAppearance(character: .ghost)))
        #expect(bit.body.id == "bits.boo")
        var saved = BotLook(body: try #require(BotBodyCatalog.bundled.body(id: "christmas.spruce")))
        saved.mirror = true
        #expect(BotLook.studioStart(for: .look(AgentAvatarLook(style: .photo, studio: saved))) == saved)
    }

    /// Dark eyes on most bodies, light ones on a dark body; a picked color wins.
    @Test func eyesStandOutOnTheirBody() throws {
        var look = BotLook(body: try #require(BotBodyCatalog.bundled.body(id: "shapes.peak")))
        for main in ["#E8459A", "#3B82F6", "#F2C94C", "#F4F1EA", "#58C47A"] {
            look.main = main
            #expect(look.resolvedEyeColor == BotLook.darkEyes, "\(main)")
        }
        for main in ["#2E3A59", "#1C1A19", "#5B1A3A"] {
            look.main = main
            #expect(look.resolvedEyeColor == BotLook.lightEyes, "\(main)")
        }
        look.eyeColor = "#0F766E"
        #expect(look.resolvedEyeColor == "#0F766E")
    }

    /// No avatar starts with a move: not a new one, not a surprise, and not one 2.6.58 saved with its
    /// old default. A move the person picks is kept.
    @Test func avatarsStartCalm() throws {
        let body = try #require(BotBodyCatalog.bundled.body(id: "bits.bop"))
        #expect(BotLook(body: body).move == .calm)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            #expect(BotLook.surprise(from: BotBodyCatalog.bundled.bodies, using: &generator)?.move == .calm)
        }
        let saved = try JSONEncoder().encode(body)
        func read(_ extra: String) throws -> BotLook {
            try JSONDecoder().decode(BotLook.self, from: Data(#"{"body": \#(String(decoding: saved, as: UTF8.self))\#(extra)}"#.utf8))
        }
        #expect(try read(#", "move": "bounce""#).move == .calm, "2.6.58 saved its default")
        #expect(try read(#", "move": "dance""#).move == .dance, "A picked move stays")
        #expect(try read(#", "move": "bounce", "version": 2"#).move == .bounce, "Picked since, it stays")
        var picked = BotLook(body: body)
        picked.move = .bounce
        #expect(try JSONDecoder().decode(BotLook.self, from: JSONEncoder().encode(picked)).move == .bounce)
    }

    /// Choices made for one body never carry over to the next.
    @Test func newBodyStartsAsItComes() throws {
        let catalog = BotBodyCatalog.bundled
        var look = BotLook(body: try #require(catalog.body(id: "shapes.peak")))
        look.eyes = .visor
        look.tilt = 20
        look.lean = -15
        look.stretch = 0.8
        look.scale = 1.1
        look.mirror = true
        look.cheeks = true
        look.mouth = .smile
        look.move = .dance
        let mug = try #require(catalog.body(id: "bitty-bots.brew"))
        look.use(mug)
        #expect(look == BotLook(body: mug))
    }

    @Test func surpriseStaysInRange() throws {
        var generator = SystemRandomNumberGenerator()
        let bodies = BotBodyCatalog.bundled.bodies
        for _ in 0..<50 {
            let look = try #require(BotLook.surprise(from: bodies, using: &generator))
            #expect(BotLook.tilts.contains(look.tilt) && BotLook.leans.contains(look.lean))
            #expect(BotLook.stretches.contains(look.stretch) && BotLook.eyeSizes.contains(look.eyeSize))
            #expect(bodies.contains(look.body))
        }
        #expect(BotLook.surprise(from: []) == nil)
    }

    /// The saved picture is a real image at the size the host takes.
    @Test func picturesRender() throws {
        let look = BotLook(body: try #require(BotBodyCatalog.bundled.body(id: "classics.kit")))
        let data = try #require(BotLookRenderer.png(look))
        let image = try #require(UIImage(data: data))
        #expect(image.size.width == CGFloat(BotLookRenderer.pixelDimension))
    }
}
