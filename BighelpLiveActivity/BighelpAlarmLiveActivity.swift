// A timer an agent set counts down here, on the Lock Screen and in the Dynamic Island. AlarmKit expects
// this extension for any countdown: without it the system may drop the timer before it rings.
// iPhone and iPad only (iOS 26 and later).
#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AlarmKit)
import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 26.0, *)
struct BighelpAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<BighelpAlarmMetadata>.self) { context in
            // The app's own page and bubble colors (Settings › Colors), like the session card.
            let snapshot = BighelpWidgetSnapshot.load()
            BighelpAlarmCard(attributes: context.attributes, state: context.state, snapshot: snapshot)
                .activityBackgroundTint(BighelpActivityColors.canvas(snapshot: snapshot))
                .activitySystemActionForegroundColor(BighelpActivityColors.accent(snapshot: snapshot))
        } dynamicIsland: { context in
            let kind = context.attributes.metadata?.kind ?? .timer
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: BighelpAlarmCard.symbol(kind))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(context.attributes.tintColor)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(BighelpAlarmCard.title(context.attributes))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        BighelpAlarmTime(mode: context.state.mode)
                            .font(.title2.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BighelpAlarmButtons(alarmID: context.state.alarmID, mode: context.state.mode,
                                        tint: context.attributes.tintColor)
                }
            } compactLeading: {
                Image(systemName: BighelpAlarmCard.symbol(kind))
                    .foregroundStyle(context.attributes.tintColor)
                    .accessibilityLabel(BighelpAlarmCard.title(context.attributes))
            } compactTrailing: {
                BighelpAlarmTime(mode: context.state.mode)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(context.attributes.tintColor)
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: BighelpAlarmCard.symbol(kind))
                    .foregroundStyle(context.attributes.tintColor)
                    .accessibilityLabel(BighelpAlarmCard.title(context.attributes))
            }
            .keylineTint(context.attributes.tintColor)
        }
    }
}

/// The Lock Screen card, drawn like the session card: the app's colors, a small "bighelp" tag, one large line.
@available(iOS 26.0, *)
private struct BighelpAlarmCard: View {
    let attributes: AlarmAttributes<BighelpAlarmMetadata>
    let state: AlarmPresentationState
    let snapshot: BighelpWidgetSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = BighelpActivityColors(snapshot: snapshot, scheme: scheme)
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: Self.symbol(attributes.metadata?.kind ?? .timer))
                .font(.title2.weight(.semibold))
                .foregroundStyle(colors.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(colors.accent.opacity(scheme == .dark ? 0.2 : 0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.title(attributes))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("bighelp")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(colors.accent)
                        .accessibilityHidden(true)
                }
                BighelpAlarmTime(mode: state.mode)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(colors.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BighelpAlarmButtons(alarmID: state.alarmID, mode: state.mode, tint: colors.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    static func symbol(_ kind: BighelpAlarmMetadata.Kind) -> String {
        kind == .timer ? "timer" : "alarm.fill"
    }

    static func title(_ attributes: AlarmAttributes<BighelpAlarmMetadata>) -> String {
        if let label = attributes.metadata?.label, !label.isEmpty { return label }
        return (attributes.metadata?.kind ?? .timer) == .timer ? "Timer" : "Alarm"
    }
}

/// What the clock says: time left while it counts down, the time it stopped at while paused, or the
/// time of day while it rings. Every number comes from the state AlarmKit reports.
@available(iOS 26.0, *)
private struct BighelpAlarmTime: View {
    let mode: AlarmPresentationState.Mode

    var body: some View {
        switch mode {
        case .countdown(let countdown):
            // A range needs its start before its end, and the fire date can already be past.
            Text(timerInterval: Date.now...max(Date.now, countdown.fireDate), countsDown: true)
        case .paused(let paused):
            let left = max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration)
            Text(Duration.seconds(left).formatted(.time(pattern: .hourMinuteSecond)))
        case .alert(let alert):
            Text(Self.timeOfDay(alert.time))
        @unknown default:
            Text("")
        }
    }

    private static func timeOfDay(_ time: Alarm.Schedule.Relative.Time) -> String {
        var parts = DateComponents()
        parts.hour = time.hour
        parts.minute = time.minute
        guard let date = Calendar.current.date(from: parts) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// Pause, resume and cancel for a timer. A ringing alarm has none: the system's own screen stops it.
@available(iOS 26.0, *)
private struct BighelpAlarmButtons: View {
    let alarmID: Alarm.ID
    let mode: AlarmPresentationState.Mode
    let tint: Color

    var body: some View {
        let id = alarmID.uuidString
        switch mode {
        case .countdown:
            HStack(spacing: 8) {
                button(BighelpAlarmPauseIntent(alarmID: id), symbol: "pause.fill", label: "Pause")
                button(BighelpAlarmCancelIntent(alarmID: id), symbol: "xmark", label: "Cancel")
            }
        case .paused:
            HStack(spacing: 8) {
                button(BighelpAlarmResumeIntent(alarmID: id), symbol: "play.fill", label: "Resume")
                button(BighelpAlarmCancelIntent(alarmID: id), symbol: "xmark", label: "Cancel")
            }
        case .alert:
            EmptyView()
        @unknown default:
            EmptyView()
        }
    }

    private func button(_ intent: some LiveActivityIntent, symbol: String, label: LocalizedStringKey) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .background(Circle().fill(tint.opacity(0.16)))
        .accessibilityLabel(label)
    }
}
#endif
