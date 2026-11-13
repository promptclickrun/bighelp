import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)
/// A right-click menu for one tile of a grid that sits in a single List row
/// (pinned chats). SwiftUI's `.contextMenu` can't be used there:
/// the row shows its first tile's menu for every tile. Only right- and
/// Control-clicks land on this view; other clicks, hovers and scrolls pass
/// through to the tile.
struct MacTileMenu: UIViewRepresentable {
    typealias Item = TileMenuItem

    /// Read when the menu opens, so it shows the tile's current choices.
    let items: () -> [Item]

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    func makeUIView(context: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ view: SecondaryClickView, context: Context) {
        context.coordinator.items = items
    }

    final class SecondaryClickView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let event, event.buttonMask.contains(.secondary) || event.modifierFlags.contains(.control) else {
                return nil
            }
            return super.hitTest(point, with: event)
        }
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var items: () -> [Item]
        /// What the open menu shows; its actions run these.
        private var shown: [Item] = []

        init(items: @escaping () -> [Item]) {
            self.items = items
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            shown = items()
            guard !shown.isEmpty else { return nil }
            let menu = TileMenuItem.menu(shown)
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
        }
    }
}
#endif

/// One choice in a pinned tile's right-click menu on the Mac.
struct TileMenuItem {
    let title: String
    let systemImage: String
    var isDestructive = false
    var isEnabled = true
    /// Draws a separator above this item.
    var startsGroup = false
    /// A submenu's choices; nil for an action.
    var children: [TileMenuItem]? = nil
    var identifier: String? = nil
    var perform: @MainActor () -> Void = {}

    #if os(iOS)
    @MainActor
    static func menu(_ items: [TileMenuItem], title: String = "", image: UIImage? = nil) -> UIMenu {
        var groups: [[UIMenuElement]] = [[]]
        for item in items {
            if item.startsGroup, !(groups.last?.isEmpty ?? true) { groups.append([]) }
            let image = UIImage(systemName: item.systemImage)
            if let children = item.children {
                groups[groups.count - 1].append(menu(children, title: item.title, image: image))
                continue
            }
            var attributes: UIMenuElement.Attributes = []
            if item.isDestructive { attributes.insert(.destructive) }
            if !item.isEnabled { attributes.insert(.disabled) }
            let perform = item.perform
            let action = UIAction(title: item.title, image: image, attributes: attributes) { _ in perform() }
            action.accessibilityIdentifier = item.identifier
            groups[groups.count - 1].append(action)
        }
        let children: [UIMenuElement] = groups.count == 1
            ? groups[0]
            : groups.map { UIMenu(options: .displayInline, children: $0) }
        return UIMenu(title: title, image: image, children: children)
    }
    #endif
}
