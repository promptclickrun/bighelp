@preconcurrency import AVFoundation
import CoreImage
import CoreGraphics
import Observation
import SwiftUI
import UIKit

enum ReflectiveVisionPresentationResolver {
    static func shouldRenderCamera(
        enabled: Bool,
        cameraIsActive: Bool,
        reduceTransparency: Bool
    ) -> Bool {
        enabled && cameraIsActive && !reduceTransparency
    }
}

enum ReflectiveVisionPermissionTrigger: Equatable, Sendable {
    case explicitUserAction
    case lifecycle
}

enum ReflectiveVisionPermissionPolicy {
    static func shouldRequest(
        enabled: Bool,
        authorization: PermissionAuthorizationState,
        trigger: ReflectiveVisionPermissionTrigger
    ) -> Bool {
        enabled
            && authorization == .notDetermined
            && trigger == .explicitUserAction
    }
}

enum ReflectiveVisionCameraState: Equatable, Sendable {
    enum Unavailability: Equatable, Sendable {
        case permissionDenied
        case restricted
        case noCamera
        case configurationFailed
    }

    case off
    case requestingPermission
    case preparing
    case active
    case unavailable(Unavailability)

    var isActive: Bool { self == .active }

    var statusText: String {
        switch self {
        case .off:
            "Off"
        case .requestingPermission:
            "Waiting for camera permission"
        case .preparing:
            "Preparing the live reflection"
        case .active:
            "Live reflection active. Camera frames stay on this device and are never recorded."
        case .unavailable(.permissionDenied):
            "Camera access is off. Bighelp is using the standard theme visuals."
        case .unavailable(.restricted):
            "Camera access is restricted. Bighelp is using the standard theme visuals."
        case .unavailable(.noCamera):
            "No camera is available. Bighelp is using the standard theme visuals."
        case .unavailable(.configurationFailed):
            "The camera could not start. Bighelp is using the standard theme visuals."
        }
    }

    var canOpenSettings: Bool {
        self == .unavailable(.permissionDenied) || self == .unavailable(.restricted)
    }
}

struct ReflectiveVisionActivationPolicy: Sendable {
    private var requestedEnabled: Bool?

    // Startup, scene activation, and camera-picker dismissal can all reconcile
    // the same setting. Do not let those callbacks create another camera
    // transition while the current one is still active or already failed.
    mutating func shouldReconcile(
        enabled: Bool,
        state: ReflectiveVisionCameraState
    ) -> Bool {
        guard enabled else {
            let changed = requestedEnabled != false
            requestedEnabled = false
            return changed
        }

        if requestedEnabled == true, state != .off {
            return false
        }

        requestedEnabled = true
        return true
    }
}

enum ReflectiveVisionCaptureArchitecture {
    static let usesSingleOutput = true
    static let maximumFramesPerSecond = 6
    static let minimumFrameInterval = 1.0 / Double(maximumFramesPerSecond)
    static let maximumFrameDimension: CGFloat = 720
    // Keep the recovery marker until the camera-backed UI has survived a
    // short rendering window. This prevents a crash immediately after the
    // camera starts from creating a relaunch loop.
    static let activationStabilityDuration: TimeInterval = 2
}

struct ReflectiveVisionActivationStability: Sendable {
    let generation: Int
    let startedAt: TimeInterval

    func canClearRecoveryMarker(
        at now: TimeInterval,
        currentGeneration: Int,
        state: ReflectiveVisionCameraState
    ) -> Bool {
        currentGeneration == generation
            && state == .active
            && now - startedAt >= ReflectiveVisionCaptureArchitecture.activationStabilityDuration
    }
}

struct ReflectiveVisionRecoveryMarker {
    static let key = "loopdy.appearance.reflectiveVision.activationInFlight"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasPendingActivation: Bool {
        defaults.bool(forKey: Self.key)
    }

    func markActivationStarted() {
        defaults.set(true, forKey: Self.key)
    }

    func markActivationStabilized() {
        defaults.removeObject(forKey: Self.key)
    }

    func markActivationFailed() {
        defaults.set(true, forKey: Self.key)
    }

    @discardableResult
    func consumePendingActivation() -> Bool {
        guard hasPendingActivation else { return false }
        defaults.removeObject(forKey: Self.key)
        return true
    }
}

