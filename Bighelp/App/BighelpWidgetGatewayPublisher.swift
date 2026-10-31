import Foundation
import WidgetKit

/// Writes the gateways widgets can be set to and the one in use, and removes the
/// widget copies of a gateway taken out of bighelp, so its chats and usage leave
/// the Home Screen with it.
@MainActor
enum BighelpWidgetGatewayPublisher {
    private static var last: BighelpWidgetGatewayList?

    static func publish(_ hosts: [FleetHost], directory: URL? = BighelpWidgetGatewayList.fileURL?.deletingLastPathComponent()) {
        let list = BighelpWidgetGatewayList(gateways: hosts.map { .init(id: $0.id.uuidString, name: $0.name) },
                                            inUse: hosts.first(where: \.isSelected)?.id.uuidString)
        guard list != last else { return }
        last = list
        try? list.save()
        // No computers listed yet (still loading) never clears the copies.
        if !list.gateways.isEmpty {
            removeCopies(keeping: Set(list.gateways.map(\.id)), in: directory)
            BighelpPlanNames.keep(gateways: Set(list.gateways.map(\.id)))
        }
        for kind in BighelpWidgetSnapshot.widgetKinds + [BighelpUsageSnapshot.kind] {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    /// Widget copies of gateways that aren't in the list anymore, and the Usage widget's single file
    /// from before each gateway had its own.
    static func removeCopies(keeping ids: Set<String>, in directory: URL?) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        if names.contains(BighelpUsageSnapshot.fileName) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(BighelpUsageSnapshot.fileName))
        }
        for prefix in [BighelpWidgetSnapshot.gatewayFilePrefix, BighelpUsageSnapshot.gatewayFilePrefix] {
            for name in names where name.hasPrefix(prefix) && name.hasSuffix(".json") {
                let id = String(name.dropFirst(prefix.count).dropLast(".json".count))
                guard !ids.contains(id) else { continue }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
            }
        }
    }
}
