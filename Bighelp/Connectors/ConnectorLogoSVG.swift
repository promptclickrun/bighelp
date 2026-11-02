import CoreGraphics
import Foundation
import ImageIO

/// Draws an app's logo from SVG, the format Hermes' connector catalog and Composio's catalog
/// link to. iOS has no SVG decoder for downloaded files, so every logo showed the placeholder.
/// This draws the part of SVG logos use: shapes and paths, groups and transforms, solid and
/// gradient fills, strokes, opacity, clip paths, masks as clips, and embedded PNG or JPEG pictures.
/// It never loads anything: external references, scripts, styles sheets, text and filters are
/// skipped, and the file, its elements and its nesting are bounded.
enum ConnectorLogoSVG {
    static let maximumBytes = 524_288
    static let maximumElements = 6_000
    static let maximumDepth = 48

    /// The logo in a transparent square `pixels` wide, or nil when it isn't an SVG this can draw.
    static func render(_ data: Data, pixels: Int) -> CGImage? {
        guard data.count <= maximumBytes, (16...1_024).contains(pixels), let root = SVGTree.parse(data),
              root.name == "svg" else { return nil }
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // SVG's y axis points down.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: 1, y: -1)
        var painter = SVGPainter(root: root, context: context)
        let side = CGFloat(pixels)
        let box = root.viewBox ?? CGRect(x: 0, y: 0, width: root.length("width") ?? side, height: root.length("height") ?? side)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(side / box.width, side / box.height)
        context.translateBy(x: (side - box.width * scale) / 2, y: (side - box.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        painter.drawChildren(of: root, style: SVGStyle())
        guard painter.drewSomething else { return nil }
        return context.makeImage()
    }
}

// MARK: - Tree

struct SVGNode {
    let name: String
    let attributes: [String: String]
    var children: [SVGNode] = []

    func attribute(_ key: String) -> String? {
        if let style = attributes["style"], let value = SVGNode.declarations(style)[key] { return value }
        return attributes[key]
    }

    func number(_ key: String) -> CGFloat? { attributes[key].flatMap(SVGNode.number) }

    func length(_ key: String) -> CGFloat? {
        guard let text = attributes[key], !text.hasSuffix("%") else { return nil }
        return SVGNode.number(text.replacingOccurrences(of: "px", with: ""))
    }

    var viewBox: CGRect? {
        guard let values = attributes["viewBox"].map(SVGNumbers.list), values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    static func number(_ text: String) -> CGFloat? {
        Double(text.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
    }

    static func declarations(_ style: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in style.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}

enum SVGTree {
    /// The document's root element, or nil for anything that isn't well-formed or goes past the bounds.
    static func parse(_ data: Data) -> SVGNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse(), !builder.failed else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [SVGNode] = []
        var root: SVGNode?
        var count = 0
        var failed = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            count += 1
            guard count <= ConnectorLogoSVG.maximumElements, stack.count < ConnectorLogoSVG.maximumDepth else {
                failed = true
                parser.abortParsing()
                return
            }
            // `svg:path` and `path` are the same element; `xlink:href` keeps its prefix.
            let local = name.split(separator: ":").last.map(String.init) ?? name
            stack.append(SVGNode(name: local, attributes: attributes))
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard let node = stack.popLast() else { return }
            if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred error: any Error) { failed = true }
    }
}

// MARK: - Style

enum SVGPaint: Equatable {
    case none
    case color(CGColor)
    case reference(String)
}

struct SVGStyle {
    var fill: SVGPaint = .color(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    var fillOpacity: CGFloat = 1
    var evenOddFill = false
    var stroke: SVGPaint = .none
    var strokeOpacity: CGFloat = 1
    var strokeWidth: CGFloat = 1
    var lineCap = CGLineCap.butt
    var lineJoin = CGLineJoin.miter
    var color = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// This element's own style over what it inherits.
    func applying(_ node: SVGNode) -> SVGStyle {
        var style = self
        if let value = node.attribute("color"), let color = SVGColor.parse(value, current: style.color) { style.color = color }
        if let value = node.attribute("fill") { style.fill = SVGColor.paint(value, current: style.color) ?? style.fill }
        if let value = node.attribute("stroke") { style.stroke = SVGColor.paint(value, current: style.color) ?? style.stroke }
        if let value = node.attribute("fill-opacity").flatMap(SVGColor.fraction) { style.fillOpacity = value }
        if let value = node.attribute("stroke-opacity").flatMap(SVGColor.fraction) { style.strokeOpacity = value }
        if let value = node.attribute("stroke-width").flatMap({ SVGNode.number($0.replacingOccurrences(of: "px", with: "")) }) {
            style.strokeWidth = max(0, value)
        }
        if let value = node.attribute("fill-rule") { style.evenOddFill = value == "evenodd" }
        switch node.attribute("stroke-linecap") {
        case "round": style.lineCap = .round
        case "square": style.lineCap = .square
        case "butt": style.lineCap = .butt
        default: break
        }
        switch node.attribute("stroke-linejoin") {
        case "round": style.lineJoin = .round
        case "bevel": style.lineJoin = .bevel
        case "miter": style.lineJoin = .miter
        default: break
        }
        return style
    }
}

enum SVGColor {
    static func paint(_ text: String, current: CGColor) -> SVGPaint? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value == "none" || value == "transparent" { return SVGPaint.none }
        if value.hasPrefix("url(") {
            guard let start = value.firstIndex(of: "#"), let end = value.firstIndex(of: ")"), start < end else { return SVGPaint.none }
            return .reference(String(value[value.index(after: start)..<end]))
        }
        return parse(value, current: current).map(SVGPaint.color)
    }

    static func parse(_ text: String, current: CGColor) -> CGColor? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "currentcolor" { return current }
        if value.hasPrefix("#") { return hex(String(value.dropFirst())) }
        if value.hasPrefix("rgb") {
            guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else { return nil }
            let parts = value[value.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            guard parts.count >= 3 else { return nil }
            func channel(_ part: Substring) -> CGFloat? {
                if part.hasSuffix("%") { return SVGNode.number(String(part.dropLast())).map { $0 / 100 } }
                return SVGNode.number(String(part)).map { $0 / 255 }
            }
            guard let red = channel(parts[0]), let green = channel(parts[1]), let blue = channel(parts[2]) else { return nil }
            let alpha = parts.count > 3 ? fraction(String(parts[3])) ?? 1 : 1
            return CGColor(srgbRed: clamp(red), green: clamp(green), blue: clamp(blue), alpha: alpha)
        }
        return named[value].flatMap(hex)
    }

    /// `0.5` or `50%`, kept between 0 and 1.
    static func fraction(_ text: String) -> CGFloat? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("%") { return SVGNode.number(String(value.dropLast())).map { clamp($0 / 100) } }
        return SVGNode.number(value).map(clamp)
    }

    private static func hex(_ digits: String) -> CGColor? {
        let bytes = Array(digits.utf8)
        guard [3, 4, 6, 8].contains(bytes.count), bytes.allSatisfy(ASCIIText.isHexDigit) else { return nil }
        let values = bytes.map { CGFloat(ASCIIText.hexValue($0)) }
        if bytes.count <= 4 {
            return CGColor(srgbRed: values[0] / 15, green: values[1] / 15, blue: values[2] / 15,
                           alpha: bytes.count == 4 ? values[3] / 15 : 1)
        }
        func pair(_ index: Int) -> CGFloat { (values[index] * 16 + values[index + 1]) / 255 }
        return CGColor(srgbRed: pair(0), green: pair(2), blue: pair(4), alpha: bytes.count == 8 ? pair(6) : 1)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    private static let named: [String: String] = [
        "black": "000000", "white": "ffffff", "red": "ff0000", "green": "008000", "blue": "0000ff",
        "yellow": "ffff00", "orange": "ffa500", "purple": "800080", "gray": "808080", "grey": "808080",
        "silver": "c0c0c0", "navy": "000080", "teal": "008080", "lime": "00ff00", "aqua": "00ffff",
        "cyan": "00ffff", "magenta": "ff00ff", "fuchsia": "ff00ff", "maroon": "800000", "olive": "808000",
    ]
}

// MARK: - Numbers and transforms

enum SVGNumbers {
    /// Numbers in an attribute, however they're separated: `0 0 24 24`, `1,2`, `-1-2.5.5`.
    static func list(_ text: String) -> [CGFloat] {
        var scanner = SVGNumberScanner(text)
        var values: [CGFloat] = []
        while let value = scanner.number() { values.append(value) }
        return values
    }

    static func transform(_ text: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t"))
            let values = list(String(rest[rest.index(after: open)..<close]))
            var step = CGAffineTransform.identity
            switch (name, values.count) {
            case ("matrix", 6): step = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            case ("translate", 1): step = CGAffineTransform(translationX: values[0], y: 0)
            case ("translate", 2): step = CGAffineTransform(translationX: values[0], y: values[1])
            case ("scale", 1): step = CGAffineTransform(scaleX: values[0], y: values[0])
            case ("scale", 2): step = CGAffineTransform(scaleX: values[0], y: values[1])
            case ("rotate", 1): step = CGAffineTransform(rotationAngle: values[0] * .pi / 180)
            case ("rotate", 3):
                step = CGAffineTransform(translationX: values[1], y: values[2]).rotated(by: values[0] * .pi / 180)
                    .translatedBy(x: -values[1], y: -values[2])
            case ("skewX", 1): step = CGAffineTransform(a: 1, b: 0, c: tan(values[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewY", 1): step = CGAffineTransform(a: 1, b: tan(values[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: break
            }
            // Listed transforms apply right to left: the first is outermost.
            result = step.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}

struct SVGNumberScanner {
    private let bytes: [UInt8]
    private(set) var index = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    var isAtEnd: Bool { mutating get { skipSeparators(); return index >= bytes.count } }

    mutating func peekCommand() -> UInt8? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        let byte = bytes[index]
        return (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) ? (byte == 0x65 || byte == 0x45 ? nil : byte) : nil
    }

    mutating func advance() { index += 1 }

    /// An arc's flag: one digit, which may run straight into the next number (`a4 4 0 014 4`).
    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count, bytes[index] == 0x30 || bytes[index] == 0x31 else { return nil }
        defer { index += 1 }
        return bytes[index] == 0x31
    }

    mutating func number() -> CGFloat? {
        skipSeparators()
        let start = index
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
        var digits = 0, sawDot = false
        while index < bytes.count {
            let byte = bytes[index]
            if ASCIIText.isDigit(byte) { digits += 1; index += 1 }
            else if byte == 0x2E, !sawDot { sawDot = true; index += 1 }
            else { break }
        }
        guard digits > 0 else { index = start; return nil }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            var probe = index + 1
            if probe < bytes.count, bytes[probe] == 0x2B || bytes[probe] == 0x2D { probe += 1 }
            if probe < bytes.count, ASCIIText.isDigit(bytes[probe]) {
                index = probe
                while index < bytes.count, ASCIIText.isDigit(bytes[index]) { index += 1 }
            }
        }
        return Double(String(decoding: bytes[start..<index], as: UTF8.self)).map { CGFloat($0) }
    }

    private mutating func skipSeparators() {
        while index < bytes.count, ASCIIText.isSpace(bytes[index]) || bytes[index] == 0x2C { index += 1 }
    }
}

// MARK: - Path data

enum SVGPathParser {
    static let maximumBytes = 262_144

    /// All of SVG's path commands, absolute and relative. Stops at the first thing it can't read,
    /// keeping what came before, as browsers do.
    static func path(_ data: String) -> CGPath {
        let path = CGMutablePath()
        guard data.utf8.count <= maximumBytes else { return path }
        var scanner = SVGNumberScanner(data)
        var command: UInt8 = 0x4D // M
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastWasCubic = false, lastWasQuad = false
        while !scanner.isAtEnd {
            if let next = scanner.peekCommand() { command = next; scanner.advance() }
            else if command == 0x5A || command == 0x7A { return path }
            let relative = (0x61...0x7A).contains(command)
            let base = relative ? current : .zero
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }
            var cubic = false, quad = false
            switch command | 0x20 {
            case 0x6D: // m
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y); start = current
                path.move(to: current)
                command = relative ? 0x6C : 0x4C
            case 0x6C: // l
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                addLine(path, current)
            case 0x68: // h
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                addLine(path, current)
            case 0x76: // v
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                addLine(path, current)
            case 0x63, 0x73: // c, s
                var control1: CGPoint
                if command | 0x20 == 0x63 {
                    guard let x1 = scanner.number(), let y1 = scanner.number() else { return path }
                    control1 = point(x1, y1)
                } else {
                    control1 = lastWasCubic ? reflect(lastControl, around: current) : current
                }
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(),
                      let y = scanner.number() else { return path }
                let control2 = point(x2, y2), end = point(x, y)
                ensureStart(path, current)
                path.addCurve(to: end, control1: control1, control2: control2)
                lastControl = control2; current = end; cubic = true
            case 0x71, 0x74: // q, t
                var control: CGPoint
                if command | 0x20 == 0x71 {
                    guard let x1 = scanner.number(), let y1 = scanner.number() else { return path }
                    control = point(x1, y1)
                } else {
                    control = lastWasQuad ? reflect(lastControl, around: current) : current
                }
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let end = point(x, y)
                ensureStart(path, current)
                path.addQuadCurve(to: end, control: control)
                lastControl = control; current = end; quad = true
            case 0x61: // a
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let x = scanner.number(),
                      let y = scanner.number() else { return path }
                let end = point(x, y)
                ensureStart(path, current)
                addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
            case 0x7A: // z
                if !path.isEmpty { path.closeSubpath() }
                current = start
            default:
                return path
            }
            lastWasCubic = cubic
            lastWasQuad = quad
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, around point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    private static func ensureStart(_ path: CGMutablePath, _ point: CGPoint) {
        if path.isEmpty { path.move(to: point) }
    }

    private static func addLine(_ path: CGMutablePath, _ point: CGPoint) {
        if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
    }

    /// SVG's endpoint arc as cubic curves (SVG 1.1, appendix F.6).
    private static func addArc(_ path: CGMutablePath, from start: CGPoint, to end: CGPoint, rx: CGFloat, ry: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, start != end else { path.addLine(to: end); return }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = (large == sweep ? -1.0 : 1.0) * sqrt(max(0, numerator / denominator))
        let cxPrime = coefficient * rx * y1 / ry, cyPrime = -coefficient * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cxPrime - sinPhi * cyPrime + (start.x + end.x) / 2,
                             y: sinPhi * cxPrime + cosPhi * cyPrime + (start.y + end.y) / 2)
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1 - cxPrime) / rx, uy = (y1 - cyPrime) / ry
        let startAngle = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, (-x1 - cxPrime) / rx, (-y1 - cyPrime) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        func mapped(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + rx * cosPhi * x - ry * sinPhi * y, y: center.y + rx * sinPhi * x + ry * cosPhi * y)
        }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 0.001)))
        let step = delta / CGFloat(segments)
        let handle = 4 / 3 * tan(step / 4)
        for index in 0..<segments {
            let a = startAngle + step * CGFloat(index), b = a + step
            path.addCurve(to: index == segments - 1 ? end : mapped(cos(b), sin(b)),
                          control1: mapped(cos(a) - handle * sin(a), sin(a) + handle * cos(a)),
                          control2: mapped(cos(b) + handle * sin(b), sin(b) - handle * cos(b)))
        }
    }
}