struct ReflectiveVisionFrame: Sendable {
    let data: Data
    let sequence: UInt64
}

final class ReflectiveVisionFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFrame: ReflectiveVisionFrame?
    private var nextSequence: UInt64 = 0

    func publish(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        nextSequence &+= 1
        latestFrame = ReflectiveVisionFrame(data: data, sequence: nextSequence)
    }

    func latest(after sequence: UInt64) -> ReflectiveVisionFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestFrame, latestFrame.sequence > sequence else { return nil }
        return latestFrame
    }
}

private final class ReflectiveVisionFrameSink: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    private let store: ReflectiveVisionFrameStore
    private let context = CIContext()
    private var lastFrameAt: CFTimeInterval = 0

    init(store: ReflectiveVisionFrameStore) {
        self.store = store
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastFrameAt >= ReflectiveVisionCaptureArchitecture.minimumFrameInterval else {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let maxDimension = max(image.extent.width, image.extent.height)
        let scale = min(
            1,
            ReflectiveVisionCaptureArchitecture.maximumFrameDimension
                / max(maxDimension, 1)
        )
        let boundedImage = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        guard let data = context.jpegRepresentation(
            of: boundedImage,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        ) else { return }

        lastFrameAt = now
        store.publish(data)
    }
}

@MainActor
@Observable
final class ReflectiveVisionCamera {
    private(set) var state: ReflectiveVisionCameraState = .off
    private(set) var latestFrame: UIImage?

    nonisolated(unsafe) fileprivate let session = AVCaptureSession()
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    nonisolated private let sessionQueue = DispatchQueue(
        label: "app.loopdy.reflective-vision.camera",
        qos: .userInitiated
    )
    nonisolated private let frameQueue = DispatchQueue(
        label: "app.loopdy.reflective-vision.frames",
        qos: .utility
    )
    nonisolated private let frameSink: ReflectiveVisionFrameSink
    private let frameStore: ReflectiveVisionFrameStore
    private let recoveryMarker: ReflectiveVisionRecoveryMarker
    private var activationGeneration = 0
    private var activationPolicy = ReflectiveVisionActivationPolicy()
    private var framePollingTask: Task<Void, Never>?
    private var activationStabilityTask: Task<Void, Never>?
    private var lastFrameSequence: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        let store = ReflectiveVisionFrameStore()
        frameStore = store
        frameSink = ReflectiveVisionFrameSink(store: store)
        recoveryMarker = ReflectiveVisionRecoveryMarker(defaults: defaults)
    }

    func update(
        enabled: Bool,
        trigger: ReflectiveVisionPermissionTrigger = .lifecycle
    ) async {
        guard activationPolicy.shouldReconcile(enabled: enabled, state: state) else {
            return
        }

        activationGeneration += 1
        let generation = activationGeneration

        guard enabled else {
            state = .off
            stopFramePolling()
            activationStabilityTask?.cancel()
            activationStabilityTask = nil
            stopSession()
            recoveryMarker.markActivationStabilized()
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            recoveryMarker.markActivationStarted()
            await prepare(generation: generation)
        case .notDetermined:
            state = .off
        case .denied:
            state = .unavailable(.permissionDenied)
        case .restricted:
            state = .unavailable(.restricted)
        @unknown default:
            state = .unavailable(.configurationFailed)
        }
    }

    func suspend() {
        activationGeneration += 1
        if state != .off {
            state = .off
        }
        stopFramePolling()
        activationStabilityTask?.cancel()
        activationStabilityTask = nil
        stopSession()
    }

    private func prepare(generation: Int) async {
        state = .preparing
        let result = await configureAndStartSession()
        guard generation == activationGeneration else {
            if result == .started { stopSession() }
            return
        }
        switch result {
        case .started:
            state = .active
            startFramePolling(generation: generation)
            scheduleActivationStabilization(generation: generation)
        case .noCamera:
            state = .unavailable(.noCamera)
            recoveryMarker.markActivationFailed()
        case .failed:
            state = .unavailable(.configurationFailed)
            recoveryMarker.markActivationFailed()
        }
    }

    private enum StartResult: Sendable {
        case started
        case noCamera
        case failed
    }

    private nonisolated func configureAndStartSession() async -> StartResult {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [session, videoOutput, frameSink, frameQueue] in
                guard let camera = AVCaptureDevice.default(
                    .builtInWideAngleCamera,
                    for: .video,
                    position: .back
                ) ?? AVCaptureDevice.default(for: .video) else {
                    continuation.resume(returning: .noCamera)
                    return
                }

                guard let input = try? AVCaptureDeviceInput(device: camera) else {
                    continuation.resume(returning: .failed)
                    return
                }

                session.beginConfiguration()
                #if !os(visionOS)
                session.sessionPreset = .medium
                #endif

                if session.inputs.isEmpty {
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        continuation.resume(returning: .failed)
                        return
                    }
                    session.addInput(input)
                }

                if !session.outputs.contains(where: { $0 === videoOutput }) {
                    guard session.canAddOutput(videoOutput) else {
                        session.commitConfiguration()
                        continuation.resume(returning: .failed)
                        return
                    }
                    videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                    ]
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    videoOutput.setSampleBufferDelegate(frameSink, queue: frameQueue)
                    session.addOutput(videoOutput)
                }

                session.commitConfiguration()
                if !session.isRunning {
                    session.startRunning()
                }
                continuation.resume(returning: session.isRunning ? .started : .failed)
            }
        }
    }

    private func startFramePolling(generation: Int) {
        framePollingTask?.cancel()
        lastFrameSequence = 0
        latestFrame = nil
        framePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled, let self else { return }
                guard self.activationGeneration == generation, self.state == .active else {
                    return
                }
                self.refreshLatestFrame()
            }
        }
    }

    private func stopFramePolling() {
        framePollingTask?.cancel()
        framePollingTask = nil
        latestFrame = nil
    }

    private func scheduleActivationStabilization(generation: Int) {
        activationStabilityTask?.cancel()
        let stability = ReflectiveVisionActivationStability(
            generation: generation,
            startedAt: CACurrentMediaTime()
        )
        activationStabilityTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(ReflectiveVisionCaptureArchitecture.activationStabilityDuration)
                )
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard stability.canClearRecoveryMarker(
                at: CACurrentMediaTime(),
                currentGeneration: self.activationGeneration,
                state: self.state
            ) else { return }
            self.recoveryMarker.markActivationStabilized()
            self.activationStabilityTask = nil
        }
    }

    private func refreshLatestFrame() {
        guard let frame = frameStore.latest(after: lastFrameSequence) else { return }
        lastFrameSequence = frame.sequence
        latestFrame = UIImage(data: frame.data)
    }

    private nonisolated func stopSession() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

