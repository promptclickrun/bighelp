import SwiftUI

@MainActor
struct WorkspaceUnavailableView: View {
    let destination: WorkspaceDestination
    let hostName: String
    let reason: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(destination.title)
            } icon: {
                // The kit's question: didn't catch that.
                BighelpLifterView(motion: .error, size: 48)
            }
        } description: {
            Text("\(reason)\n\nSelected host: \(hostName)")
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("workspace.unavailable.\(destination.rawValue)")
    }
}

/// A host page while its computer reconnects (after you come back to the
/// app): it comes back by itself, so there's nothing to reopen.
struct WorkspaceReconnectingView: View {
    let destination: WorkspaceDestination
    let hostName: String
    let hasFailed: Bool

    var body: some View {
        HostPageWaitingView(hostName: hostName, hasFailed: hasFailed)
            .navigationTitle(destination.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("workspace.reconnecting.\(destination.rawValue)")
    }
}

/// A page that needs its computer while the connection comes back by itself: the
/// loader without words, and a message only once the quiet tries failed
/// (`WorkspaceConnectionState.disconnected`).
struct HostPageWaitingView: View {
    let hostName: String
    let hasFailed: Bool

    var body: some View {
        if hasFailed {
            ContentUnavailableView("Not connected to \(hostName)", systemImage: "wifi.exclamationmark",
                                   description: Text("This page opens once \(hostName) answers."))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
