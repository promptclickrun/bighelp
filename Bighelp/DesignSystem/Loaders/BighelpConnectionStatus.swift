import SwiftUI
import UIKit

/// The four states of a host connection, each with its own color and motion:
/// dots while connecting, a spinning arc while trying again, one calm ping when
/// connected, and nothing moving when it's down. A label always goes with the
/// color.
enum BighelpConnectionPhase: String, CaseIterable, Sendable {
    case connecting, reconnecting, connected, disconnected

    var label: String {
        switch self {
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        }
    }

    func tint(in theme: BighelpTheme) -> Color {
        switch self {
        case .connecting: theme.information
        case .reconnecting: theme.warning
        case .connected: theme.success
        case .disconnected: theme.danger
        }
    }
}

/// Facts about a connection, all optional. Only what the caller really knows is
/// shown; nothing is filled in or estimated.
struct BighelpConnectionDetail: Equatable, Sendable {
    /// Which try this is, and how many there will be ("Trying again · 2 of 5").
    var attempt: Int?
    var maximumAttempts: Int?
    /// A measured round trip.
    var latencyMilliseconds: Int?
    /// The version the host reported.
    var hermesVersion: String?
    /// A plain sentence the caller already has ("Hermes didn't answer.").
    var message: String?

    init(attempt: Int? = nil, maximumAttempts: Int? = nil, latencyMilliseconds: Int? = nil,
         hermesVersion: String? = nil, message: String? = nil) {
        self.attempt = attempt
        self.maximumAttempts = maximumAttempts
        self.latencyMilliseconds = latencyMilliseconds
        self.hermesVersion = hermesVersion
        self.message = message
    }

    /// The line under a host's name for `phase`, or nil when nothing real is known.
    func text(for phase: BighelpConnectionPhase) -> String? {
        switch phase {
        case .reconnecting:
            if let attempt, let maximumAttempts, (1...99).contains(attempt), (attempt...99).contains(maximumAttempts) {
                return "Trying again · \(attempt) of \(maximumAttempts)"
            }
            return cleanMessage
        case .connected:
            var parts: [String] = []
            if let version = cleanVersion { parts.append("Hermes \(version)") }
            if let latencyMilliseconds, (0..<60_000).contains(latencyMilliseconds) {
                parts.append("\(latencyMilliseconds) ms")
            }
            return parts.isEmpty ? cleanMessage : parts.joined(separator: " · ")
        case .connecting, .disconnected:
            return cleanMessage
        }
    }

    private var cleanVersion: String? {
        guard let value = hermesVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= 24,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-+".unicodeScalars.contains($0) })
        else { return nil }
        return value
    }

    private var cleanMessage: String? {
        guard let value = message?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(160))
    }
}

/// Which device this is, for the "this device ↔ host" line.
enum BighelpDeviceKind: Sendable, CaseIterable {
    case iPhone, iPad, mac, visionPro

    @MainActor static var current: Self {
        #if targetEnvironment(macCatalyst)
        .mac
        #elseif os(visionOS)
        .visionPro
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }

    var label: String {
        switch self {
        case .iPhone: "This iPhone"
        case .iPad: "This iPad"
        case .mac: "This Mac"
        case .visionPro: "This Vision Pro"
        }
    }

    var systemImage: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "laptopcomputer"
        case .visionPro: "visionpro"
        }
    }
}

/// The small mark for a phase: three bouncing dots, a spinning arc, a dot
/// (which pings once on becoming connected), or a hollow ring that never moves.
struct BighelpConnectionIndicator: View {
    let phase: BighelpConnectionPhase
    var tint: Color?

    @BighelpThemeReader private var theme
    @BighelpLoaderMotionReader private var motion
    @BighelpLoaderScaled(relativeTo: .footnote) private var side: CGFloat = 14
    @State private var pings = 0

    var body: some View {
        let color = tint ?? phase.tint(in: theme)
        let unit = side / 14
        ZStack {
            switch phase {
            case .connecting:
                // The kit's launch: a dot pops in and unspools into the b.
                BighelpNoodleView(motion: .launch, size: side, playback: .loop(pause: 0.6), tint: color)
            case .reconnecting:
                // The kit's spring: bouncing back.
                BighelpNoodleView(motion: .spring, size: side, playback: .loop(pause: 0.3), tint: color)
            case .connected:
                Circle().fill(color)
                    .frame(width: 8 * unit, height: 8 * unit)
                    .keyframeAnimator(initialValue: BighelpPingFrame.rest, trigger: pings) { ping, frame in
                        ping.scaleEffect(frame.scale).opacity(frame.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            MoveKeyframe(1)
                            CubicKeyframe(2.6, duration: BighelpLoaderTiming.ping * 0.7)
                        }
                        KeyframeTrack(\.opacity) {
                            MoveKeyframe(0.55)
                            LinearKeyframe(0, duration: BighelpLoaderTiming.ping * 0.7)
                        }
                    }
                Circle().fill(color).frame(width: 8 * unit, height: 8 * unit)
            case .disconnected:
                Circle().strokeBorder(color, lineWidth: 2 * unit)
                    .frame(width: 8 * unit, height: 8 * unit)
            }
        }
        .frame(width: side, height: side)
        .onChange(of: phase) { old, new in
            // Once, on the way in. A host that was already connected stays still.
            if new == .connected, old != .connected, motion.animates { pings += 1 }
        }
        .accessibilityHidden(true)
    }
}

