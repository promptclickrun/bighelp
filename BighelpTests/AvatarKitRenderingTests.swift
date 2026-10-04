import SwiftUI
import Testing
@testable import Bighelp

/// Every kit character draws more than its backdrop: on devices they showed as plain discs.
@MainActor
struct AvatarKitRenderingTests {
    @Test(arguments: CompanionCharacter.allCases)
    func characterDrawsItsBody(_ character: CompanionCharacter) throws {
        let kit = try #require(AvatarKit.bundled)
        let art = try #require(kit.character(character.rawValue))
        let colors = AvatarKitColors(character: art)
        let renderer = ImageRenderer(content: AvatarKitView(kit: kit, art: art, colors: colors, isAnimating: false,
                                                            showsBackground: false).frame(width: 100, height: 100))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let pixels = try #require(Self.rgba(image))
        let drawn = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 32 }.count
        #expect(drawn > 600, "\(character.rawValue) drew \(drawn) pixels")
        var distinct = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            distinct.insert(UInt32(pixels[index] >> 4) << 8 | UInt32(pixels[index + 1] >> 4) << 4 | UInt32(pixels[index + 2] >> 4))
        }
        #expect(distinct.count >= 3, "\(character.rawValue) has \(distinct.count) colors")
    }

    @Test func catalogCharactersDrawTheirBodies() throws {
        let kit = try #require(AvatarKitLibrary.bundledKit)
        for art in kit.characters {
            let renderer = ImageRenderer(content: AvatarKitView(kit: kit, art: art, colors: AvatarKitColors(character: art),
                                                                isAnimating: false).frame(width: 100, height: 100))
            renderer.scale = 1
            let pixels = try #require(renderer.cgImage.flatMap(Self.rgba))
            let drawn = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 32 }.count
            #expect(drawn > 600, "\(art.id) drew \(drawn) pixels")
            #expect(Self.distinctColors(pixels) >= 3, "\(art.id) draws in its own colors, not one silhouette")
        }
    }

    /// The color check that, failing on one iPhone, drew every avatar in the fallback red.
    @Test func colorCodesReadTheSameEverywhere() {
        #expect(CompanionAppearance.validatedColorHex("#f28b32") == "#F28B32")
        #expect(CompanionAppearance.validatedColorHex(" F28B32\n") == "#F28B32")
        for bad in ["#F28B3", "#F28B32FF", "#GG8B32", "", "#", "＃F28B32", "#F28B 2"] {
            #expect(CompanionAppearance.validatedColorHex(bad) == nil, "\(bad)")
        }
        let color = CompanionColor.components("#F28B32")
        #expect(color.red == 242.0 / 255 && color.green == 139.0 / 255 && color.blue == 50.0 / 255)
        #expect(CompanionColor.components("nonsense") == CompanionColor.components(CompanionAppearance.fallbackColorHex))
        #expect(CompanionAppearance.validatedColorway("sunset-2") == "sunset-2")
        #expect(CompanionAppearance.validatedColorway("Sunset") == nil)
    }

    static func distinctColors(_ pixels: [UInt8]) -> Int {
        var distinct = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            distinct.insert(UInt32(pixels[index] >> 4) << 8 | UInt32(pixels[index + 1] >> 4) << 4 | UInt32(pixels[index + 2] >> 4))
        }
        return distinct.count
    }

    static func rgba(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? data : nil
    }
}
