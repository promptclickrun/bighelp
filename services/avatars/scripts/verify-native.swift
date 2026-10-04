import AppKit
import SwiftUI

// Test-only hex adapter; production uses CompanionColor for the same #RRGGBB values.
extension Color {
    init(buddyHex hex: String) {
        let value = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16)!
        self.init(red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255)
    }
}

@main
struct NativeKitProbe {
    @MainActor
    static func main() throws {
        let kit = try JSONDecoder().decode(AvatarKit.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checked = 0
        for character in kit.characters {
            var palette = AvatarKitColors(character: character)
            func render(_ palette: AvatarKitColors, frame: AvatarKitFrame = AvatarKitFrame(animates: false)) throws -> Data {
                let renderer = ImageRenderer(content: Canvas { context, size in
                    AvatarKitRenderer.draw(character, kit: kit, colors: palette,
                                           frame: frame, in: context, size: size)
                }.frame(width: 256, height: 256))
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    fatalError("No native render for \(character.id)")
                }
                return png
            }
            let original = try render(palette)
            palette.primary = "#FF00AA"
            let changed = try render(palette)
            precondition(original != changed, "Primary color is not editable for \(character.id)")
            try original.write(to: output.appendingPathComponent("\(character.id)-original.png"))
            try changed.write(to: output.appendingPathComponent("\(character.id)-custom.png"))
            if character.id.hasPrefix("bighelp-") || character.id.hasPrefix("halloween-") {
                for state in kit.states {
                    let first = try render(palette, frame: AvatarKitFrame(state: state, time: 0.17))
                    let second = try render(palette, frame: AvatarKitFrame(state: state, time: 0.73))
                    precondition(first != second, "Animation does not change for \(character.id)/\(state)")
                }
            }
            checked += 1
        }
        print("PASS: decoded and rendered \(checked) characters with the app's AvatarKit decoder and renderer; primary-color override changes every rendered PNG.")
    }
}
