import SwiftUI
import UIKit

/// The agent's review note (its Photo actions message), drawn as a quote from the agent: it adds to
/// the review; it never replaces the app's own warnings.
struct ImageDraftReviewNote: View {
    let text: String
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space8) {
            Image(systemName: "quote.bubble")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .accessibilityHidden(true)
            Text(text)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, BighelpTokens.space12)
        .padding(.vertical, BighelpTokens.space8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.incomingMessageSolid, in: UnevenRoundedRectangle(
            topLeadingRadius: 4, bottomLeadingRadius: BighelpTokens.radius16,
            bottomTrailingRadius: BighelpTokens.radius16, topTrailingRadius: BighelpTokens.radius16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("image-draft.review.note")
    }
}

/// The app's own list of what to check. It shows whatever the agent's messages say.
struct ImageDraftCheckBox: View {
    let lines: [String]
    /// The agent's own "missing fields" message, under the app's list and never counted in it.
    var note: String?
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Label(lines.count == 1 ? String(localized: "1 thing to check")
                                   : String(localized: "\(lines.count) things to check"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(theme.warning)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warning.opacity(0.12), in: .rect(cornerRadius: BighelpTokens.radius12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("image-draft.review.check")
    }
}

/// Check, Guess, Missing or Edited beside a field. A guess never reads as something from the photo.
struct ImageDraftBadgeView: View {
    let badge: ImageDraftBadge
    @BighelpThemeReader private var theme

    var body: some View {
        Text(title)
            .font(.bighelp(.caption, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, BighelpTokens.space8)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
            .fixedSize()
            .accessibilityIdentifier("image-draft.badge.\(badge.rawValue)")
    }

    private var title: String {
        switch badge {
        case .check: String(localized: "Check")
        case .guess: String(localized: "Guess")
        case .missing: String(localized: "Missing")
        case .edited: String(localized: "You changed")
        }
    }

    private var color: Color {
        switch badge {
        case .check, .guess: theme.warning
        case .missing: theme.danger
        case .edited: theme.action
        }
    }
}

/// The photo, pinch and double-tap to zoom, full screen. Kept in memory: the person's card is never
/// written to a temporary file for a preview.
struct ImageDraftPhotoViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            ImageDraftZoomingImage(image: image)
                .ignoresSafeArea()
                .accessibilityLabel(Text("The photo you sent"))
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .background(.black.opacity(0.45), in: .circle)
            }
            .bighelpPlainButtonStyle()
            .bighelpIconLabel(String(localized: "Close"))
            .bighelpCancelAction()
            .padding(BighelpTokens.space16)
            .accessibilityIdentifier("image-draft.photo.close")
        }
    }
}

private struct ImageDraftZoomingImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = context.coordinator
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])
        context.coordinator.imageView = view
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                                       size: size), animated: true)
            }
        }
    }
}
