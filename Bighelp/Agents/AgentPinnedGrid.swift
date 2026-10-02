import SwiftUI

/// The Pinned grid on Agents. Tap opens an agent's chat. Touch and hold lifts
/// the agent: drag it to a new place and the others make room (pinned agents
/// only), or let go without moving to see that agent's actions.
struct AgentPinnedGrid: View {
    let agents: [AgentProfile]
    let canReorder: Bool
    let imageURL: (AgentProfile) -> URL?
    let liveState: (AgentProfile) -> AgentLiveState
    let isPrimary: (AgentProfile) -> Bool
    let open: (AgentProfile) -> Void
    let manage: (AgentProfile) -> Void
    let reorder: ([String]) -> Void
    let create: (() -> Void)?
    @Binding var isArranging: Bool

    var body: some View {
        PinnedArrangeGrid(
            items: agents,
            columns: PinnedAgentsLayout.columns,
            canReorder: canReorder, space: "agents.pinned", open: open, manage: manage, reorder: reorder,
            isArranging: $isArranging, identifier: { "agents.featured.\($0.id)" },
            tile: { agent, lifted in
                AgentFeaturedTile(agent: agent, imageURL: imageURL(agent), liveState: liveState(agent),
                                  isPrimary: isPrimary(agent), isLifted: lifted)
            },
            trailing: {
                if let create {
                    AgentNewTile(action: create)
                        .accessibilityIdentifier("agents.featured.create")
                }
            }
        )
    }
}

/// A grid of pinned things. Tap opens one. Touch and hold lifts it: drag it to
/// a new place and the others make room, or let go without moving to see its
/// actions (when it has any).
///
/// SwiftUI long-press menus can't be used here: the grid is one List row, and
/// a List row shows the first menu in it whichever tile was pressed. So with
/// `menu`, letting go opens the tile's own UIKit menu (`TileMenuAnchor`), the
/// same system menu a row's `.contextMenu` shows. On the Mac each tile also
/// has its own right-click menu (`MacTileMenu`).
struct PinnedArrangeGrid<Item: Identifiable, Tile: View, Trailing: View>: View where Item.ID == String {
    let items: [Item]
    let columns: [GridItem]
    let canReorder: Bool
    /// The grid's coordinate space; unique per screen.
    let space: String
    let open: (Item) -> Void
    let manage: ((Item) -> Void)?
    /// The tile's menu, shown when it's let go without moving. Where a menu
    /// can't be opened (visionOS, iOS before 17.4), `manage` runs instead.
    var menu: ((Item) -> [TileMenuItem])? = nil
    let reorder: ([String]) -> Void
    @Binding var isArranging: Bool
    let identifier: (Item) -> String
    @ViewBuilder let tile: (Item, _ isLifted: Bool) -> Tile
    @ViewBuilder let trailing: () -> Trailing

    private struct Lift: Equatable {
        let id: String
        /// Where each place in the grid was when the tile was lifted.
        let slots: [CGRect]
        /// The finger's spot within the lifted tile.
        let grab: CGSize
        /// Where the finger was when the tile lifted.
        let start: CGPoint
        var location: CGPoint
        var moved = false
    }

    @State private var frames: [String: CGRect] = [:]
    @State private var arrangement: [Item]?
    @State private var lift: Lift?
    #if os(iOS)
    @State private var anchors = TileMenuAnchors()
    #endif
    @GestureState private var isTouching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: [Item] { arrangement ?? items }

