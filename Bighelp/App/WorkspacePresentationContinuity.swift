import SwiftUI

/// bighelp closes the host connection soon after you leave and reconnects when
/// you're back, and every reconnect is a new `WorkspaceOwner`. Treating that as
/// a new computer closed whatever was open. Now a reconnect to the same
/// computer and sign-in keeps open sheets and screens, and the ones holding a
/// connection of their own get the new one once the host is all the way back.
/// Another computer or sign-in still closes them.
struct WorkspacePresentationContinuity: ViewModifier {
    let owner: WorkspaceOwner?
    let registryGeneration: UUID?
    /// The host has finished coming back (the runtime refreshed after reconnecting).
    let isHostSettled: Bool
    @Binding var signIn: WorkspaceSignIn?
    let close: () -> Void
    /// False when the host isn't ready for it yet; it's tried again when it settles.
    let reattach: () -> Bool

    @State private var needsReattach = false

    func body(content: Content) -> some View {
        content
            .onChange(of: owner, initial: true) { _, owner in
                // Disconnected: keep everything until we know what comes back.
                guard let owner else { return }
                switch WorkspaceReconnect.classify(owner.signIn, previous: signIn) {
                case .sameSignIn:
                    needsReattach = true
                    reattachWhenSettled()
                case .boundary:
                    signIn = owner.signIn
                    needsReattach = false
                    close()
                }
            }
            .onChange(of: registryGeneration) { _, _ in
                signIn = nil
                needsReattach = false
                close()
            }
            .onChange(of: isHostSettled) { _, _ in reattachWhenSettled() }
    }

    private func reattachWhenSettled() {
        guard needsReattach, owner != nil, isHostSettled else { return }
        if reattach() { needsReattach = false }
    }
}

enum WorkspaceReconnect: Equatable {
    case sameSignIn, boundary

    static func classify(_ signIn: WorkspaceSignIn, previous: WorkspaceSignIn?) -> Self {
        signIn == previous ? .sameSignIn : .boundary
    }
}

/// Demo runs have no connection to lose. With `-demo-reconnects-on-return`,
/// coming back from the background is a reconnect, as it is with a host: a new
/// connection for the same sign-in.
struct DemoReconnectOnReturn: ViewModifier {
    static let launchArgument = "-demo-reconnects-on-return"

    let scenePhase: ScenePhase
    @Binding var connection: UUID
    let isEnabled: Bool

    @State private var wasInBackground = false

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            guard isEnabled, ProcessInfo.processInfo.arguments.contains(Self.launchArgument) else { return }
            switch phase {
            case .background: wasInBackground = true
            case .active where wasInBackground:
                wasInBackground = false
                connection = UUID()
            default: break
            }
        }
    }
}
