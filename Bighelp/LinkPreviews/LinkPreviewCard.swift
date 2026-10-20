import SwiftUI
import UIKit

/// Saved on this device; chats and the Feed read it with `@AppStorage`.
enum LinkPreviewPreferences {
    static let enabledKey = "bighelp.chat.link-previews"
}

/// A link's preview, like Messages shows one: the page's picture, title,
/// summary and site. Tapping opens the link, in the chosen browser in chats.
/// YouTube videos get a card that plays them in place.
struct LinkPreviewCard: View {
    let url: URL
    /// Shown until the page's own title arrives, or if it has none.
    var fallbackTitle: String?
    private let video: YouTubeVideo?

    @Environment(\.openURL) private var openURL
    @State private var result: LinkPreviewStore.Result?
    @State private var picture: UIImage?

    init(url: URL, fallbackTitle: String? = nil) {
        self.url = url
        self.fallbackTitle = fallbackTitle.flatMap { $0.isEmpty ? nil : $0 }
        video = YouTubeVideo(url: url)
        // Known previews draw at their final size straight away.
        _result = State(initialValue: LinkPreviewStore.shared.cached(url))
    }

    var body: some View {
        Group {
            if let video {
                YouTubeCard(video: video, url: url, preview: preview, picture: picture)
            } else {
                linkCard
            }
        }
        .task(id: url) {
            if result == nil { result = await LinkPreviewStore.shared.load(url) }
            if picture == nil, result?.preview?.imageAspect != nil {
                picture = await LinkPreviewStore.shared.picture(for: url)
            }
        }
    }

    private var linkCard: some View {
        Button {
            openURL(url)
        } label: {
            card
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.url = url
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            // The menu is built with the card, so the picture is encoded only when it's copied:
            // encoding it here ran on every redraw and was most of a long chat's scrolling.
            if let picture {
                Button {
                    guard let png = picture.pngData() else { return }
                    UIPasteboard.general.setItems(ChatPictureClipboard.items(data: png, mimeType: "image/png"))
                    BighelpHaptics.success()
                } label: {
                    Label("Copy Picture", systemImage: "photo.on.rectangle")
                }
            }
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the link")
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier("link-preview")
    }

    private var preview: LinkPreview? { result?.preview }
    private var site: String { preview?.displaySite ?? LinkPreview.host(of: url) }
    private var title: String { preview?.title ?? fallbackTitle ?? site }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let aspect = preview?.imageAspect {
                // Very tall pictures are cropped so the card stays card-sized.
                theme.surface
                    .aspectRatio(min(max(aspect, 1.2), 2.4), contentMode: .fit)
                    .overlay {
                        if let picture {
                            Image(uiImage: picture)
                                .resizable()
                                .scaledToFill()
                                .transition(.opacity)
                        }
                    }
                    .clipped()
                    .animation(.easeOut(duration: 0.2), value: picture != nil)
            }
            HStack(spacing: BighelpTokens.space12) {
                if preview?.imageAspect == nil {
                    Image(systemName: "link")
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 34, height: 34)
                        .background(theme.surface, in: .rect(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(2)
                    if let summary = preview?.summary {
                        Text(summary)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(2)
                    }
                    if site != title {
                        Text(site)
                            .font(.bighelp(.caption))
                            .foregroundStyle(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.incomingMessageBackground)
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .contentShape(.rect(cornerRadius: 18, style: .continuous))
    }

    private var accessibilityText: String {
        [title, preview?.summary, site == title ? nil : site].compactMap { $0 }.joined(separator: ". ")
    }

    @BighelpThemeReader private var theme
}
