import SwiftUI

/// Says which extras this host couldn't answer, instead of failing the page.
struct SkippedPartsNote: View {
    let parts: [String]

    var body: some View {
        if !parts.isEmpty {
            Section {
                Label("This computer didn't return: \(parts.joined(separator: ", ")). Everything else is up to date.",
                      systemImage: "info.circle")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.skipped-parts")
            }
        }
    }
}
