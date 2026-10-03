import Foundation
import Testing
@testable import Bighelp

/// Fleet settings runs each host's own update and restart flows side by side:
/// offline and signed-out hosts are skipped, and one host's failure never
/// stops the others. The hosts answer Hermes' real routes (`FleetMaintenanceFixtureHTTP`).
@MainActor
struct FleetMaintenanceTests {
    private typealias HTTP = FleetMaintenanceFixtureHTTP
    private typealias Plugin = FleetPluginFixture

    private let homeID = UUID()
    private let studioID = UUID()
    private let officeID = UUID()
    private let atticID = UUID()

    private func store(_ hosts: [FleetMaintenanceFixture.Host]) -> (FleetMaintenanceStore, FleetMaintenanceFixture) {
        let fixture = FleetMaintenanceFixture(hosts: hosts)
        return (FleetMaintenanceStore(connector: fixture, pollInterval: .milliseconds(10), maximumPolls: 200), fixture)
    }

    private func ready(_ id: UUID, _ name: String, _ http: HTTP, _ plugin: Plugin = Plugin(installed: "2.20.1", latest: "2.20.1"))
        -> FleetMaintenanceFixture.Host {
        .init(id: id, name: name, reach: .ready(http, plugin))
    }

    @Test func listsWhereEachHostStandsAndSkipsOfflineAndSignedOutHosts() async throws {
        let home = HTTP(script: .init(version: "0.21.4", commitsBehind: 12))
        let studio = HTTP(script: .init(version: "0.21.5", commitsBehind: 0))
        let (store, _) = store([
            ready(homeID, "Home", home, Plugin(installed: "2.19.0", latest: "2.20.1")),
            ready(studioID, "Studio", studio),
            .init(id: officeID, name: "Office", reach: .offline("Offline. Couldn't reach this host.")),
            .init(id: atticID, name: "Attic", reach: .signedOut),
        ])
        await store.refresh()

        let row = try #require(store.host(homeID))
        #expect(row.hermes == FleetHostJob(.pending, "12 commits behind"))
        #expect(row.pluginJob == FleetHostJob(.pending, "2.19.0 → 2.20.1"))
        #expect(row.gateway == FleetHostJob(.current, "Running"))
        #expect(store.host(studioID)?.hermes.kind == .current)
        #expect(store.host(studioID)?.pluginJob.kind == .current)
        for id in [officeID, atticID] {
            let skipped = try #require(store.host(id))
            #expect(skipped.hermes.kind == .unavailable)
            #expect(skipped.pluginJob.kind == .unavailable)
            #expect(skipped.gateway.kind == .unavailable)
        }
        #expect(store.host(atticID)?.hermes.text.contains("Signed out") == true)
        #expect(store.hermesCandidates.map(\.id) == [homeID])
        #expect(store.gatewayCandidates.map(\.id) == [homeID, studioID], "Offline hosts aren't restarted")

        await store.updateHermesEverywhere()
        #expect(home.launches == ["hermes-update"])
        #expect(studio.launches.isEmpty, "A host that's up to date isn't updated")
        #expect(row.hermes.kind == .done)
        #expect(store.host(officeID)?.hermes.kind == .unavailable)
    }

    @Test func oneHostsFailedUpdateDoesNotStopTheOthers() async throws {
        let home = HTTP(script: .init(version: "0.21.4", commitsBehind: 4, updateExitCode: 1))
        let studio = HTTP(script: .init(version: "0.21.3", commitsBehind: 9))
        let (store, _) = store([ready(homeID, "Home", home), ready(studioID, "Studio", studio)])
        await store.refresh()
        #expect(store.hermesCandidates.count == 2)

        await store.updateHermesEverywhere()
        #expect(home.launches == ["hermes-update"])
        #expect(studio.launches == ["hermes-update"])
        #expect(store.host(homeID)?.hermes == FleetHostJob(.failed, "Update failed"))
        #expect(store.host(studioID)?.hermes == FleetHostJob(.done, "Updated · 0.21.5"))
    }

