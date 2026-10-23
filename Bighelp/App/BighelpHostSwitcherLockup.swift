import SwiftUI

/// The bighelp lockup in the top bar. Touch and hold it to switch hosts; on
/// the Mac, click it.
struct BighelpHostSwitcherLockup: View {
    var demoHosts: DemoHosts?
    @Environment(\.bighelpHostRegistry) private var registry
    @Environment(\.bighelpScreen) private var screen

    var body: some View {
        let hosts = BighelpMenuHosts.current(registry: registry, demoHosts: demoHosts)
        if hosts.hosts.count + (hosts.add == nil ? 0 : 1) > 0 {
            #if targetEnvironment(macCatalyst)
            // A click that does nothing reads as broken on a Mac, where holding is rare.
            Menu { hostItems(hosts) } label: { mark }
                .accessibilityLabel(BighelpBrand.appName)
                .accessibilityHint("Switch hosts.")
                .accessibilityIdentifier("brand.host-switcher")
            #else
            Menu { hostItems(hosts) } label: {
                mark
            } primaryAction: {}
            .accessibilityLabel(BighelpBrand.appName)
            .accessibilityHint("Touch and hold to switch hosts.")
            .accessibilityIdentifier("brand.host-switcher")
            #endif
        } else {
            mark
        }
    }

    /// The iPhone Duo puts the bar's buttons down its side strip: the Noodle alone fits there.
    @ViewBuilder
    private var mark: some View {
        if screen.usesSideBar {
            BighelpNoodleMark(size: 26)
        } else {
            BighelpWordmark(height: 26)
        }
    }

    @ViewBuilder
    private func hostItems(_ hosts: BighelpMenuHosts) -> some View {
        Section("Switch host") {
            ForEach(hosts.hosts) { host in
                Button { hosts.select(host.id) } label: {
                    if host.isSelected { Label(host.name, systemImage: "checkmark") } else { Text(host.name) }
                }
                .accessibilityIdentifier("brand.host.\(host.id)")
            }
        }
        if let add = hosts.add {
            Button(action: add) { Label("Add host", systemImage: "plus") }
                .accessibilityIdentifier("brand.host.add")
        }
    }
}
