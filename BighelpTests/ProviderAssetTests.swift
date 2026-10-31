import CryptoKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

struct ProviderAssetTests {
    private let officialAssetNames = [
        "ProviderLogoOpenAI",
        "ProviderLogoAnthropic",
        "ProviderLogoClaude",
        "ProviderLogoCodex",
        "ProviderLogoGoogle",
        "ProviderLogoOpenRouter",
        "ProviderLogoMistral",
        "ProviderLogoLMStudio",
        "ProviderLogoHuggingFace",
        "ProviderLogoVenice",
        "ProviderLogoGitHubCopilot",
    ]

    private let fallbackAssetNames = [
        "ProviderLogoAzure",
        "ProviderLogoBedrock",
        "ProviderLogoCerebras",
        "ProviderLogoCohere",
        "ProviderLogoDeepSeek",
        "ProviderLogoFireworks",
        "ProviderLogoGroq",
        "ProviderLogoMinimax",
        "ProviderLogoMoonshot",
        "ProviderLogoNVIDIA",
        "ProviderLogoNous",
        "ProviderLogoOllama",
        "ProviderLogoPerplexity",
        "ProviderLogoTogether",
        "ProviderLogoXAI",
        "ProviderLogoZAI",
    ]

    @Test func officialProviderAssetsDeclareExplicitAnyAndDarkVectors() throws {
        for assetName in officialAssetNames {
            let imagesetURL = assetCatalogURL
                .appending(path: "\(assetName).imageset", directoryHint: .isDirectory)
            let contentsURL = imagesetURL.appending(path: "Contents.json")
            let data = try Data(contentsOf: contentsURL)
            let object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let images = try #require(object["images"] as? [[String: Any]])
            let anyImage = images.first { $0["appearances"] == nil }
            let darkImage = images.first { image in
                guard let appearances = image["appearances"] as? [[String: String]] else {
                    return false
                }
                return appearances.contains {
                    $0["appearance"] == "luminosity" && $0["value"] == "dark"
                }
            }

            let anyFilename = try #require(anyImage?["filename"] as? String)
            let darkFilename = try #require(darkImage?["filename"] as? String)
            #expect(FileManager.default.fileExists(
                atPath: imagesetURL.appending(path: anyFilename).path(percentEncoded: false)
            ))
            #expect(FileManager.default.fileExists(
                atPath: imagesetURL.appending(path: darkFilename).path(percentEncoded: false)
            ))
            #expect(
                (object["properties"] as? [String: Any])?["preserves-vector-representation"]
                    as? Bool == true
            )
        }
    }

    @Test func fallbackProvidersDoNotShipThirdPartyImagesets() {
        for assetName in fallbackAssetNames {
            let imagesetURL = assetCatalogURL
                .appending(path: "\(assetName).imageset", directoryHint: .isDirectory)
            #expect(!FileManager.default.fileExists(atPath: imagesetURL.path(percentEncoded: false)))
        }
    }

    @Test func registryArtworkMatchesTheCatalogAllowlist() {
        let registeredOfficialAssets = Set(
            AIProviderBrand.allCases.compactMap(\.logoAssetName)
        )

        #expect(registeredOfficialAssets == Set(officialAssetNames))
        #expect(
            AIProviderBrand.allCases.filter { $0.logoAssetName == nil }.count
                == fallbackAssetNames.count + 1
        )
    }

    @Test func copilotCatalogBundlesExactOfficialInvertocatVariants() throws {
        let imagesetURL = assetCatalogURL
            .appending(path: "ProviderLogoGitHubCopilot.imageset", directoryHint: .isDirectory)
        let catalog = try catalogImages(at: imagesetURL)
        let anyFilename = try #require(catalog.anyFilename)
        let darkFilename = try #require(catalog.darkFilename)

        #expect(anyFilename == "ProviderLogoGitHubCopilot-Light.svg")
        #expect(darkFilename == "ProviderLogoGitHubCopilot-Dark.svg")
        #expect(
            try sha256(of: imagesetURL.appending(path: anyFilename))
                == "693d7abe6f899646cc2e96856723b45e95f71885a54910b2749f6decdf7e1ee1"
        )
        #expect(
            try sha256(of: imagesetURL.appending(path: darkFilename))
                == "ccd84c89b1056345608fc3489357f8acc7397e49a3cdc2d418b6c8016911d47b"
        )
    }

    @Test func googleCatalogBundlesExactCurrentGeminiGradientForBothAppearances() throws {
        let imagesetURL = assetCatalogURL
            .appending(path: "ProviderLogoGoogle.imageset", directoryHint: .isDirectory)
        let catalog = try catalogImages(at: imagesetURL)
        let anyFilename = try #require(catalog.anyFilename)
        let darkFilename = try #require(catalog.darkFilename)
        let officialHash = "cda2df6631d5fa227de3fa04ed78cf354f910ba92a9f086e7455655c10ad9d09"

        #expect(anyFilename == "ProviderLogoGoogle-Light.svg")
        #expect(darkFilename == "ProviderLogoGoogle-Dark.svg")
        #expect(try sha256(of: imagesetURL.appending(path: anyFilename)) == officialHash)
        #expect(try sha256(of: imagesetURL.appending(path: darkFilename)) == officialHash)
    }

    @Test func copilotBrandArtworkIsSharedAcrossTypedCallSites() {
        let names: [String?] = [nil, "GitHub Copilot", "GitHub Copilot ACP", "Copilot Adaptive"]
        for context in AIProviderMarkContext.allCases {
            for name in names {
                #expect(AIProviderMarkPresentation.resolve(
                    brand: .githubCopilot, context: context, visibleProviderName: name
                ) == .official(assetName: "ProviderLogoGitHubCopilot"))
            }
        }
    }

    @Test func openAIArtworkUsesFullCanvasOpticalExpansion() {
        let openAI = AIProviderBrand.openAI.officialArtworkGeometry
        let anthropic = AIProviderBrand.anthropic.officialArtworkGeometry
        let copilot = AIProviderBrand.githubCopilot.officialArtworkGeometry

        #expect(openAI == .init(
            insetFraction: 0,
            opticalScale: 2,
            clipsToFrame: false
        ))
        #expect(anthropic == .init(
            insetFraction: 0.10,
            opticalScale: 1,
            clipsToFrame: false
        ))
        #expect(copilot == anthropic)
        #expect(openAI.opticalScale > anthropic.opticalScale)
    }

    @Test func visibleProviderIdentityPreservesAuthoritativeCopilotNamesAndWireIDs() {
        let fixtures = [
            (providerID: "copilot", providerName: "GitHub Copilot"),
            (providerID: "copilot-acp", providerName: "GitHub Copilot ACP"),
            (providerID: "copilot-adaptive", providerName: "Copilot Adaptive"),
            (providerID: "github-copilot", providerName: "My Copilot Gateway"),
        ]

        for fixture in fixtures {
            let identity = AIProviderVisibleIdentity.resolve(
                providerID: fixture.providerID,
                providerName: fixture.providerName
            )

            #expect(identity.rawProviderID == fixture.providerID)
            #expect(identity.visibleProviderName == fixture.providerName)
            #expect(identity.brand == .githubCopilot)
        }
    }

    @Test func visibleProviderIdentityLeavesOtherDisplayNamesUnchanged() {
        let identity = AIProviderVisibleIdentity.resolve(
            providerID: "openai",
            providerName: "My OpenAI Gateway"
        )

        #expect(identity.rawProviderID == "openai")
        #expect(identity.visibleProviderName == "My OpenAI Gateway")
        #expect(identity.brand == .openAI)
    }

    @MainActor
    @Test func copilotRendersDistinctOfficialVectorsInLightAndDarkAppearances() throws {
        let lightAsset = try renderedCopilotAsset(colorScheme: .light)
        let darkAsset = try renderedCopilotAsset(colorScheme: .dark)
        let lightMark = try renderedCopilotMark(colorScheme: .light)
        let darkMark = try renderedCopilotMark(colorScheme: .dark)

        #expect(lightAsset != darkAsset)
        #expect(lightMark != darkMark)
    }

    @MainActor
    @Test func copilotSharedArtworkRendersInEveryTypedCallSite() throws {
        for context in AIProviderMarkContext.allCases {
            let image = try renderedProviderMark(
                providerID: "github-copilot",
                providerName: "GitHub Copilot",
                context: context,
                colorScheme: .light
            )
            let topCenterAlpha = try rgbaPixels(in: image).pixel(x: 22, y: 4).alpha

            #expect(topCenterAlpha == 0)
        }
    }

    @MainActor
    @Test func copilotProviderVariantsShareArtworkWithoutRewritingNames() throws {
        for (id, name) in [("copilot", "GitHub Copilot"),
                           ("copilot-acp", "GitHub Copilot ACP"),
                           ("copilot-adaptive", "Copilot Adaptive")] {
            let identity = AIProviderVisibleIdentity.resolve(providerID: id, providerName: name)
            let image = try renderedProviderMark(
                providerID: id, providerName: name,
                context: .chatQuickChoice, colorScheme: .light
            )
            let topCenterAlpha = try rgbaPixels(in: image).pixel(x: 22, y: 4).alpha
            #expect(topCenterAlpha == 0)
            #expect(identity.rawProviderID == id)
            #expect(identity.visibleProviderName == name)
        }
    }

    @MainActor
    @Test func mistralRendersTheOfficialGradientWithoutACircularWell() throws {
        for colorScheme in [ColorScheme.light, .dark] {
            let image = try renderedProviderMark(
                providerID: "mistral",
                providerName: "Mistral AI",
                colorScheme: colorScheme
            )
            let pixels = try rgbaPixels(in: image)

            #expect(pixels.pixel(x: 22, y: 4).alpha == 0)
            #expect(pixels.containsChromaticOpaquePixel)
        }
    }

    @MainActor
    @Test func googleRendersTheCurrentGeminiGradientInBothAppearances() throws {
        for colorScheme in [ColorScheme.light, .dark] {
            let image = try renderedProviderMark(
                providerID: "google",
                providerName: "Google",
                colorScheme: colorScheme
            )
            let pixels = try rgbaPixels(in: image)

            #expect(pixels.containsChromaticOpaquePixel)
        }
    }

    @Test func bundledNoticesContainOnlyTheStillBundledMITSourceAndAreResources() throws {
        let notices = try String(contentsOf: noticesURL, encoding: .utf8)
        #expect(notices.contains(openRouterMITLicense))
        #expect(!notices.contains("primer/octicons"))

        let noticesHash = try sha256(of: noticesURL)
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)
        #expect(provenance.contains("- Bundled notices filename: `ProviderLogos-NOTICES.txt`"))
        #expect(provenance.contains("- Bundled notices SHA-256: `\(noticesHash)`"))

        let project = try String(contentsOf: projectURL, encoding: .utf8)
        #expect(project.contains("ProviderLogos-NOTICES.txt in Resources"))
        #expect(project.contains("path = \"ProviderLogos-NOTICES.txt\""))
    }

    @Test func provenanceSchemaMatchesEveryCatalogAssetAndItsHashes() throws {
        let provenance = try String(contentsOf: provenanceURL, encoding: .utf8)

        for entry in provenanceEntries {
            let section = try #require(
                provenanceSection(named: entry.providerHeading, in: provenance)
            )
            let imagesetURL = assetCatalogURL
                .appending(path: "\(entry.assetName).imageset", directoryHint: .isDirectory)
            let catalog = try catalogImages(at: imagesetURL)
            let anyFilename = try #require(catalog.anyFilename)
            let darkFilename = try #require(catalog.darkFilename)
            let anyHash = try sha256(
                of: imagesetURL.appending(path: anyFilename)
            )
            let darkHash = try sha256(
                of: imagesetURL.appending(path: darkFilename)
            )

            #expect(section.contains("- Semantic asset name: `\(entry.assetName)`"))
            #expect(section.contains("- Any source filename: `"))
            #expect(section.contains("- Any source SHA-256: `"))
            #expect(section.contains("- Any bundled filename: `\(anyFilename)`"))
            #expect(section.contains("- Any bundled SHA-256: `\(anyHash)`"))
            #expect(section.contains("- Dark source filename: `"))
            #expect(section.contains("- Dark source SHA-256: `"))
            #expect(section.contains("- Dark bundled filename: `\(darkFilename)`"))
            #expect(section.contains("- Dark bundled SHA-256: `\(darkHash)`"))
            #expect(section.contains("- Usage basis:"))
            #expect(section.contains("- Placement restrictions honored by renderer:"))
        }

        let mistral = try #require(provenanceSection(named: "Mistral AI", in: provenance))
        #expect(mistral.contains("Mistral-Icon-Gradient-RGB.svg"))
        #expect(mistral.contains("`5aa0534fb52009c3ef9321544cd14d4b84ba34d4ee041abb3bdde9c3f2e765ca`"))
        #expect(provenance.contains("`a9578921a6dc44cfe53b45131fe08ad522e1da416d7eb98ad92472c370da2ccf`"))
        #expect(!provenance.contains("primer/octicons"))

        let google = try #require(provenanceSection(named: "Google Gemini", in: provenance))
        #expect(google.contains("Google_Gemini_icon_2025.svg"))
        #expect(google.contains("`cda2df6631d5fa227de3fa04ed78cf354f910ba92a9f086e7455655c10ad9d09`"))

        let copilot = try #require(provenanceSection(named: "GitHub Copilot", in: provenance))
        #expect(copilot.contains("GitHub_Invertocat_Black.svg"))
        #expect(copilot.contains("GitHub_Invertocat_White.svg"))
        #expect(copilot.contains("`e2a67d6cc51d990a52c46c1cf6bcab688db4830982174bca50e0be7a5c2f3194`"))

        let anthropic = try #require(provenanceSection(named: "Anthropic", in: provenance))
        #expect(anthropic.contains("`a3e1ae6a83806cd36109948d9f04fff4db5ace50380120fa50e58c8da0af1ca4`"))
        #expect(anthropic.contains("`b54bcde1c76ec29ee84b0f4cb4af38ef2c3ec7685b79f0df82aa732f65786fe1`"))
        #expect(anthropic.contains("`ac8b8e506f81999b2a0a785059a8d7361c23ac9c7c44d172f31b3796b3062a22`"))
        #expect(anthropic.contains("`45e5976b4ce1536a50b70d89f903ea3ddecb008059c2fb8448a874ffcc41b57b`"))
    }

    private var assetCatalogURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Bighelp/Resources/ProviderLogos.xcassets", directoryHint: .isDirectory)
    }

    private var resourcesURL: URL {
        assetCatalogURL.deletingLastPathComponent()
    }

    private var noticesURL: URL {
        resourcesURL.appending(path: "ProviderLogos-NOTICES.txt")
    }

    private var provenanceURL: URL {
        resourcesURL.appending(path: "ProviderLogos-PROVENANCE.md")
    }

    private var projectURL: URL {
        resourcesURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Bighelp.xcodeproj/project.pbxproj")
    }

    @MainActor
    private func renderedCopilotAsset(colorScheme: ColorScheme) throws -> Data {
        let renderer = ImageRenderer(
            content: Image("ProviderLogoGitHubCopilot")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 44, height: 44)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = 1
        return try #require(renderer.uiImage?.pngData())
    }

    @MainActor
    private func renderedCopilotMark(colorScheme: ColorScheme) throws -> Data {
        let renderer = ImageRenderer(
            content: AIProviderMarkView(
                providerID: "github-copilot",
                providerName: "GitHub Copilot",
                context: .modelPickerProviderHeader,
                size: 44
            )
            .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = 1
        return try #require(renderer.uiImage?.pngData())
    }

    @MainActor
    private func renderedProviderMark(
        providerID: String,
        providerName: String,
        context: AIProviderMarkContext = .modelPickerProviderHeader,
        colorScheme: ColorScheme
    ) throws -> UIImage {
        let renderer = ImageRenderer(
            content: AIProviderMarkView(
                providerID: providerID,
                providerName: providerName,
                context: context,
                size: 44
            )
            .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = 1
        return try #require(renderer.uiImage)
    }

    private func catalogImages(at imagesetURL: URL) throws -> (
        anyFilename: String?, darkFilename: String?
    ) {
        let data = try Data(contentsOf: imagesetURL.appending(path: "Contents.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let images = try #require(object["images"] as? [[String: Any]])
        let anyFilename = images.first { $0["appearances"] == nil }?["filename"] as? String
        let darkFilename = images.first { image in
            guard let appearances = image["appearances"] as? [[String: String]] else {
                return false
            }
            return appearances.contains {
                $0["appearance"] == "luminosity" && $0["value"] == "dark"
            }
        }?["filename"] as? String
        return (anyFilename, darkFilename)
    }

    private func provenanceSection(named heading: String, in provenance: String) -> String? {
        let marker = "## \(heading)\n"
        guard let start = provenance.range(of: marker)?.lowerBound else { return nil }
        let tail = provenance[start...]
        guard let next = tail.dropFirst(marker.count).range(of: "\n## ")?.lowerBound else {
            return String(tail)
        }
        return String(tail[..<next])
    }

    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func rgbaPixels(in image: UIImage) throws -> RGBAPixels {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(try #require(image.cgImage), in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBAPixels(width: width, height: height, bytes: bytes)
    }

    private let provenanceEntries = [
        (providerHeading: "OpenAI", assetName: "ProviderLogoOpenAI"),
        (providerHeading: "Anthropic", assetName: "ProviderLogoAnthropic"),
        (providerHeading: "Google Gemini", assetName: "ProviderLogoGoogle"),
        (providerHeading: "OpenRouter", assetName: "ProviderLogoOpenRouter"),
        (providerHeading: "Mistral AI", assetName: "ProviderLogoMistral"),
        (providerHeading: "LM Studio", assetName: "ProviderLogoLMStudio"),
        (providerHeading: "Hugging Face", assetName: "ProviderLogoHuggingFace"),
        (providerHeading: "Venice", assetName: "ProviderLogoVenice"),
        (providerHeading: "GitHub Copilot", assetName: "ProviderLogoGitHubCopilot"),
        (providerHeading: "Claude", assetName: "ProviderLogoClaude"),
        (providerHeading: "Codex", assetName: "ProviderLogoCodex"),
    ]

    private let openRouterMITLicense = """
    MIT License

    Copyright (c) 2026 OpenRouter Contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """

}

private struct RGBAPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func pixel(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    var containsChromaticOpaquePixel: Bool {
        stride(from: 0, to: bytes.count, by: 4).contains { offset in
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            let alpha = Int(bytes[offset + 3])
            return alpha > 200 && max(red, green, blue) - min(red, green, blue) > 24
        }
    }
}
