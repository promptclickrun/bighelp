import SwiftUI
import UIKit

/// The live screen. Watching, or with "move the view" on: pinch to zoom and drag to look
/// around. In control: a tap clicks, a long press right-clicks, one finger drags, two
/// fingers scroll. On the Mac the mouse, trackpad and keyboard go straight to the screen.
struct BotScreenCanvas: UIViewRepresentable {
    let model: BotScreenViewerModel
    let label: String
    // Passed in, not read off the model here, so SwiftUI updates the view whenever they change.
    let screenSize: BotScreenSize
    let inControl: Bool
    let drivesScreen: Bool
    let wantsKeyboard: Bool

    init(model: BotScreenViewerModel, label: String) {
        self.model = model
        self.label = label
        screenSize = model.screenSize
        inControl = model.isInControl
        drivesScreen = model.isInControl && model.touchesDriveScreen
        wantsKeyboard = model.showsKeyboard
    }

    func makeUIView(context: Context) -> BotScreenCanvasView {
        let view = BotScreenCanvasView()
        view.model = model
        model.frameSink = { [weak view] frame in view?.show(frame) }
        return view
    }

    func updateUIView(_ view: BotScreenCanvasView, context: Context) {
        view.accessibilityLabel = label
        view.update(screenSize: screenSize, inControl: inControl, drivesScreen: drivesScreen,
                    wantsKeyboard: wantsKeyboard)
    }
}

final class BotScreenCanvasView: UIView, UIScrollViewDelegate, UIKeyInput, UIPointerInteractionDelegate {
    weak var model: BotScreenViewerModel?

