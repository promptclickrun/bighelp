import SwiftUI

/// The bold blocks of Feed, Ideas and Goals, and New chat in the bottom bar: pastel fills with ink
/// on them, and a deep green for what's new today. The pastels keep their color after dark, where
/// they read well on the black page; the green gets a little darker so it stays a block.
enum BighelpBlockColor: String, CaseIterable, Sendable {
    case lime, lilac, sky, peach, forest

    /// The block's fill.
    func fill(dark: Bool) -> Color {
        switch self {
        case .lime: Color(hex: "C9EE8F")
        case .lilac: Color(hex: "E6ADF0")
        case .sky: Color(hex: "BFD8F5")
        case .peach: Color(hex: "FF9459")
        case .forest: Color(hex: dark ? "1F3D34" : "244A3F")
        }
    }

    /// Text and icons on the block.
    var ink: Color { self == .forest ? .white : Color(hex: "141414") }

    /// The pastels in a fixed order, so the same item keeps its color between launches.
    static let pastels: [BighelpBlockColor] = [.lime, .lilac, .sky, .peach]

    /// A pastel for `key` (an item's ID, a category): the same key always gets the same one.
    static func pastel(for key: String) -> BighelpBlockColor {
        // FNV-1a, not `hashValue`, which changes on every launch.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return pastels[Int(hash % UInt64(pastels.count))]
    }
}
