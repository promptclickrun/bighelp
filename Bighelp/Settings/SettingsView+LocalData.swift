import SwiftUI

extension SettingsView {
    /// Clear local cache and what it last said, as rows of the computer in use's This device group.
    /// The page that shows them confirms first (`ClearCacheConfirmation`).
    @ViewBuilder
    var clearLocalCacheRows: some View {
        Button {
            isClearCacheConfirmationPresented = true
        } label: {
            Label(
                isClearingLocalCache ? "Refreshing local data…" : "Clear local cache",
                systemImage: "arrow.clockwise.circle"
            )
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        }
        .disabled(isClearingLocalCache)
        .accessibilityIdentifier("settings.account.clear-local-cache")

        if let localCacheStatusMessage {
            Text(localCacheStatusMessage)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .accessibilityIdentifier("settings.account.clear-local-cache-status")
        }
    }

    func clearLocalCache() {
        guard !isClearingLocalCache else { return }
        isClearingLocalCache = true
        localCacheStatusMessage = nil
        Task { @MainActor in
            let succeeded = await onClearLocalCache()
            localCacheStatusMessage = succeeded
                ? String(localized: "Local cache cleared. Fresh data is ready.")
                : String(localized: "The local cache could not be refreshed. Try again.")
            isClearingLocalCache = false
        }
    }
}
