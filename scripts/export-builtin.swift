import Foundation

// Compile with the unmodified Foundation-only HermesBlobFace.swift and
// HermesShapeFace.swift. The shape drawing below transcribes the resting 2D
// Canvas in HermesFaceViews.swift (40×44 layout, default 52-point ring).
// Faces: blobatar 2.0.0, MIT, Copyright (c) 2026 Alain.
// Shapes: Hermes Agent Bot Mode, MIT, Copyright (c) 2026 Nous Research.
@main
struct ExportBuiltin {
    struct NativeLook: Codable {
        let style: String
        let shape: String
    }

    struct Entry: Codable {
        let id: String
        let name: String
        let file: String
        let nativeLook: NativeLook
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "ExportBuiltin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: export-builtin OUTPUT_DIRECTORY"])
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let faces = root.appendingPathComponent("faces", isDirectory: true)
        try FileManager.default.createDirectory(at: faces, withIntermediateDirectories: true)
        var faceEntries: [Entry] = []
        for kind in HermesBlobFace.Kind.allCases {
            let id = "face-\(kind.rawValue)"
            // Do not add whitespace or alter markup: this is blobatar's exact SVG.
            try HermesBlobFace.render(seed: "agent", kind: kind).svg.write(
                to: faces.appendingPathComponent("\(id).svg"), atomically: true, encoding: .utf8)
            faceEntries.append(Entry(id: id, name: kind.displayName, file: "\(id).svg",
                                     nativeLook: NativeLook(style: "face", shape: "blobatar::\(kind.rawValue)")))
        }
        try encoder.encode(faceEntries).write(to: faces.appendingPathComponent("index.json"))

        let shapes = root.appendingPathComponent("shapes", isDirectory: true)
        try FileManager.default.createDirectory(at: shapes, withIntermediateDirectories: true)
        var shapeEntries: [Entry] = []
        for shape in HermesShapeFace.pickerShapes {
            let id = "shape-\(shape)"
            try shapeSVG(shape).write(to: shapes.appendingPathComponent("\(id).svg"),
                                      atomically: true, encoding: .utf8)
            shapeEntries.append(Entry(id: id, name: HermesShapeFace.displayName(shape), file: "\(id).svg",
                                      nativeLook: NativeLook(style: "shape", shape: shape)))
        }
        try encoder.encode(shapeEntries).write(to: shapes.appendingPathComponent("index.json"))
        FileHandle.standardError.write(Data("Exported \(faceEntries.count) Faces and \(shapeEntries.count) Shapes.\n".utf8))
    }

    static func number(_ value: Double) -> String {
        precondition(value.isFinite, "Non-finite SVG coordinate")
        // Unlike blobatar, the native shape ring is not rounded to two decimals.
        return String(value)
    }

    static func shapeSVG(_ shape: String) -> String {
        let color = HermesShapeFace.primaryColor
        let dark = HermesShapeFace.isDark(color)
        let eye = dark ? "#e8dcc3" : "#000000"
        let eyeOpacity = dark ? "0.95" : "0.85"
        let sparkle = dark ? "#000000" : "#ffffff"
        let sparkleOpacity = dark ? "0.6" : "0.85"
        let ring = HermesShapeFace.ring(shape)
        precondition(!ring.isEmpty)
        let path = ring.enumerated().map { index, point in
            "\(index == 0 ? "M" : "L")\(number(point.0)) \(number(point.1))"
        }.joined() + "Z"
        let eyeY = HermesShapeFace.eyeLine(shape)
        // The native triangle extends above y=0. Canvas does not clip its
        // drawing; SVG overflow likewise preserves that existing geometry.
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 40 44\" overflow=\"visible\"><path fill=\"\(color)\" d=\"\(path)\"/>"
        for x in [15.4, 24.6] {
            svg += "<ellipse cx=\"\(number(x))\" cy=\"\(number(eyeY))\" rx=\"2.2\" ry=\"2.3\" fill=\"\(eye)\" fill-opacity=\"\(eyeOpacity)\"/>"
            svg += "<circle cx=\"\(number(x - 0.6))\" cy=\"\(number(eyeY - 0.7))\" r=\"0.65\" fill=\"\(sparkle)\" fill-opacity=\"\(sparkleOpacity)\"/>"
        }
        return svg + "</svg>"
    }
}
