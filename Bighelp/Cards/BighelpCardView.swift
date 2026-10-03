import SwiftUI

struct BighelpCardDesignTokens {
    static let spacing: CGFloat = 12
    static let compactSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 18
}

private struct BighelpCardDataClientEnvironmentKey: EnvironmentKey {
    static let defaultValue: any BighelpCardDataFetching = BighelpCardStaticDataClient()
}

extension EnvironmentValues {
    var bighelpCardDataClient: any BighelpCardDataFetching {
        get { self[BighelpCardDataClientEnvironmentKey.self] }
        set { self[BighelpCardDataClientEnvironmentKey.self] = newValue }
    }
}

/// Delivered cards are embedded, validated values, not refreshable resources.
/// The data-client environment above remains a compatibility contract for hosts;
/// this shipping view deliberately never reads it or starts a data client.
struct BighelpCardView: View {
    let card: BighelpCardDocument
    private let renderer: BighelpCardRenderer
    private let background: CardBackground?
    @State private var updatedAt: Date?
    @Environment(\.scenePhase) private var scenePhase

    init(card: BighelpCardDocument) {
        self.card = card
        renderer = BighelpCardRenderer(card: card)
        background = renderer.isValid ? CardBackground.of(card) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpCardDesignTokens.spacing) {
            renderer
            HStack(spacing: 6) {
                Image(systemName: statusSymbol)
                Text(statusText)
                Spacer(minLength: 8)
            }
            .font(.bighelp(.caption))
            .foregroundStyle(.secondary)
        }
        .padding()
        .modifier(BighelpCardSurface(background: background))
        .clipShape(RoundedRectangle(cornerRadius: BighelpCardDesignTokens.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpCardDesignTokens.cornerRadius)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.spokenSummary)
        .task { updatedAt = Date() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { updatedAt = Date() }
        }
    }

    private var statusText: String {
        guard renderer.isValid else { return "Unavailable" }
        guard let updatedAt else { return "Waiting to update" }
        return "Updated \(updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var statusSymbol: String {
        guard renderer.isValid else { return "exclamationmark.triangle.fill" }
        return updatedAt == nil
            ? "arrow.trianglehead.2.clockwise.rotate.90"
            : "checkmark.circle.fill"
    }
}

/// The card's usual surface, or its weather. Over weather the content is drawn
/// in the dark color scheme (white text); the scrim keeps that readable.
private struct BighelpCardSurface: ViewModifier {
    let background: CardBackground?

    func body(content: Content) -> some View {
        if let background {
            content
                .environment(\.colorScheme, .dark)
                .modifier(CardBackgroundInk())
                .background { CardBackgroundView(background: background) }
        } else {
            content.background(Color(uiColor: .secondarySystemBackground))
        }
    }
}

/// Vision Pro gives the whole app one fixed ink, dark in a light window. Over
/// weather the card's text is white with grey secondary text, as on iPhone.
private struct CardBackgroundInk: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
        content.foregroundStyle(Color.white, Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.6))
        #else
        content
        #endif
    }
}

struct BighelpCardRenderer: View {
    static let supportedTypes = BighelpCardValidator.supportedElementTypes

    let card: BighelpCardDocument
    let isValid: Bool

    init(card: BighelpCardDocument) {
        self.card = card
        isValid = (try? BighelpCardValidator.validateForStaticRelease(card)) != nil
    }

    var body: some View {
        if isValid {
            render(card.root)
        } else {
            unavailable("Invalid or unsupported card")
        }
    }

