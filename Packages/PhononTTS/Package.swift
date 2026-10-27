// swift-tools-version: 6.0
import PackageDescription

// Phonon text to speech (gradium-ai/xn-ptts) for the app's on-device voices. Upstream's own
// manifest asks for iOS 18, which Xcode won't link into an app that still supports iOS 17, so
// this package keeps the app's minimum and its API says "iOS 18 or later" instead.
let package = Package(
    name: "PhononTTS",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "PhononTTS", targets: ["PhononTTS"]),
    ],
    targets: [
        // The compiled core of release v0.5.0, checked against its published checksum.
        // arm64 only: the app leaves Intel simulators out.
        .binaryTarget(
            name: "PhononCore",
            url: "https://github.com/gradium-ai/xn-ptts/releases/download/v0.5.0/PhononCore.xcframework.zip",
            checksum: "d91096a18650d4ffd23f211e2ea534c3bc251a7b66859497b56e1c89f3e92ca9"
        ),
        .target(
            name: "PhononTTS",
            dependencies: ["PhononCore"],
            linkerSettings: [
                .linkedFramework("CoreML"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
