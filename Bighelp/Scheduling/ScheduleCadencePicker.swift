import SwiftUI

/// Friendly presets layered over `ScheduledTaskEditorPickerState`.
enum ScheduleFrequency: String, CaseIterable, Identifiable {
    case once = "Once"
    case daily = "Daily"
    case weekdays = "Weekdays"
    case weekly = "Weekly"
    case custom = "Custom"
    var id: Self { self }
    /// Five equal segments leave no room for "Weekdays" on iPhone.
    var segmentTitle: String { self == .weekdays ? "Mon–Fri" : rawValue }
}

enum ScheduleCustomMode: String, CaseIterable, Identifiable {
    case days = "On days I pick"
    case monthly = "Once a month"
    case words = "In my own words"
    var id: Self { self }
}

/// The "When?" choice of a scheduled task, and of a scheduled workflow.
struct ScheduleCadence: Equatable {
    var picker: ScheduledTaskEditorPickerState
    var frequency: ScheduleFrequency
    var customMode: ScheduleCustomMode

    static let weekdaySet: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    init(picker: ScheduledTaskEditorPickerState, describing: Bool = false) {
        self.picker = picker
        customMode = describing ? .words : picker.kind == .monthly ? .monthly : .days
        frequency = describing ? .custom : Self.frequency(for: picker)
    }

    var isDescribing: Bool { frequency == .custom && customMode == .words }

    mutating func apply(_ newValue: ScheduleFrequency) {
        frequency = newValue
        switch newValue {
        case .once:
            picker.kind = .once
        case .daily:
            picker.kind = .repeating
            picker.selectedDays = Set(Weekday.allCases)
        case .weekdays:
            picker.kind = .repeating
            picker.selectedDays = Self.weekdaySet
        case .weekly:
            picker.kind = .repeating
            if picker.selectedDays.count != 1 {
                let today = Calendar.current.component(.weekday, from: .now)
                picker.selectedDays = [Weekday(rawValue: today) ?? .monday]
            }
        case .custom:
            setCustomMode(customMode)
        }
    }

    mutating func setCustomMode(_ mode: ScheduleCustomMode) {
        customMode = mode
        switch mode {
        case .days: picker.kind = .repeating
        case .monthly: picker.kind = .monthly
        case .words: break
        }
    }

    mutating func toggle(_ day: Weekday) {
        picker.toggle(day)
        frequency = Self.frequency(for: picker)
        if frequency == .custom { customMode = .days }
    }

    static func frequency(for state: ScheduledTaskEditorPickerState) -> ScheduleFrequency {
        switch state.kind {
        case .once: return .once
        case .monthly: return .custom
        case .repeating:
            if state.selectedDays == Set(Weekday.allCases) { return .daily }
            if state.selectedDays == weekdaySet { return .weekdays }
            if state.selectedDays.count == 1 { return .weekly }
            return .custom
        }
    }
}

/// The rows of the "When?" section: how often, which days, which day of the month, the time.
/// `words` is the "In my own words" control, when the caller offers it.
struct ScheduleCadenceRows<Words: View>: View {
    @Binding var cadence: ScheduleCadence
    var frequencies: [ScheduleFrequency] = ScheduleFrequency.allCases
    var customModes: [ScheduleCustomMode] = ScheduleCustomMode.allCases
    /// Accessibility identifiers start with this, as the scheduled task editor's always have.
    var identifier = "scheduled-task.editor"
    @ViewBuilder var words: () -> Words
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @BighelpThemeReader private var theme

    var body: some View {
        frequencyPicker
        switch cadence.frequency {
        case .once:
            DatePicker("Date", selection: $cadence.picker.scheduledDate, displayedComponents: .date)
                .environment(\.timeZone, cadence.picker.timeZone)
            timePicker
        case .daily, .weekdays, .weekly:
            weekdayChips
            timePicker
        case .custom:
            Picker("Repeat", selection: Binding(get: { cadence.customMode }, set: { cadence.setCustomMode($0) })) {
                ForEach(customModes) { mode in Text(mode.rawValue).tag(mode) }
            }
            .accessibilityIdentifier("\(identifier).custom-mode")
            switch cadence.customMode {
            case .days:
                weekdayChips
                timePicker
            case .monthly:
                Picker("Day of month", selection: $cadence.picker.monthlyDay) {
                    ForEach(1...31, id: \.self) { day in
                        Text(day.formatted()).tag(day)
                    }
                }
                timePicker
            case .words:
                words()
            }
        }
    }

    private var frequencyBinding: Binding<ScheduleFrequency> {
        Binding(get: { cadence.frequency }, set: { cadence.apply($0) })
    }

    @ViewBuilder
    private var frequencyPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("How often", selection: frequencyBinding) {
                ForEach(frequencies) { option in Text(option.rawValue).tag(option) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("\(identifier).frequency")
        } else {
            Picker("How often", selection: frequencyBinding) {
                ForEach(frequencies) { option in
                    Text(option.segmentTitle).tag(option).accessibilityLabel(option.rawValue)
                }
            }
            .bighelpSegmentedPicker()
            .listRowInsets(EdgeInsets(
                top: BighelpTokens.space12,
                leading: BighelpTokens.space12,
                bottom: BighelpTokens.space12,
                trailing: BighelpTokens.space12
            ))
            .accessibilityIdentifier("\(identifier).frequency")
        }
    }

    private var timePicker: some View {
        DatePicker("Time", selection: $cadence.picker.scheduledTime, displayedComponents: .hourAndMinute)
            .environment(\.timeZone, cadence.picker.timeZone)
    }

    @ViewBuilder
    private var weekdayChips: some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: BighelpTokens.space8)],
                spacing: BighelpTokens.space8
            ) {
                ForEach(orderedWeekdays) { day in weekdayChip(day, title: day.shortTitle) }
            }
        } else {
            HStack(spacing: BighelpTokens.space4) {
                ForEach(orderedWeekdays) { day in weekdayChip(day, title: String(day.title.prefix(1))) }
            }
        }
    }

    private func weekdayChip(_ day: Weekday, title: String) -> some View {
        let isSelected = cadence.picker.selectedDays.contains(day)
        return Button(title) { cadence.toggle(day) }
            .buttonStyle(.plain)
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(isSelected ? theme.action : theme.incomingMessageBackground, in: .capsule)
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
            .accessibilityLabel(day.title)
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("\(identifier).weekday.\(day.title.lowercased())")
    }

    private var orderedWeekdays: [Weekday] {
        let first = Calendar.current.firstWeekday
        return Weekday.allCases.sorted { lhs, rhs in
            (lhs.rawValue - first + 7) % 7 < (rhs.rawValue - first + 7) % 7
        }
    }
}

extension ScheduleCadenceRows where Words == EmptyView {
    init(cadence: Binding<ScheduleCadence>, frequencies: [ScheduleFrequency] = ScheduleFrequency.allCases,
         customModes: [ScheduleCustomMode] = ScheduleCustomMode.allCases, identifier: String) {
        self.init(cadence: cadence, frequencies: frequencies, customModes: customModes, identifier: identifier,
                  words: { EmptyView() })
    }
}