    var body: some View {
        LazyVGrid(columns: columns, spacing: BighelpTokens.space12) {
            ForEach(shown) { item in cell(item) }
            trailing()
        }
        #if os(iOS)
        // Beside the tiles, not in them, so each tile stays one element.
        .background(alignment: .topLeading) {
            if menu != nil {
                ForEach(items) { item in
                    if let frame = frames[item.id] {
                        TileMenuAnchor(id: item.id, anchors: anchors)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        #endif
        .coordinateSpace(.named(space))
        .onChange(of: isTouching) { _, touching in
            // Ends a lift however the touch ended, including a cancelled one.
            if !touching { finish() }
        }
    }

    private func cell(_ item: Item) -> some View {
        let lifted = lift?.id == item.id
        return tile(item, lifted)
            #if targetEnvironment(macCatalyst)
            .overlay { MacTileMenu(items: { macMenu(for: item) }).accessibilityHidden(true) }
            #endif

            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frames[item.id] = $0 }
            .offset(lifted ? offset(for: item) : .zero)
            .zIndex(lifted ? 1 : 0)
            .onTapGesture { open(item) }
            .modifier(HoldToArrange(
                space: space, legacy: press(item),
                began: { begin(item, at: $0) }, moved: { follow(to: $0) }, ended: { finish() }))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint)
            .accessibilityAction { open(item) }
            .accessibilityActions {
                if let menu {
                    ForEach(Array(menu(item).filter { $0.children == nil && $0.isEnabled }.enumerated()), id: \.offset) {
                        Button($0.element.title, action: $0.element.perform)
                    }
                } else if let manage {
                    Button("Manage agent") { manage(item) }
                }
                if canReorder {
                    Button("Move earlier") { move(item, by: -1) }
                    Button("Move later") { move(item, by: 1) }
                }
            }
            .accessibilityIdentifier(identifier(item))
    }

    private var hint: String {
        #if targetEnvironment(macCatalyst)
        switch (canReorder, manage != nil || menu != nil) {
        case (true, true): "Opens this agent's chat. Click and hold to move it; right-click for more actions."
        case (true, false): "Opens this agent's chat. Click and hold to move it."
        case (false, _): "Opens this agent's chat. Right-click for more actions."
        }
        #else
        switch (canReorder, manage != nil || menu != nil) {
        case (true, true): "Opens this agent's chat. Touch and hold to move it or for more actions."
        case (true, false): "Opens this agent's chat. Touch and hold to move it."
        case (false, _): "Opens this agent's chat. Touch and hold for more actions."
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// The same choices as holding a tile on iPhone, plus moving it without a drag.
    private func macMenu(for item: Item) -> [MacTileMenu.Item] {
        var entries = [MacTileMenu.Item(title: "Open chat", systemImage: "bubble.left") { open(item) }]
        if let menu {
            entries += menu(item).enumerated().map { index, entry in
                var entry = entry
                if index == 0 { entry.startsGroup = true }
                return entry
            }
        } else if let manage {
            entries.append(MacTileMenu.Item(title: "Manage agent", systemImage: "slider.horizontal.3") { manage(item) })
        }
        if canReorder, let index = items.firstIndex(where: { $0.id == item.id }) {
            entries.append(MacTileMenu.Item(title: "Move earlier", systemImage: "arrow.left",
                                            isEnabled: index > 0, startsGroup: true) { move(item, by: -1) })
            entries.append(MacTileMenu.Item(title: "Move later", systemImage: "arrow.right",
                                            isEnabled: index < items.count - 1) { move(item, by: 1) })
        }
        return entries
    }
    #endif

    /// iOS 17's hold-then-drag. SwiftUI's drag holds back the list's scroll
    /// even beside it, so iOS 18 and later use UIKit's long press instead.
    private func press(_ item: Item) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(space)))
            .updating($isTouching) { value, touching, _ in
                if case .second(true, _) = value { touching = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if lift == nil { begin(item, at: drag?.startLocation) }
                if let drag { follow(to: drag.location) }
            }
    }

    private func begin(_ item: Item, at start: CGPoint?) {
        let slots = items.map { frames[$0.id] ?? .zero }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let slot = slots[index]
        let point = start ?? CGPoint(x: slot.midX, y: slot.midY)
        BighelpHaptics.tap(rigid: true)
        isArranging = true
        arrangement = items
        withAnimation(.snappy(duration: 0.2)) {
            lift = Lift(id: item.id, slots: slots,
                        grab: CGSize(width: point.x - slot.minX, height: point.y - slot.minY),
                        start: point, location: point)
        }
    }

    private func follow(to location: CGPoint) {
        guard var current = lift else { return }
        current.location = location
        if hypot(location.x - current.start.x, location.y - current.start.y) > 8 { current.moved = true }
        lift = current
        guard canReorder, current.moved, var order = arrangement,
              let from = order.firstIndex(where: { $0.id == current.id }),
              let to = nearestSlot(to: location, in: current.slots), to != from else { return }
        let item = order.remove(at: from)
        order.insert(item, at: to)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { arrangement = order }
    }

    private func finish() {
        guard let finished = lift else { return }
        let order = arrangement?.map(\.id)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            lift = nil
            arrangement = nil
        }
        isArranging = false
        if !finished.moved, let item = items.first(where: { $0.id == finished.id }) {
            #if os(iOS)
            if let menu, anchors.present(item.id, items: menu(item)) { return }
            #endif
            manage?(item)
        } else if canReorder, let order, order != items.map(\.id) {
            reorder(order)
        }
    }

    /// Keeps the lifted tile under the finger while the grid reflows around it.
    private func offset(for item: Item) -> CGSize {
        guard let lift, let index = shown.firstIndex(where: { $0.id == item.id }),
              lift.slots.indices.contains(index) else { return .zero }
        let slot = lift.slots[index]
        return CGSize(width: lift.location.x - lift.grab.width - slot.minX,
                      height: lift.location.y - lift.grab.height - slot.minY)
    }

    private func nearestSlot(to point: CGPoint, in slots: [CGRect]) -> Int? {
        if let inside = slots.firstIndex(where: { $0.contains(point) }) { return inside }
        return slots.indices.min { lhs, rhs in
            hypot(slots[lhs].midX - point.x, slots[lhs].midY - point.y)
                < hypot(slots[rhs].midX - point.x, slots[rhs].midY - point.y)
        }
    }

    private func move(_ item: Item, by step: Int) {
        guard canReorder, let index = items.firstIndex(where: { $0.id == item.id }),
              items.indices.contains(index + step) else { return }
        var order = items.map(\.id)
        order.swapAt(index, index + step)
        reorder(order)
    }
}

/// Touch and hold lifts a tile; moving then drags it. UIKit's long press
/// fails as soon as the finger moves first, so a swipe that starts on a tile
/// still scrolls the list around it.
private struct HoldToArrange<Legacy: Gesture>: ViewModifier {
    let space: String
    let legacy: Legacy
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: () -> Void

