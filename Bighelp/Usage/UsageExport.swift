import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Usage page as it is when Share is tapped: its range, Cost or Tokens,
/// the computers in Limits and every number, ready to write as a file.
struct UsageExportSnapshot: Equatable, Sendable {
    /// One computer's plans and limits, as Limits shows them (hidden plans left out).
    struct Computer: Equatable, Sendable {
        let id: String
        let name: String
        let providers: [ProviderUsage]
        /// Why no plans show ("Couldn't reach this computer.").
        var note: String?
        /// What the agents used through each provider in the range, by provider id.
        var used: [String: UsageAmount] = [:]
    }

    /// Set again when the file is written, so it says when it was made.
    var generatedAt: Date
    let range: UsageRange
    let metric: UsageMetric
    let summary: UsageSummary
    /// Limits' computers; empty when the page shows none.
    let computers: [Computer]
    /// Several computers, each under its own name.
    let namesComputers: Bool
    /// The page's own warning, like "Couldn't refresh. Showing the last result."
    var notice: String?
    /// When the numbers were read from the computers.
    var readAt: Date?
    var calendar = Calendar.current

    var firstDay: Date? { summary.points.first?.date }
    var lastDay: Date? { summary.points.last?.date }

    /// "Sep 4 – Oct 3, 2026".
    var dateRangeText: String {
        guard let first = firstDay, let last = lastDay else { return "The last \(range.days) days" }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar,
                                     timeZone: calendar.timeZone)
        let short = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        let sameYear = calendar.component(.year, from: first) == calendar.component(.year, from: last)
        return "\((sameYear ? short : style).format(first)) – \(style.format(last))"
    }

    var generatedText: String {
        "Made \(generatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, calendar: calendar, timeZone: calendar.timeZone)))"
    }

    /// The computers the numbers come from: "Home Hermes, Studio Mac".
    var computersText: String? {
        let names = summary.hosts.map(\.title)
        return names.count > 1 ? names.joined(separator: ", ") : names.first
    }

    var measureText: String { metric == .cost ? "Estimated cost" : "Processed tokens" }

    /// "bighelp-usage-2026-10-03".
    var baseFileName: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "bighelp-usage-\(formatter.string(from: generatedAt))"
    }
}

