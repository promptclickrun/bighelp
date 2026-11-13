import SwiftUI

/// One row of Today's grid: Small panels side by side, or one Wide or Tall panel.
struct TodayPanelRow: Identifiable, Equatable {
    let panels: [TodayPanelDescriptor]

    var id: String { panels.first?.id ?? "" }
    var takesRow: Bool { panels.count == 1 && panels[0].size.takesRow }
}

/// Packs panels into rows, keeping their order: Small panels fill a row up to `columns`; Wide and Tall
/// start a row of their own, so a Small one before them stays alone with the rest of its row empty.
enum TodayPanelPacking {
    static func rows(_ panels: [TodayPanelDescriptor], columns: Int = 2) -> [TodayPanelRow] {
        let columns = max(1, columns)
        var rows: [TodayPanelRow] = []
        var pending: [TodayPanelDescriptor] = []
        for panel in panels {
            if panel.size.takesRow {
                if !pending.isEmpty { rows.append(TodayPanelRow(panels: pending)); pending = [] }
                rows.append(TodayPanelRow(panels: [panel]))
            } else {
                pending.append(panel)
                if pending.count == columns { rows.append(TodayPanelRow(panels: pending)); pending = [] }
            }
        }
        if !pending.isEmpty { rows.append(TodayPanelRow(panels: pending)) }
        return rows
    }

    /// Two columns on a phone, more where the column is wide, one at accessibility text sizes.
    static func columns(width: CGFloat, isAccessibilitySize: Bool) -> Int {
        if isAccessibilitySize { return 1 }
        return max(2, min(4, Int(width / 260)))
    }
}

/// Today's panels on a grid. Each panel is drawn by the shell's factory; the grid gives it its
/// card, its size and the long-press menu (Resize, Hide, Delete).
struct TodayPanelGrid: View {
    /// Shown panels, in order, at the sizes the person chose (`TodayPanelLayoutStore.shown`).
    let panels: [TodayPanelDescriptor]
    let columns: Int
    let makePanel: (TodayPanelDescriptor) -> AnyView
    let layout: TodayPanelLayoutStore
    var onDelete: ((TodayPanelDescriptor) -> Void)?
    /// A panel's own rows in its long-press menu, before Hide (a Space's Open and Update now).
    var menuItems: ((TodayPanelDescriptor) -> AnyView)? = nil

    var body: some View {
        VStack(spacing: BighelpTokens.space12) {
            ForEach(TodayPanelPacking.rows(panels, columns: columns)) { row in
                if row.takesRow {
                    cell(row.panels[0])
                } else {
                    HStack(alignment: .top, spacing: BighelpTokens.space12) {
                        ForEach(row.panels) { cell($0) }
                        // A lone Small panel keeps its width; the rest of the row stays empty.
                        ForEach(row.panels.count..<max(columns, row.panels.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                                .accessibilityHidden(true)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func cell(_ panel: TodayPanelDescriptor) -> some View {
        TodayPanelCell(panel: panel, content: makePanel(panel), layout: layout, onDelete: onDelete, menuItems: menuItems)
    }
}

/// A panel's card and its long-press (right-click on the Mac) menu.
private struct TodayPanelCell: View {
    let panel: TodayPanelDescriptor
    let content: AnyView
    let layout: TodayPanelLayoutStore
    let onDelete: ((TodayPanelDescriptor) -> Void)?
    let menuItems: ((TodayPanelDescriptor) -> AnyView)?

    var body: some View {
        content
            .padding(BighelpTokens.space16)
            .frame(maxWidth: .infinity, minHeight: Self.minimumHeight(panel.size), maxHeight: .infinity,
                   alignment: .topLeading)
            .bighelpSurface(.card)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: BighelpTokens.cardCornerRadius,
                                                                style: .continuous))
            .contextMenu { TodayPanelMenu(panel: panel, layout: layout, onDelete: onDelete, menuItems: menuItems) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(panel.title)
            .accessibilityIdentifier("today.panel.\(panel.id)")
    }

    static func minimumHeight(_ size: TodayPanelSize) -> CGFloat {
        BighelpTokens.scaled(size == .tall ? 340 : 150)
    }
}

/// Resize, the panel's own rows, Hide and, for panels the shell can delete, Delete.
struct TodayPanelMenu: View {
    let panel: TodayPanelDescriptor
    let layout: TodayPanelLayoutStore
    let onDelete: ((TodayPanelDescriptor) -> Void)?
    var menuItems: ((TodayPanelDescriptor) -> AnyView)? = nil

    var body: some View {
        Menu {
            TodayPanelSizePicker(panel: panel, layout: layout)
                .pickerStyle(.inline)
        } label: {
            Label("Resize", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .accessibilityIdentifier("today.panel.resize")
        menuItems?(panel)
        Button("Hide from Today", systemImage: "eye.slash") { layout.setHidden(panel, true) }
            .accessibilityIdentifier("today.panel.hide")
        if panel.canDelete, let onDelete {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { onDelete(panel) }
                .accessibilityIdentifier("today.panel.delete")
        }
    }
}

/// Small, Wide or Tall; the pick sticks (`TodayPanelLayoutStore.setSize`).
struct TodayPanelSizePicker: View {
    let panel: TodayPanelDescriptor
    let layout: TodayPanelLayoutStore

    var body: some View {
        Picker("Size", selection: Binding(get: { layout.size(of: panel) },
                                          set: { layout.setSize($0, for: panel) })) {
            ForEach(TodayPanelSize.allCases, id: \.self) { size in
                Text(size.title).tag(size)
            }
        }
        .accessibilityIdentifier("today.panel.size.\(panel.id)")
    }
}

/// Edit Today: drag to order, a size for each panel, the eye to hide; hidden panels below with Show.
struct TodayPanelEditList: View {
    let panels: [TodayPanelDescriptor]
    let layout: TodayPanelLayoutStore

    var body: some View {
        let shown = layout.shown(panels)
        let hidden = layout.hiddenPanels(panels)
        List {
            Section("On Today") {
                ForEach(shown) { panel in
                    row(panel)
                }
                .onMove { layout.move(fromOffsets: $0, toOffset: $1, among: panels) }
            }
            if !hidden.isEmpty {
                Section("Hidden") {
                    ForEach(hidden) { panel in
                        hiddenRow(panel)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.edit.list")
    }

    private func row(_ panel: TodayPanelDescriptor) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.primaryText)
                // Its second line is its size, and picks it.
                TodayPanelSizePicker(panel: panel, layout: layout)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(theme.secondaryText)
                    .buttonStyle(.borderless)
            }
            Spacer(minLength: BighelpTokens.space8)
            Button {
                layout.setHidden(panel, true)
            } label: {
                Image(systemName: "eye")
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Hide \(panel.title)")
            .accessibilityIdentifier("today.edit.hide.\(panel.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.edit.row.\(panel.id)")
    }

    private func hiddenRow(_ panel: TodayPanelDescriptor) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Text(panel.title)
                .font(.bighelp(.body))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: BighelpTokens.space8)
            Button("Show") { layout.setHidden(panel, false) }
                .font(.bighelp(.body, weight: .semibold))
                .tint(theme.action)
                .buttonStyle(.borderless)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("today.edit.show.\(panel.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.edit.hidden.\(panel.id)")
    }

    @BighelpThemeReader private var theme
}