/// A status capsule: the indicator and its label in the phase's color.
struct BighelpConnectionPill: View {
    let phase: BighelpConnectionPhase
    /// Replaces the phase's own words ("No internet" for a dropped network).
    var label: String?

    @BighelpThemeReader private var theme
    @BighelpLoaderMotionReader private var motion
    @BighelpLoaderScaled(relativeTo: .footnote) private var height: CGFloat = 28

    var body: some View {
        let color = phase.tint(in: theme)
        let text = label ?? phase.label
        HStack(spacing: 7) {
            BighelpConnectionIndicator(phase: phase)
            Text(text)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .font(.bighelp(.footnote, weight: .semibold))
        .foregroundStyle(color)
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .frame(minHeight: height)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
        .animation(motion.moves ? .easeOut(duration: BighelpTokens.stateDuration) : nil, value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("connection.pill.\(phase.rawValue)")
    }
}

/// For host setup: this device and the host as two tiles joined by a line that
/// shows the phase. Dashes flow and dots travel while connecting, one dot
/// probes while trying again, a single dot crosses once on connecting, and a
/// broken line holds still when it's down. The status pill and any real detail
/// sit underneath.
struct BighelpConnectionLine: View {
    let phase: BighelpConnectionPhase
    let hostName: String
    var hostSystemImage = "desktopcomputer"
    /// Defaults to the device this runs on.
    var device: BighelpDeviceKind?
    /// Replaces the pill's words.
    var label: String?
    var detail: BighelpConnectionDetail?
    var showsStatus = true

    @BighelpThemeReader private var theme

    var body: some View {
        let device = device ?? .current
        VStack(spacing: BighelpTokens.space16) {
            HStack(alignment: .top, spacing: 10) {
                BighelpConnectionNode(title: device.label, systemImage: device.systemImage, tint: theme.action)
                BighelpConnectionTrack(phase: phase)
                    .frame(maxWidth: .infinity)
                    .padding(.top, BighelpConnectionNode.tileSide / 2 - 10)
                BighelpConnectionNode(title: hostName, systemImage: hostSystemImage,
                                      tint: phase == .disconnected ? theme.tertiaryText : Self.hostTint(theme))
            }
            if showsStatus {
                VStack(spacing: BighelpTokens.space4) {
                    BighelpConnectionPill(phase: phase, label: label)
                    if let text = detail?.text(for: phase) {
                        Text(text)
                            .font(.bighelp(.footnote))
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .contentTransition(.opacity)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.label) to \(hostName): \(label ?? phase.label)")
        .accessibilityValue(detail?.text(for: phase) ?? "")
        .accessibilityIdentifier("connection.line")
    }

    /// Hosts' own tile color from Settings, so a computer looks the same everywhere.
    static func hostTint(_ theme: BighelpTheme) -> Color {
        SettingsMenuSection.connectivityAndNotifications.tintHex.map(Color.init(hex:)) ?? theme.secondaryText
    }
}

/// Keyframes of the loader motions, as plain math so tests can check them.
enum BighelpConnectionMotion {
    static let bounceDelays: [TimeInterval] = [0, 0.15, 0.3]
    static let packetDelays: [TimeInterval] = [0, 0.53, 1.06]

    /// How high a dot is (0 rest, 1 top): up by 30% of the loop, down by 60%.
    static func bounce(_ time: BighelpLoaderTime, index: Int) -> Double {
        guard !time.isStill else { return 0 }
        let p = time.phase(BighelpLoaderTiming.dotsBounce, offset: -bounceDelays[index % bounceDelays.count])
        if p < 0.3 { return BighelpLoaderCurve.easeInOut(p / 0.3) }
        if p < 0.6 { return 1 - BighelpLoaderCurve.easeInOut((p - 0.3) / 0.3) }
        return 0
    }

    /// A traveling packet: where it is along the line (0...1) and how visible.
    static func travel(_ phase: Double) -> (position: Double, opacity: Double) {
        let position = BighelpLoaderCurve.site(phase)
        let opacity = phase < 0.15 ? phase / 0.15 : phase > 0.85 ? (1 - phase) / 0.15 : 1
        return (position, opacity)
    }
}

private struct BighelpPingFrame {
    var scale: CGFloat
    var opacity: Double
    static let rest = Self(scale: 1, opacity: 0)
}

private struct BighelpConnectionNode: View {
    static let tileSide: CGFloat = 40

    let title: String
    let systemImage: String
    let tint: Color

    @BighelpThemeReader private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 6) {
            BighelpSymbolImage(systemName: systemImage)
                .frame(width: 22, height: 22)
                .foregroundStyle(tint)
                .frame(width: Self.tileSide, height: Self.tileSide)
                .background(tint.opacity(theme.isDarkPalette ? 0.26 : 0.13), in: shape)
                .overlay { shape.strokeBorder(tint.opacity(theme.isDarkPalette ? 0.22 : 0.16), lineWidth: 1) }
            // Names wrap at their spaces; an address has none, so it shrinks to
            // one line instead of breaking mid-number ("10.255.255." over "1").
            Text(title)
                .font(.bighelp(.caption2, weight: .medium))
                .foregroundStyle(theme.tertiaryText)
                .multilineTextAlignment(.center)
                .lineLimit(title.contains(" ") ? 2 : 1)
                .minimumScaleFactor(0.7)
                .truncationMode(.middle)
        }
        .frame(width: 64)
        .animation(.easeOut(duration: BighelpTokens.stateDuration), value: tint)
    }
}

private struct BighelpConnectionTrack: View {
    let phase: BighelpConnectionPhase

    @BighelpThemeReader private var theme
    @BighelpLoaderMotionReader private var motion
    @State private var hellos = 0

    var body: some View {
        let color = phase.tint(in: theme)
        GeometryReader { proxy in
            let width = proxy.size.width
            let middle = proxy.size.height / 2
            ZStack(alignment: .topLeading) {
                switch phase {
                case .connecting, .reconnecting:
                    BighelpLoaderClock(cadence: .smooth) { time in
                        ZStack(alignment: .topLeading) {
                            dashedLine(width: width, middle: middle, color: color, time: time)
                            if phase == .connecting {
                                ForEach(0..<3, id: \.self) { index in
                                    let travel = BighelpConnectionMotion.travel(time.phase(
                                        BighelpLoaderTiming.packetTravel,
                                        offset: -BighelpConnectionMotion.packetDelays[index]))
                                    packet(color: color, size: 8)
                                        .position(x: width * travel.position, y: middle)
                                        .opacity(time.isStill ? (index == 1 ? 1 : 0) : travel.opacity)
                                }
                            } else {
                                let reach = 0.08 + 0.54 * time.pingPong(BighelpLoaderTiming.packetProbe, rest: 0.5)
                                packet(color: color, size: 8)
                                    .position(x: width * reach, y: middle)
                            }
                        }
                    }
                case .connected:
                    Capsule().fill(color.opacity(0.9))
                        .frame(width: width, height: 2)
                        .position(x: width / 2, y: middle)
                    packet(color: color, size: 6)
                        .keyframeAnimator(initialValue: BighelpHelloFrame.rest, trigger: hellos) { dot, frame in
                            dot.position(x: width * frame.position, y: middle).opacity(frame.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.position) {
                                MoveKeyframe(0)
                                CubicKeyframe(1, duration: 1.4)
                            }
                            KeyframeTrack(\.opacity) {
                                MoveKeyframe(0)
                                LinearKeyframe(1, duration: 0.2)
                                LinearKeyframe(1, duration: 1)
                                LinearKeyframe(0, duration: 0.2)
                            }
                        }
                case .disconnected:
                    brokenLine(width: width, middle: middle, color: color)
                }
            }
        }
        .frame(height: 20)
        .frame(minWidth: 60)
        .onChange(of: phase) { old, new in
            if new == .connected, old != .connected, motion.animates { hellos += 1 }
        }
        .accessibilityHidden(true)
    }

    private func dashedLine(width: CGFloat, middle: CGFloat, color: Color, time: BighelpLoaderTime) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: middle))
            path.addLine(to: CGPoint(x: width, y: middle))
        }
        .stroke(color.opacity(0.45), style: StrokeStyle(
            lineWidth: 2, lineCap: .butt, dash: [6, 5],
            dashPhase: -11 * time.phase(BighelpLoaderTiming.dashFlow)))
    }

    private func brokenLine(width: CGFloat, middle: CGFloat, color: Color) -> some View {
        ZStack(alignment: .topLeading) {
            Capsule().fill(color.opacity(0.4))
                .frame(width: width * 0.4, height: 2)
                .position(x: width * 0.2, y: middle)
            Capsule().fill(color.opacity(0.4))
                .frame(width: width * 0.4, height: 2)
                .position(x: width * 0.8, y: middle)
            ForEach([-4.0, 4.0], id: \.self) { shift in
                Capsule().fill(color)
                    .frame(width: 2, height: 14)
                    .rotationEffect(.degrees(20))
                    .position(x: width / 2 + shift, y: middle)
            }
        }
    }

    private func packet(color: Color, size: CGFloat) -> some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.18)).frame(width: size + 8, height: size + 8))
    }
}

private struct BighelpHelloFrame {
    var position: CGFloat
    var opacity: Double
    static let rest = Self(position: 0, opacity: 0)
}