    @Test func aHermesUpdateThatLeavesTheGatewayBehindNeedsARestart() async throws {
        let studio = HTTP(script: .init(version: "0.21.3", commitsBehind: 3, gatewayRestartIncomplete: true))
        let (store, _) = store([ready(studioID, "Studio", studio)])
        await store.refresh()
        await store.updateHermesEverywhere()
        let row = try #require(store.host(studioID))
        #expect(row.hermes.kind == .needsRestart)

        await store.finishHermesUpdate(on: studioID)
        #expect(studio.launches == ["hermes-update", "gateway-restart"])
        #expect(row.hermes == FleetHostJob(.done, "Updated · 0.21.5"))
        #expect(row.gateway == FleetHostJob(.done, "Restarted"))
    }

    @Test func followsAnUpdateAcrossTheReconnectAfterHermesRestarts() async throws {
        let home = HTTP(script: .init(version: "0.21.4", commitsBehind: 2, runningReads: 3, dropsConnectionOnUpdate: true))
        let (store, fixture) = store([ready(homeID, "Home", home)])
        await store.refresh()
        await store.updateHermesEverywhere()
        #expect(fixture.connectCount[homeID] ?? 0 >= 2, "Reconnected after the restart")
        #expect(home.launches == ["hermes-update"], "Followed, never launched again")
        #expect(store.host(homeID)?.hermes.kind == .done)
    }

    @Test func pluginUpdatesNeedARestartPerHostAndFailuresStayOnTheirHost() async throws {
        let home = Plugin(installed: "2.19.0", latest: "2.20.1")
        let studio = Plugin(installed: "2.18.2", latest: "2.20.1")
        studio.failsUpdate = true
        let office = Plugin(installed: "2.20.1", latest: "2.20.1")
        let (store, _) = store([
            ready(homeID, "Home", HTTP(script: .init(version: "0.21.5", commitsBehind: 0)), home),
            ready(studioID, "Studio", HTTP(script: .init(version: "0.21.5", commitsBehind: 0)), studio),
            ready(officeID, "Office", HTTP(script: .init(version: "0.21.5", commitsBehind: 0)), office),
        ])
        await store.refresh()
        #expect(store.pluginCandidates.map(\.id) == [homeID, studioID])

        await store.updatePluginEverywhere()
        #expect(store.host(homeID)?.pluginJob == FleetHostJob(.needsRestart, "2.20.1 installed · Needs restart"))
        #expect(store.host(studioID)?.pluginJob.kind == .failed)
        #expect(store.host(officeID)?.pluginJob == FleetHostJob(.current, "Up to date · 2.20.1"))

        await store.restartPlugin(on: homeID)
        #expect(home.state == .upToDate)
        #expect(store.host(homeID)?.pluginJob == FleetHostJob(.done, "Updated · 2.20.1"))
    }

    @Test func gatewayRestartsReportEachHostAndSkipOfflineOnes() async throws {
        let home = HTTP(script: .init(version: "0.21.5", commitsBehind: 0))
        let studio = HTTP(script: .init(version: "0.21.5", commitsBehind: 0, restartExitCode: 1))
        let (store, _) = store([
            ready(homeID, "Home", home), ready(studioID, "Studio", studio),
            .init(id: officeID, name: "Office", reach: .offline("Offline.")),
        ])
        await store.refresh()
        await store.restartGatewaysEverywhere()
        #expect(home.launches == ["gateway-restart"])
        #expect(studio.launches == ["gateway-restart"])
        #expect(store.host(homeID)?.gateway == FleetHostJob(.done, "Restarted"))
        #expect(store.host(studioID)?.gateway == FleetHostJob(.failed, "Restart failed"))
        #expect(store.host(officeID)?.gateway.kind == .unavailable)
    }
}
