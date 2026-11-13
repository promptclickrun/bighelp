import SwiftUI

/// Hosts the menu can switch between: connected hosts, or demo mode's sample ones.
struct BighelpMenuHosts {
    struct Host: Identifiable, Equatable {
        let id: String
        let name: String
        let isSelected: Bool
    }

    /// The all-hosts view's switch: every agent on every host in one list.
    struct AllHosts {
        let isOn: Bool
        /// All hosts narrowed to one computer (the host marked selected).
        var isFocused = false
        /// Every computer again, still in all hosts.
        var showAll: () -> Void = {}
        let toggle: () -> Void
    }

    var hosts: [Host] = []
    var select: (String) -> Void = { _ in }
    var add: (() -> Void)?
    var allHosts: AllHosts?

    @MainActor
    static func current(registry: BighelpHostRegistry?, demoHosts: DemoHosts?) -> BighelpMenuHosts {
        let add: (() -> Void)? = registry.flatMap { registry in
            registry.canConfigureHosts ? { registry.beginSetup() } : nil
        }
        if let registry, !registry.hosts.isEmpty {
            return BighelpMenuHosts(
                hosts: registry.hosts.map {
                    Host(id: $0.id.uuidString, name: $0.name, isSelected: $0.id == registry.selectedHostID)
                },
                select: { id in registry.select(UUID(uuidString: id)) },
                add: add
            )
        }
        if let demoHosts, !demoHosts.hosts.isEmpty {
            return BighelpMenuHosts(
                hosts: demoHosts.hosts.map { Host(id: $0.id, name: $0.name, isSelected: $0.id == demoHosts.selectedHostID) },
                select: { id in _ = demoHosts.selectHost(id) },
                add: add
            )
        }
        return BighelpMenuHosts(add: add)
    }
}