private struct ReflectiveVisionEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ReflectiveVisionCameraKey: EnvironmentKey {
    static let defaultValue: ReflectiveVisionCamera? = nil
}

extension EnvironmentValues {
    var reflectiveVisionEnabled: Bool {
        get { self[ReflectiveVisionEnabledKey.self] }
        set { self[ReflectiveVisionEnabledKey.self] = newValue }
    }

    var reflectiveVisionCamera: ReflectiveVisionCamera? {
        get { self[ReflectiveVisionCameraKey.self] }
        set { self[ReflectiveVisionCameraKey.self] = newValue }
    }
}

private struct ReflectiveVisionMaterialModifier: ViewModifier {
    let isEligible: Bool

    @Environment(\.reflectiveVisionEnabled) private var enabled
    @Environment(\.reflectiveVisionCamera) private var camera
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let rendersCamera = ReflectiveVisionPresentationResolver.shouldRenderCamera(
            enabled: enabled && isEligible,
            cameraIsActive: camera?.state.isActive == true,
            reduceTransparency: reduceTransparency
        )
        if rendersCamera, let frame = camera?.latestFrame {
            content
                .opacity(0.16)
                .overlay {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFill()
                        .saturation(1.22)
                        .contrast(1.08)
                        .blur(radius: 6, opaque: true)
                        .overlay(.white.opacity(0.08))
                        .mask(content)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}

extension View {
    nonisolated func reflectiveVisionMaterial(isEligible: Bool = true) -> some View {
        modifier(ReflectiveVisionMaterialModifier(isEligible: isEligible))
    }

    nonisolated func reflectiveVisionIcon() -> some View {
        reflectiveVisionMaterial()
    }
}
