import SwiftUI

/// Every time zone, searchable.
@MainActor
struct SimpleBotTimeZonePicker: View {
    let current: String
    let onPick: (String) -> Void
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
            List(zones, id: \.self) { zone in
                Button { onPick(zone) } label: {
                    HStack {
                        Text(zone.replacingOccurrences(of: "_", with: " "))
                        Spacer()
                        if zone == current { Image(systemName: "checkmark") }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query)
            .navigationTitle("Time Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
