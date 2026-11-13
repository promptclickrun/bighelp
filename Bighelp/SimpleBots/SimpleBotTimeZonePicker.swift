import SwiftUI

/// Settings › Your computers › Time zone: Automatic (follow this device), then every time zone,
/// searchable. `onPick` gets nil for Automatic.
@MainActor
struct SimpleBotTimeZonePicker: View {
    let current: String
    let isAutomatic: Bool
    let onPick: (String?) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return all }
        return all.filter { $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(words) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        choice(String(localized: "Automatic"), isSelected: isAutomatic) { onPick(nil) }
                            .accessibilityIdentifier("settings.time-zone.automatic")
                    } footer: {
                        Text("Follows this device's time zone.")
                    }
                }
                Section {
                    ForEach(zones, id: \.self) { zone in
                        choice(Self.name(zone), isSelected: !isAutomatic && zone == current) { onPick(zone) }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Time zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    /// "America/New York" for "America/New_York".
    static func name(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    private func choice(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if isSelected { Image(systemName: "checkmark") }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
