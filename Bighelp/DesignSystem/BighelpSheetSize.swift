import SwiftUI

/// How big a sheet opens on the Mac. There sheets are panels sized to their
/// content, and detents (iPhone) don't apply, so a sheet that names no size
/// opens small. iPhone, iPad and Vision Pro ignore this.
enum BighelpSheetSize: Sendable {
    /// A short choice or confirmation.
    case compact
    /// A form, list or editor: most sheets.
    case standard
    /// A studio, board or anything with a big preview.
    case large

    /// Mac sheets open at their content's minimum size, so this is the size they open at.
    fileprivate var preferred: CGSize {
        switch self {
        case .compact: CGSize(width: 480, height: 420)
        case .standard: CGSize(width: 680, height: 740)
        case .large: CGSize(width: 920, height: 780)
        }
    }

    #if targetEnvironment(macCatalyst)
    /// The preferred size, kept clear of the screen's edges and menu bar.
    @MainActor fileprivate var opening: CGSize {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(width: min(preferred.width, screen.width - 80), height: min(preferred.height, screen.height - 140))
    }
    #endif
}

extension View {
    /// `.sheet`, with a Mac fix: Catalyst sometimes leaves a sheet on screen after
    /// SwiftUI closes it (Done runs, the state says closed, but the sheet stays,
    /// stops updating and blocks the window until Esc). The screen that opened it
    /// then closes it through UIKit. Use it for every sheet.
    func bighelpSheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        #if targetEnvironment(macCatalyst)
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
            .background { BighelpMacSheetCloser(token: isPresented.wrappedValue ? AnyHashable(true) : nil) }
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    func bighelpSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                         @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if targetEnvironment(macCatalyst)
        sheet(item: item, onDismiss: onDismiss, content: content)
            .background { BighelpMacSheetCloser(token: item.wrappedValue.map { AnyHashable($0.id) }) }
        #else
        sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    /// `.fullScreenCover`, with the same Mac fix as `bighelpSheet`.
    func bighelpFullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                               @ViewBuilder content: @escaping () -> Content) -> some View {
        #if targetEnvironment(macCatalyst)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
            .background { BighelpMacSheetCloser(token: isPresented.wrappedValue ? AnyHashable(true) : nil) }
        #else
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    func bighelpFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
            .background { BighelpMacSheetCloser(token: item.wrappedValue.map { AnyHashable($0.id) }) }
        #else
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    /// Keeps UIKit in sync when a reopened Catalyst popover closes in SwiftUI.
    func bighelpPopoverDismissal(isPresented: Binding<Bool>) -> some View {
        #if targetEnvironment(macCatalyst)
        background { BighelpMacPopoverDismissal(isPresented: isPresented) }
        #else
        self
        #endif
    }

    /// The sheet's size on the Mac; put it on the sheet's content.
    func bighelpSheetSize(_ size: BighelpSheetSize = .standard) -> some View {
        #if targetEnvironment(macCatalyst)
        frame(minWidth: size.opening.width, maxWidth: .infinity, minHeight: size.opening.height, maxHeight: .infinity)
        #else
        self
        #endif
    }
}

/// Transient chat choices attach to their originating control on the Mac.
/// Other platforms retain their existing sheet presentation.
enum BighelpChatPanelAnchor: Hashable {
    case attachments
    case appearance
}

extension View {
    func bighelpChatPanelAnchor(_ anchor: BighelpChatPanelAnchor) -> some View {
        #if targetEnvironment(macCatalyst)
        anchorPreference(key: BighelpChatPanelAnchors.self, value: .bounds) { [anchor: $0] }
        #else
        self
        #endif
    }

    func bighelpChatPanel<Panel: View>(
        isPresented: Binding<Bool>,
        anchor: BighelpChatPanelAnchor,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder panel: @escaping () -> Panel
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(BighelpChatPanelPresenter(
            isPresented: isPresented, anchor: anchor, onDismiss: onDismiss, panel: panel
        ))
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: panel)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct BighelpChatPanelPresenter<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let anchor: BighelpChatPanelAnchor
    let onDismiss: (() -> Void)?
    @ViewBuilder let panel: () -> Panel
    @State private var layout = BighelpChatPanelLayout()

