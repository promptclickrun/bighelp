import SwiftUI

/// The logo for setup screens: the wordmark, or the mark alone. A motion plays in the
/// mark's place (the onboarding's reveal, host setup's launch); without one it's still.
struct BighelpLogo: View {
    enum Presentation {
        case full
        case mark
    }

    let presentation: Presentation
    let height: CGFloat
    let motion: BighelpNoodleMotion?
    let onFinish: (() -> Void)?

    init(presentation: Presentation = .full, height: CGFloat = 32, motion: BighelpNoodleMotion? = nil,
         onFinish: (() -> Void)? = nil) {
        self.presentation = presentation
        self.height = height
        self.motion = motion
        self.onFinish = onFinish
    }

    var body: some View {
        Group {
            switch presentation {
            case .full:
                BighelpWordmark(height: height, motion: motion, onFinish: onFinish)
            case .mark:
                BighelpNoodleView(motion: motion ?? .idle, size: height, isPaused: motion == nil, onFinish: onFinish)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BighelpBrand.appName)
        .accessibilityIdentifier("loopdy.brand-logo")
    }
}
