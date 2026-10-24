import UIKit

/// The chat's built rows, kept by ID so a row that scrolls back in shows what it built
/// before. Building a message (its SwiftUI rows, text view and text layout) takes more than
/// a frame on a 120 Hz screen, and UIKit's reuse built it again each time it came back.
/// Cells have no reuse identifier, so UIKit never gives one to another row. Rows off screen
/// wait in `parking`, a hidden view the timeline puts in its table, so they keep its traits.
@MainActor
final class ChatTimelineBuiltRows<State: AnyObject> {
    @MainActor final class Row {
        let cell = ChatTimelineCell(style: .default, reuseIdentifier: nil)
        var state: State?
        /// Changed while off screen: it's drawn again when it shows.
        var isStale = false
    }

    let limit: Int
    let parking = UIView()
    private var rows: [String: Row] = [:]

    init(limit: Int) {
        self.limit = limit
        parking.isHidden = true
        parking.isUserInteractionEnabled = false
        parking.accessibilityElementsHidden = true
    }

    var count: Int { rows.count }

    subscript(id: String) -> Row? { rows[id] }

    /// The row's built cell and state, or a new empty row.
    func row(for id: String) -> Row {
        if let row = rows[id] { return row }
        let row = Row()
        row.cell.accessibilityIdentifier = id
        rows[id] = row
        return row
    }

    /// Over the limit, the rows farthest from the ones on screen go (`index` places a row in
    /// the chat; a row it can't place goes first). Rows on screen always stay.
    func trim(around onScreen: ClosedRange<Int>, index: (String) -> Int?) {
        guard rows.count > limit else { return }
        func distance(_ id: String) -> Int {
            guard let index = index(id) else { return .max }
            return index < onScreen.lowerBound ? onScreen.lowerBound - index : max(0, index - onScreen.upperBound)
        }
        let farthest = rows.filter { !isOnScreen($0.value) }.keys.sorted { distance($0) > distance($1) }
        for id in farthest.prefix(rows.count - limit) { forget(id) }
    }

    /// UIKit takes a cell without a reuse identifier out of the table once it has gone by.
    func park(_ id: String) {
        guard let row = rows[id], row.cell.superview == nil else { return }
        parking.addSubview(row.cell)
    }

    func markStale(_ ids: some Sequence<String>) {
        for id in ids { rows[id]?.isStale = true }
    }

    /// Forgets the rows of IDs the chat no longer has.
    func remove(notIn ids: Set<String>) {
        for id in rows.keys where !ids.contains(id) { forget(id) }
    }

    /// Forgets every row, or every row that isn't on screen (a memory warning, a new look).
    func removeAll(keepingOnScreen: Bool = false) {
        for (id, row) in rows where !keepingOnScreen || !isOnScreen(row) { forget(id) }
    }

    private func isOnScreen(_ row: Row) -> Bool {
        row.cell.superview != nil && row.cell.superview !== parking
    }

    /// A row on screen is only forgotten: UIKit takes its cell out when it's done with it.
    private func forget(_ id: String) {
        if let cell = rows[id]?.cell, cell.superview === parking { cell.removeFromSuperview() }
        rows[id] = nil
    }
}

/// A row's cell. Its SwiftUI row is a plain subview rather than the cell's content
/// configuration: UIKit tells configured content it's hidden for reuse each time a row goes
/// by, and SwiftUI then made the row's text views again when it came back. Sizes come from
/// the hosted row, as they do for configured content; with the table's
/// `.enabledIncludingConstraints`, a row that grows (a streaming answer) resizes its cell.
final class ChatTimelineCell: UITableViewCell {
    private(set) var hosted: (UIView & UIContentView)?

    func host(_ configuration: some UIContentConfiguration) {
        if let hosted, hosted.supports(configuration) {
            hosted.configuration = configuration
            return
        }
        hosted?.removeFromSuperview()
        let view = configuration.makeContentView()
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        hosted = view
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize,
                                          withHorizontalFittingPriority horizontal: UILayoutPriority,
                                          verticalFittingPriority vertical: UILayoutPriority) -> CGSize {
        guard let hosted else {
            return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontal,
                                                 verticalFittingPriority: vertical)
        }
        return hosted.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontal,
                                              verticalFittingPriority: vertical)
    }
}