    private func render(
        _ id: String,
        item: BighelpJSONValue? = nil,
        itemSourceID: String? = nil
    ) -> AnyView {
        guard let node = card.elements[id]?.object,
              let type = node["type"]?.string,
              let props = node["props"]?.object,
              let children = node["children"]?.array?.compactMap(\.string) else {
            return AnyView(unavailable("Invalid card element"))
        }

        switch type {
        case "card":
            return AnyView(VStack(alignment: .leading, spacing: BighelpCardDesignTokens.spacing) {
                if let title = text(props["title"], item: item, itemSourceID: itemSourceID) {
                    Text(title).font(.bighelp(.headline))
                }
                if let subtitle = text(props["subtitle"], item: item, itemSourceID: itemSourceID) {
                    Text(subtitle).font(.bighelp(.subheadline)).foregroundStyle(.secondary)
                }
                renderChildren(children, item: item, itemSourceID: itemSourceID)
            })
        case "vstack":
            return AnyView(VStack(alignment: .leading, spacing: spacing(props["spacing"])) {
                renderChildren(children, item: item, itemSourceID: itemSourceID)
            })
        case "hstack":
            return AnyView(HStack(alignment: .center, spacing: spacing(props["spacing"])) {
                renderChildren(children, item: item, itemSourceID: itemSourceID)
            })
        case "grid":
            let count = max(1, min(props["columns"]?.integer ?? 2, 3))
            return AnyView(LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: count),
                alignment: .leading,
                spacing: spacing(props["spacing"])
            ) {
                renderChildren(children, item: item, itemSourceID: itemSourceID)
            })
        case "text":
            let value = text(props["value"], item: item, itemSourceID: itemSourceID) ?? "Unavailable"
            return AnyView(Text(value)
                .font(textFont(props["typography"]?.string))
                .foregroundStyle(semanticColor(props["color"]?.string))
                .lineLimit(props["line_limit"]?.integer))
        case "metric":
            let label = text(props["label"], item: item, itemSourceID: itemSourceID) ?? "Value"
            let value = resolved(props["value"], item: item, itemSourceID: itemSourceID)
            return AnyView(VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.bighelp(.caption)).foregroundStyle(.secondary)
                Text(format(value, specification: props["format"]))
                    .font(.bighelp(.title3).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(semanticColor(props["semantic"]?.string))
            }.frame(maxWidth: .infinity, alignment: .leading))
        case "badge":
            let value = format(resolved(props["value"], item: item, itemSourceID: itemSourceID), specification: nil)
            let color = semanticColor(props["semantic"]?.string)
            return AnyView(Text(value)
                .font(.bighelp(.caption).weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.12), in: Capsule()))
        case "progress":
            let value = number(resolved(props["value"], item: item, itemSourceID: itemSourceID)) ?? 0
            let maximum = max(number(resolved(props["maximum"], item: item, itemSourceID: itemSourceID)) ?? 1, 0.000_001)
            let label = text(props["label"], item: item, itemSourceID: itemSourceID) ?? "Progress"
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label).font(.bighelp(.caption)).foregroundStyle(.secondary)
                    Spacer()
                    Text(format(.number(value), specification: props["format"])).font(.bighelp(.caption)).monospacedDigit()
                }
                ProgressView(value: min(max(value, 0), maximum), total: maximum)
                    .tint(semanticColor(props["semantic"]?.string))
            })
        case "chart":
            let values = (props["series"]?.array ?? []).prefix(6).flatMap { series -> [Double] in
                (series.object?["points"]?.array ?? []).prefix(120).compactMap { point in
                    number(resolved(point.object?["y"], item: item, itemSourceID: itemSourceID))
                }
            }
            return AnyView(BighelpCardMiniChart(
                values: values,
                color: semanticColor(props["series"]?.array?.first?.object?["semantic"]?.string)
            ).accessibilityLabel(props["description"]?.string ?? "Chart"))
        case "table":
            return AnyView(renderTable(props: props, children: children, item: item, itemSourceID: itemSourceID))
        case "list":
            return AnyView(renderList(props: props, children: children, itemSourceID: itemSourceID))
        case "divider":
            return AnyView(Divider())
        case "spacer":
            return AnyView(Spacer(minLength: spacing(props["size"])))
        case "image":
            let name = props["name"]?.string ?? "photo"
            let label = props["accessibility_label"]?.string ?? "Image"
            return AnyView(Image(systemName: name)
                .font(.bighelp(.title2))
                .foregroundStyle(semanticColor(props["semantic"]?.string))
                .accessibilityLabel(label))
        default:
            return AnyView(unavailable("Unsupported card element"))
        }
    }

    private func renderChildren(
        _ children: [String],
        item: BighelpJSONValue?,
        itemSourceID: String?
    ) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            render(child, item: item, itemSourceID: itemSourceID)
        }
    }

    private func renderList(
        props: [String: BighelpJSONValue],
        children: [String],
        itemSourceID: String?
    ) -> some View {
        let bindingSource = props["items"]?.object?["source"]?.string
        let items = Array((resolved(props["items"], item: nil, itemSourceID: itemSourceID)?.array ?? []).prefix(50))
        return VStack(alignment: .leading, spacing: BighelpCardDesignTokens.compactSpacing) {
            if items.isEmpty {
                Text(props["empty_text"]?.string ?? "No items available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, listItem in
                    renderChildren(children, item: listItem, itemSourceID: bindingSource)
                    if props["shows_dividers"]?.boolean == true, index < items.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func renderTable(
        props: [String: BighelpJSONValue],
        children: [String],
        item: BighelpJSONValue?,
        itemSourceID: String?
    ) -> some View {
        let columns = Array((props["columns"]?.array ?? []).prefix(8))
        let rows = Array((props["rows"]?.array ?? []).prefix(50))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Text(column.object?["label"]?.string ?? "Column")
                        .font(.bighelp(.caption).weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ForEach(Array((row.object?["cells"]?.array ?? []).prefix(columns.count).enumerated()), id: \.offset) { index, cell in
                        Text(format(
                            resolved(cell, item: item, itemSourceID: itemSourceID),
                            specification: index < columns.count ? columns[index].object?["format"] : nil
                        ))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func resolved(
        _ specification: BighelpJSONValue?,
        item: BighelpJSONValue?,
        itemSourceID: String?
    ) -> BighelpJSONValue? {
        guard let specification else { return nil }
        guard case .value(let value) = BighelpCardValueResolver.resolve(
            specification,
            sources: [:],
            item: item,
            itemSourceID: itemSourceID
        ) else { return nil }
        return value
    }

    private func text(
        _ specification: BighelpJSONValue?,
        item: BighelpJSONValue?,
        itemSourceID: String?
    ) -> String? {
        guard let value = resolved(specification, item: item, itemSourceID: itemSourceID) else { return nil }
        return format(value, specification: nil)
    }

    private func format(_ value: BighelpJSONValue?, specification: BighelpJSONValue?) -> String {
        guard let value else { return "Unavailable" }
        let format = specification?.object
        let style = format?["style"]?.string
        if let number = number(value) {
            let minimumDigits = max(0, min(format?["minimum_fraction_digits"]?.integer ?? 0, 6))
            let maximumDigits = max(minimumDigits, min(format?["maximum_fraction_digits"]?.integer ?? 2, 6))
            switch style {
            case "currency":
                return number.formatted(
                    .currency(code: format?["currency"]?.string ?? "USD")
                        .precision(.fractionLength(minimumDigits...maximumDigits))
                )
            case "percent":
                return (number / 100).formatted(
                    .percent.precision(.fractionLength(minimumDigits...maximumDigits))
                )
            case "integer":
                return number.formatted(.number.precision(.fractionLength(0)))
            default:
                return number.formatted(.number.precision(.fractionLength(minimumDigits...maximumDigits)))
            }
        }
        return String((value.displayText ?? "").prefix(2_000))
    }

    private func number(_ value: BighelpJSONValue?) -> Double? {
        switch value {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }

    private func spacing(_ value: BighelpJSONValue?) -> CGFloat {
        switch value?.string {
        case "none": 0
        case "small": 8
        case "large": 16
        default: 12
        }
    }

    private func textFont(_ token: String?) -> Font {
        switch token {
        case "caption": .caption
        case "headline": .headline
        case "title": .title3
        default: .body
        }
    }

    private func semanticColor(_ token: String?) -> Color {
        switch token {
        case "positive": .green
        case "warning": .orange
        case "negative": .red
        case "accent": .accentColor
        case "secondary": .secondary
        default: .primary
        }
    }

    private func unavailable(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.bighelp(.caption))
            .foregroundStyle(.secondary)
    }
}

private struct BighelpCardMiniChart: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(values.max() ?? 1, 0.000_001)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.prefix(24).enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(height: max(2, geometry.size.height * max(0, value) / maximum))
                }
            }
        }
        .frame(minHeight: 72)
        .accessibilityLabel("Chart with \(values.count) values")
    }
}
