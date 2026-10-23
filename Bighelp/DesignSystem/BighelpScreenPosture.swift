import SwiftUI

/// Which of the iPhone Duo's screens the app is on, and how it's held.
///
/// The cover screen is wide and short (466 × 678 pt), with the camera and the status in an 84-pt
/// column on its trailing edge. The inner screen opens to 951 × 669 pt, regular both ways, with the
/// fold down its middle; held the other way up it's 669 × 951 with the fold across it, the way it
/// sits half-folded like a small laptop. Each half of iOS's 50/50 Split View is about the cover
/// screen's size and shape, so it gets the cover screen's layouts.
enum BighelpScreenPosture: String, Equatable, Sendable {
    /// Every other iPhone, iPad, Mac and Vision Pro: the layouts they've always had.
    case standard
    /// The cover screen, or half of the inner one: short and wide. The bottom bar stands up in
    /// the side column, and chats can have the switcher beside them.
    case cover
    /// The inner screen held wide, the fold down its middle: the list on one side of the fold,
    /// the chat on the other, like the pages of a book.
    case open
    /// The inner screen held upright, the fold across it. Laid out like a big phone; half-folded
    /// (a small laptop), chats keep their messages above the fold and type below it.
    case openUpright

    /// Taller than this (height over width) is an ordinary phone held upright: 2.17 for most
    /// iPhones, 1.78 for the smallest. The cover screen is 1.46, half of the inner one 1.41.
    static let coverMaximumAspect: CGFloat = 1.7
    /// Wider than this is the inner screen, never the cover one, whatever its shape.
    static let coverMaximumWidth: CGFloat = 520

    static func classify(
        isPhone: Bool,
        horizontal: UserInterfaceSizeClass?,
        vertical: UserInterfaceSizeClass?,
        size: CGSize
    ) -> BighelpScreenPosture {
        guard isPhone, size.width > 0, size.height > 0 else { return .standard }
        // Only the inner screen gives a phone regular width and height; any other iPhone on its
        // side is compact height.
        if horizontal == .regular, vertical == .regular {
            return size.width >= size.height ? .open : .openUpright
        }
        if horizontal == .compact, vertical == .regular, size.width <= coverMaximumWidth,
           size.height / size.width < coverMaximumAspect {
            return .cover
        }
        return .standard
    }

    static var isPhone: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}

/// The screen the window is on, as the layouts that differ on the Duo need it.
struct BighelpScreenGeometry: Equatable, Sendable {
    var posture: BighelpScreenPosture = .standard
    /// The window's size, safe areas included.
    var size: CGSize = .zero
    /// The system's column on the trailing edge (camera and status), measured from the window's
    /// trailing edge. Zero where there is none.
    var trailingColumnWidth: CGFloat = 0
    /// Where the column's empty part starts, under the camera and the status.
    var trailingColumnFreeTop: CGFloat = 0
    /// The fold, in the window's coordinates, where the screen has one.
    var fold: CGRect?
    /// Half-folded: the system asks that nothing sit across the fold.
    var isFoldActive = false
    /// Wider than tall: where iPad and Mac can show the switcher beside a chat.
    var isLandscape = false

    /// The cover screen and the inner one held wide have a column on the trailing edge for the
    /// camera and the status: the bottom bar stands up in it.
    var usesSideBar: Bool { posture == .cover || posture == .open }

    /// Half-folded with the fold across the screen, like a small laptop: messages above it, the
    /// message box and the keyboard below.
    var isLaptop: Bool {
        guard posture == .openUpright, isFoldActive, let fold else { return false }
        return fold.width > fold.height
    }

    /// The list's width beside the chat when open: up to the fold, so nothing sits across it and
    /// each side is the size of the cover screen. Without a fold to go by, about an iPhone's width.
    var splitColumnWidth: CGFloat {
        guard let fold, fold.height > fold.width, size.width > 0 else { return 340 }
        return min(max(fold.minX, 300), max(300, size.width - 360))
    }

    /// The width the side bar and the switcher take. The system's column when it's wide
    /// enough, else this much is kept free beside the page.
    static let sideColumnWidth: CGFloat = 60
}

extension EnvironmentValues {
    @Entry var bighelpScreen = BighelpScreenGeometry()
}