    func body(content: Content) -> some View {
        // The presentation belongs to the stable chat view. Anchor preference
        // readers only measure geometry; they do not own a modal controller.
        content
            .backgroundPreferenceValue(BighelpChatPanelAnchors.self) { anchors in
                GeometryReader { geometry in
                    Color.clear
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .preference(key: BighelpChatPanelLayouts.self, value: [
                            anchor: BighelpChatPanelLayout(
                                rect: anchors[anchor].map { geometry[$0] }
                                    ?? CGRect(x: geometry.size.width / 2, y: geometry.size.height / 2,
                                              width: 1, height: 1),
                                availableSize: geometry.size
                            )
                        ])
                }
            }
            .onPreferenceChange(BighelpChatPanelLayouts.self) { layouts in
                if let resolved = layouts[anchor] { layout = resolved }
            }
            .popover(isPresented: $isPresented,
                     attachmentAnchor: layout.rect.isEmpty ? .rect(.bounds) : .rect(.rect(layout.rect)),
                     arrowEdge: anchor == .attachments ? .bottom : .top) {
                panel()
                    .frame(width: min(560, max(280, layout.availableSize.width - 32)),
                           height: min(620, max(300, layout.availableSize.height - 100)))
                    .presentationCompactAdaptation(.popover)
                    .bighelpPopoverDismissal(isPresented: $isPresented)
                    .onDisappear { onDismiss?() }
            }
    }
}

/// Remembers the sheet UIKit put up for one `bighelpSheet`, and closes it if
/// it's still up a moment after SwiftUI closed it.
private struct BighelpMacSheetCloser: UIViewRepresentable {
    /// What's presented: nil while closed, the item's ID for `item:` sheets.
    let token: AnyHashable?

    final class Coordinator {
        weak var sheet: UIViewController?
        var token: AnyHashable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A plain view, never a view controller: chat message rows (which own sheets) are UIKit
    /// cells, and a cell can't host a view controller. SwiftUI drew a yellow box with a "no"
    /// sign in its place, behind every message (`MacSheetPresentationTests`).
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        guard token != coordinator.token else { return }
        coordinator.token = token
        if let token {
            let before = coordinator.sheet ?? Self.presenter(of: view)?.presentedViewController
            // SwiftUI puts the sheet up after this update.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak view] in
                guard coordinator.token == token, let view,
                      let sheet = Self.presenter(of: view)?.presentedViewController, sheet !== before else { return }
                coordinator.sheet = sheet
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard coordinator.token == nil, let sheet = coordinator.sheet else { return }
                coordinator.sheet = nil
                // SwiftUI closed it, or is closing it: nothing to do.
                guard sheet.presentingViewController != nil, sheet.view.window != nil, !sheet.isBeingDismissed else { return }
                sheet.dismiss(animated: true)
            }
        }
    }

    /// The nearest controller above this view that has something presented.
    private static func presenter(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view.next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        var candidate = responder as? UIViewController
        while let current = candidate {
            if current.presentedViewController != nil { return current }
            candidate = current.parent
        }
        return view.window?.rootViewController
    }
}

// Catalyst can leave a reopened SwiftUI popover visible after its binding is
// false. Dismiss from within that popover, without touching another window.
private struct BighelpMacPopoverDismissal: UIViewControllerRepresentable {
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard !isPresented, controller.view.window != nil else { return }
        var candidate: UIViewController? = controller
        while let current = candidate, current.presentingViewController == nil {
            candidate = current.parent
        }
        guard let presented = candidate else { return }
        guard !presented.isBeingDismissed else { return }
        let presentation = _isPresented
        DispatchQueue.main.async { [weak presented] in
            guard !presentation.wrappedValue, let presented,
                  presented.view.window != nil,
                  presented.presentingViewController != nil,
                  !presented.isBeingDismissed else { return }
            presented.dismiss(animated: true)
        }
    }
}

private struct BighelpChatPanelLayout: Equatable {
    var rect: CGRect = .zero
    var availableSize: CGSize = CGSize(width: 680, height: 740)
}

private struct BighelpChatPanelLayouts: PreferenceKey {
    static var defaultValue: [BighelpChatPanelAnchor: BighelpChatPanelLayout] { [:] }

    static func reduce(value: inout [BighelpChatPanelAnchor: BighelpChatPanelLayout],
                       nextValue: () -> [BighelpChatPanelAnchor: BighelpChatPanelLayout]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct BighelpChatPanelAnchors: PreferenceKey {
    static var defaultValue: [BighelpChatPanelAnchor: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [BighelpChatPanelAnchor: Anchor<CGRect>],
                       nextValue: () -> [BighelpChatPanelAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
#endif
