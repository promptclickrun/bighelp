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

/// What a host page (Default model, Provider Keys, a Nerd Mode tool) shows,
/// given the connection it was opened with. Every reconnect is a new owner;
/// judging pages by the whole owner turned coming back to the app into
/// "Reopen this feature".
enum WorkspaceScreenAvailability: Equatable {
    /// Its connection is the live one.
    case current
    /// Same computer and sign-in: the connection is on its way back, or is
    /// back and the page is about to get it.
    case reconnecting
    /// Another computer or sign-in.
    case unavailable

    static func of(openedFor owner: WorkspaceOwner, current: WorkspaceOwner?,
                   signIn: WorkspaceSignIn?) -> Self {
        if current == owner { return .current }
        return (current?.signIn ?? signIn) == owner.signIn ? .reconnecting : .unavailable
    }

    /// Still this computer's page: keep it, don't ask to open it again.
    var keepsScreen: Bool { self != .unavailable }
}

/// The host pages open in the navigation stack, one per destination. There
/// used to be one slot, so Provider Keys opened from Default model replaced
/// Default model's page, and going back found it gone.
struct WorkspaceOpenScreens<Screen> {
    private(set) var screens: [WorkspaceDestination: Screen] = [:]

    subscript(destination: WorkspaceDestination) -> Screen? { screens[destination] }

    var destinations: Set<WorkspaceDestination> { Set(screens.keys) }

    /// Returns the page it replaces, to retire.
    @discardableResult
    mutating func open(_ screen: Screen, for destination: WorkspaceDestination) -> Screen? {
        screens.updateValue(screen, forKey: destination)
    }

    /// Returns the pages no longer in the stack, to retire.
    mutating func keep(only open: Set<WorkspaceDestination>) -> [Screen] {
        let closed = screens.filter { !open.contains($0.key) }
        for destination in closed.keys { screens[destination] = nil }
        return Array(closed.values)
    }

    mutating func removeAll() -> [Screen] { keep(only: []) }
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