// MARK: - Drawing

struct SVGPainter {
    let context: CGContext
    private let definitions: [String: SVGNode]
    private(set) var drewSomething = false
    private var references = 0

    init(root: SVGNode, context: CGContext) {
        self.context = context
        var definitions: [String: SVGNode] = [:]
        func collect(_ node: SVGNode) {
            if let id = node.attributes["id"], definitions[id] == nil { definitions[id] = node }
            node.children.forEach(collect)
        }
        collect(root)
        self.definitions = definitions
    }

    private static let skipped: Set<String> = [
        "defs", "clipPath", "mask", "linearGradient", "radialGradient", "pattern", "symbol", "style", "script",
        "title", "desc", "metadata", "text", "filter", "foreignObject", "marker",
    ]

    mutating func drawChildren(of node: SVGNode, style: SVGStyle) {
        for child in node.children { draw(child, inherited: style) }
    }

    mutating func draw(_ node: SVGNode, inherited: SVGStyle) {
        guard !Self.skipped.contains(node.name), node.attribute("display") != "none",
              node.attribute("visibility") != "hidden" else { return }
        let style = inherited.applying(node)
        let opacity = node.attribute("opacity").flatMap(SVGColor.fraction) ?? 1
        guard opacity > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if let transform = node.attributes["transform"] { context.concatenate(SVGNumbers.transform(transform)) }
        if let clip = reference(node.attribute("clip-path")) ?? reference(node.attribute("mask")) {
            guard applyClip(clip) else { return }
        }
        if opacity < 1 { context.setAlpha(opacity); context.beginTransparencyLayer(auxiliaryInfo: nil) }
        defer { if opacity < 1 { context.endTransparencyLayer() } }

        switch node.name {
        case "svg", "g", "a", "switch":
            drawChildren(of: node, style: style)
        case "use":
            guard references < 64, let id = reference(href(node)), let target = definitions[id] else { return }
            references += 1
            context.translateBy(x: node.number("x") ?? 0, y: node.number("y") ?? 0)
            draw(target, inherited: style)
        case "image":
            drawImage(node)
        default:
            guard let shape = Self.shape(node) else { return }
            fill(shape, style: style)
            stroke(shape, style: style)
        }
    }

