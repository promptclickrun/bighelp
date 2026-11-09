import Foundation
import Testing
@testable import Bighelp

@MainActor
struct HostPluginUpdateTests {
    @Test func versionsCompareNumerically() {
        #expect(HostPluginPin.compare("2.16.1", "2.16.0") == .orderedDescending)
        #expect(HostPluginPin.compare("2.9.0", "2.16.0") == .orderedAscending)
        #expect(HostPluginPin.compare("2.16", "2.16.0") == .orderedSame)
        #expect(HostPluginPin.compare("3.0.0", "2.99.99") == .orderedDescending)
    }

    @Test func onlyPlainDottedVersionsAreAccepted() {
        #expect(HostPluginPin.validVersion("2.16.1"))
        for bad in ["", "2.16.1-beta", "v2.16", "2.16.1\n", String(repeating: "1", count: 33)] {
            #expect(!HostPluginPin.validVersion(bad), "\(bad)")
        }
    }

    @Test func theInstalledListCarriesTheVersionOnDisk() throws {
        func list(_ version: BighelpJSONValue) -> BighelpJSONValue {
            .object(["plugins": .array([
                .object(["name": .string("other"), "key": .string("other"), "status": .string("enabled")]),
                .object(["name": .string("loopdy"), "key": .string("loopdy"), "status": .string("enabled"),
                         "pinned_sha": .string(String(repeating: "a", count: 40)), "version": version]),
            ])])
        }
        #expect(try HostInstalledPlugin.decodeList(list(.string("2.15.0"))).first?.version == "2.15.0")
        // A strange version string is ignored rather than trusted or fatal.
        #expect(try HostInstalledPlugin.decodeList(list(.string("<script>"))).first?.version == nil)
        #expect(try HostInstalledPlugin.decodeList(list(.null)).first?.version == nil)
    }

    @Test func versionsDecideWhetherToUpdateOrRestart() {
        typealias Model = HostPluginUpdateModel
        #expect(Model.state(installed: "2.15.0", running: "2.15.0", latest: "2.16.1") == .updateAvailable)
        // Updated files, old code still running: restart to finish.
        #expect(Model.state(installed: "2.16.1", running: "2.15.0", latest: "2.16.1") == .restartNeeded)
        #expect(Model.state(installed: "2.16.1", running: "2.16.1", latest: "2.16.1") == .upToDate)
        // A newer host is never offered a downgrade.
        #expect(Model.state(installed: "2.17.0", running: "2.17.0", latest: "2.16.1") == .upToDate)
        // Unknown running version (older plugins without native context) doesn't block.
        #expect(Model.state(installed: "2.16.1", running: nil, latest: "2.16.1") == .upToDate)
        // On disk, but the dashboard hasn't loaded it (a first install): only a restart starts it.
        #expect(Model.state(installed: "2.16.1", running: nil, latest: "2.16.1", loaded: false) == .restartNeeded)
        #expect(Model.state(installed: "2.15.0", running: nil, latest: "2.16.1", loaded: false) == .updateAvailable)
        // Until GitHub names the newest release, nothing is offered.
        #expect(Model.state(installed: "1.0.0", running: "1.0.0", latest: nil) == .upToDate)
    }

    /// Plugin releases reach hosts without an app build, so the app pins none.
    @Test func theAppBuildPinsNoPluginVersion() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "BighelpNotificationPluginRevision") == nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "BighelpNotificationPluginVersion") == nil)
    }
}
