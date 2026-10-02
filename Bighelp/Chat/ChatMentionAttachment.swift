import UIKit

/// One inline text attachment keeps a name pill together when the sentence wraps.
/// Retain the typed handle for native selection's Copy action.
final class ChatMentionAttachment: NSTextAttachment {
    let originalText: String
    let displayName: String
    let font: UIFont
    let foreground: UIColor

    @MainActor
    init(originalText: String, displayName: String, font: UIFont, foreground: UIColor) {
        self.originalText = originalText
        self.displayName = displayName
        self.font = font.bighelpApplyingTraits(.traitBold)
        self.foreground = foreground
        super.init(data: nil, ofType: nil)

        let padding = max(5, font.pointSize * 0.3)
        let labelWidth = ceil((displayName as NSString).size(withAttributes: [.font: self.font]).width)
        let size = CGSize(width: min(labelWidth, 220) + padding * 2, height: ceil(font.lineHeight + 4))
        image = UIGraphicsImageRenderer(size: size).image { _ in
            let shape = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                                     cornerRadius: size.height / 2)
            foreground.withAlphaComponent(0.14).setFill()
            shape.fill()
            foreground.withAlphaComponent(0.45).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (displayName as NSString).draw(in: CGRect(x: padding, y: 2, width: size.width - padding * 2,
                                                      height: font.lineHeight), withAttributes: [
                .font: self.font, .foregroundColor: foreground, .paragraphStyle: paragraph
            ])
        }
        bounds = CGRect(x: 0, y: font.descender - 2, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { nil }

    @MainActor
    func matches(_ other: ChatMentionAttachment) -> Bool {
        originalText == other.originalText && displayName == other.displayName
            && font.isEqual(other.font) && foreground.isEqual(other.foreground)
    }
}
