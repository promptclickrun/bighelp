import Foundation

/// A quick "could this text hold the marker?" for paths that run on every
/// redraw of a long chat. Foundation's `contains` compares Characters and was
/// most of such a redraw. A Character match of an ASCII marker is always a byte
/// match too, so a byte search that finds nothing rules it out; callers keep
/// their exact check for the rare text that has the bytes.
enum ChatTextMarker {
    static func mayContain(_ marker: String, in text: String) -> Bool {
        assert(marker.utf8.allSatisfy { $0 < 0x80 }, "Markers are ASCII")
        var text = text
        var marker = marker
        return text.withUTF8 { haystack in
            marker.withUTF8 { needle in
                guard let needleStart = needle.baseAddress, !needle.isEmpty else { return true }
                guard let start = haystack.baseAddress, haystack.count >= needle.count else { return false }
                return memmem(start, haystack.count, needleStart, needle.count) != nil
            }
        }
    }
}
