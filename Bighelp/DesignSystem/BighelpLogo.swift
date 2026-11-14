import SwiftUI

/// The logo for setup screens: the wordmark, or the lifter alone. A motion plays in the
/// lifter's place (the welcome's success, host setup's idle); without one he's still.
struct BighelpLogo: View {
    enum Presentation {
        case full
        case mark
    }

    let presentation: Presentation
    let height: CGFloat
    let motion: BighelpLifterMotion?
    let playback: BighelpLifterPlayback
    let onFinish: (() -> Void)?

    init(presentation: Presentation = .full, height: CGFloat = 32, motion: BighelpLifterMotion? = nil,
         playback: BighelpLifterPlayback = .once, onFinish: (() -> Void)? = nil) {
        self.presentation = presentation
        self.height = height
        self.motion = motion
        self.playback = playback
        self.onFinish = onFinish
    }

    var body: some View {
        Group {
            switch presentation {
            case .full:
                BighelpWordmark(height: height, motion: motion, playback: playback, onFinish: onFinish)
            case .mark:
                BighelpLifterView(motion: motion ?? .idle, size: height, playback: playback,
                                  isPaused: motion == nil, onFinish: onFinish)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BighelpBrand.appName)
        .accessibilityIdentifier("loopdy.brand-logo")
    }
}
