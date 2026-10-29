import SwiftUI

/// Where the controls an agent's drive can point at are on screen right now, by id. The driving
/// overlay puts its touch dot and its arrival spotlight there. A control that isn't on screen has
/// no frame, and the drive moves on without the dot.
@MainActor
@Observable
final class DriveTargets {
    static let shared = DriveTargets()

    /// Frames in window coordinates, which the overlay's own window shares.
    private(set) var frames: [String: CGRect] = [:]

    func frame(_ id: String) -> CGRect? { frames[id] }

    fileprivate func update(_ id: String, frame: CGRect?) {
        guard frames[id] != frame else { return }
        frames[id] = frame
    }
}

extension View {
    /// Lets a drive scroll this page (a Form, List or ScrollView) to a control that isn't on screen yet:
    /// rows far down a long list aren't drawn, so they have no frame until they're scrolled to.
    func driveScrolls() -> some View {
        modifier(DriveScrollModifier())
    }

    /// Marks a control a drive can point at: a row, a tab or a button a place's playbook taps.
    /// Use the place catalog's target id (`DrivePlace`), which is usually the control's own
    /// accessibility identifier.
    func driveTarget(_ id: String) -> some View {
        modifier(DriveTargetModifier(id: id))
    }
}

private struct DriveTargetModifier: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content
            // What `driveScrolls()` scrolls to.
            .id(id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                DriveTargets.shared.update(id, frame: frame)
            }
            .onDisappear { DriveTargets.shared.update(id, frame: nil) }
    }
}

private struct DriveScrollModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: DriveNavigator.shared.scrollRequest) { _, request in
                guard let request else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                    proxy.scrollTo(request.target, anchor: .center)
                }
            }
        }
    }
}
