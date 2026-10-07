import SwiftUI

/// The island's little stage: the agent's avatar acting out its work.
/// Chasing a brain while thinking, code streaming out while coding,
/// fixing a computer, painting, sending paper planes…
struct IslandStage: View {
    let activity: AgentIslandActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let avatarSize: CGFloat = 38

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                // Reduce Motion keeps one still frame of the same scene.
                let time = reduceMotion ? 1.3 : context.date.timeIntervalSinceReferenceDate
                let scene = IslandScene(kind: activity.kind, size: proxy.size, time: time)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in scene.drawBehind(&context) }
                    AgentLiveAvatar(agentID: activity.agentID, displayName: activity.name,
                                    imageURL: activity.imageURL, activity: activity.kind,
                                    size: Self.avatarSize, showsBadge: false)
                        .rotationEffect(.degrees(scene.avatarTilt))
                        .position(scene.avatarCenter)
                    Canvas { context, _ in scene.drawInFront(&context) }
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Where everything is at one moment. Pure math on time, so the scene is
/// cheap to draw and identical for every frame at the same time.
struct IslandScene {
    let kind: AgentActivityKind
    let size: CGSize
    let time: Double

    private var width: Double { size.width }
    private var height: Double { size.height }
    private var floor: Double { height * 0.62 }

    // MARK: Avatar

    var avatarCenter: CGPoint {
        switch kind {
        case .thinking, .memory:
            // Runs after the brain it's chasing.
            CGPoint(x: chaseX - 40, y: floor - hop(rate: 11, height: 5))
        case .web, .seeing, .scheduling, .idle:
            CGPoint(x: walkX, y: floor - hop(rate: 9, height: 3))
        case .coding, .files:
            CGPoint(x: 26, y: floor - abs(sin(time * 16)) * 1.2)
        case .tools:
            CGPoint(x: width * 0.42, y: floor - abs(sin(time * 8)) * 2)
        case .images, .publishing:
            CGPoint(x: 28, y: floor - hop(rate: 5, height: 2))
        case .replying, .messaging, .delegating:
            CGPoint(x: 28, y: floor - hop(rate: 6, height: 4))
        case .waiting:
            CGPoint(x: width * 0.5, y: floor)
        case .done:
            CGPoint(x: width * 0.5, y: floor - hop(rate: 5, height: 12))
        case .failed:
            CGPoint(x: width * 0.5, y: floor + 2)
        }
    }

    var avatarTilt: Double {
        switch kind {
        case .thinking, .memory, .web, .seeing, .scheduling, .idle: sin(time * 11) * 7
        case .tools: sin(time * 8) * 4
        case .waiting: sin(time * 3) * 5
        case .failed: -8
        default: sin(time * 3) * 2
        }
    }

    private func hop(rate: Double, height: Double) -> Double { abs(sin(time * rate)) * height }

    /// Left to right across the stage, then around again.
    private var walkX: Double {
        let loop = width + 60
        return (time * 34).truncatingRemainder(dividingBy: loop) - 30
    }

    private var chaseX: Double {
        let loop = width + 70
        return (time * 44).truncatingRemainder(dividingBy: loop) + 10
    }

    private func phase(_ index: Int, of count: Int, rate: Double) -> Double {
        (time * rate + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1)
    }

    // MARK: Drawing

    func drawBehind(_ context: inout GraphicsContext) {
        switch kind {
        case .thinking, .memory: brains(&context)
        case .coding: codeStream(&context)
        case .web: surfing(&context)
        case .images: painting(&context)
        case .tools: fixingComputer(&context)
        case .files: filesToFolder(&context)
        case .replying: speechBubbles(&context)
        case .messaging: paperPlanes(&context)
        case .scheduling: calendar(&context)
        case .delegating: passingToHelpers(&context)
        case .seeing: searching(&context)
        case .publishing: pinning(&context)
        case .waiting: waving(&context)
        case .done: confetti(&context)
        case .failed: rainCloud(&context)
        case .idle: break
        }
    }

