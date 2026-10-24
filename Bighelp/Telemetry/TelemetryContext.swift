import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum TelemetryChannel: String, CaseIterable, Sendable {
    case debug
    case testflight
    case appstore
}

/// What every batch says about the app and the device, from the Worker's
/// allowlist: versions, the OS, the kind of device and where the build came from.
/// No device name, no identifier of the device itself.
struct TelemetryContext: Equatable, Sendable {
    var appVersion: String?
    var build: String?
    var os: String
    var osVersion: String?
    var deviceClass: String
    var channel: TelemetryChannel

    /// The Worker's `version` pattern: `^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$`.
    static func isVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count) && parts.allSatisfy { (1...4).contains($0.utf8.count) && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
    }

    /// `^[0-9]{1,7}$`
    static func isBuild(_ value: String) -> Bool {
        (1...7).contains(value.utf8.count) && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    /// The batch's `context` object. A value that fails its pattern is left out.
    var wire: [String: String] {
        var result = ["os": os, "deviceClass": deviceClass, "channel": channel.rawValue]
        if let appVersion, Self.isVersion(appVersion) { result["appVersion"] = appVersion }
        if let build, Self.isBuild(build) { result["build"] = build }
        if let osVersion, Self.isVersion(osVersion) { result["osVersion"] = osVersion }
        return result
    }

    @MainActor
    static func current(bundle: Bundle = .main, process: ProcessInfo = .processInfo) -> TelemetryContext {
        let version = process.operatingSystemVersion
        let os: String
        let device: String
        #if os(visionOS)
        os = "visionOS"; device = "Vision"
        #elseif targetEnvironment(macCatalyst)
        os = "macOS"; device = "Mac"
        #else
        if UIDevice.current.userInterfaceIdiom == .pad { os = "iPadOS"; device = "iPad" }
        else { os = "iOS"; device = "iPhone" }
        #endif
        return TelemetryContext(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            os: os,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            deviceClass: device,
            channel: channel(receiptName: bundle.appStoreReceiptURL?.lastPathComponent))
    }

    /// A build from Xcode is `debug`; TestFlight installs carry a sandbox receipt;
    /// anything else that was built for release is counted as the App Store
    /// (the Mac app's direct download has no receipt either).
    static func channel(receiptName: String?, isDebugBuild: Bool = Self.isDebugBuild) -> TelemetryChannel {
        if isDebugBuild { return .debug }
        return receiptName == "sandboxReceipt" ? .testflight : .appstore
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
