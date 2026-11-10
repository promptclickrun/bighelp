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
        NavigationStack {
            ChatDrawingCanvas(box: canvas, hasStrokes: $hasStrokes)
                .ignoresSafeArea(edges: .bottom)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                            .accessibilityIdentifier("chat.drawing.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            if let image = canvas.picture() { onAdd(image) } else { onCancel() }
                        }
                        .disabled(!hasStrokes)
                        .accessibilityIdentifier("chat.drawing.add")
                    }
                }
        }
        // The page is paper in both appearances, so the picture is what was drawn.
        .preferredColorScheme(.light)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // A stroke that starts near the top must draw, not pull the sheet down.
        .interactiveDismissDisabled()
        .accessibilityIdentifier("chat.drawing")
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
