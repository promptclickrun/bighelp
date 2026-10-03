import CoreTransferable
import SwiftUI
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
                     appearance: BighelpAppearanceContext) throws -> Data {
        let data: Data? = switch format {
        case .csv: Data(UsageExportCSV.make(snapshot).utf8)
        case .html: Data(UsageExportHTML.make(snapshot, palette: .init(appearance: appearance)).utf8)
        case .png: UsageExportRenderer.png(snapshot, appearance: appearance)
        case .pdf: UsageExportRenderer.pdf(snapshot, appearance: appearance)
        }
        guard let data, !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    @MainActor
    static func write(_ format: UsageExportFormat, _ snapshot: UsageExportSnapshot,
                      appearance: BighelpAppearanceContext) throws -> URL {
        let data = try data(format, snapshot, appearance: appearance)
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

/// One format of the page for ShareLink, written only once something asks for it.
struct UsageExportItem: Transferable {
    let format: UsageExportFormat
    let snapshot: UsageExportSnapshot
    let appearance: BighelpAppearanceContext

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { try await $0.file() }
            .exportingCondition { $0.format == .pdf }
        FileRepresentation(exportedContentType: .png) { try await $0.file() }
            .exportingCondition { $0.format == .png }
        FileRepresentation(exportedContentType: .html) { try await $0.file() }
            .exportingCondition { $0.format == .html }
        FileRepresentation(exportedContentType: .commaSeparatedText) { try await $0.file() }
            .exportingCondition { $0.format == .csv }
    }

    private func file() async throws -> SentTransferredFile {
        var snapshot = snapshot
        snapshot.generatedAt = .now
        let format = format, appearance = appearance
        let url = try await MainActor.run { try UsageExporter.write(format, snapshot, appearance: appearance) }
        return SentTransferredFile(url)
    }
}
