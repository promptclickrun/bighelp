#if !os(visionOS)
import AppIntents
import Foundation

/// bighelp's Focus filter. The person adds it to a Focus in iOS Settings › Focus › Focus filters
/// and fills in a name, a note for their agents and whether agent alerts stay quiet. iOS runs it
/// when that Focus turns on and runs it again with every value at its default when it turns off
/// (a missing name and note, Quiet agent alerts off). The values go to the app group
/// (`BighelpFocusFilterState`) for `focus.current` and the notification extension.
///
/// It lives in the app, so iOS starts bighelp in the background to run it; it asks for nothing
/// from iOS and reaches no host.
struct BighelpFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Bighelp"
    static let description = IntentDescription(
        "Tell your bots about this Focus, and keep their alerts quiet while it is on.",
        categoryName: "Focus"
    )

    @Parameter(title: "Name", description: "What this Focus is, like Work or Sleep. Your bots can read it.")
    var name: String?

    @Parameter(title: "Note for bots", description: "Anything your bots should know while this Focus is on.")
    var note: String?

    @Parameter(title: "Quiet bot alerts", default: false)
    var quietAlerts: Bool

    var displayRepresentation: DisplayRepresentation {
        guard let name = BighelpFocusFilterState.clean(name, limit: BighelpFocusFilterState.maximumNameLength) else {
            return DisplayRepresentation(title: "Bighelp")
        }
        return DisplayRepresentation(title: "Bighelp", subtitle: "\(name)")
    }

    func perform() async throws -> some IntentResult {
        BighelpFocusFilterStore.shared.apply(name: name, note: note, quietAlerts: quietAlerts)
        return .result()
    }
}
#endif
