import SwiftUI
import UIKit
#if os(iOS) && !targetEnvironment(macCatalyst)
import PencilKit
#endif

/// Drawing from the plus menu: Apple's canvas and tool picker on a sheet. Add hands back the
/// drawing as a picture for the message; Cancel throws it away.
struct ChatDrawingSheet: View {
    /// Apple's canvas with finger drawing and its tool picker: iPhone and iPad.
    static var isSupported: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    let onAdd: (UIImage) -> Void
    let onCancel: () -> Void

    #if os(iOS) && !targetEnvironment(macCatalyst)
    @State private var canvas = ChatDrawingCanvasBox()
    @State private var hasStrokes = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(PaperButtonStyle(isProminent: false))
                    .accessibilityIdentifier("chat.drawing.cancel")
                Spacer()
                Button("Add") {
                    if let image = canvas.picture() { onAdd(image) } else { onCancel() }
                }
                .buttonStyle(PaperButtonStyle(isProminent: true))
                .disabled(!hasStrokes)
                .accessibilityIdentifier("chat.drawing.add")
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space12)
            ChatDrawingCanvas(box: canvas, hasStrokes: $hasStrokes)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color.white)
        .presentationBackground(Color.white)
        .presentationDetents([.large])
        // A stroke that starts near the top must draw, not pull the sheet down.
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.drawing")
    }

    /// The page is white paper in both appearances, so the picture is what was drawn. Its buttons
    /// have their own fixed colors: a navigation bar's follow the app's appearance, and in dark
    /// mode they were white words on the white page.
    private struct PaperButtonStyle: ButtonStyle {
        let isProminent: Bool
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.bighelp(.body).weight(.semibold))
                .foregroundStyle(isProminent ? Color.white : Color.black)
                .padding(.horizontal, BighelpTokens.space16)
                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                .background(isProminent ? Color.black : Color(white: 0.92), in: .capsule)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.3)
                .contentShape(.capsule)
        }
    }
    #else
    var body: some View { EmptyView() }
    #endif
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// Holds the canvas for the sheet's Add, which reads the drawing out of it.
@MainActor
final class ChatDrawingCanvasBox {
    weak var view: PKCanvasView?

    /// The strokes on white, with a margin, at the screen's scale; nil when nothing is drawn.
    func picture() -> UIImage? {
        guard let view, !view.drawing.strokes.isEmpty else { return nil }
        let frame = view.drawing.bounds.insetBy(dx: -24, dy: -24).intersection(view.bounds)
        guard frame.width > 0, frame.height > 0 else { return nil }
        let scale = view.window?.screen.scale ?? 2
        let strokes = view.drawing.image(from: frame, scale: scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: frame.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: frame.size))
            strokes.draw(in: CGRect(origin: .zero, size: frame.size))
        }
    }
}

private struct ChatDrawingCanvas: UIViewRepresentable {
    let box: ChatDrawingCanvasBox
    @Binding var hasStrokes: Bool

    func makeCoordinator() -> Coordinator { Coordinator(hasStrokes: $hasStrokes) }

    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView()
        view.drawingPolicy = .anyInput
        view.backgroundColor = .white
        view.isOpaque = true
        view.overrideUserInterfaceStyle = .light
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "chat.drawing.canvas"
        box.view = view
        let picker = context.coordinator.picker
        // The palette and its colors go by the white page too. Left to dark mode, the picker
        // takes its black as white.
        picker.overrideUserInterfaceStyle = .light
        picker.colorUserInterfaceStyle = .light
        picker.addObserver(view)
        picker.setVisible(true, forFirstResponder: view)
        // The picker shows for the first responder, which a view becomes only once it's in a window.
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {}

    static func dismantleUIView(_ view: PKCanvasView, coordinator: Coordinator) {
        coordinator.picker.setVisible(false, forFirstResponder: view)
        coordinator.picker.removeObserver(view)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let picker = PKToolPicker()
        private let hasStrokes: Binding<Bool>

        init(hasStrokes: Binding<Bool>) {
            self.hasStrokes = hasStrokes
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let drawn = !canvasView.drawing.strokes.isEmpty
            if hasStrokes.wrappedValue != drawn { hasStrokes.wrappedValue = drawn }
        }
    }
}
#endif