    func drawInFront(_ context: inout GraphicsContext) {
        switch kind {
        case .coding:
            symbol("laptopcomputer", color: .white.opacity(0.9), size: 17,
                   at: CGPoint(x: 50, y: floor + 6), in: &context)
        case .tools:
            let swing = Angle.degrees(-30 + sin(time * 9) * 40)
            symbol("wrench.adjustable.fill", color: Color(red: 0.8, green: 0.84, blue: 0.9), size: 15,
                   at: CGPoint(x: width * 0.42 + 18, y: floor - 8), rotation: swing, in: &context)
        case .images:
            let swing = Angle.degrees(sin(time * 6) * 35)
            symbol("paintbrush.pointed.fill", color: .white, size: 14,
                   at: CGPoint(x: 46, y: floor - 10), rotation: swing, in: &context)
        default:
            break
        }
    }

    private func symbol(_ name: String, color: Color, size: Double, at point: CGPoint,
                        opacity: Double = 1, rotation: Angle = .zero, in context: inout GraphicsContext) {
        var layer = context
        layer.opacity = opacity
        layer.translateBy(x: point.x, y: point.y)
        layer.rotate(by: rotation)
        layer.draw(Text(Image(systemName: name)).font(.system(size: size, weight: .semibold)).foregroundStyle(color),
                   at: .zero)
    }

    private func glyph(_ text: String, color: Color, size: Double, at point: CGPoint, opacity: Double,
                       in context: inout GraphicsContext) {
        var layer = context
        layer.opacity = opacity
        layer.draw(Text(text).font(.system(size: size, weight: .bold, design: .monospaced)).foregroundStyle(color),
                   at: point)
    }

    // Thinking: a brain bobs ahead and the avatar can never quite catch it.
    private func brains(_ context: inout GraphicsContext) {
        let pink = Color(red: 1, green: 0.6, blue: 0.78)
        let brain = CGPoint(x: chaseX + 4, y: floor - 12 + sin(time * 3.4) * 7)
        for trail in 1...4 {
            let offset = Double(trail) * 9
            glyph("·", color: pink, size: 12, at: CGPoint(x: brain.x - offset - 8, y: brain.y + sin(time * 3.4 - Double(trail)) * 5),
                  opacity: 0.55 - Double(trail) * 0.12, in: &context)
        }
        symbol(kind == .memory ? "brain.head.profile" : "brain.fill", color: pink, size: 19, at: brain, in: &context)
        // More ideas floating further ahead.
        for index in 0..<2 {
            let x = (chaseX + 60 + Double(index) * 55).truncatingRemainder(dividingBy: width + 110)
            symbol("sparkle", color: Color(red: 0.8, green: 0.7, blue: 1), size: 9,
                   at: CGPoint(x: x, y: floor - 26 + sin(time * 2 + Double(index)) * 6),
                   opacity: 0.4 + 0.3 * sin(time * 4 + Double(index)), in: &context)
        }
    }

    // Coding: tokens stream out of the laptop across the island.
    private func codeStream(_ context: inout GraphicsContext) {
        let tokens = ["{", "}", "</>", "=>", "fn", "();", "01", "let", "[]", "if", "&&", "}"]
        let lanes: [Double] = [-18, -8, 2, 12]
        for index in 0..<12 {
            let progress = phase(index, of: 12, rate: 0.45)
            let x = 64 + progress * (width - 76)
            let y = floor + lanes[index % lanes.count] - 6
            let green = Color(red: 0.38, green: 0.95 - Double(index % 3) * 0.1, blue: 0.6)
            glyph(tokens[index % tokens.count], color: green, size: 11, at: CGPoint(x: x, y: y),
                  opacity: sin(progress * .pi), in: &context)
        }
    }

