import SwiftUI

#if os(visionOS)
/// Vision Pro's places: a vertical glass strip beside the window, where visionOS puts its own tab
/// bars, with New chat under them. Each target is 60pt and lights up where you look. Shown at the
/// roots only; a pushed chat has Back.
struct HomeTabOrnament: View {
    @Binding var selection: HomeTab
    let items: [HomeTabItem]
    var onNewChat: (() -> Void)?

    var body: some View {
        VStack(spacing: BighelpTokens.space8) {
            ForEach(items) { item in place(item) }
            if let onNewChat {
                Divider().frame(width: 36)
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.bighelp(.title2).weight(.semibold))
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.plain)
                .buttonBorderShape(.circle)
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.highlight)
                .help(FloatingTabBar.newChatVisibleLabel)
                .accessibilityLabel(FloatingTabBar.newChatAccessibilityLabel)
                .accessibilityIdentifier(HomeTabBar.newChatIdentifier)
            }
        }
        .padding(BighelpTokens.space12)
        .glassBackgroundEffect(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Primary navigation")
        .accessibilityIdentifier("primary-navigation")
    }

    private func place(_ item: HomeTabItem) -> some View {
        let isSelected = selection == item.id
        let showsDot = item.showsDot(selected: isSelected)
        return Button {
            selection = item.id
        } label: {
            Image(systemName: item.symbol(selected: isSelected))
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)
                .frame(width: 28, height: 28)
                .frame(width: 60, height: 60)
                .background {
                    if isSelected { Circle().fill(.white.opacity(0.22)) }
                }
                .overlay(alignment: .topTrailing) {
                    if showsDot {
                        Circle().fill(Color.accentColor).frame(width: 10, height: 10).padding(8)
                    }
                }
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityValue(showsDot ? String(localized: "New") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }
}
#endif
