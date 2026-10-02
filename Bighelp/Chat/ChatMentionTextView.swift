import UIKit

final class ChatMentionTextView: UITextView {
    override func copy(_ sender: Any?) {
        guard selectedRange.location != NSNotFound, selectedRange.length > 0,
              NSMaxRange(selectedRange) <= textStorage.length else {
            super.copy(sender)
            return
        }
        let selection = textStorage.attributedSubstring(from: selectedRange)
        var containsMention = false
        selection.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selection.length)) { value, _, _ in
            if value is ChatMentionAttachment { containsMention = true }
        }
        guard containsMention else {
            super.copy(sender)
            return
        }
        UIPasteboard.general.string = ChatMentionRendering.plainText(selection)
    }
}
