import Foundation
import Observation
import SwiftUI
import UIKit

/// The shortcut names the person lets their agents run. iOS gives apps no list of the person's
/// shortcuts, so they type the exact names. Kept on this device, for every host.
@MainActor
@Observable
final class ShortcutNameStore {
    static let defaultsKey = "bighelp.device-tools.shortcuts.v1"
    static let maximumCount = 50
    static let maximumLength = 100

    /// The store the tool reads and Device access edits, set when the tool is made (it is given the
    /// app's `UserDefaults`). Until then, a store on the standard defaults.
    static var current = ShortcutNameStore(defaults: .standard)

    enum AddResult: Equatable {
        case added, empty, tooLong, invalid, duplicate, full
    }

    private(set) var names: [String]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persists: Bool

    /// `persists` is false in demo mode, whose changes last only for the launch.
    init(defaults: UserDefaults, persists: Bool = true) {
        self.defaults = defaults
        self.persists = persists
        names = persists ? Self.clean(defaults.stringArray(forKey: Self.defaultsKey) ?? []) : []
    }

    func contains(_ name: String) -> Bool { names.contains(name) }

    /// Names are exact (Shortcuts matches them as typed), so only spaces and new lines at the ends go.
    @discardableResult
    func add(_ raw: String) -> AddResult {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .empty }
        guard name.count <= Self.maximumLength else { return .tooLong }
        guard Self.isPlain(name) else { return .invalid }
        guard !names.contains(name) else { return .duplicate }
        guard names.count < Self.maximumCount else { return .full }
        names.append(name)
        save()
        return .added
    }

    func remove(_ name: String) {
        guard let index = names.firstIndex(of: name) else { return }
        names.remove(at: index)
        save()
    }

    private func save() {
        if persists { defaults.set(names, forKey: Self.defaultsKey) }
    }

    /// Whatever the file holds, only well-formed names come out, once each, at most 50.
    static func clean(_ stored: [String]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for name in stored where !name.isEmpty && name.count <= maximumLength && isPlain(name) && seen.insert(name).inserted {
            names.append(name)
            if names.count == maximumCount { break }
        }
        return names
    }

    /// No control characters (new lines, tabs, NUL): a name is one line the person could type.
    private static func isPlain(_ name: String) -> Bool {
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// `shortcuts.list` and `shortcuts.run`: the agent's `iphone_shortcuts` tool, which runs only the shortcuts the person picked.
///
/// `run` opens Shortcuts (`shortcuts://x-callback-url/run-shortcut`), which runs the shortcut and opens
/// bighelp again at one of three callback URLs. Apple documents the callback: `x-success` gets a `result`
/// parameter with the shortcut's text output, `x-error` gets `errorMessage`, `x-cancel` gets nothing
/// (support.apple.com/guide/shortcuts/apdcd7f20a6f). While the run is out, `DeviceToolHandoff` keeps the
/// call, the phone channel and the grants alive across bighelp leaving the screen.
@MainActor
final class DeviceShortcutsTool: DeviceCapabilityTool {
    enum Failure: String, DeviceToolFailure, Equatable {
        case invalidArguments = "invalid_arguments"
        /// The name is not one the person added (or they added none).
        case notAllowed = "not_allowed"
        case unsupportedOperation = "unsupported_operation"
        /// Another shortcut is still out.
        case busy = "device_busy"
        /// Nothing came back in time: the shortcut may or may not have run. Never run again blindly.
        case outcomeUnknown = "outcome_unknown"

        var code: String { rawValue }
    }

    typealias URLOpener = @MainActor (URL) async -> Bool

    static let maximumInputLength = 4000
    static let maximumOutputLength = 8000
    static let toolName = "shortcuts"

    /// Shortcuts' URL scheme with callbacks is Apple's for iOS, iPadOS and macOS. visionOS's Shortcuts
    /// is not documented to support it, so the tool says unavailable there.
    static var isSupported: Bool {
        #if os(visionOS)
        false
        #else
        true
        #endif
    }

    let capability = DeviceToolCapability.shortcuts
    private let store: ShortcutNameStore
    private let handoff: DeviceToolHandoff
    private let opener: URLOpener
    private let timeout: Duration

    init(store: ShortcutNameStore, handoff: DeviceToolHandoff = .shared, timeout: Duration = DeviceToolHandoff.deadline,
         opener: @escaping URLOpener = { await UIApplication.shared.open($0) }) {
        self.store = store
        self.handoff = handoff
        self.timeout = timeout
        self.opener = opener
    }

    static func live(_ environment: DeviceToolEnvironment) -> DeviceShortcutsTool {
        let store = ShortcutNameStore(defaults: environment.defaults, persists: !environment.usesFixtures)
        ShortcutNameStore.current = store
        return DeviceShortcutsTool(store: store)
    }

    // No iOS permission: the switch alone decides.
    func status() async -> DeviceToolSystemAccess { Self.isSupported ? .available : .unavailable }
    func request() async -> DeviceToolSystemAccess { Self.isSupported ? .available : .unavailable }

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        context: DeviceToolCallContext,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        guard Self.isSupported else { throw AppleDeviceToolError.unavailable }
        switch operation {
        case "shortcuts.list":
            guard arguments.isEmpty else { throw Failure.invalidArguments }
            try authorize()
            return ["shortcuts": .array(store.names.map { .object(["name": .string($0)]) })]
        case "shortcuts.run":
            return try await run(arguments, authorize: authorize)
        default:
            throw Failure.unsupportedOperation
        }
    }

    private func run(
        _ arguments: [String: BighelpJSONValue], authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        // Check everything first, so a refused request opens nothing.
        guard Set(arguments.keys).isSubset(of: ["name", "input"]),
              let name = arguments["name"]?.string, !name.isEmpty, name.count <= ShortcutNameStore.maximumLength
        else { throw Failure.invalidArguments }
        var input: String?
        if let value = arguments["input"] {
            guard let text = value.string, text.count <= Self.maximumInputLength else { throw Failure.invalidArguments }
            input = text.isEmpty ? nil : text
        }
        guard store.contains(name) else { throw Failure.notAllowed }

        let runID = UUID()
        guard let url = Self.runURL(name: name, input: input, runID: runID) else { throw Failure.invalidArguments }
        // The last look before bighelp leaves for Shortcuts.
        try authorize()
        let opener = opener
        let outcome = await handoff.perform(
            tool: Self.toolName, runID: runID, timeout: timeout,
            isStillWanted: { (try? authorize()) != nil },
            open: { await opener(url) })
        // Back, or given up: the call may only deliver while it is still wanted. A refusal here
        // means nothing will use the return grace, so it ends now.
        do { try authorize() } catch {
            handoff.endReturnGrace()
            throw error
        }
        let id = runID.uuidString.lowercased()
        switch outcome {
        case .callback(let callback):
            switch callback.kind {
            case .success:
                return Self.payload(id: id, status: "completed", text: callback.parameters["result"])
            case .cancel:
                return Self.payload(id: id, status: "cancelled", text: nil)
            case .error:
                // Shortcuts' own words for what went wrong.
                return Self.payload(id: id, status: "failed", text: callback.parameters["errorMessage"])
            }
        case .notOpened:
            throw AppleDeviceToolError.unavailable
        case .busy:
            throw Failure.busy
        case .timedOut, .retired:
            throw Failure.outcomeUnknown
        }
    }

    /// `{id, status, output, truncated}`. The output is cleaned of control characters other than new
    /// lines and tabs, and cut at 8000 characters. It is the agent's alone: the journal never keeps it.
    static func payload(id: String, status: String, text: String?) -> [String: BighelpJSONValue] {
        let clean = String(String.UnicodeScalarView((text ?? "").unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }))
        let truncated = clean.count > maximumOutputLength
        return [
            "id": .string(id),
            "status": .string(status),
            "output": .string(truncated ? String(clean.prefix(maximumOutputLength)) : clean),
            "truncated": .boolean(truncated),
        ]
    }

    /// `shortcuts://x-callback-url/run-shortcut?name=…&input=text&text=…&x-success=…&x-cancel=…&x-error=…`
    /// Every value is percent-encoded to unreserved characters, so a name or text with `&`, `=`, `+`
    /// or `#` stays one value.
    static func runURL(name: String, input: String?, runID: UUID) -> URL? {
        var pairs: [(String, String)] = [("name", name)]
        if let input { pairs += [("input", "text"), ("text", input)] }
        for (key, kind) in [("x-success", DeviceToolHandoff.CallbackKind.success),
                            ("x-cancel", .cancel), ("x-error", .error)] {
            guard let callback = DeviceToolHandoff.callbackURL(tool: toolName, kind: kind, runID: runID) else { return nil }
            pairs.append((key, callback.absoluteString))
        }
        let query = pairs.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: "shortcuts://x-callback-url/run-shortcut?" + query)
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// What Device access shows under the shortcuts switch: the names the person lets agents run.
@MainActor
struct ShortcutsPermissionExtras: View {
    let permissions: DeviceToolPermissions
    @State private var store = ShortcutNameStore.current
    @State private var isEditing = false
    @BighelpThemeReader private var theme

