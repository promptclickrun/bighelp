import SwiftUI
import UIKit

/// The home's places handed to iOS as toolbar items, for the iPhone Duo's side strip. Built with the
/// iOS 27.1 SDK, the Duo lays a screen's toolbar out down the strip, so the places line up with the
/// screen's own buttons there instead of a column of our own lying over them (`BighelpStripTabs`).
struct HomeStripTabs: ToolbarContent {
    @Binding var selection: HomeTab
    let items: [HomeTabItem]
    var onNewChat: (() -> Void)?
    let selectedTint: Color
    let tint: Color

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            ForEach(items) { item in
                place(item)
            }
            if let onNewChat {
                Button(action: onNewChat) {
                    Label(FloatingTabBar.newChatVisibleLabel, systemImage: "square.and.pencil")
                }
                .tint(selectedTint)
                .accessibilityIdentifier(HomeTabBar.newChatIdentifier)
            }
        }
    }

    private func place(_ item: HomeTabItem) -> some View {
        let isSelected = selection == item.id
        let isNew = item.showsDot(selected: isSelected)
        return Button {
            BighelpKeyboard.dismiss()
            selection = item.id
        } label: {
            Label { Text(item.title) } icon: { icon(item, selected: isSelected, isNew: isNew) }
                .labelStyle(.iconOnly)
        }
        .tint(isSelected ? selectedTint : tint)
        .accessibilityLabel(item.title)
        .accessibilityValue(isNew ? String(localized: "New") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }

    private func icon(_ item: HomeTabItem, selected: Bool, isNew: Bool) -> Image {
        let name = item.symbol(selected: selected)
        guard isNew, let base = UIImage(systemName: name) else { return Image(systemName: name) }
        // A toolbar button shows no badge, so Today with something new draws the bar's dot into its
        // icon, colored here as the toolbar would have tinted it.
        let diameter = max(6, base.size.width * 0.28)
        // The dot gets its own corner, just outside the icon's art.
        let inset = diameter * 0.5
        let size = CGSize(width: base.size.width + inset, height: base.size.height + inset)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            base.withTintColor(UIColor(tint), renderingMode: .alwaysOriginal).draw(at: CGPoint(x: 0, y: inset))
            UIColor(selectedTint).setFill()
            UIBezierPath(ovalIn: CGRect(x: size.width - diameter, y: 0, width: diameter, height: diameter)).fill()
        }
        // On the image itself: the toolbar tints anything it's allowed to.
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
    }
}
