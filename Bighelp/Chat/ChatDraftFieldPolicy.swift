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

    static func shouldOfferExpandedEditor(
        hasText: Bool,
        measuredHeight: CGFloat,
        lineHeight: CGFloat,
        thresholdLines: Int = 4
    ) -> Bool {
        let boundedThreshold = max(thresholdLines, 1)
        return hasText
            && measuredHeight > max(lineHeight, 1) * CGFloat(boundedThreshold)
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