    var body: some View {
        if DeviceShortcutsTool.isSupported {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Button { isEditing = true } label: {
                    HStack {
                        Text("Shortcuts your agent can run").bighelpFont(.body)
                        Spacer(minLength: BighelpTokens.space8)
                        Text(store.names.isEmpty ? String(localized: "None") : "\(store.names.count)")
                            .bighelpFont(.metadata).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.bighelp(.footnote, weight: .semibold))
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("permissions.device-tools.shortcuts.names")
                Text("To run one, bighelp opens Shortcuts, then comes back when it is done. Your agent can only run the shortcuts you add here.")
                    .bighelpFont(.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .bighelpSheet(isPresented: $isEditing) { ShortcutNamesEditor(store: store) }
        }
    }
}

/// Adds and removes the exact names of the shortcuts agents may run.
@MainActor
private struct ShortcutNamesEditor: View {
    let store: ShortcutNameStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var message: String?
    @FocusState private var isFieldFocused: Bool
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Shortcut name", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFieldFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .accessibilityIdentifier("shortcuts.names.field")
                    Button("Add", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("shortcuts.names.add")
                    if let message {
                        Text(message).bighelpFont(.metadata).foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Add a shortcut")
                } footer: {
                    Text("Type the name exactly as it is in the Shortcuts app. You can add up to \(ShortcutNameStore.maximumCount).")
                        .bighelpFont(.metadata)
                }
                .listRowBackground(theme.surface)

                Section {
                    if store.names.isEmpty {
                        Text("No shortcuts yet. Your agent can run none.").foregroundStyle(.secondary)
                    }
                    ForEach(store.names, id: \.self) { name in
                        HStack {
                            Text(name).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: BighelpTokens.space8)
                            Button {
                                store.remove(name)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(theme.danger)
                                    .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(name)")
                        }
                    }
                } header: {
                    Text("Your agent can run")
                }
                .listRowBackground(theme.surface)
            }
            .bighelpFormSurface()
            .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .accessibilityIdentifier("shortcuts.names.editor")
        }
        .bighelpSheetSize(.standard)
    }

    private func add() {
        switch store.add(draft) {
        case .added: draft = ""; message = nil; isFieldFocused = true
        case .empty: message = nil
        case .tooLong: message = String(localized: "That name is too long.")
        case .invalid: message = String(localized: "Use a name on one line.")
        case .duplicate: message = String(localized: "That shortcut is already in the list.")
        case .full: message = String(localized: "The list is full. Remove one to add another.")
        }
    }
}
