import SwiftUI

/// An active Blueprint with `[placeholder]` blanks being filled inline inside `ChatComposer`.
/// Keeps `ChatComposer.==` untouched so ordinary chats pay zero redraw cost.
struct ChatBlueprintDraft: Equatable {
    enum Token: Identifiable, Equatable {
        case word(id: Int, text: String)
        case blank(BlueprintAdLib.Blank, prefix: String, suffix: String)

        var id: String {
            switch self {
            case .word(let id, _): "w.\(id)"
            case .blank(let blank, _, _): "b.\(blank.id)"
            }
        }
    }

    let source: String
    let adLib: BlueprintAdLib
    private(set) var values: [Int: String]
    var activeBlankID: Int
    let tokens: [Token]

    init?(source: String) {
        let adLib = BlueprintAdLib(source)
        guard !adLib.blanks.isEmpty else { return nil }
        self.source = source
        self.adLib = adLib
        let initial = adLib.initialValues
        self.values = initial
        self.activeBlankID = adLib.blanks.first {
            (initial[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.id ?? adLib.blanks[0].id
        self.tokens = Self.tokenize(adLib: adLib)
    }

    var blanks: [BlueprintAdLib.Blank] { adLib.blanks }

    var activeBlank: BlueprintAdLib.Blank {
        adLib.blanks.first { $0.id == activeBlankID } ?? adLib.blanks[0]
    }

    var activeIndex: Int {
        adLib.blanks.firstIndex { $0.id == activeBlankID } ?? 0
    }

    var isComplete: Bool { adLib.isComplete(values) }

    var filledText: String { adLib.filled(values) }

    func value(for blankID: Int) -> String {
        values[blankID] ?? ""
    }

    func hasValue(for blankID: Int) -> Bool {
        BlueprintAdLib.value(values[blankID]) != nil
    }

    mutating func setValue(_ raw: String, for blankID: Int) {
        let bounded = String(raw.replacingOccurrences(of: "\n", with: " ").prefix(200))
        values[blankID] = bounded
    }

    mutating func advanceToNextBlank(preferringUnfilled: Bool = false) {
        guard blanks.count > 1 else { return }
        let start = activeIndex
        if preferringUnfilled {
            for offset in 1...blanks.count {
                let candidate = blanks[(start + offset) % blanks.count]
                if !hasValue(for: candidate.id) {
                    activeBlankID = candidate.id
                    return
                }
            }
        }
        activeBlankID = blanks[(start + 1) % blanks.count].id
    }

    static func suggestions(for blank: BlueprintAdLib.Blank) -> [String] {
        if blank.isChoice { return blank.options }
        if blank.isNumber {
            var seen = Set<String>()
            let numbers = [blank.hint, "3", "5", "10", "20"].filter {
                !$0.isEmpty && seen.insert($0).inserted
            }
            return Array(numbers.prefix(4))
        }
        let lower = blank.hint.lowercased()
        if lower.contains("brand") || lower.contains("product") || lower.contains("company") {
            return ["bighelp", "Hermes Agent", "My product"]
        }
        if lower.contains("competitor") {
            return ["Linear", "Cursor", "Notion"]
        }
        if lower.contains("website") {
            return ["bighelp.app", "example.com", "docs site"]
        }
        if lower.contains("channel") {
            return ["YouTube", "Newsletter", "Tech blog"]
        }
        if lower.contains("niche") || lower.contains("industry") {
            return ["AI & dev tools", "iOS apps", "Product design"]
        }
        if lower.contains("city") || lower.contains("location") {
            return ["Austin", "San Francisco", "New York"]
        }
        if lower.contains("stock") || lower.contains("ticker") {
            return ["AAPL, NVDA, MSFT", "Semiconductors", "S&P 500 leaders"]
        }
        if lower.contains("topic") || lower.contains("subject") {
            return ["Swift 6", "On-device AI", "Agent workflows"]
        }
        if lower.contains("name") {
            return ["Alex", "Sam", "Jordan"]
        }
        if lower.contains("date") {
            return ["next Friday", "May 15", "in two weeks"]
        }
        if lower.contains("monday") || lower.contains("morning") || lower.contains("am")
            || lower.contains("pm") || lower.contains("time") {
            return ["Monday 8am", "Weekday 7:30am", "Friday 4pm"]
        }
        return []
    }

    /// Breaks prose around blanks into word chunks while attaching adjacent punctuation
    /// (`$`, `'s`, `.`, `,`) directly to its blank so chips never leave stray gaps like `Feed .`.
    private static func tokenize(adLib: BlueprintAdLib) -> [Token] {
        let prefixes: Set<Character> = ["$", "£", "€", "#", "@", "“", "\""]
        let suffixes = [",", ".", "!", "?", ";", ":", "'s", "’s", "”", "\""]

        var strings = Array(repeating: "", count: adLib.pieces.count)
        for (index, piece) in adLib.pieces.enumerated() {
            if case .text(let text) = piece { strings[index] = text }
        }

        var blankAffixes: [Int: (prefix: String, suffix: String)] = [:]
        for (index, piece) in adLib.pieces.enumerated() {
            guard case .blank(let blankID) = piece else { continue }
            var prefix = ""
            if index > 0, let last = strings[index - 1].last, prefixes.contains(last) {
                let beforeLast = strings[index - 1].dropLast()
                if beforeLast.isEmpty || beforeLast.last?.isWhitespace == true {
                    prefix = String(last)
                    strings[index - 1] = String(beforeLast)
                }
            }
            var suffix = ""
            if index + 1 < strings.count {
                let next = strings[index + 1]
                for candidate in suffixes.sorted(by: { $0.count > $1.count }) where next.hasPrefix(candidate) {
                    let remainder = next.dropFirst(candidate.count)
                    if remainder.isEmpty || remainder.first?.isWhitespace == true {
                        suffix = candidate
                        strings[index + 1] = String(remainder)
                        break
                    }
                }
            }
            blankAffixes[blankID] = (prefix, suffix)
        }

        var result: [Token] = []
        var wordCounter = 0
        for (index, piece) in adLib.pieces.enumerated() {
            switch piece {
            case .text:
                for word in strings[index].split(whereSeparator: \.isWhitespace) {
                    result.append(.word(id: wordCounter, text: String(word)))
                    wordCounter += 1
                }
            case .blank(let id):
                let blank = adLib.blanks[id]
                let affix = blankAffixes[id] ?? ("", "")
                result.append(.blank(blank, prefix: affix.prefix, suffix: affix.suffix))
            }
        }
        return result
    }
}

/// Quick-fill rail above `ChatComposer` when a Blueprint with `[blanks]` is active (`2B`).
struct ComposerBlueprintTray: View, Equatable {
    let model: ChatModel
    let onSwitchToPlainText: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
    }

    @BighelpThemeReader private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isCustomFieldFocused: Bool

    var body: some View {
        if let draft = model.blueprintDraft {
            let blank = draft.activeBlank
            let presets = ChatBlueprintDraft.suggestions(for: blank)
            let currentValue = draft.value(for: blank.id)
            let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)

            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                HStack(spacing: BighelpTokens.space8) {
                    Text("Blank \(draft.activeIndex + 1) of \(draft.blanks.count) · \(blank.hint)")
                        .font(.bighelp(.caption, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    Spacer(minLength: BighelpTokens.space4)

                    if draft.blanks.count > 1 {
                        Button {
                            BighelpHaptics.tap()
                            model.advanceBlueprintBlank()
                        } label: {
                            HStack(spacing: 3) {
                                Text("Next blank")
                                Image(systemName: "arrow.right")
                                    .font(.bighelp(.caption2, weight: .bold))
                            }
                            .font(.bighelp(.caption, weight: .semibold))
                            .foregroundStyle(theme.action)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(.rect)
                        }
                        .bighelpPlainButtonStyle()
                        .accessibilityIdentifier("chat.blueprint.next")
                    }

                    Button {
                        isCustomFieldFocused = false
                        onSwitchToPlainText()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.bighelp(.caption, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(theme.secondaryText.opacity(0.12), in: .circle)
                            .contentShape(.circle)
                    }
                    .bighelpPlainButtonStyle(.circle)
                    .bighelpIconLabel("Edit full message text")
                    .accessibilityIdentifier("chat.blueprint.plain-text")
                }

                if !presets.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(presets, id: \.self) { preset in
                                let isSelected = currentValue == preset
                                Button {
                                    BighelpHaptics.tap()
                                    model.pickBlueprintSuggestion(preset, for: blank.id)
                                } label: {
                                    Text(preset)
                                        .font(.bighelp(.caption, weight: .semibold))
                                        .foregroundStyle(isSelected ? theme.actionForeground : theme.primaryText)
                                        .padding(.horizontal, BighelpTokens.space12)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule().fill(isSelected ? theme.action : theme.canvas)
                                        )
                                        .overlay {
                                            if !isSelected {
                                                Capsule().strokeBorder(
                                                    contrast == .increased ? theme.primaryText : theme.border,
                                                    lineWidth: BighelpTokens.hairline
                                                )
                                            }
                                        }
                                        .contentShape(Capsule())
                                }
                                .bighelpPlainButtonStyle(.capsule)
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                                .accessibilityIdentifier("chat.blueprint.preset.\(preset)")
                            }
                        }
                    }
                }

                if !blank.isChoice {
                    HStack(spacing: BighelpTokens.space8) {
                        Image(systemName: "character.cursor.ibeam")
                            .font(.bighelp(.caption2, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .accessibilityHidden(true)
                        TextField(
                            blank.hint,
                            text: Binding(
                                get: { model.blueprintDraft?.value(for: blank.id) ?? "" },
                                set: { model.updateBlueprintBlank(blank.id, value: $0) }
                            ),
                            prompt: Text("Type \(blank.hint)…").bighelpFieldHint(theme)
                        )
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.primaryText)
                        .focused($isCustomFieldFocused)
                        .keyboardType(blank.isNumber ? .numbersAndPunctuation : .default)
                        .submitLabel(draft.blanks.count > 1 ? .next : .done)
                        .onSubmit {
                            if draft.blanks.count > 1 {
                                model.advanceBlueprintBlank(preferringUnfilled: true)
                            } else {
                                isCustomFieldFocused = false
                            }
                        }
                        .bighelpMacField()
                        .accessibilityIdentifier("chat.blueprint.input")

                        if !currentValue.isEmpty {
                            Button {
                                model.updateBlueprintBlank(blank.id, value: "")
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.bighelp(.footnote))
                                    .foregroundStyle(theme.tertiaryText)
                            }
                            .bighelpPlainButtonStyle(.circle)
                            .accessibilityLabel("Clear blank")
                        }
                    }
                    .padding(.horizontal, BighelpTokens.space12)
                    .padding(.vertical, 7)
                    .background(theme.canvas, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(theme.border, lineWidth: BighelpTokens.hairline)
                    }
                }
            }
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, BighelpTokens.space8 + 2)
            .background(shape.fill(theme.surface))
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? theme.primaryText : theme.border,
                    lineWidth: contrast == .increased ? 1.5 : BighelpTokens.hairline
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.blueprint.tray")
        }
    }
}