    func body(content: Content) -> some View {
        #if os(visionOS) // No UIKit recognizers in SwiftUI there.
        content.simultaneousGesture(legacy)
        #else
        if #available(iOS 18.0, *) {
            content.gesture(HoldToDrag(space: space, began: began, moved: moved, ended: ended))
        } else {
            content.simultaneousGesture(legacy)
        }
        #endif
    }
}

#if !os(visionOS)
@available(iOS 18.0, *)
private struct HoldToDrag: UIGestureRecognizerRepresentable {
    let space: String
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.35
        recognizer.allowableMovement = 10
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let point = context.converter.location(in: .named(space))
        switch recognizer.state {
        case .began: began(point)
        case .changed: moved(point)
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }
}
#endif

#if targetEnvironment(macCatalyst)
/// A right-click menu for one tile of a grid that sits in a single List row
/// (pinned agents, pinned chats). SwiftUI's `.contextMenu` can't be used there:
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

/// One choice in a pinned tile's menu. The same list draws as a SwiftUI menu
/// (`TileMenuContent`, a row's `.contextMenu`) and as a UIKit one (a tile's
/// own menu), so a pinned tile and its row offer the same things.
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

/// `TileMenuItem`s as SwiftUI menu content, for a row's `.contextMenu`.
struct TileMenuContent: View {
    let items: [TileMenuItem]

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.startsGroup { Divider() }
            if let children = item.children {
                Menu {
                    TileMenuContent(items: children)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                .accessibilityIdentifier(item.identifier ?? item.title)
            } else {
                Button(item.title, systemImage: item.systemImage, role: item.isDestructive ? .destructive : nil,
                       action: item.perform)
                    .disabled(!item.isEnabled)
                    .accessibilityIdentifier(item.identifier ?? item.title)
            }
        }
    }
}

#if os(iOS)
/// The tiles' menu buttons, by tile, so the grid can open one when a tile is
/// let go without moving.
@MainActor
final class TileMenuAnchors {
    private var buttons: [String: WeakButton] = [:]

    private struct WeakButton { weak var button: UIButton? }

    func register(_ button: UIButton, for id: String) { buttons[id] = WeakButton(button: button) }

    /// Opens the tile's menu beside it. False when it can't be opened here.
    func present(_ id: String, items: [TileMenuItem]) -> Bool {
        guard #available(iOS 17.4, *), !items.isEmpty, let button = buttons[id]?.button, button.window != nil else {
            return false
        }
        button.menu = TileMenuItem.menu(items)
        button.performPrimaryAction()
        return true
    }
}

/// An invisible menu button the size of a tile. It never takes touches (the
/// tile's own tap and hold do); the grid opens its menu (`TileMenuAnchors`).
struct TileMenuAnchor: UIViewRepresentable {
    let id: String
    let anchors: TileMenuAnchors

    func makeUIView(context: Context) -> AnchorButton {
        let button = AnchorButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.isAccessibilityElement = false
        button.accessibilityElementsHidden = true
        anchors.register(button, for: id)
        return button
    }

    func updateUIView(_ button: AnchorButton, context: Context) {
        anchors.register(button, for: id)
    }

    final class AnchorButton: UIButton {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}
#endif
