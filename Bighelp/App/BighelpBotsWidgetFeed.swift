import Foundation
import Observation
import UIKit
import WidgetKit

/// Keeps the Bots widget current: every gateway's bots (the computer in use live,
/// the others from All agents' copies) and each bot's face, in the shared app
/// group, so the widget shows the chosen bots with the app closed.
@MainActor
final class BighelpBotsWidgetFeed {
    static let shared = BighelpBotsWidgetFeed()

    /// Where a face comes from: the bot's picture on this device, or its default shape.
    enum Face: Equatable, Sendable {
        case picture(URL)
        case shape(SimpleBotMark)
    }

    struct Plan: Equatable {
        var roster = BighelpBotsWidgetRoster()
        /// Face key → where it comes from.
        var faces: [String: Face] = [:]
    }

    private weak var agents: AgentDirectoryStore?
    private weak var fleet: FleetStore?
    private var pending: Task<Void, Never>?
    private var written: Plan?
    private var writing: Task<Void, Never>?
    private var shapes: [SimpleBotMark: Data] = [:]

    /// Follows these agents and computers from now on.
    func attach(agents: AgentDirectoryStore, fleet: FleetStore?) {
        guard agents !== self.agents || fleet !== self.fleet else { return }
        self.agents = agents
        self.fleet = fleet
        observe()
        update()
    }

