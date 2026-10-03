import SwiftUI

extension SettingsView {
    var localCache: some View {
        Section {
            Button {
                isClearCacheConfirmationPresented = true
            } label: {
                Label(
                    isClearingLocalCache ? "Refreshing Local Data…" : "Clear Local Cache",
                    systemImage: "arrow.clockwise.circle"
                )
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            }
            .disabled(
                isClearingLocalCache
            )
            .accessibilityIdentifier("settings.account.clear-local-cache")

            if let localCacheStatusMessage {
                Text(localCacheStatusMessage)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("settings.account.clear-local-cache-status")
            }
        } header: {
            Text("Local Data")
        } footer: {
            Text("Clears cached data for the selected Hermes host and immediately downloads a fresh copy. Your preferences are kept.")
                .bighelpFont(.metadata)
        }
        .listRowBackground(theme.surface)
    }

    func clearLocalCache() {
        guard !isClearingLocalCache else { return }
        isClearingLocalCache = true
        localCacheStatusMessage = nil
        Task { @MainActor in
            let succeeded = await onClearLocalCache()
            localCacheStatusMessage = succeeded
                ? "Local cache cleared. Fresh data is ready."
                : "The local cache could not be refreshed. Try again."
            isClearingLocalCache = false
        }
    }

    var connectivity: some View {
        Section {
            Toggle(isOn: $settings.offlineModeEnabled) {
                settingLabel(
                    "Offline mode",
                    detail: "Keep downloaded sessions readable while pausing network actions."
                )
            }
        } header: {
            Text("Connectivity")
        }
        .listRowBackground(theme.surface)
    }
}