    // Web: a spinning globe floats along while the avatar walks the waves.
    private func surfing(_ context: inout GraphicsContext) {
        let blue = Color(red: 0.4, green: 0.72, blue: 1)
        for index in 0..<8 {
            let x = (Double(index) * (width / 7) - (time * 30).truncatingRemainder(dividingBy: width / 7))
            glyph("~", color: blue.opacity(0.7), size: 13, at: CGPoint(x: x, y: floor + 18), opacity: 0.6, in: &context)
        }
        symbol("globe.americas.fill", color: blue, size: 16,
               at: CGPoint(x: walkX + 26, y: floor - 20 + sin(time * 2.5) * 3),
               rotation: .degrees(sin(time * 1.5) * 20), in: &context)
        for index in 0..<3 {
            let progress = phase(index, of: 3, rate: 0.6)
            glyph("·", color: blue, size: 14, at: CGPoint(x: walkX + 40 + progress * 60, y: floor - 20 - progress * 10),
                  opacity: 1 - progress, in: &context)
        }
    }

    // Images: paint splats bloom across the island.
    private func painting(_ context: inout GraphicsContext) {
        let colors: [Color] = [.pink, .orange, .yellow, .green, .cyan, .purple, .red]
        for index in 0..<7 {
            let progress = phase(index, of: 7, rate: 0.35)
            let x = 72 + (width - 90) * (Double((index * 37) % 100) / 100)
            let y = floor - 16 + Double((index * 53) % 30) - 10
            let radius = 3 + progress * 8
            var layer = context
            layer.opacity = progress < 0.7 ? 1 : (1 - progress) / 0.3
            layer.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                       with: .color(colors[index % colors.count]))
        }
    }

    // Tools: fixing the computer, sparks flying.
    private func fixingComputer(_ context: inout GraphicsContext) {
        let computer = CGPoint(x: width * 0.66, y: floor - 4)
        symbol("desktopcomputer", color: .white.opacity(0.9), size: 28, at: computer, in: &context)
        for index in 0..<5 {
            let progress = phase(index, of: 5, rate: 1.4)
            let angle = Double(index) * 1.25 + 0.4
            let point = CGPoint(x: computer.x - 14 + cos(angle) * progress * 18,
                                y: computer.y - 8 - sin(angle) * progress * 16)
            symbol("sparkle", color: .yellow, size: 7, at: point, opacity: 1 - progress, in: &context)
        }
    }

    // Files: pages fly from the avatar into a folder.
    private func filesToFolder(_ context: inout GraphicsContext) {
        let folder = CGPoint(x: width - 30, y: floor)
        symbol("folder.fill", color: Color(red: 1, green: 0.8, blue: 0.35), size: 24, at: folder, in: &context)
        for index in 0..<3 {
            let progress = phase(index, of: 3, rate: 0.5)
            let x = 44 + progress * (folder.x - 50)
            let y = floor - 6 - sin(progress * .pi) * 20
            symbol("doc.text.fill", color: .white, size: 12, at: CGPoint(x: x, y: y),
                   opacity: progress < 0.9 ? 1 : (1 - progress) * 10, rotation: .degrees(progress * 30), in: &context)
        }
    }

    // Replying: speech bubbles drift up and away.
    private func speechBubbles(_ context: inout GraphicsContext) {
        for index in 0..<4 {
            let progress = phase(index, of: 4, rate: 0.4)
            let point = CGPoint(x: 50 + progress * (width - 70), y: floor - 8 - sin(progress * .pi) * 14)
            symbol("ellipsis.bubble.fill", color: .white, size: 15, at: point, opacity: sin(progress * .pi), in: &context)
        }
    }

    // Messaging: paper planes swoop across.
    private func paperPlanes(_ context: inout GraphicsContext) {
        for index in 0..<3 {
            let progress = phase(index, of: 3, rate: 0.35)
            let point = CGPoint(x: 46 + progress * (width - 60), y: floor - 6 - sin(progress * .pi * 2) * 10)
            symbol("paperplane.fill", color: Color(red: 0.55, green: 0.8, blue: 1), size: 14, at: point,
                   opacity: sin(progress * .pi), rotation: .degrees(cos(progress * .pi * 2) * -20), in: &context)
        }
    }

    // Scheduling: the calendar waits while the alarm rings.
    private func calendar(_ context: inout GraphicsContext) {
        symbol("calendar", color: .white, size: 22, at: CGPoint(x: width - 34, y: floor - 2), in: &context)
        symbol("alarm.fill", color: .orange, size: 14, at: CGPoint(x: width - 62, y: floor - 16),
               rotation: .degrees(sin(time * 30) * 12), in: &context)
    }

    // Delegating: a ball goes back and forth with two helpers.
    private func passingToHelpers(_ context: inout GraphicsContext) {
        let helper = CGPoint(x: width - 34, y: floor)
        symbol("person.2.fill", color: Color(red: 0.75, green: 0.8, blue: 1), size: 20, at: helper, in: &context)
        let progress = (sin(time * 2.2) + 1) / 2
        let x = 46 + progress * (helper.x - 62)
        let y = floor - 6 - sin(progress * .pi) * 22
        var layer = context
        layer.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.yellow))
    }

    // Seeing: a magnifying glass sweeps along with the avatar.
    private func searching(_ context: inout GraphicsContext) {
        symbol("magnifyingglass", color: .white, size: 17,
               at: CGPoint(x: walkX + 26, y: floor - 14 + sin(time * 4) * 4),
               rotation: .degrees(sin(time * 3) * 15), in: &context)
    }

    // Publishing: pins drop onto the board.
    private func pinning(_ context: inout GraphicsContext) {
        for index in 0..<3 {
            let x = 70 + Double(index) * ((width - 90) / 3)
            var card = context
            card.opacity = 0.35
            card.fill(Path(roundedRect: CGRect(x: x - 12, y: floor - 6, width: 26, height: 16), cornerRadius: 4),
                      with: .color(.white))
            let progress = phase(index, of: 3, rate: 0.5)
            let drop = min(1, progress * 2)
            symbol("pin.fill", color: .red, size: 12, at: CGPoint(x: x + 1, y: floor - 30 + drop * 22),
                   opacity: progress < 0.85 ? 1 : (1 - progress) / 0.15, in: &context)
        }
    }

    // Waiting: waving for attention.
    private func waving(_ context: inout GraphicsContext) {
        symbol("hand.wave.fill", color: .yellow, size: 15, at: CGPoint(x: width * 0.5 + 22, y: floor - 12),
               rotation: .degrees(sin(time * 8) * 25), in: &context)
        symbol("questionmark.bubble.fill", color: .white, size: 15, at: CGPoint(x: width * 0.5 - 26, y: floor - 16),
               opacity: 0.6 + 0.4 * sin(time * 3), in: &context)
    }

    // Done: confetti.
    private func confetti(_ context: inout GraphicsContext) {
        let colors: [Color] = [.pink, .yellow, .green, .cyan, .orange, .purple]
        for index in 0..<16 {
            let progress = phase(index, of: 16, rate: 0.5)
            let x = width * (Double((index * 29) % 100) / 100)
            let y = -4 + progress * (height + 8)
            var layer = context
            layer.translateBy(x: x, y: y)
            layer.rotate(by: .degrees(progress * 360 + Double(index) * 20))
            layer.fill(Path(CGRect(x: -2.5, y: -1.5, width: 5, height: 3)), with: .color(colors[index % colors.count]))
        }
    }

    // Failed: a little rain cloud.
    private func rainCloud(_ context: inout GraphicsContext) {
        symbol("cloud.rain.fill", color: Color(red: 0.7, green: 0.75, blue: 0.85), size: 18,
               at: CGPoint(x: width * 0.5, y: floor - 30 + sin(time * 2) * 2), in: &context)
    }
}
