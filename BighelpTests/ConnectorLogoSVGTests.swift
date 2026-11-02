import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Bighelp

/// App logos come from the catalogs as SVG, which iOS can't decode by itself (every row showed
/// the placeholder). These are made-up logos that use what real ones do.
struct ConnectorLogoSVGTests {
    private struct Pixel: Equatable { let red, green, blue, alpha: Int }

    /// The color at (x, y) from the top left, in 0…255.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> Pixel {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let index = (y * image.width + x) * 4
        return Pixel(red: Int(bytes[index]), green: Int(bytes[index + 1]), blue: Int(bytes[index + 2]), alpha: Int(bytes[index + 3]))
    }

    private func render(_ svg: String, pixels: Int = 64) -> CGImage? {
        ConnectorLogoSVG.render(Data(svg.utf8), pixels: pixels)
    }

    private func isClose(_ value: Pixel, _ red: Int, _ green: Int, _ blue: Int, alpha: Int = 255, slack: Int = 6) -> Bool {
        abs(value.red - red) <= slack && abs(value.green - green) <= slack && abs(value.blue - blue) <= slack
            && abs(value.alpha - alpha) <= slack
    }

    @Test func nonFiniteLogoNumbersAreRejected() {
        for text in ["nan", "inf", "1e999", "-1e999"] {
            #expect(SVGNode.number(text) == nil)
        }
        var scanner = SVGNumberScanner("1e999")
        #expect(scanner.number() == nil)
    }

    @Test func extremeArcGeometryDoesNotCrash() {
        let path = SVGPathParser.path("M0 0 A1e300 1e300 0 0 1 100 100")
        #expect(!path.isEmpty)
        _ = SVGPathParser.path("M0 0 A1e999 1e999 1e999 0 1 100 100")
    }

    @Test func aFilledShapeDrawsInItsColorTheRightWayUp() throws {
        let image = try #require(render("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" fill="none">
              <rect width="100" height="50" fill="#FF0000"/>
              <path d="M0 50h100v50H0z" fill="rgb(0, 0, 255)"/>
            </svg>
            """))
        #expect(isClose(pixel(image, 32, 8), 255, 0, 0), "The top half is the first rectangle")
        #expect(isClose(pixel(image, 32, 56), 0, 0, 255), "The bottom half is the path")
    }

    @Test func rootFillReachesTheLogoPaths() throws {
        let image = try #require(render("<svg viewBox=\"0 0 10 10\" fill=\"#FF0000\"><path d=\"M0 0h10v10H0z\"/></svg>"))
        #expect(isClose(pixel(image, 32, 32), 255, 0, 0))
    }

    @Test func aClipPathRoundsTheCorners() throws {
        let image = try #require(render("""
            <svg width="128" height="128" viewBox="0 0 512 512" fill="none" xmlns="http://www.w3.org/2000/svg">
              <g clip-path="url(#clip)"><rect width="512" height="512" fill="#533AFD"/></g>
              <defs><clipPath id="clip"><rect width="512" height="512" rx="128" fill="white"/></clipPath></defs>
            </svg>
            """))
        #expect(pixel(image, 0, 0).alpha == 0, "The corner is cut away")
        #expect(isClose(pixel(image, 32, 32), 0x53, 0x3A, 0xFD))
    }

    @Test func anEmbeddedImagePatternDrawsTheBrand() throws {
        let png = Self.redPNG().base64EncodedString()
        let image = try #require(render("""
            <svg viewBox="0 0 10 10"><rect width="10" height="10" fill="url(#brand)"/>
            <defs><pattern id="brand" patternContentUnits="objectBoundingBox" width="1" height="1">
            <use href="#picture" transform="scale(0.25)"/></pattern>
            <image id="picture" width="4" height="4" href="data:image/png;base64,\(png)"/></defs></svg>
            """))
        #expect(isClose(pixel(image, 32, 32), 255, 0, 0))
    }

    @Test func aPatternCannotReferToItselfForever() {
        #expect(render("""
            <svg viewBox="0 0 10 10"><rect width="10" height="10" fill="url(#loop)"/>
            <defs><pattern id="loop" patternContentUnits="objectBoundingBox">
            <rect width="1" height="1" fill="url(#loop)"/></pattern></defs></svg>
            """) == nil)
    }

    @Test func aMaskShowsOnlyWhereItsPainted() throws {
        let image = try #require(render("""
            <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
              <mask id="m" style="mask-type:luminance"><circle cx="25" cy="50" r="20" fill="white"/></mask>
              <g mask="url(#m)"><rect width="100" height="100" fill="#00AA00"/></g>
            </svg>
            """))
        #expect(isClose(pixel(image, 16, 32), 0, 0xAA, 0))
        #expect(pixel(image, 48, 32).alpha == 0, "Outside the mask stays clear")
    }

    @Test func gradientsFillFromStopToStop() throws {
        let image = try #require(render("""
            <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
              <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0">
                <stop offset="0" stop-color="#000000"/><stop offset="100%" stop-color="#FFFFFF"/>
              </linearGradient></defs>
              <rect width="100" height="100" fill="url(#g)"/>
            </svg>
            """))
        let left = pixel(image, 1, 32), right = pixel(image, 62, 32)
        #expect(left.red < 30 && right.red > 225, "Dark on the left, light on the right")
        #expect(left.alpha == 255 && right.alpha == 255)
    }

    @Test func compactPathSyntaxReads() {
        // Arc flags run into the next number, numbers run into each other, and S and T reflect.
        let path = SVGPathParser.path("M10 10a5 5 0 0110 0l-.5.5.5.5S30 30 40 20T60 20h-1e1v10z")
        #expect(!path.isEmpty)
        let box = path.boundingBoxOfPath
        #expect(box.minX >= 9.9 && box.maxX <= 60.1 && box.maxY >= 29.9)
        #expect(SVGNumbers.list("-1-2.5.5,3e1") == [-1, -2.5, 0.5, 30])
    }

    @Test func groupTransformsAndOpacityApply() throws {
        let image = try #require(render("""
            <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
              <g transform="translate(50 0) scale(0.5 1)"><rect width="100" height="100" fill="#000" opacity="0.5"/></g>
            </svg>
            """))
        #expect(pixel(image, 10, 32).alpha == 0, "The left half is empty after the move")
        #expect(abs(pixel(image, 48, 32).alpha - 128) <= 6, "Half opacity")
    }

    @Test func aPictureInsideTheFileDrawsButALinkOutNeverLoads() throws {
        let png = Self.redPNG().base64EncodedString()
        let image = try #require(render("""
            <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
              <image width="10" height="10" href="data:image/png;base64,\(png)"/>
            </svg>
            """))
        #expect(isClose(pixel(image, 32, 32), 255, 0, 0))
        #expect(render("""
            <svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg">
              <image width="10" height="10" href="https://example.com/logo.png"/>
            </svg>
            """) == nil, "Nothing drawable without loading: no logo")
    }

    @Test(arguments: [
        "<svg xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M0 0L10 10\"",  // cut off
        "<html><body>Not found</body></html>",
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><text>Hi</text></svg>",
    ])
    func anythingElseIsNoLogo(_ text: String) {
        #expect(render(text) == nil)
    }

    @Test func aHugeOrDeepFileIsRefused() {
        let deep = String(repeating: "<g>", count: 100) + "<rect width=\"10\" height=\"10\"/>" + String(repeating: "</g>", count: 100)
        #expect(render("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\">\(deep)</svg>") == nil)
        let big = String(repeating: "<rect width=\"1\" height=\"1\"/>", count: 7_000)
        #expect(render("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\">\(big)</svg>") == nil)
    }

    /// The loader picks the SVG drawer or the picture decoder by what the file is.
    @Test func theLoaderDrawsSVGAndPictures() {
        #expect(ConnectorLogoLoader.draw(Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\" fill=\"#fff\"/></svg>".utf8)) != nil)
        #expect(ConnectorLogoLoader.draw(Self.redPNG()) != nil)
        #expect(ConnectorLogoLoader.draw(Data("not a logo".utf8)) == nil)
    }

    /// A black mark on nothing gets a light tile after dark; a colored tile or a light mark doesn't.
    @Test func darkInkIsTold() throws {
        let black = try #require(render("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><circle cx=\"5\" cy=\"5\" r=\"3\"/></svg>"))
        let tile = try #require(render("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\" fill=\"#111\"/><circle cx=\"5\" cy=\"5\" r=\"3\" fill=\"#fff\"/></svg>"))
        let color = try #require(render("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><circle cx=\"5\" cy=\"5\" r=\"3\" fill=\"#36C5F0\"/></svg>"))
        #expect(ConnectorLogoLoader.isDarkInk(black))
        #expect(!ConnectorLogoLoader.isDarkInk(tile))
        #expect(!ConnectorLogoLoader.isDarkInk(color))
    }

    private static func redPNG() -> Data {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
