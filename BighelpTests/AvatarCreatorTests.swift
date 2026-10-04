import Foundation
import Testing
import UIKit
@testable import Bighelp

@MainActor
struct AvatarCreatorTests {
    @Test func looksSavedBeforeTheCreatorStillLoad() throws {
        let saved = Data(##"{"character":"pip","colorHex":"#3366AA","matchesTheme":false}"##.utf8)
        let look = try JSONDecoder().decode(CompanionAppearance.self, from: saved)
        #expect(look.character == .octopus)
        #expect(look.eyeStyle == nil && look.eyeColorHex == nil && look.topper == nil)
        #expect(look.pattern == nil && look.vibe == nil)
    }

    @Test func creatorChoicesRoundTripAndUnknownValuesFallBack() throws {
        let look = CompanionAppearance(character: .cat, colorHex: "#2bb3b1", matchesTheme: false,
            eyeStyle: .venom, eyeColorHex: "c2185b", topper: .crown, pattern: .hex, vibe: .dancer)
        let restored = try JSONDecoder().decode(CompanionAppearance.self, from: JSONEncoder().encode(look))
        #expect(restored == look)
        #expect(restored.colorHex == "#2BB3B1")
        #expect(restored.eyeColorHex == "#C2185B")

        // A newer build's option must not cost this build the whole pet.
        let future = Data(##"{"character":"sol","colorHex":"#F6C445","matchesTheme":false,"eyeStyle":"laser","topper":"wizardHat","pattern":"tartan","vibe":"moonwalk","eyeColorHex":"not-a-color"}"##.utf8)
        let lenient = try JSONDecoder().decode(CompanionAppearance.self, from: future)
        #expect(lenient.character == .dragon)
        #expect(lenient.eyeStyle == nil && lenient.topper == nil && lenient.pattern == nil)
        #expect(lenient.vibe == nil && lenient.eyeColorHex == nil)
    }

    @Test func agentCompanionKeepsEveryCreatorChoice() {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        let look = CompanionAppearance(character: .owl, colorHex: "#7B4FD6", matchesTheme: false,
            eyeStyle: .scowl, topper: .catEars, pattern: .camo, vibe: .sleepy)
        store.setOverride(look, for: "host:agent")
        #expect(store.override(for: "host:agent") == look)
        #expect(CompanionStore(defaults: defaults).override(for: "host:agent") == look)
    }

    /// A Bit's face parts are part of its look. Dropping them showed the Bit's
    /// own halo in chat after you picked a headset.
    @Test func agentCompanionKeepsABitsFaceParts() {
        let defaults = isolatedDefaults()
        let store = CompanionStore(defaults: defaults)
        let look = CompanionAppearance(character: .cloud, colorHex: "#FF7A70", matchesTheme: false,
            bitEyes: .visor, bitMouth: .cat, bitAccessory: .headset, showsCheeks: false)
        store.setOverride(look, for: "host:agent")
        #expect(store.override(for: "host:agent") == look)
        #expect(CompanionStore(defaults: defaults).override(for: "host:agent") == look)

        var swapped = look
        swapped.bitAccessory = .crown
        store.setOverride(swapped, for: "host:agent")
        #expect(store.override(for: "host:agent")?.bitAccessory == .crown)
    }

    @Test func eyesStayReadableOnAnyBodyColor() {
        // Ink eyes vanish on a charcoal body; snow eyes on a snow body.
        #expect(CompanionAvatar.readableEyeColor(authored: "#16181B", body: "#2E3238") == "#F5F6F4")
        #expect(CompanionAvatar.readableEyeColor(authored: "#F5F6F4", body: "#F2F1EC") == "#16181B")
        // A readable authored color is kept as designed.
        #expect(CompanionAvatar.readableEyeColor(authored: "#16181B", body: "#F6C445") == "#16181B")
        #expect(CompanionAvatar.readableEyeColor(authored: "#F5F6F4", body: "#1E7A4E") == "#F5F6F4")
    }

    @Test func catalogCharactersOfferCharacterColorAndMoves() throws {
        let entries = AvatarCatalog.bundled.avatars(in: .bighelp, at: .now)
        #expect(entries.count >= 10, "The shipped catalog has bighelp's characters")
        let model = AvatarCreatorModel(appearance: CompanionAppearance(character: .lobster))
        #expect(model.tabs == [.character, .color, .extras, .moves], "An older bundled look keeps its tabs")
        model.tab = .extras
        model.select(try #require(entries.first))
        #expect(model.tabs == [.character, .color, .moves])
        #expect(model.tab == .character)
        #expect(model.appearance.catalogAvatar?.id == entries.first?.id)
        #expect(model.appearance.kitArt != nil, "It draws from the shipped pack with nothing downloaded")
    }

    @Test func categoriesAndRandomizeInEach() {
        let entries = AvatarCatalog.bundled.avatars(in: .bighelp, at: .now)
        let model = AvatarCreatorModel(appearance: CompanionAppearance(character: .lobster, matchesTheme: true))
        model.selectColor("#3F6FD8")
        #expect(!model.appearance.matchesTheme && model.appearance.colorHex == "#3F6FD8")
        model.selectThemeColor()
        #expect(model.appearance.matchesTheme)
        for _ in 0..<20 {
            let before = model.appearance.catalogAvatar?.id
            model.shuffle(from: entries)
            #expect(model.appearance.catalogAvatar?.id != before)
            #expect(!model.appearance.matchesTheme)
            #expect(model.tabs.contains(model.tab))
        }
        model.select(.hermes)
        #expect(model.style == .face && model.category == .hermes)
        model.style = .shapes
        let shape = model.shape
        model.randomizeShape()
        #expect(model.shape != shape && HermesShapeFace.pickerShapes.contains(model.shape))
        model.select(.other)
        #expect(model.style == .catalog && model.catalogGroup == .other && model.category == .other)
        model.select(.petdex)
        #expect(model.style == .pets)
        model.select(.bighelp)
        #expect(model.style == .catalog && model.category == .bighelp)
    }

    @Test func newAgentsCloneTheDefaultAgentUnlessCloningIsUnavailable() async throws {
        let store = AgentDirectoryStore(
            client: AgentDirectoryFixtureClient(profiles: [.financeFixture, .defaultFixture]),
            defaults: isolatedDefaults()
        )
        try await store.load()
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor(),
                                               profileCloneSupport: .nativeBundleOnly)
        #expect(model.draft.cloneSourceProfileID == AgentProfile.defaultFixture.id)
        #expect(model.cloneSourceName == AgentProfile.defaultFixture.name)
        #expect(!model.draft.skipBundledSkills)
        #expect(!model.hasUnsavedChanges)
        model.selectCloneSource(nil)
        #expect(model.cloneSourceName == nil)

        let unsupported = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor())
        #expect(unsupported.draft.cloneSourceProfileID == nil)
        let editing = AgentEditorModel.editing(.financeFixture, store: store, processor: AvatarImageProcessor())
        #expect(editing.draft.cloneSourceProfileID == nil && editing.cloneSourceName == nil)
    }

    @Test func creatorLookTravelsWithItsAvatarUntilRemoved() async throws {
        let store = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: []), defaults: isolatedDefaults())
        let model = AgentEditorModel.creating(store: store, processor: AvatarImageProcessor())
        let png = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let look = CompanionAppearance(character: .fox, colorHex: "#9B87F5", matchesTheme: false, vibe: .bouncy)
        try await model.importCompanionAvatar(data: png, appearance: look)
        #expect(model.selectedCompanionAppearance == look)
        #expect(model.selectedCompanionCharacter == .fox)
        try await model.importAvatar(data: png)
        #expect(model.selectedCompanionAppearance == nil)
        try await model.importCompanionAvatar(data: png, appearance: look)
        model.removeAvatar()
        #expect(model.selectedCompanionAppearance == nil && model.pendingAvatar == nil)
    }

    /// Chats draw an agent's saved character ahead of its picture. Saving a
    /// pet, face, shape or photo over a character must retire the character,
    /// or new chats keep showing it while the editor shows the new avatar.
    @Test func savingAnotherKindOfAvatarRetiresTheOldCharacter() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
                                        defaults: isolatedDefaults())
        try await store.load()
        let companions = CompanionStore(defaults: isolatedDefaults())
        let pets = PetAvatarStore(defaults: isolatedDefaults(), directory: directory.appending(path: "pets"))
        let key = CompanionStore.agentKey(agentScope: "scope", agentID: AgentProfile.financeFixture.id)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let fox = CompanionAppearance(character: .fox, colorHex: "#9B87F5", matchesTheme: false, vibe: .bouncy)

        let first = AgentEditorModel.editing(.financeFixture, store: store, processor: AvatarImageProcessor(),
                                             avatarDirectory: directory)
        try await first.importCompanionAvatar(data: png, appearance: fox)
        let saved = try await first.save()
        first.applySavedLook(companions: companions, pets: pets, key: CompanionStore.agentKey(agentScope: "scope", agentID: saved.id))
        #expect(companions.override(for: key) == fox)

        let unchanged = AgentEditorModel.editing(saved, store: store, processor: AvatarImageProcessor(),
                                                 avatarDirectory: directory)
        unchanged.draft.role = "Keeps the books"
        _ = try await unchanged.save()
        unchanged.applySavedLook(companions: companions, pets: pets, key: key)
        #expect(companions.override(for: key) == fox)

        // A petdex pet replaces the character, and its moves play in chats.
        let pip = PetdexFixtures.pets[0]
        let pet = AgentEditorModel.editing(saved, store: store, processor: AvatarImageProcessor(),
                                           avatarDirectory: directory)
        try await pet.importPetAvatar(data: png, pet: pip)
        _ = try await pet.save()
        pet.applySavedLook(companions: companions, pets: pets, key: key)
        #expect(companions.override(for: key) == nil)
        for _ in 0..<400 where pets.slug(for: key) == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(pets.slug(for: key) == pip.slug)
        #expect(pets.frames(for: key, move: .run)?.count == PetdexSprite.framesPerMove)

        // A face replaces the pet.
        let face = AgentEditorModel.editing(saved, store: store, processor: AvatarImageProcessor(),
                                            avatarDirectory: directory)
        try await face.importLookAvatar(data: png, look: AgentAvatarLook(style: .face, shape: "blobatar"))
        _ = try await face.save()
        face.applySavedLook(companions: companions, pets: pets, key: key)
        #expect(pets.slug(for: key) == nil)
        #expect(pets.frames(for: key, move: .idle) == nil)

        companions.setOverride(fox, for: key)
        let removed = AgentEditorModel.editing(saved, store: store, processor: AvatarImageProcessor(),
                                               avatarDirectory: directory)
        removed.removeAvatar()
        _ = try await removed.save()
        removed.applySavedLook(companions: companions, pets: pets, key: key)
        #expect(companions.override(for: key) == nil)
    }
}

/// Face and Shape colors: saturation down to gray keeps the hue and brightness.
struct AvatarColorAdjustTests {
    @Test func saturationRunsFromGrayToVivid() {
        #expect(abs(AvatarColorAdjust.saturation(of: "#FF0000") - 1) < 0.01)
        #expect(AvatarColorAdjust.color("#FF0000", saturation: 0) == "#FFFFFF", "Gray at full brightness")
        #expect(AvatarColorAdjust.color("#804040", saturation: 0) == "#808080", "Gray, same brightness")
        #expect(AvatarColorAdjust.saturation(of: AvatarColorAdjust.color("#3366CC", saturation: 0.25)) > 0.2)
        #expect(AvatarColorAdjust.saturation(of: "hsl(210, 80%, 50%)") > 0.5, "Hermes's hsl() colors read too")
    }
}
