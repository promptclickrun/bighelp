import Foundation
import Observation

/// The sample computers demo mode can switch between. Real hosts live in
/// `BighelpHostRegistry`; outside demo mode this list is empty.
@Observable
@MainActor
final class DemoHosts {
    struct Host: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    static let standard = [Host(id: "host-1", name: "Home Hermes")]
    static let several = standard + [Host(id: "host-2", name: "Studio Hermes")]

    let hosts: [Host]
    private(set) var selectedHostID: String?
    private let onSelectedHostChange: (String?) -> Void

    init(hosts: [Host] = [], onSelectedHostChange: @escaping (String?) -> Void = { _ in }) {
        self.hosts = hosts
        selectedHostID = hosts.first?.id
        self.onSelectedHostChange = onSelectedHostChange
    }

    func host(id: String) -> Host? {
        hosts.first { $0.id == id }
    }

    @discardableResult
    func selectHost(_ id: String) -> Bool {
        guard host(id: id) != nil, selectedHostID != id else { return false }
        selectedHostID = id
        onSelectedHostChange(id)
        return true
    }
}
