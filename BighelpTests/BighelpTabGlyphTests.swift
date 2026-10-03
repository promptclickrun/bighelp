import SwiftUI
import Testing
@testable import Bighelp

struct BighelpTabGlyphTests {
    /// The design's paths read right: each drawing covers its grid the way the
    /// mockup does (outermost points plus half the 1.7-pt stroke, or a dot's edge).
    @Test func glyphsSitOnTheirGridLikeTheDesign() {
        // minX, minY, maxX, maxY on the 24-pt grid.
        func expected(_ glyph: BighelpTabGlyph, _ selected: Bool) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            switch glyph {
            case .chat: (3.5 - 0.85, 4 - 0.85, 20.5 + 0.85, 19.9 + 0.85)
            case .feed: (3.5 - 0.85, 2.4 - 0.85, 21.6 + 0.85, 20.5 + 0.85)
            // The dot (radius 1.6, or 1.9 selected) reaches past the sparkle.
            case .ideas: (3 - 0.85, 5.4 - (selected ? 1.9 : 1.6), 18.6 + (selected ? 1.9 : 1.6), 21 + 0.85)
            case .goals: (3 - 0.85, 3.5 - 0.85, 21 + 0.85, 19.5 + 0.85)
            }
        }
        for glyph in BighelpTabGlyph.allCases {
            for selected in [false, true] {
                let bounds = glyph.path(selected: selected).boundingRect
                let edges = expected(glyph, selected)
                let outline = CGRect(x: edges.0, y: edges.1, width: edges.2 - edges.0, height: edges.3 - edges.1)
                #expect(abs(bounds.minX - outline.minX) < 0.2, "\(glyph) \(selected) left")
                #expect(abs(bounds.maxX - outline.maxX) < 0.2, "\(glyph) \(selected) right")
                #expect(abs(bounds.minY - outline.minY) < 0.2, "\(glyph) \(selected) top")
                #expect(abs(bounds.maxY - outline.maxY) < 0.2, "\(glyph) \(selected) bottom")
            }
        }
    }

    /// Selected is the filled variant: its eyes and lines are cut out of a solid
    /// shape, so the middle of the bubble is ink only when selected.
    @Test func selectedGlyphsAreFilled() {
        let middle = CGPoint(x: 12, y: 14.5)
        #expect(!BighelpTabGlyph.chat.path(selected: false).contains(middle))
        #expect(BighelpTabGlyph.chat.path(selected: true).contains(middle))
        // The eyes stay open in the filled bubble.
        #expect(!BighelpTabGlyph.chat.path(selected: true).contains(CGPoint(x: 9.2, y: 11)))
        #expect(BighelpTabGlyph.chat.path(selected: false).contains(CGPoint(x: 9.2, y: 11)))
        #expect(BighelpTabGlyph.goals.path(selected: true).contains(CGPoint(x: 11, y: 17)))
        #expect(!BighelpTabGlyph.goals.path(selected: false).contains(CGPoint(x: 11, y: 17)))
    }

    @Test func barTabsUseTheGlyphs() {
        #expect(AppTab.sessions.glyph == .chat)
        #expect(AppTab.feed.glyph == .feed)
        #expect(AppTab.ideas.glyph == .ideas)
        #expect(AppTab.goals.glyph == .goals)
        #expect(AppTab.apps.glyph == nil)
    }
}
