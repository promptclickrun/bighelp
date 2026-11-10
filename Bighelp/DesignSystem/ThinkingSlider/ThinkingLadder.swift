import CoreGraphics

// The Thinking control's arithmetic: where a touch is on the track, which level that is, and what a
// drag sends. Adapted from hermex (MIT).

enum ThinkingSliderMetrics {
    static let height: CGFloat = 56
    /// How far the thumb's center stays from each end of the track.
    static let inset: CGFloat = 24
}

/// One level the control offers.
struct BighelpThinkingLevel: Equatable, Identifiable, Sendable {
    /// What goes to the host.
    let value: String
    /// The name in the header and the large-text list ("Medium").
    let title: String
    /// The name under the track ("Med").
    let shortTitle: String

    var id: String { value }
}

/// Hermes' automatic level ("Auto"), which is not a point on the ladder. While it is on, the value
/// reads its title, the thumb rests at the bottom and no label is bold.
struct BighelpThinkingAutomatic {
    let title: String
    let isOn: Bool
    let select: () -> Void
}

/// The levels the control offers and where the chat is on them. The host's level stays on the ladder
/// even when the model's list doesn't name it, so a newer host's level still shows.
struct ThinkingLadder: Equatable {
    let levels: [String]
    let currentIndex: Int?

    init(levels: [String], current: String?) {
        var levels = levels
        if let current, !levels.contains(current) { levels.append(current) }
        self.levels = levels
        currentIndex = current.flatMap(levels.firstIndex(of:))
    }

    /// Where a touch at `x` is along the track, 0 to 1. The thumb's center stops short of each end,
    /// so a finger on the thumb at either end reads as that end, and past it stays on the ladder.
    static func position(atX x: CGFloat, width: CGFloat) -> Double {
        let span = max(width - ThinkingSliderMetrics.inset * 2, 1)
        return Double(min(max((x - ThinkingSliderMetrics.inset) / span, 0), 1))
    }

    /// The nearest level to a position along the track.
    func index(atPosition position: Double) -> Int {
        guard levels.count > 1 else { return 0 }
        return Int((min(max(position, 0), 1) * Double(levels.count - 1)).rounded())
    }

    func position(of index: Int) -> Double {
        levels.count > 1 ? Double(index) / Double(levels.count - 1) : 0
    }

    /// What a release at `index` sends: nothing when it lands on the current level.
    func commit(at index: Int) -> String? {
        guard levels.indices.contains(index), index != currentIndex else { return nil }
        return levels[index]
    }

    /// Whether a touch's first movement is adjusting the level. A mostly vertical one is the list
    /// scrolling, and must neither preview nor send a level from wherever the finger happened to be.
    static func isAdjustment(_ movement: CGSize) -> Bool {
        abs(movement.width) >= abs(movement.height)
    }

    /// VoiceOver's swipe or a Mac arrow key: one level along, or nothing at either end. With no
    /// current level, it starts from the bottom of the ladder.
    func adjusted(by step: Int) -> Int? {
        let next = currentIndex.map { $0 + step } ?? 0
        return levels.indices.contains(next) ? next : nil
    }
}

/// A drag along a Thinking track. It keeps only where the finger is, so the level it names always
/// comes from the ladder as it is now.
struct ThinkingSliderDrag: Equatable {
    /// 0 to 1 along the track, while a finger is down and for a moment after it lands on a new level.
    private(set) var position: Double?
    /// The finger is gone and `position` holds where it landed. The picked level reaches the ladder
    /// through the screen around the track, an update after this state changes, and for that update
    /// the thumb would otherwise jump back toward the old level.
    private(set) var isLanded = false
    private var lastTickIndex: Int?

    /// Moves the finger. True when it crossed onto another level, for a tick.
    mutating func move(to position: Double, on ladder: ThinkingLadder) -> Bool {
        self.position = position
        isLanded = false
        let index = ladder.index(atPosition: position)
        defer { lastTickIndex = index }
        return index != (lastTickIndex ?? ladder.currentIndex)
    }

    /// Lifts the finger, once. The level it landed on, unless that's the current one.
    mutating func end(on ladder: ThinkingLadder) -> Int? {
        guard let position, !isLanded else { return nil }
        let index = ladder.index(atPosition: position)
        guard index != ladder.currentIndex else {
            cancel()
            return nil
        }
        self.position = ladder.position(of: index)
        isLanded = true
        lastTickIndex = nil
        return index
    }

    mutating func cancel() {
        position = nil
        isLanded = false
        lastTickIndex = nil
    }
}
