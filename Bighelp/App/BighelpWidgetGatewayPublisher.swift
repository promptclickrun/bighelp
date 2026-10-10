import Foundation
import WidgetKit

/// Writes the gateways widgets can be set to, and removes the widget copy of a
/// gateway taken out of bighelp, so its chats leave the Home Screen with it.
@MainActor
enum BighelpWidgetGatewayPublisher {
    private static var last: BighelpWidgetGatewayList?

    static func publish(_ hosts: [FleetHost], directory: URL? = BighelpWidgetGatewayList.fileURL?.deletingLastPathComponent()) {
        let list = BighelpWidgetGatewayList(gateways: hosts.map { .init(id: $0.id.uuidString, name: $0.name) })
        guard list != last else { return }
        last = list
        try? list.save()
        // No computers listed yet (still loading) never clears the copies.
        if !list.gateways.isEmpty { removeCopies(keeping: Set(list.gateways.map(\.id)), in: directory) }
        for kind in BighelpWidgetSnapshot.widgetKinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }

    /// Widget copies of gateways that aren't in the list anymore.
    static func removeCopies(keeping ids: Set<String>, in directory: URL?) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let prefix = BighelpWidgetSnapshot.gatewayFilePrefix
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            let id = String(name.dropFirst(prefix.count).dropLast(".json".count))
            guard !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
        }
    }
}