    /// The outline of a basic shape or path, in its own coordinates.
    static func shape(_ node: SVGNode) -> CGPath? {
        func value(_ key: String) -> CGFloat { node.length(key) ?? 0 }
        switch node.name {
        case "path":
            return node.attributes["d"].map(SVGPathParser.path)
        case "rect":
            let rect = CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
            guard rect.width > 0, rect.height > 0 else { return nil }
            var rx = node.length("rx") ?? node.length("ry") ?? 0, ry = node.length("ry") ?? node.length("rx") ?? 0
            rx = min(max(0, rx), rect.width / 2); ry = min(max(0, ry), rect.height / 2)
            return rx > 0 && ry > 0 ? CGPath(roundedRect: rect, cornerWidth: rx, cornerHeight: ry, transform: nil) : CGPath(rect: rect, transform: nil)
        case "circle":
            let r = value("r")
            guard r > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: value("cx") - r, y: value("cy") - r, width: r * 2, height: r * 2), transform: nil)
        case "ellipse":
            let rx = value("rx"), ry = value("ry")
            guard rx > 0, ry > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: value("cx") - rx, y: value("cy") - ry, width: rx * 2, height: ry * 2), transform: nil)
        case "line":
            let path = CGMutablePath()
            path.move(to: CGPoint(x: value("x1"), y: value("y1")))
            path.addLine(to: CGPoint(x: value("x2"), y: value("y2")))
            return path
        case "polygon", "polyline":
            let values = SVGNumbers.list(node.attributes["points"] ?? "")
            guard values.count >= 4 else { return nil }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: values[0], y: values[1]))
            var index = 2
            while index + 1 < values.count { path.addLine(to: CGPoint(x: values[index], y: values[index + 1])); index += 2 }
            if node.name == "polygon" { path.closeSubpath() }
            return path
        default:
            return nil
        }
    }

    private mutating func fill(_ shape: CGPath, style: SVGStyle) {
        guard !shape.isEmpty, style.fillOpacity > 0 else { return }
        switch style.fill {
        case .none:
            return
        case .color(let color):
            context.addPath(shape)
            context.setFillColor(color.copy(alpha: color.alpha * style.fillOpacity) ?? color)
            context.fillPath(using: style.evenOddFill ? .evenOdd : .winding)
            drewSomething = true
        case .reference(let id):
            guard let gradient = definitions[id] else { return }
            context.saveGState()
            context.addPath(shape)
            context.clip(using: style.evenOddFill ? .evenOdd : .winding)
            if style.fillOpacity < 1 { context.setAlpha(style.fillOpacity) }
            if paintGradient(gradient, box: shape.boundingBoxOfPath) { drewSomething = true }
            context.restoreGState()
        }
    }

    private mutating func stroke(_ shape: CGPath, style: SVGStyle) {
        guard !shape.isEmpty, style.strokeWidth > 0, style.strokeOpacity > 0 else { return }
        let color: CGColor
        switch style.stroke {
        case .none: return
        case .color(let value): color = value
        case .reference(let id):
            // A gradient stroke draws in its first color.
            guard let first = definitions[id].flatMap({ stops(of: $0).first?.color }) else { return }
            color = first
        }
        context.addPath(shape)
        context.setStrokeColor(color.copy(alpha: color.alpha * style.strokeOpacity) ?? color)
        context.setLineWidth(style.strokeWidth)
        context.setLineCap(style.lineCap)
        context.setLineJoin(style.lineJoin)
        context.strokePath()
        drewSomething = true
    }

    /// Clips to a clip path's shapes, or to a mask's (its painted shapes stand in for its luminance).
    private func applyClip(_ id: String) -> Bool {
        guard let clip = definitions[id], clip.name == "clipPath" || clip.name == "mask" else { return true }
        let path = CGMutablePath()
        var evenOdd = false
        func collect(_ node: SVGNode, transform: CGAffineTransform) {
            var transform = transform
            if let own = node.attributes["transform"] { transform = SVGNumbers.transform(own).concatenating(transform) }
            if node.name == "g" || node.name == "clipPath" || node.name == "mask" {
                node.children.forEach { collect($0, transform: transform) }
            } else if let shape = Self.shape(node) {
                // A mask shows where it's painted light; its black or unpainted shapes hide.
                if clip.name == "mask", ["none", "black", "#000", "#000000"].contains(node.attribute("fill") ?? "") { return }
                evenOdd = evenOdd || node.attribute("clip-rule") == "evenodd"
                path.addPath(shape, transform: transform)
            }
        }
        collect(clip, transform: .identity)
        guard !path.isEmpty else { return false }
        context.addPath(path)
        context.clip(using: evenOdd ? .evenOdd : .winding)
        return true
    }

    private struct Stop { let offset: CGFloat; let color: CGColor }

    private func stops(of gradient: SVGNode, depth: Int = 0) -> [Stop] {
        let own = gradient.children.filter { $0.name == "stop" }.map { stop -> Stop in
            let offset = stop.attribute("offset").flatMap(SVGColor.fraction) ?? 0
            let base = stop.attribute("stop-color").flatMap { SVGColor.parse($0, current: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)) }
                ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            let alpha = stop.attribute("stop-opacity").flatMap(SVGColor.fraction) ?? 1
            return Stop(offset: offset, color: base.copy(alpha: base.alpha * alpha) ?? base)
        }
        if own.isEmpty, depth < 4, let id = reference(href(gradient)), let parent = definitions[id] {
            return stops(of: parent, depth: depth + 1)
        }
        // Offsets never go back.
        var floor: CGFloat = 0
        return own.map { stop in floor = max(floor, stop.offset); return Stop(offset: floor, color: stop.color) }
    }

    private func paintGradient(_ node: SVGNode, box: CGRect) -> Bool {
        let stops = stops(of: node)
        guard let first = stops.first else { return false }
        guard stops.count > 1, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                         colors: stops.map(\.color) as CFArray,
                                                         locations: stops.map(\.offset)) else {
            context.setFillColor(first.color)
            context.fill(box)
            return true
        }
        let userSpace = node.attributes["gradientUnits"] == "userSpaceOnUse"
        func coordinate(_ key: String, _ fallback: CGFloat) -> CGFloat {
            guard let text = node.attributes[key] else { return fallback }
            if text.hasSuffix("%") { return (SVGNode.number(String(text.dropLast())) ?? 0) / 100 }
            return SVGNode.number(text) ?? fallback
        }
        if !userSpace {
            guard box.width > 0, box.height > 0 else { return false }
            context.concatenate(CGAffineTransform(a: box.width, b: 0, c: 0, d: box.height, tx: box.minX, ty: box.minY))
        }
        if let transform = node.attributes["gradientTransform"] { context.concatenate(SVGNumbers.transform(transform)) }
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if node.name == "radialGradient" {
            let cx = coordinate("cx", 0.5), cy = coordinate("cy", 0.5), r = coordinate("r", 0.5)
            let focus = CGPoint(x: coordinate("fx", cx), y: coordinate("fy", cy))
            context.drawRadialGradient(gradient, startCenter: focus, startRadius: 0,
                                       endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: options)
        } else {
            context.drawLinearGradient(gradient, start: CGPoint(x: coordinate("x1", 0), y: coordinate("y1", 0)),
                                       end: CGPoint(x: coordinate("x2", 1), y: coordinate("y2", 0)), options: options)
        }
        return true
    }

    /// Only pictures inside the file (`data:image/png` or `jpeg`); a link out is never followed.
    private mutating func drawImage(_ node: SVGNode) {
        guard let link = href(node), link.hasPrefix("data:image/"), let comma = link.firstIndex(of: ","),
              link[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(link[link.index(after: comma)...]), options: .ignoreUnknownCharacters),
              data.count <= ConnectorLogoSVG.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, type == "public.png" || type == "public.jpeg",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let frame = CGRect(x: node.length("x") ?? 0, y: node.length("y") ?? 0,
                           width: node.length("width") ?? CGFloat(image.width), height: node.length("height") ?? CGFloat(image.height))
        guard frame.width > 0, frame.height > 0 else { return }
        let scale = min(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let target = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        // The context is flipped for SVG; a picture draws the right way up in its own flip.
        context.saveGState()
        context.translateBy(x: 0, y: target.maxY + target.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: target)
        context.restoreGState()
        drewSomething = true
    }

    private func href(_ node: SVGNode) -> String? { node.attributes["href"] ?? node.attributes["xlink:href"] }

    /// `url(#id)` or `#id` to `id`.
    private func reference(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value != "none" else { return nil }
        if value.hasPrefix("url("), let close = value.firstIndex(of: ")") {
            value = String(value[value.index(value.startIndex, offsetBy: 4)..<close]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        }
        guard value.hasPrefix("#") else { return nil }
        return String(value.dropFirst())
    }
}
