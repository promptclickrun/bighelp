#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// UI tests open a Markdown file an agent sent, as a chat's file preview shows it. Made-up content.
enum MarkdownAttachmentFixture {
    static let launchArgument = "-test-markdown-attachment"

    static let text = """
    # Kyoto plan

    Three days, **two** temples a day.

    - Day 1: Fushimi Inari, then Gion
    - Day 2: Arashiyama bamboo grove
    - Day 3: Kinkaku-ji

    `Budget`: about $1,200 for two.
    """

    @MainActor
    static func rootView() -> some View {
        let attachment = try? ChatAttachment(id: "fixture-markdown", fileName: "Kyoto plan.md",
                                             mimeType: "text/markdown", data: Data(text.utf8))
        return Group {
            if let attachment { ChatAttachmentPreviewView(attachment: attachment) }
        }
    }
}
#endif
