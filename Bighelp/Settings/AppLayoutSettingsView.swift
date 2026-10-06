import SwiftUI

/// Settings › Appearance › App layout: what the bottom bar holds after Chat, and the
/// order of ☰. Whatever isn't in the bar is in ☰, so nothing is ever out of reach.
struct AppLayoutSettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var isResetConfirmationPresented = false

    private var layout: BighelpAppLayout { settings.appLayout }

    var body: some View {
        List {
            barSection
            addSection
            menuSection
            Section {
                Button("Reset to Default Layout", role: .destructive) {
                    isResetConfirmationPresented = true
                }
                .disabled(layout == .standard)
                .accessibilityIdentifier("app-layout.reset")
            } footer: {
                Text("Puts the bottom bar and the menu back the way bighelp recommends.")
            }
            .listRowBackground(theme.surface)
        }
        .alert("Reset to the default layout?", isPresented: $isResetConfirmationPresented) {
            Button("Reset", role: .destructive) {
                withAnimation { settings.appLayout = .standard }
            }
            .accessibilityIdentifier("app-layout.reset.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The bottom bar becomes Chat, Feed, Ideas, Goals and Files again, and the menu returns to its standard order.")
        }
        // Handles to drag. Adding and removing are their own buttons.
        .environment(\.editMode, .constant(.active))
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle("App layout")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("app-layout")
    }

    // MARK: Bottom bar

    private var barSection: some View {
        Section {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: "lock.fill")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.tertiaryText)
                    .frame(width: BighelpTokens.hitTarget)
                    .accessibilityHidden(true)
                label("Chat", symbol: "bubble.left")
            }
            .moveDisabled(true)
            .accessibilityIdentifier("app-layout.bar.chat")
            ForEach(layout.pinned) { place in
                HStack(spacing: BighelpTokens.space12) {
                    circleButton("minus.circle.fill", tint: theme.danger,
                                 label: "Remove \(place.title) from the bottom bar",
                                 id: "app-layout.remove.\(place.rawValue)") {
                        withAnimation { settings.appLayout.unpin(place) }
                    }
                    label(place.title, symbol: place.symbol)
                }
                // Keeps the remove button's own identifier reachable.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("app-layout.bar.\(place.rawValue)")
            }
            .onMove { settings.appLayout.movePinned(from: $0, to: $1) }
        } header: {
            Text("Bottom bar")
        } footer: {
            Text("Chat is always first. Drag to change the order. What you remove goes to the menu.")
        }
        .listRowBackground(theme.surface)
    }

    private var addSection: some View {
        Section {
            ForEach(BighelpPlace.allCases.filter { $0.canPin && !layout.isPinned($0) }) { place in
                HStack(spacing: BighelpTokens.space12) {
                    circleButton("plus.circle.fill", tint: layout.canPinMore ? theme.success : theme.tertiaryText,
                                 label: "Add \(place.title) to the bottom bar",
                                 id: "app-layout.add.\(place.rawValue)") {
                        withAnimation { settings.appLayout.pin(place) }
                    }
                    .disabled(!layout.canPinMore)
                    label(place.title, symbol: place.symbol)
                }
                .moveDisabled(true)
            }
        } header: {
            Text("Add to the bottom bar")
        } footer: {
            Text(layout.canPinMore
                 ? "The bottom bar holds Chat and up to \(BighelpAppLayout.maximumPinned) more."
                 : "The bottom bar is full. Remove one to add another.")
        }
        .listRowBackground(theme.surface)
    }

    // MARK: Menu

    private var menuSection: some View {
        Section {
            ForEach(layout.menuPlaces) { place in
                label(place.title, symbol: place.symbol)
                    .accessibilityIdentifier("app-layout.menu.\(place.rawValue)")
            }
            .onMove { settings.appLayout.moveMenu(from: $0, to: $1) }
        } header: {
            Text("Menu")
        } footer: {
            Text("The menu shows everything that isn't in the bottom bar. Drag to change the order.")
        }
        .listRowBackground(theme.surface)
    }

    private func circleButton(_ symbol: String, tint: Color, label: String, id: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.bighelp(.title3))
                .foregroundStyle(tint)
                .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func label(_ title: String, symbol: String) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpIconTile(systemName: symbol)
            Text(title)
                .bighelpFont(.body)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 0)
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}
