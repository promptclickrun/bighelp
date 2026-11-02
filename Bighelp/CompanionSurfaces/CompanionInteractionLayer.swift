import CoreGraphics
import Foundation
import SwiftUI

struct CompanionInteractionLayer: View {
    let pet: AgentPetIdentity
    let reaction: CompanionReaction
    var audioLevel: Double = 0
    var itemSize: CGFloat = 92
    var insets = CompanionSurfaceInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    var isThrowable = true
    var restsAtTop = false
    var accessibilityID = "companion-chat"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var canvasSpace
    @State private var physics: CompanionPhysics?
    @State private var motionTask: Task<Void, Never>?
    @State private var isVisible = false
    @State private var squish: CGFloat = 1
    @GestureState private var isDragActive = false

    var body: some View {
        GeometryReader { proxy in
            let bounds = insets.bounds(in: proxy.size)
            let side = min(itemSize, bounds.width, bounds.height)
            let size = CGSize(width: side, height: side)
            let resting = CGPoint(x: bounds.maxX - side / 2,
                                  y: restsAtTop ? bounds.minY + side / 2 : bounds.maxY - side / 2)
            if side >= 24 {
                AgentPet(identity: pet, reaction: CompanionAcceptanceFixture.reaction(reaction),
                         isAnimating: isVisible && scenePhase == .active,
                         audioLevel: audioLevel, isInteracting: isDragActive)
                    .allowsHitTesting(false)
                    .scaleEffect(x: 2 - squish, y: squish)
                    .frame(width: side, height: side)
                    .contentShape(.circle)
                    .overlay {
                        touchSurface(bounds: bounds, size: size, resting: resting)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(pet.name) companion")
                    .accessibilityValue(CompanionAcceptanceFixture.reaction(reaction).accessibilityDescription)
                    .accessibilityIdentifier(accessibilityID)
                    .accessibilityAction(named: "Return companion to its resting place") {
                        stopMotion()
                        physics = CompanionPhysics(position: resting, size: size)
                    }
                    .position(physics?.position ?? resting)
                    .onChange(of: proxy.size) { _, _ in
                        stopMotion()
                        if var current = physics {
                            current.setSize(size, bounds: bounds)
                            physics = current
                        }
                    }
            }
        }
        .coordinateSpace(name: canvasSpace)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; stopMotion() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stopMotion() } }
        .onChange(of: reduceMotion) { _, enabled in if enabled { stopMotion() } }
        .onChange(of: pet.agentID) { _, _ in stopMotion(); physics = nil }
        .onChange(of: isDragActive) { _, active in
            // GestureState also resets on cancellation, when onEnded is absent.
            if !active, physics?.isDragging == true { stopMotion() }
        }
    }

    private var supportsThrow: Bool {
        isThrowable && !reduceMotion
    }

    @ViewBuilder
    private func touchSurface(bounds: CGRect, size: CGSize, resting: CGPoint) -> some View {
        if supportsThrow {
            Circle().fill(.clear).contentShape(.circle)
                .gesture(dragGesture(bounds: bounds, size: size, resting: resting))
        }
    }

    private func dragGesture(bounds: CGRect, size: CGSize, resting: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(canvasSpace))
            .updating($isDragActive) { _, active, _ in active = true }
            .onChanged { value in
                motionTask?.cancel()
                motionTask = nil
                var current = physics ?? CompanionPhysics(position: resting, size: size)
                if !current.isDragging {
                    current.startDrag(at: value.startLocation, time: value.time.timeIntervalSinceReferenceDate, bounds: bounds)
                }
                current.moveDrag(to: value.location, time: value.time.timeIntervalSinceReferenceDate, bounds: bounds)
                physics = current
            }
            .onEnded { value in
                guard var current = physics else { return }
                current.endDrag(at: value.location, time: value.time.timeIntervalSinceReferenceDate, bounds: bounds)
                physics = current
                startMotion(bounds: bounds)
            }
    }

    private func startMotion(bounds: CGRect) {
        // Cancel the old loop without erasing the newly sampled release velocity.
        motionTask?.cancel()
        guard isVisible, scenePhase == .active, !reduceMotion else { return }
        motionTask = Task { @MainActor in
            let clock = ContinuousClock()
            var previous = clock.now
            while !Task.isCancelled {
                do { try await clock.sleep(for: .milliseconds(16)) } catch { return }
                guard !Task.isCancelled, isVisible, scenePhase == .active, !reduceMotion,
                      var current = physics, !current.isDragging else { return }
                let now = clock.now
                let elapsed = previous.duration(to: now)
                previous = now
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
                let downward = current.velocity.dy
                current.step(dt: seconds, bounds: bounds)
                squish = downward > 100 && current.velocity.dy < 0 ? 0.88 : min(1, squish + 0.025)
                physics = current
                if current.isSettled { squish = 1; return }
            }
        }
    }

    private func stopMotion() {
        motionTask?.cancel()
        motionTask = nil
        squish = 1
        if let current = physics {
            physics = CompanionPhysics(position: current.position, size: current.size)
        }
    }
}
