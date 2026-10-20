import SwiftUI

/// The bighelp lockup in the top bar. Touch and hold it to switch hosts; on
/// the Mac, click it.
struct BighelpHostSwitcherLockup: View {
    var demoHosts: DemoHosts?
    @Environment(\.bighelpHostRegistry) private var registry

    var body: some View {
        let hosts = BighelpMenuHosts.current(registry: registry, demoHosts: demoHosts)
        if hosts.hosts.count + (hosts.add == nil ? 0 : 1) > 0 {
            #if targetEnvironment(macCatalyst)
            // A click that does nothing reads as broken on a Mac, where holding is rare.
            Menu { hostItems(hosts) } label: { BighelpWordmark(height: 26) }
                .accessibilityLabel(BighelpBrand.appName)
                .accessibilityHint("Switch hosts.")
                .accessibilityIdentifier("brand.host-switcher")
            #else
            Menu { hostItems(hosts) } label: {
                BighelpWordmark(height: 26)
            } primaryAction: {}
            .accessibilityLabel(BighelpBrand.appName)
            .accessibilityHint("Touch and hold to switch hosts.")
            .accessibilityIdentifier("brand.host-switcher")
            #endif
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
