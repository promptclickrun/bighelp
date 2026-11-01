#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Synthetic sources for checking native citation taps, selection and completion without a host.
struct ChatCitationFixture: View {
    @State private var streaming = true

    static let text = """
    The sample garden opens at nine.[1]

    Bring water and comfortable shoes.[2]

    | Visit | Source |
    | --- | --- |
    | Morning walk | Garden guide.[1] |

    Sources

    [1] https://example.com/garden
    [2] https://example.com/walk
    """

    var body: some View {
        NavigationStack {
            VStack {
                Toggle("Streaming", isOn: $streaming).padding()
                ScrollView {
                    MessageBubble(role: .assistant, speakerName: "Juno", text: Self.text,
                                  delivery: streaming ? "Streaming" : "Received",
                                  isPendingSubmission: false, onFork: nil)
                        .padding()
                }
            }
            .navigationTitle("Citation check")
        }
        .environment(\.bighelpUIV3Enabled, true)
    }
}
#endif