    private let scrollView = UIScrollView()
    private let screenView = UIView()
    private var screenSize = BotScreenSize.standard
    private var inControl = false
    private var drivesScreen = false
    private var wantsKeyboard = false
    private var fittedSize = CGSize.zero
    private var scrollCarry = CGPoint.zero
    /// Keys down on a hardware keyboard, by HID usage, with the keysym their press sent.
    private var heldKeys: [Int: UInt32] = [:]
    private lazy var inputGestures: [UIGestureRecognizer] = makeInputGestures()

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        screenView.layer.contentsGravity = .resize
        screenView.layer.minificationFilter = .trilinear
        screenView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        scrollView.addSubview(screenView)
        addSubview(scrollView)
        inputGestures.forEach(scrollView.addGestureRecognizer)
        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityIdentifier = "screen.viewer.canvas"
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ frame: RFBFrame) {
        screenView.layer.contents = frame.image
    }

    func update(screenSize: BotScreenSize, inControl: Bool, drivesScreen: Bool, wantsKeyboard: Bool) {
        if screenSize != self.screenSize {
            self.screenSize = screenSize
            fittedSize = .zero
            setNeedsLayout()
        }
        if !inControl, self.inControl { releaseHeldKeys() }
        self.inControl = inControl
        self.drivesScreen = drivesScreen
        self.wantsKeyboard = wantsKeyboard
        applyMode()
        updateKeyboardFocus()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let available = bounds.size
        guard available.width > 0, available.height > 0 else { return }
        var fit = available
        if available.width / available.height > screenSize.aspectRatio {
            fit.width = available.height * screenSize.aspectRatio
        } else {
            fit.height = available.width / screenSize.aspectRatio
        }
        fit = CGSize(width: fit.width.rounded(.down), height: fit.height.rounded(.down))
        if fit != fittedSize {
            fittedSize = fit
            scrollView.zoomScale = 1
            screenView.frame = CGRect(origin: .zero, size: fit)
            scrollView.contentSize = fit
        }
        centerScreen()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateKeyboardFocus()
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { screenView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerScreen() }

    private func centerScreen() {
        let content = scrollView.contentSize
        let available = scrollView.bounds.size
        scrollView.contentInset = UIEdgeInsets(top: max(0, (available.height - content.height) / 2),
                                               left: max(0, (available.width - content.width) / 2),
                                               bottom: 0, right: 0)
    }

    private func applyMode() {
        inputGestures.forEach { $0.isEnabled = drivesScreen }
        #if targetEnvironment(macCatalyst)
        // A Mac has a real right button; holding the left one is a drag, not a right-click.
        inputGestures.first { $0 is UILongPressGestureRecognizer }?.isEnabled = false
        #endif
        scrollView.isScrollEnabled = !drivesScreen
        scrollView.pinchGestureRecognizer?.isEnabled = !drivesScreen
    }

    // MARK: Pointer

    private func makeInputGestures() -> [UIGestureRecognizer] {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let secondaryTap = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryTap))
        secondaryTap.buttonMaskRequired = .secondary
        // A finger's tap would match too and turn every tap into a right-click.
        secondaryTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.5
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        let twoFingers = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        twoFingers.minimumNumberOfTouches = 2
        twoFingers.maximumNumberOfTouches = 2
        // A mouse wheel or trackpad scroll carries no touches at all.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
        return [tap, secondaryTap, longPress, drag, twoFingers, wheel, hover]
    }

    /// Where a gesture is on the screen, in the screen's own pixels.
    private func screenPoint(_ location: CGPoint) -> CGPoint {
        let size = screenView.bounds.size
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: location.x / size.width * CGFloat(screenSize.width),
                       y: location.y / size.height * CGFloat(screenSize.height))
    }

    private func screenPoint(_ recognizer: UIGestureRecognizer) -> CGPoint {
        screenPoint(recognizer.location(in: screenView))
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        model?.click(.left, at: screenPoint(recognizer))
    }

    @objc private func handleSecondaryTap(_ recognizer: UITapGestureRecognizer) {
        model?.click(.right, at: screenPoint(recognizer))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        model?.click(.right, at: screenPoint(recognizer))
    }

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        let point = screenPoint(recognizer)
        switch recognizer.state {
        case .began:
            // The pan starts after the finger has moved a little; press where it went down.
            let location = recognizer.location(in: screenView)
            let moved = recognizer.translation(in: screenView)
            let start = screenPoint(CGPoint(x: location.x - moved.x, y: location.y - moved.y))
            model?.movePointer(to: start)
            model?.press(.left, at: start)
            model?.movePointer(to: point)
        case .changed:
            model?.movePointer(to: point)
        case .ended, .cancelled, .failed:
            model?.release(.left, at: point)
        default:
            break
        }
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            scrollCarry = .zero
        case .changed:
            let moved = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            scrollCarry.x += moved.x
            scrollCarry.y += moved.y
            let step: CGFloat = 24
            let point = screenPoint(recognizer)
            // Content follows the fingers: moving them down scrolls up.
            let vertical = Int(scrollCarry.y / step)
            if vertical != 0 {
                model?.scroll(vertical > 0 ? .wheelUp : .wheelDown, steps: abs(vertical), at: point)
                scrollCarry.y -= CGFloat(vertical) * step
            }
            let horizontal = Int(scrollCarry.x / step)
            if horizontal != 0 {
                model?.scroll(horizontal > 0 ? .wheelLeft : .wheelRight, steps: abs(horizontal), at: point)
                scrollCarry.x -= CGFloat(horizontal) * step
            }
        default:
            break
        }
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        model?.movePointer(to: screenPoint(recognizer))
    }

    /// The screen draws its own pointer, so the Mac's and iPad's hides over it while driving.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        drivesScreen ? .hidden() : nil
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { inControl }

    private func updateKeyboardFocus() {
        guard window != nil else { return }
        #if targetEnvironment(macCatalyst)
        // A Mac's keyboard types on the screen whenever this person is in control.
        let wantsFocus = inControl
        #else
        let wantsFocus = inControl && wantsKeyboard
        #endif
        if wantsFocus, !isFirstResponder {
            becomeFirstResponder()
        } else if !wantsFocus, isFirstResponder {
            resignFirstResponder()
        }
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            releaseHeldKeys()
            // The keyboard went away on its own (the iPad's hide-keyboard key): say so.
            if model?.showsKeyboard == true { model?.showsKeyboard = false }
        }
        return resigned
    }

    var hasText: Bool { true }

    func insertText(_ text: String) { model?.type(text) }

    func deleteBackward() {
        model?.key(RFBKeysym.backSpace, down: true)
        model?.key(RFBKeysym.backSpace, down: false)
    }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard inControl, let key = press.key, let keysym = Self.keysym(for: key) else {
                unhandled.insert(press)
                continue
            }
            heldKeys[key.keyCode.rawValue] = keysym
            model?.key(keysym, down: true)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseKeys(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = releaseKeys(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func releaseKeys(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let keysym = heldKeys.removeValue(forKey: key.keyCode.rawValue) else {
                unhandled.insert(press)
                continue
            }
            model?.key(keysym, down: false)
        }
        return unhandled
    }

    private func releaseHeldKeys() {
        for keysym in heldKeys.values { model?.key(keysym, down: false) }
        heldKeys = [:]
    }

    /// ⌘ shortcuts stay the Mac's (⌘W, ⌘Q); everything else goes to the screen.
    private static func keysym(for key: UIKey) -> UInt32? {
        guard !key.modifierFlags.contains(.command) else { return nil }
        let usage = key.keyCode.rawValue
        if let modifier = RFBKeysym.forModifier(usage: usage) { return modifier }
        return RFBKeysym.forHardwareKey(usage: usage, characters: key.characters,
                                        charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                        controlOrAlt: !key.modifierFlags.isDisjoint(with: [.control, .alternate]))
    }
}