/// Hides the plain text editor without unmounting it while `blueprintDraft` chips are active.
struct BlueprintHiddenEditorModifier: ViewModifier {
    let model: ChatModel

    func body(content: Content) -> some View {
        let isActive = model.blueprintDraft != nil
        content
            .opacity(isActive ? 0 : 1)
            .allowsHitTesting(!isActive)
            .accessibilityHidden(isActive)
            .frame(height: isActive ? 0 : nil)
    }
}

/// Flowing inline sentence with tappable dashed (`+ my brand`) and filled (`Feed`) chips inside `ChatComposer`.
struct ComposerBlueprintChipField: View, Equatable {
    let model: ChatModel
    let onEditPlainText: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
    }

    @BighelpThemeReader private var theme

    var body: some View {
        if let draft = model.blueprintDraft {
            BighelpFlowLayout(spacing: 4, lineSpacing: 6) {
                ForEach(draft.tokens) { token in
                    switch token {
                    case .word(_, let text):
                        Text(text)
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.primaryText)
                            .padding(.vertical, 2)
                            .onTapGesture(perform: onEditPlainText)
                    case .blank(let blank, let prefix, let suffix):
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            if !prefix.isEmpty {
                                Text(prefix)
                                    .font(.bighelp(.body))
                                    .foregroundStyle(theme.primaryText)
                            }
                            BlueprintInlineChip(
                                hint: blank.hint,
                                value: BlueprintAdLib.value(draft.value(for: blank.id)),
                                isFocused: draft.activeBlankID == blank.id
                            ) {
                                BighelpHaptics.tap()
                                model.focusBlueprintBlank(blank.id)
                            }
                            .accessibilityIdentifier("chat.blueprint.chip.\(blank.id)")
                            if !suffix.isEmpty {
                                Text(suffix)
                                    .font(.bighelp(.body))
                                    .foregroundStyle(theme.primaryText)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.blueprint.sentence")
        }
    }
}

private struct BlueprintInlineChip: View {
    let hint: String
    let value: String?
    let isFocused: Bool
    let action: () -> Void

    @BighelpThemeReader private var theme

    var body: some View {
        let isFilled = value != nil
        Button(action: action) {
            HStack(spacing: 3) {
                if !isFilled {
                    Image(systemName: "plus")
                        .font(.bighelp(.caption2, weight: .bold))
                }
                Text(value ?? hint)
                    .font(.bighelp(.subheadline, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(isFilled ? theme.primaryText : theme.action)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(theme.action.opacity(isFilled ? (theme.isDarkPalette ? 0.24 : 0.16) : 0.12))
            )
            .overlay {
                if isFilled {
                    Capsule().strokeBorder(theme.action.opacity(isFocused ? 0.95 : 0.55), lineWidth: isFocused ? 2 : 1.25)
                } else {
                    Capsule().strokeBorder(
                        theme.action,
                        style: StrokeStyle(lineWidth: isFocused ? 1.75 : 1.25, dash: [4, 3])
                    )
                }
            }
            .shadow(color: isFocused ? theme.action.opacity(0.28) : .clear, radius: 3)
            .contentShape(Capsule())
        }
        .bighelpPlainButtonStyle(.capsule)
        .accessibilityLabel(value.map { "\(hint): \($0)" } ?? "Blank: \(hint)")
        .accessibilityHint("Tap to fill in \(hint)")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }
}