    private func observe() {
        withObservationTracking { _ = makePlan() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.changed() }
        }
    }

    /// All agents' copies change while replies stream; write at most every half second.
    private func changed() {
        observe()
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            pending = nil
            update()
        }
    }

    /// Nil when the store it followed is gone (another computer took over): nothing to write then.
    private func makePlan() -> Plan? {
        guard let agents else { return nil }
        let current = fleet?.hosts.first(where: \.isSelected)?.id
            ?? BighelpWidgetSnapshot.load().hostID.flatMap(UUID.init(uuidString:))
        return Self.plan(current: agents.knowsProfiles ? agents.profiles : nil, primaryID: agents.primaryAgentID,
                         pinnedIDs: agents.pinnedAgentIDs, picture: { agents.avatarURL(for: $0) },
                         currentHostID: current, fleet: fleet)
    }

    private func update() {
        guard let plan = makePlan(), plan != written else { return }
        written = plan
        // Shapes are drawn here (SwiftUI); pictures are copied off the main thread.
        var drawn: [String: Data] = [:]
        for (key, face) in plan.faces {
            guard case .shape(let mark) = face else { continue }
            if shapes[mark] == nil { shapes[mark] = SimpleBotMarkView.png(mark, pixels: CGFloat(BighelpActivityAvatarStore.pixelSize)) }
            drawn[key] = shapes[mark]
        }
        let previous = writing
        // Gateways still set up keep their saved bots when this plan doesn't know them yet.
        let gateways = fleet.map { Set($0.hosts.map(\.id.uuidString)) }.flatMap { $0.isEmpty ? nil : $0 }
        writing = Task.detached(priority: .utility) {
            await previous?.value
            Self.write(plan, drawn: drawn, keeping: gateways)
            WidgetCenter.shared.reloadTimelines(ofKind: BighelpWidgetSnapshot.botsWidgetKind)
        }
    }

    /// Writes the faces, marks which ones are shapes, removes faces no longer listed, then the roster.
    /// A gateway the plan has no bots for keeps its saved ones and their faces, while it's still among
    /// `keeping` (every gateway when nil): the app often doesn't know a gateway's bots yet, like at
    /// launch before the computer answers, and a widget must never go empty for that.
    nonisolated static func write(_ plan: Plan, drawn: [String: Data], keeping gateways: Set<String>? = nil,
                                  faces directory: URL? = BighelpBotsWidgetFaces.directory,
                                  roster url: URL? = BighelpBotsWidgetRoster.fileURL) {
        let saved = BighelpBotsWidgetRoster.load(from: url)
        var carried: [String: [BighelpBotsWidgetRoster.Bot]] = [:]
        for (gateway, bots) in saved.gateways where plan.roster.gateways[gateway] == nil {
            guard gateway == BighelpWidgetGateway.inUseID || gateways?.contains(gateway) != false else { continue }
            carried[gateway] = bots
        }
        var shapeKeys: Set<String> = [], kept: Set<String> = []
        for bots in carried.values {
            for bot in bots {
                guard let key = bot.faceKey else { continue }
                kept.insert("\(key).png")
                if bot.isShape { shapeKeys.insert(key) }
            }
        }
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for key in plan.faces.keys.sorted().prefix(BighelpBotsWidgetFaces.maximumFiles) {
                guard let destination = BighelpPinnedAvatarStore.fileURL(key: key, in: directory) else { continue }
                let ok: Bool
                switch plan.faces[key] {
                case .picture(let source)?: ok = BighelpActivityAvatarWriter.write(source, to: destination)
                case .shape?:
                    ok = drawn[key].map { png in
                        (try? png.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
                    } ?? false
                case nil: ok = false
                }
                guard ok else { continue }
                kept.insert(destination.lastPathComponent)
                if hasClearCorners(destination) { shapeKeys.insert(key) }
            }
            for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where !kept.contains(file) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file, isDirectory: false))
            }
        }
        var roster = plan.roster
        for (gateway, bots) in plan.roster.gateways {
            roster.gateways[gateway] = bots.map { bot in
                var bot = bot
                if let key = bot.faceKey, !kept.contains("\(key).png") { bot.faceKey = nil }
                bot.isShape = bot.faceKey.map(shapeKeys.contains) ?? false
                return bot
            }
        }
        roster.gateways.merge(carried) { planned, _ in planned }
        try? roster.save(to: url)
    }

    /// A Simple Bot shape is clear around it; a photo fills its corners.
    nonisolated static func hasClearCorners(_ url: URL) -> Bool {
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage, image.width > 4, image.height > 4,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        let width = image.width, height = image.height
        return [(1, 1), (width - 2, 1), (1, height - 2), (width - 2, height - 2)].allSatisfy { x, y in
            pixels[(y * width + x) * 4 + 3] < 16
        }
    }

    // MARK: Plan

    /// Each gateway's bots, the primary one first, then pinned, then by name; hidden bots stay off.
    /// `current` is nil while the computer in use's bots aren't known: All agents' copy of it stands in,
    /// or nothing, and `write` keeps that gateway's saved bots.
    static func plan(current: [AgentProfile]?, primaryID: String?, pinnedIDs: [String],
                     picture: (AgentProfile) -> URL?, currentHostID: UUID?, fleet: FleetStore?) -> Plan {
        var plan = Plan()
        let currentKey = currentHostID?.uuidString ?? BighelpWidgetGateway.inUseID
        plan.roster.inUseHostID = currentKey
        func add(_ bots: [(id: String, name: String, picture: URL?)], gateway: String, hostID: UUID?) {
            plan.roster.gateways[gateway] = bots.prefix(BighelpBotsWidgetRoster.maximumBotsPerGateway).map { bot in
                let key = BighelpPinnedAvatarWriter.key(hostID: hostID, agentID: bot.id)
                plan.faces[key] = bot.picture.map(Face.picture) ?? .shape(.defaultMark(for: bot.id))
                return .init(agentID: bot.id, name: clip(bot.name), faceKey: key)
            }
        }
        if let current {
            let primary = current.first { $0.id == primaryID } ?? current.first(where: \.isDefault)
            add(ordered(current.filter { $0.placement?.isHidden != true }, primaryID: primary?.id, pinnedIDs: pinnedIDs,
                        id: \.id, name: \.name).map { (id: $0.id, name: $0.name, picture: picture($0)) },
                gateway: currentKey, hostID: currentHostID)
        }
        for host in (fleet?.hosts ?? []).prefix(BighelpBotsWidgetRoster.maximumGateways)
            where host.id != currentHostID || current == nil {
            let agents = fleet?.agents(on: host.id).filter { !$0.isHidden } ?? []
            guard !agents.isEmpty else { continue }
            add(ordered(agents, primaryID: agents.first(where: \.isDefault)?.profileID,
                        pinnedIDs: agents.filter(\.isPinned).map(\.profileID), id: \.profileID, name: \.name)
                    .map { (id: $0.profileID, name: $0.name, picture: fleet?.avatars.url(for: $0.avatarFile)) },
                gateway: host.id.uuidString, hostID: host.id)
        }
        return plan
    }

    private static func ordered<T>(_ items: [T], primaryID: String?, pinnedIDs: [String],
                                   id: KeyPath<T, String>, name: KeyPath<T, String>) -> [T] {
        func rank(_ item: T) -> Int {
            if item[keyPath: id] == primaryID { return -1 }
            return pinnedIDs.firstIndex(of: item[keyPath: id]) ?? Int.max
        }
        return items.sorted { left, right in
            let l = rank(left), r = rank(right)
            if l != r { return l < r }
            return left[keyPath: name].localizedStandardCompare(right[keyPath: name]) == .orderedAscending
        }
    }

    private static func clip(_ value: String) -> String {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "Bot" }
        return collapsed.count <= 32 ? collapsed : String(collapsed.prefix(31)) + "…"
    }
}
