import Foundation
import Observation

/// The stores that keep the Bots view's choices on this phone.
@MainActor
struct BotsAppStateStores {
    let order: SimpleBotsOrderStore
    let fleet: FleetStore?
    let primary: () -> String?
    let setPrimary: (String?) -> Void
    let voices: AgentVoiceChoices
    let marks: SimpleBotMarkStore
    let pets: PetAvatarStore
    let companions: CompanionStore
    /// Puts a pet chosen on another device on an agent (`PetAvatarStore.restore`).
    let restorePet: (_ slug: String, _ agentKey: String) -> Void
    /// A sign-in's pins and primary bot: the live store's for the gateway in use, else what its settings keep.
    let pins: (_ scope: String) -> AgentDirectoryStore.SavedPins
    let setPins: (_ pins: AgentDirectoryStore.SavedPins, _ scope: String) -> Void

    func read(scopes: [String]) -> BotsPhoneState {
        BotsPhoneState(orders: order.orders, sections: fleet?.sections ?? [], groupSections: fleet?.groupSectionIDs ?? [:],
                       pinnedGroups: fleet?.pinnedGroupIDs ?? [], hiddenGroups: fleet?.hiddenGroupIDs ?? [],
                       primary: primary(), voices: voices.all, marks: marks.marks,
                       pets: pets.assignments.merging(pets.wanted) { _, wanted in wanted },
                       characters: companions.agentOverrides,
                       pins: Dictionary(scopes.map { ($0, pins($0)) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Writes only what changed, so a store and the screens reading it hear nothing about the rest.
    func write(_ next: BotsPhoneState, over old: BotsPhoneState) {
        if next.orders != old.orders {
            for scope in Set(next.orders.keys).union(old.orders.keys) where next.orders[scope] != old.orders[scope] {
                order.set(next.orders[scope] ?? [], scope: scope)
            }
        }
        if let fleet, next.sections != old.sections || next.groupSections != old.groupSections
            || next.pinnedGroups != old.pinnedGroups || next.hiddenGroups != old.hiddenGroups {
            fleet.sections = next.sections
            fleet.groupSectionIDs = next.groupSections
            fleet.pinnedGroupIDs = next.pinnedGroups
            fleet.hiddenGroupIDs = next.hiddenGroups
            fleet.saveSections()
        }
        if next.primary != old.primary { setPrimary(next.primary) }
        if next.voices != old.voices { voices.replaceAll(next.voices) }
        if next.marks != old.marks { marks.replaceAll(next.marks) }
        for key in Set(next.pets.keys).union(old.pets.keys) where next.pets[key] != old.pets[key] {
            if let slug = next.pets[key] { restorePet(slug, key) } else { pets.remove(key) }
        }
        for key in Set(next.characters.keys).union(old.characters.keys) where next.characters[key] != old.characters[key] {
            companions.setOverride(next.characters[key], for: key)
        }
        for (scope, saved) in next.pins where old.pins[scope] != saved { setPins(saved, scope) }
    }
}

/// Keeps the Bots view's choices (the order of the home, sections, the primary bot and each bot's
/// voice, mark, pet and character) on the person's computers, and the newest of them on this phone.
/// A change in any of those stores becomes patches (`BotsAppState` shapes) and goes to every
/// computer reached; each sync reads them all and puts the newest on this phone. The stores stay
/// the source the screens read, so the home never waits for a computer, and a computer without the
/// feature keeps working as before: its choices stay on this phone.
@MainActor
@Observable
final class BotsAppStateSync {
    /// Set up by the app (`BighelpApp`).
    static let shared = BotsAppStateSync()

    /// Sign-ins (`cacheScopeID`) on computers whose plugin can't keep these choices: there they stay
    /// on this phone only, and Rearrange says to update the plugin.
    private(set) var phoneOnlyScopes: Set<String> = []

    /// Every host set up on this phone.
    @ObservationIgnored var hosts: @MainActor () -> [BotsAppStateHost] = { [] }
    /// The computers reached now: the gateway in use, and the others kept connected.
    @ObservationIgnored var computers: @MainActor () -> [AppStateComputer] = { [] }

    let engine: AppStateSync
    /// Demo mode's computer has a store of its own, kept for the run only, so its made-up bots never
    /// reach a real computer's values (real-host tests add a real computer to the demo).
    let demoEngine: AppStateSync
    @ObservationIgnored var usesDemo: @MainActor () -> Bool = { false }
    private var current: AppStateSync { usesDemo() ? demoEngine : engine }
    @ObservationIgnored private var stores: BotsAppStateStores?
    /// What the stores held after the last change or sync. Changes are found by naming both it and
    /// the stores now the same way, so learning a computer's ID is never taken for a change.
    @ObservationIgnored private var last = BotsPhoneState()
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    private let settle: Duration

    init(engine: AppStateSync = BotsAppStateSync.makeEngine(), demoEngine: AppStateSync? = nil,
         settle: Duration = .milliseconds(600)) {
        self.engine = engine
        self.demoEngine = demoEngine
            ?? AppStateSync(keys: engine.keys, device: engine.device, file: nil, person: { BighelpPersonID.current() })
        self.settle = settle
    }

    static func makeEngine() -> AppStateSync {
        let directory = URL.applicationSupportDirectory.appending(path: "BighelpAppState", directoryHint: .isDirectory)
        return AppStateSync(keys: BotsAppState.keys, device: deviceID(),
                            file: directory.appending(path: "state.json", directoryHint: .notDirectory),
                            person: { BighelpPersonID.current() })
    }

    /// A random ID for this install, only so the computer can say which device wrote last.
    static func deviceID(defaults: UserDefaults = .standard) -> String {
        let key = "bighelp.app-state.device"
        if let saved = defaults.string(forKey: key), AppStateWire.isID(saved) { return saved }
        let made = UUID().uuidString.lowercased()
        defaults.set(made, forKey: key)
        return made
    }

    /// Starts watching the stores. What they hold now is the starting point: nothing is sent for it
    /// until it changes, or a computer is reached for the first time.
    func start(_ stores: BotsAppStateStores) {
        self.stores = stores
        last = stores.read(scopes: scopes())
        watch()
    }

    /// Reads every computer reached, writes what's newer here to them, and puts the newest on this phone.
    func sync() async {
        if let running {
            again = true
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                again = false
                record()
                let computers = computers()
                if !computers.isEmpty {
                    let outcome = await current.sync(computers) { [weak self] key, value, ids in
                        self?.join(key, value: value, computers: ids) ?? []
                    }
                    note(outcome)
                }
                apply()
            } while again
        }
        running = task
        await task.value
        running = nil
    }

    private func note(_ outcome: AppStateSync.Outcome) {
        var scopes = phoneOnlyScopes
        for host in hosts() {
            if outcome.lacking.contains(host.hostKey) { scopes.formUnion(host.scopes) }
            if outcome.reached.contains(host.hostKey) { scopes.subtract(host.scopes) }
        }
        if scopes != phoneOnlyScopes { phoneOnlyScopes = scopes }
    }

    // MARK: Changes here

    private func watch() {
        guard let stores else { return }
        withObservationTracking {
            _ = stores.read(scopes: scopes())
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.storesChanged() }
        }
    }

    private func storesChanged() {
        watch()
        // A burst of changes (a Save, a section renamed on each member) goes as one.
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            guard let settle = self?.settle else { return }
            try? await Task.sleep(for: settle)
            // Only a change made here goes out; one a sync just put in the stores doesn't.
            guard !Task.isCancelled, let self, record() else { return }
            await sync()
        }
    }

    /// Whatever changed in the stores since `last`, as patches for the computers. True when there was any.
    @discardableResult
    private func record() -> Bool {
        guard let stores else { return false }
        let phone = stores.read(scopes: scopes())
        guard phone != last else { return false }
        let names = self.names()
        let layout = BotsAppState.layoutShape.patches(from: BotsAppState.layout(last, names: names),
                                                      to: BotsAppState.layout(phone, names: names))
        if !layout.isEmpty { current.change(BotsAppState.layoutKey, layout) }
        let settings = BotsAppState.settingsShape.patches(from: BotsAppState.settings(last, names: names),
                                                          to: BotsAppState.settings(phone, names: names))
        if !settings.isEmpty { current.change(BotsAppState.settingsKey, settings) }
        last = phone
        return !layout.isEmpty || !settings.isEmpty
    }

    // MARK: The computers' choices here

    /// Puts the newest values on this phone, for the computers each one lists.
    private func apply() {
        guard let stores else { return }
        // Anything changed while the computers were read goes on top first, so it isn't lost.
        record()
        let names = self.names()
        let old = stores.read(scopes: scopes())
        var next = old
        if let layout = current.value(BotsAppState.layoutKey) {
            next = BotsAppState.applying(layout: layout, to: next, names: names.joined(in: layout))
        }
        if let settings = current.value(BotsAppState.settingsKey) {
            next = BotsAppState.applying(settings: settings, to: next, names: names.joined(in: settings))
        }
        if next != old { stores.write(next, over: old) }
        // Read back: what a store couldn't keep (past its bound) isn't a change to send.
        last = stores.read(scopes: scopes())
    }

    /// For computers a value doesn't list yet, what this phone has for them; all of it when no
    /// computer has the value. A value already on a computer keeps everything else it has.
    private func join(_ key: String, value: BighelpJSONValue?, computers: [String]) -> [AppStatePatch] {
        guard let stores else { return [] }
        let names = self.names()
        let phone = stores.read(scopes: scopes())
        let (shape, whole) = key == BotsAppState.layoutKey
            ? (BotsAppState.layoutShape, BotsAppState.layout(phone, names: names))
            : (BotsAppState.settingsShape, BotsAppState.settings(phone, names: names))
        let patches = shape.patches(from: nil, to: whole)
        guard let value else {
            var seed = [AppStatePatch(path: ["v"], value: .integer(BotsAppState.version))] + patches
            if key == BotsAppState.layoutKey {
                for field in BotsAppState.groupListFields where !patches.contains(where: { $0.path == [field] }) {
                    seed.append(AppStatePatch(path: [field], value: .array([])))
                }
            }
            return seed
        }
        let joining = Set(computers)
        var joined = patches.filter { BotsAppState.computer(of: $0.path).map(joining.contains) == true }
        if key == BotsAppState.layoutKey {
            // Pinned and hidden group chats are one list for every computer: the joining ones' are added to it.
            for field in BotsAppState.groupListFields {
                let listed = (value.object?[field]?.array ?? []).compactMap(\.string)
                let adding = (whole.object?[field]?.array ?? []).compactMap(\.string).filter { group in
                    group.split(separator: "/", maxSplits: 1).first.map { joining.contains(String($0)) } == true
                        && !listed.contains(group)
                }
                if !adding.isEmpty {
                    joined.append(AppStatePatch(path: [field], value: .array((listed + adding).map(BighelpJSONValue.string))))
                }
            }
        }
        return joined
    }

    private func scopes() -> [String] { hosts().flatMap(\.scopes) }

    private func names() -> BotsAppState.Names {
        BotsAppState.Names(hosts: hosts(), computerIDs: current.saved.computers)
    }
}

extension BotsAppState {
    /// `bots.layout`'s lists of group chats, one for every computer.
    static let groupListFields = ["pinnedGroups", "hiddenGroups"]

    /// The computer a part of a value belongs to; nil for parts every computer shares.
    static func computer(of path: [String]) -> String? {
        guard path.count >= 2 else { return nil }
        switch path[0] {
        case "home": return path[1]
        case "groupSections", "bots": return path[1].split(separator: "/", maxSplits: 1).first.map(String.init)
        default: return nil
        }
    }
}

extension BotsAppState.Names {
    /// Only the computers `value` lists: what it holds for them replaces what this phone has.
    func joined(in value: BighelpJSONValue) -> Self {
        let listed = Set((value.object?[AppStateSync.computersField]?.array ?? []).compactMap(\.string))
        return Self(hosts: hosts, computerIDs: computerIDs.filter { listed.contains($0.value) })
    }
}