extension UsageExportSnapshot {
    /// What's on the page now. Nil until there are numbers to share.
    @MainActor
    static func make(store: UsageStore, providerUsage: ProviderUsageStore?, computers: UsageLimitsComputers,
                     hidden: Set<String>, now: Date = .now) -> UsageExportSnapshot? {
        guard let summary = store.summary else { return nil }
        let shown = providerUsage == nil ? [] : computers.shown.map { computer -> Computer in
            func used(_ providers: [ProviderUsage]) -> [String: UsageAmount] {
                Dictionary(providers.compactMap { provider in
                    summary.agentsUse(of: provider, hostID: computer.id).map { (provider.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
            }
            if computer.isSelected {
                guard let providerUsage else { return Computer(id: computer.id, name: computer.name, providers: []) }
                switch providerUsage.state {
                case .needsPluginUpdate:
                    return Computer(id: computer.id, name: computer.name, providers: [],
                                    note: "Update the bighelp plugin to see plans and limits.")
                default:
                    guard let report = providerUsage.report else {
                        let note: String = if case .unavailable(let message) = providerUsage.state { message }
                            else { "Plans and limits were still loading." }
                        return Computer(id: computer.id, name: computer.name, providers: [], note: note)
                    }
                    let providers = ProviderUsagePresentation.visible(report.providers, hidden: hidden)
                    return Computer(id: computer.id, name: computer.name, providers: providers,
                                    note: providers.isEmpty ? "No AI plans to show." : nil, used: used(providers))
                }
            }
            switch computer.usage?.limits {
            case .loaded(let report)?:
                let providers = ProviderUsagePresentation.visible(report.providers, hidden: hidden)
                return Computer(id: computer.id, name: computer.name, providers: providers,
                                note: providers.isEmpty ? "No AI plans to show." : nil, used: used(providers))
            case .needsPluginUpdate?:
                return Computer(id: computer.id, name: computer.name, providers: [],
                                note: "Update the bighelp plugin on \(computer.name) to see its plans and limits.")
            case .unavailable(let message)?:
                return Computer(id: computer.id, name: computer.name, providers: [], note: message)
            case nil:
                return Computer(id: computer.id, name: computer.name, providers: [],
                                note: computer.usage?.failure ?? "Its plans and limits couldn't be read.")
            }
        }
        let notice: String? = if case .unavailable(let message) = store.state { message } else { nil }
        return UsageExportSnapshot(generatedAt: now, range: store.range, metric: store.metric, summary: summary,
                                   computers: shown, namesComputers: shown.count > 1, notice: notice,
                                   readAt: store.updatedAt)
    }
}

/// The four ways to share the page.
enum UsageExportFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf, png, html, csv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .png: "Image (PNG)"
        case .html: "Web page (HTML)"
        case .csv: "Spreadsheet (CSV)"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .png: "photo"
        case .html: "safari"
        case .csv: "tablecells"
        }
    }

    var contentType: UTType {
        switch self {
        case .pdf: .pdf
        case .png: .png
        case .html: .html
        case .csv: .commaSeparatedText
        }
    }

    var fileExtension: String { rawValue }
}

/// Writes exports to the temporary folder, one folder per file so each keeps
/// its friendly name, and clears out the earlier ones.
enum UsageExporter {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: "bighelp-usage-export", directoryHint: .isDirectory)
    }

    @MainActor
    static func data(_ format: UsageExportFormat, _ snapshot: UsageExportSnapshot,
                     appearance: BighelpAppearanceContext) async throws -> Data {
        let data: Data? = switch format {
        case .csv: Data(UsageExportCSV.make(snapshot).utf8)
        case .html: Data(UsageExportHTML.make(snapshot, palette: .init(appearance: appearance)).utf8)
        case .png: UsageExportRenderer.png(snapshot, appearance: appearance)
        case .pdf: await UsageExportRenderer.pdf(snapshot, appearance: appearance)
        }
        guard let data, !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    @MainActor
    static func write(_ format: UsageExportFormat, _ snapshot: UsageExportSnapshot,
                      appearance: BighelpAppearanceContext) async throws -> URL {
        let data = try await data(format, snapshot, appearance: appearance)
        removeAll()
        let directory = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(snapshot.baseFileName).\(format.fileExtension)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Exports are only for handing to the share sheet; none are kept.
    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Writes the format picked, saying so while it works: drawing the page as a PDF or picture can
/// take seconds, and with the share sheet asking for it the screen froze with nothing to show.
@MainActor
@Observable
final class UsageExportJob {
    private(set) var exporting: UsageExportFormat?
    var failed = false

    #if DEBUG
    /// "-test-slow-usage-export": long enough for UI tests to see Exporting….
    private static let holdMilliseconds = CommandLine.arguments.contains("-test-slow-usage-export") ? 2_500 : 350
    #else
    private static let holdMilliseconds = 350
    #endif

    func run(_ format: UsageExportFormat, _ snapshot: UsageExportSnapshot,
             appearance: BighelpAppearanceContext) async -> URL? {
        guard exporting == nil else { return nil }
        exporting = format
        defer { exporting = nil }
        // Let the menu close and the loader appear before drawing holds up the screen.
        try? await Task.sleep(for: .milliseconds(Self.holdMilliseconds))
        var snapshot = snapshot
        snapshot.generatedAt = .now
        do {
            return try await UsageExporter.write(format, snapshot, appearance: appearance)
        } catch {
            failed = true
            return nil
        }
    }
}

/// Opens the share sheet for a finished export, pointing at Share on iPad, Mac and Vision Pro.
@MainActor
final class UsageShareSheetAnchor {
    fileprivate weak var host: UIViewController?

    func share(_ url: URL, title: String) {
        guard let host, host.view.window != nil else { return }
        let sheet = UIActivityViewController(activityItems: [UsageShareItem(url: url, title: title)],
                                             applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = host.view
        sheet.popoverPresentationController?.sourceRect = host.view.bounds
        host.present(sheet, animated: true)
    }
}

/// Sits behind Share so the sheet has a place to come from.
struct UsageShareSheetHost: UIViewControllerRepresentable {
    let anchor: UsageShareSheetAnchor

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        // Taps belong to Share above it.
        host.view.isUserInteractionEnabled = false
        anchor.host = host
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        anchor.host = host
    }
}

/// The file, titled "Usage, <range>" at the top of the share sheet.
private final class UsageShareItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.url = url
        return metadata
    }
}
