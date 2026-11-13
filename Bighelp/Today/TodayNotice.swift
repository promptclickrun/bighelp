import SwiftUI
import Observation

/// One quiet line under Today's header for what a panel's action did when it needs saying: Update
/// now that came back "too soon", a delete the computer refused. It goes by itself, and is read
/// out to VoiceOver as it appears.
@MainActor
@Observable
final class TodayNotice {
    static let shared = TodayNotice()
    /// How long a line stays.
    static let duration: Duration = .seconds(6)

    private(set) var message: String?
    @ObservationIgnored private var clearing: Task<Void, Never>?

    func show(_ message: String) {
        self.message = message
        AccessibilityNotification.Announcement(message).post()
        clearing?.cancel()
        clearing = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    func dismiss() {
        clearing?.cancel()
        clearing = nil
        message = nil
    }
}

/// The line, under the header. Nothing is drawn while there is none.
struct TodayNoticeBar: View {
    var notice: TodayNotice = .shared
    @BighelpThemeReader private var theme

    var body: some View {
        if let message = notice.message {
            Text(verbatim: message)
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space8)
                .accessibilityIdentifier("today.notice")
        }
    }
}
