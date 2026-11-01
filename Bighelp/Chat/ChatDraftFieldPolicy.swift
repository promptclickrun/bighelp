import SwiftUI
import UIKit

/// Preserve the native editor's actual selection as the mention caret.
struct DraftCaretSelection {
    static func characterOffset(in text: String, selectedRange: NSRange) -> Int {
        let utf16Length = text.utf16.count
        let location = min(max(0, selectedRange.location), utf16Length)
        let prefix = text.utf16.prefix(location)
        return String(decoding: prefix, as: UTF16.self).count
    }

}

enum DraftFieldSizing {
    /// The message box grows to this many lines, then scrolls.
    static let maximumVisibleLines = 4

    static func height(
        measuredHeight: CGFloat,
        lineHeight: CGFloat,
        maximumVisibleLines: Int = DraftFieldSizing.maximumVisibleLines
    ) -> CGFloat {
        let boundedLineHeight = max(lineHeight, 1)
        let maximumHeight = boundedLineHeight * CGFloat(max(maximumVisibleLines, 1))
        return min(max(measuredHeight, boundedLineHeight), maximumHeight)
    }

    /// Expand shows above the message box once the draft takes this many lines (#728).
    static let expandLines = 3

    /// The lines a measured draft takes. The editor has no insets, so each line is one line
    /// height; rounding absorbs the fraction of a point TextKit adds.
    static func lineCount(measuredHeight: CGFloat, lineHeight: CGFloat) -> Int {
        Int((max(measuredHeight, 0) / max(lineHeight, 1)).rounded())
    }

    static func shouldOfferExpandedEditor(
        hasText: Bool,
        measuredHeight: CGFloat,
        lineHeight: CGFloat,
        minimumLines: Int = DraftFieldSizing.expandLines
    ) -> Bool {
        hasText && lineCount(measuredHeight: measuredHeight, lineHeight: lineHeight) >= max(minimumLines, 1)
    }
}

enum DraftFieldUpdatePolicy {
    static func shouldKeepCaretVisible(currentText: String, incomingText: String) -> Bool {
        currentText != incomingText
    }
}

struct DraftCaretScrollGeneration {
    private(set) var current = 0

    mutating func beginRequest() -> Int {
        current += 1
        return current
    }

    func isCurrent(_ request: Int) -> Bool {
        request == current
    }
}
