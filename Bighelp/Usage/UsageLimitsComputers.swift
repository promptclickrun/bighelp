import Foundation

/// Which computers Usage › Limits shows: the one in use, another one, or all of
/// them, each under its own name. Only the Limits section follows it; the
/// charts, totals and By computer keep to All hosts, so one choice never
/// changes what the rest of the page adds up.
struct UsageLimitsComputers: Equatable {
    /// Saved on this device: "current", "all" or a computer's id. The key never changes.
    static let choiceKey = "bighelp.usage.limits-computer"

    enum Choice: Equatable {
        /// The computer in use, whichever that is.
        case current
        case all
        case computer(String)

        init(saved: String) {
            switch saved {
            case "", "current": self = .current
            case "all": self = .all
            default: self = .computer(saved)
            }
        }

        var saved: String {
            switch self {
            case .current: "current"
            case .all: "all"
            case .computer(let id): id
            }
        }
    }

    struct Computer: Identifiable, Equatable {
        let id: String
        let name: String
        /// The computer in use: its limits come from `ProviderUsageStore`.
        let isSelected: Bool
        /// What was read from another computer; nil for the one in use.
        let usage: HostUsage?
    }

    /// The computer in use first, then the others in the order they were read.
    let computers: [Computer]
    /// The saved choice, or the computer in use when that one is gone.
    let choice: Choice

    init(selectedID: String, selectedName: String?, hosts: [HostUsage], saved: String) {
        var computers = [Computer(id: selectedID, name: selectedName ?? hosts.first { $0.id == selectedID }?.name
                                    ?? "This computer", isSelected: true, usage: nil)]
        computers += hosts.filter { $0.id != selectedID }.map {
            Computer(id: $0.id, name: $0.name, isSelected: false, usage: $0)
        }
        self.computers = computers
        switch Choice(saved: saved) {
        case .all where computers.count > 1:
            choice = .all
        case .computer(let id) where id != selectedID && computers.contains(where: { $0.id == id }):
            choice = .computer(id)
        default:
            choice = .current
        }
    }

    /// One computer has nothing to choose between.
    var offersChoice: Bool { computers.count > 1 }

    /// With all of them showing, each computer's plans sit under its name.
    var showsNames: Bool { offersChoice && choice == .all }

    var shown: [Computer] {
        switch choice {
        case .current: Array(computers.prefix(1))
        case .all: computers
        case .computer(let id): computers.filter { $0.id == id }
        }
    }

    /// The menu's label: the computer shown, or "All computers".
    var title: String {
        choice == .all ? "All computers" : shown.first?.name ?? "This computer"
    }

    func isChosen(_ computer: Computer) -> Bool {
        choice != .all && shown.first?.id == computer.id
    }

    /// What picking a computer saves: the one in use is "current", so the
    /// choice follows a switch to another computer.
    static func saved(for computer: Computer) -> String {
        computer.isSelected ? Choice.current.saved : Choice.computer(computer.id).saved
    }
}
