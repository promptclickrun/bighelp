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

/// Which edge of the window the system's own column (camera and status) runs along. The Duo's cover
/// screen keeps it on the trailing edge; an app on the LEFT of Split View on the inner screen has its
/// controls — that column among them — along its own leading edge instead, and a layout that assumed
/// "trailing" puts the chat switcher opposite the camera column, squeezing the page between two.
enum BighelpSideColumnEdge: String, Equatable, Sendable {
    case leading, trailing

    /// For `.move(edge:)` and an overlay's alignment.
    var edge: Edge { self == .leading ? .leading : .trailing }
    /// For the safe-area APIs, which take a set of edges.
    var edgeSet: Edge.Set { self == .leading ? .leading : .trailing }
}

/// The screen the window is on, as the layouts that differ on the Duo need it.
struct BighelpScreenGeometry: Equatable, Sendable {
    var posture: BighelpScreenPosture = .standard
    /// The window's size, safe areas included.
    var size: CGSize = .zero
    /// Which edge of the window the system's own column runs along (camera and status).
    var sideColumnEdge: BighelpSideColumnEdge = .trailing
    /// The system's column: how much of the window it takes, and where its empty part starts, under
    /// the camera and the status (`columnFreeTop`). Zero where there is none.
    var sideColumnWidth: CGFloat = 0
    var sideColumnFreeTop: CGFloat = 0
    /// The fold, in the window's coordinates, where the screen has one.
    var fold: CGRect?
    /// Half-folded: the system asks that nothing sit across the fold.
    var isFoldActive = false
    /// The system's own bottom inset (the home indicator), which the fold's half sits inside.
    var bottomInset: CGFloat = 0
    /// Wider than tall: where iPad and Mac can show the switcher beside a chat.
    var isLandscape = false

    /// The cover screen and the inner one held wide have a column on the trailing edge for the
    /// camera and the status: the bottom bar stands up in it.
    var usesSideBar: Bool { posture == .cover || posture == .open }

    /// The open posture's list has places of its own, down its leading edge: the system's column on
    /// the trailing edge belongs to the chat beside it. So the system's strip stands down there and
    /// the list carries them; everywhere else the strip is where they go.
    func placesGoWithTheList(listIsShown: Bool) -> Bool { posture == .open && listIsShown }

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

    /// The half under the fold while half-folded, clear of the system's own bottom inset. It's a
    /// page's floor: half-folded, nothing may sit across the fold and the half under it faces away,
    /// so every screen ends there and only a chat puts anything in it (its message box, then the
    /// keyboard). Zero anywhere else.
    var foldDeckHeight: CGFloat {
        guard isLaptop, let fold else { return 0 }
        return max(0, size.height - fold.minY - bottomInset)
    }

    /// The width the side bar and the switcher take. The system's column when it's wide
    /// enough, else this much is kept free beside the page.
    static let sideColumnWidth: CGFloat = 60

    /// How far down its column the iPhone Duo's camera and status reach: the height of the area
    /// the system reports there (84 × 174 points).
    static let statusAreaHeight: CGFloat = 174

    /// Where the system's column is free. The system reports where the camera and the status end,
    /// but not always: for the first moments after launch, and whenever its API returns no area,
    /// the column's inset is there with no report. Their height is kept clear then, or whatever
    /// goes in the column would start under the status and take no taps. A screen with no column
    /// of the system's (half of the open screen in Split View) has nothing to clear.
    static func columnFreeTop(reportedEnd: CGFloat?, systemColumnWidth: CGFloat) -> CGFloat {
        if let reportedEnd { return reportedEnd }
        return systemColumnWidth >= sideColumnWidth ? statusAreaHeight : 0
    }