/// Works out the posture from the window's size, size classes and the fold, and hands it to every
/// screen, pushed chats included. Apply it outside the navigation stack, around the whole window.
struct BighelpScreenPostureReader: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var measured = Measured()

    /// What the window's geometry says, in the window's coordinates.
    struct Measured: Equatable {
        var size: CGSize = .zero
        var trailingInset: CGFloat = 0
        var occlusion: CGRect?
        var fold: CGRect?
        var isFoldActive = false
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Measured.self) { proxy in
                Self.measure(proxy)
            } action: { measured = $0 }
            .environment(\.bighelpScreen, Self.geometry(measured, horizontal: horizontalSizeClass,
                                                        vertical: verticalSizeClass))
            #if DEBUG
            .overlay(alignment: .topLeading) {
                // The simulated fold, drawn so screenshots show what lies across it.
                if BighelpScreenDebug.foldsHalfway, let fold = Self.geometry(measured, horizontal: horizontalSizeClass,
                                                                               vertical: verticalSizeClass).fold {
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .foregroundStyle(Color.red.opacity(0.7))
                        .frame(width: max(fold.width, 1), height: max(fold.height, 1))
                        .offset(x: fold.minX, y: fold.minY)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            #endif
    }

    static func geometry(_ measured: Measured, horizontal: UserInterfaceSizeClass?,
                         vertical: UserInterfaceSizeClass?) -> BighelpScreenGeometry {
        var measured = measured
        let posture = BighelpScreenDebug.posture ?? BighelpScreenPosture.classify(
            isPhone: BighelpScreenPosture.isPhone, horizontal: horizontal, vertical: vertical, size: measured.size)
        let isLandscape = measured.size.width > measured.size.height
        // Everywhere but the Duo, only which way up the window is: resizing a Mac window or
        // dragging iPad's Split View doesn't redraw every screen that reads this.
        guard posture != .standard else { return BighelpScreenGeometry(isLandscape: isLandscape) }
        if BighelpScreenDebug.foldsHalfway, measured.size.width > 0 {
            // DEBUG: a half-folded screen, as the simulator can't fold one.
            let size = measured.size
            measured.fold = size.width >= size.height
                ? CGRect(x: size.width / 2 - 6, y: 0, width: 12, height: size.height)
                : CGRect(x: 0, y: size.height / 2 - 6, width: size.width, height: 12)
            measured.isFoldActive = true
        }
        return BighelpScreenGeometry(
            posture: posture,
            size: measured.size,
            trailingColumnWidth: max(measured.trailingInset,
                                     measured.occlusion.map { max(0, measured.size.width - $0.minX) } ?? 0),
            trailingColumnFreeTop: measured.occlusion.map(\.maxY) ?? 0,
            fold: measured.fold,
            isFoldActive: measured.isFoldActive,
            isLandscape: isLandscape
        )
    }

    /// The window's size, the camera's column and the fold. Reserved regions come in the proxy's
    /// own coordinates, which start inside the safe area; they're moved to the window's.
    nonisolated private static func measure(_ proxy: GeometryProxy) -> Measured {
        let insets = proxy.safeAreaInsets
        var measured = Measured(
            size: CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                         height: proxy.size.height + insets.top + insets.bottom),
            trailingInset: insets.trailing)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            func inWindow(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: insets.leading, dy: insets.top) }
            let half = measured.size.width / 2
            measured.occlusion = proxy.reservedRegions(kind: .occlusion)
                .filter { $0.isActive && inWindow($0.frame).midX > half }
                .map { inWindow($0.frame) }
                .reduce(nil as CGRect?) { merged, frame in merged.map { $0.union(frame) } ?? frame }
            // Where the fold is even while the screen lies flat, so the list can stop at it.
            let folds = proxy.reservedRegions(kind: .division, options: .includeInactive)
            if let fold = folds.first(where: \.isActive) ?? folds.first {
                measured.fold = inWindow(fold.frame)
                measured.isFoldActive = fold.isActive
            }
        }
        #endif
        return measured
    }
}

/// DEBUG and UI tests: show a posture on any device, and a half-folded screen, which the simulator
/// can't fold. `-bighelp.debug.screen-posture cover|open|openUpright`, `-bighelp.debug.fold-halfway YES`.
enum BighelpScreenDebug {
    static var posture: BighelpScreenPosture? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "bighelp.debug.screen-posture").flatMap(BighelpScreenPosture.init(rawValue:))
        #else
        nil
        #endif
    }

    static var foldsHalfway: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "bighelp.debug.fold-halfway")
        #else
        false
        #endif
    }
}