    /// The system's column, whichever edge it is on. Split View puts an app's controls along its own
    /// outer edge, so the app left of the divider has the camera and the status along its leading
    /// edge; the cover screen keeps them trailing. The wider side wins, and a screen that reports
    /// neither keeps the trailing edge, which is where the Duo's own column is.
    static func sideColumn(leading: CGRect?, trailing: CGRect?,
                           leadingInset: CGFloat, trailingInset: CGFloat)
        -> (edge: BighelpSideColumnEdge, width: CGFloat, freeTop: CGFloat) {
        let leadingWidth = max(leadingInset, leading.map(\.width) ?? 0)
        let trailingWidth = max(trailingInset, trailing.map(\.width) ?? 0)
        let isLeading = leadingWidth > trailingWidth
        let region = isLeading ? leading : trailing
        let inset = isLeading ? leadingInset : trailingInset
        return (isLeading ? .leading : .trailing,
                isLeading ? leadingWidth : trailingWidth,
                columnFreeTop(reportedEnd: region?.maxY, systemColumnWidth: inset))
    }
}

extension EnvironmentValues {
    @Entry var bighelpScreen = BighelpScreenGeometry()
}

/// Half-folded, the half under the fold belongs to no page: the screen's other half faces away, and
/// the system asks that nothing sit across the fold. Without this, a list, a board or a bot's page
/// drew its bottom half — and its bar — under the crease, where the person can't see or touch it.
/// Every screen ends at the fold with the tab bar on it. A chat is the one page that uses that half,
/// and says so: its message box rests on it, and the keyboard rises under the message box.
struct BighelpFoldBoundary: ViewModifier {
    /// True while the page on top is a chat, which fills the half under the fold itself
    /// (`ChatView.laptopDeckHeight`, `ChatLaptopDesk`).
    let pageUsesDeck: Bool
    @Environment(\.bighelpScreen) private var screen

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            // The page's own frame ends at the fold: a list, a board and a bar all lay out inside it,
            // which a safe-area inset can't promise for the bar a root adds itself.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !pageUsesDeck, screen.foldDeckHeight > 0 {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: screen.foldDeckHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
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
        var leadingInset: CGFloat = 0
        var trailingInset: CGFloat = 0
        var bottomInset: CGFloat = 0
        var leadingOcclusion: CGRect?
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
        if BighelpScreenDebug.withholdsOcclusion { measured.occlusion = nil }
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
        // Which edge the camera and the status sit on: trailing on the cover screen, leading for the
        // app on the left of Split View. A debug column stands in for one no simulator arranges.
        let column = BighelpScreenDebug.leadingColumnWidth.map {
            (edge: BighelpSideColumnEdge.leading, width: $0,
             freeTop: BighelpScreenGeometry.statusAreaHeight)
        } ?? BighelpScreenGeometry.sideColumn(
            leading: measured.leadingOcclusion, trailing: measured.occlusion,
            leadingInset: measured.leadingInset, trailingInset: measured.trailingInset)
        return BighelpScreenGeometry(
            posture: posture,
            size: measured.size,
            sideColumnEdge: column.edge,
            sideColumnWidth: column.width,
            sideColumnFreeTop: column.freeTop,
            fold: measured.fold,
            isFoldActive: measured.isFoldActive,
            bottomInset: measured.bottomInset,
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
            leadingInset: insets.leading,
            trailingInset: insets.trailing,
            bottomInset: insets.bottom)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            func inWindow(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: insets.leading, dy: insets.top) }
            let half = measured.size.width / 2
            // Both edges: Split View keeps an app's camera and status on its own outer edge, which is
            // the leading one for the app on the left.
            func merged(_ frames: [CGRect]) -> CGRect? {
                frames.reduce(nil as CGRect?) { union, frame in union.map { $0.union(frame) } ?? frame }
            }
            let regions = proxy.reservedRegions(kind: .occlusion).filter(\.isActive).map { inWindow($0.frame) }
            measured.leadingOcclusion = merged(regions.filter { $0.midX < half })
            measured.occlusion = merged(regions.filter { $0.midX > half })
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

    /// A screen whose system reports no camera and status area, which the system's API allows:
    /// `-bighelp.debug.no-occlusion YES`. The system's column itself stays.
    static var withholdsOcclusion: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "bighelp.debug.no-occlusion")
        #else
        false
        #endif
    }

    /// The system's column on the leading edge, as Split View gives the app left of the divider and no
    /// simulator arranges. `-bighelp.debug.leading-column 84`.
    static var leadingColumnWidth: CGFloat? {
        #if DEBUG
        let width = UserDefaults.standard.double(forKey: "bighelp.debug.leading-column")
        return width > 0 ? width : nil
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
