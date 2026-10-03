import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Bighelp

/// Usage › Share: a PDF, a PNG, a web page and a spreadsheet of the page.
/// Every computer, agent and number here is made up.
@MainActor
struct UsageExportTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Oct 3, 2026, midday UTC.
    private static let today = Date(timeIntervalSince1970: 1_791_028_800)

    private static func provider(_ id: String, _ name: String, plan: String? = nil,
                                 windows: [ProviderUsage.Window] = [], facts: [ProviderUsage.Fact] = []) -> ProviderUsage {
        ProviderUsage(id: id, name: name, status: .ok, message: nil, plan: plan, detectedVia: ["cli"],
                      activeInHermes: false, windows: windows, facts: facts, manageURL: nil, approximate: false)
    }

    private static func snapshot(multiHost: Bool = true, metric: UsageMetric = .cost,
                                 agentName: String = "Ada") -> UsageExportSnapshot {
        let calendar = Self.calendar
        var hosts = [HostUsage(id: "home", name: "Home Hermes", agents: [
            AgentUsage(id: "ada", name: agentName,
                       report: UsageFixtures.report(seed: 0, days: 30, today: today, calendar: calendar)),
            AgentUsage(id: "rio", name: "Rio Tanaka",
                       report: UsageFixtures.report(seed: 1, days: 30, today: today, calendar: calendar)),
        ])]
        if multiHost {
            hosts.append(HostUsage(id: "studio", name: "Studio Mac", agents: [
                AgentUsage(id: "sage", name: "Sage Ortiz",
                           report: UsageFixtures.report(seed: 2, days: 30, today: today, calendar: calendar)),
            ]))
            hosts.append(HostUsage(id: "office", name: "Office Linux", failure: "Couldn't reach this computer."))
        }
        let summary = UsageSummary(hosts: hosts, days: 30, today: today, calendar: calendar)
        let claude = provider("claude", "Claude", plan: "Max 5x", windows: [
            .init(label: "Week", usedPercent: 41, resetsAt: today.addingTimeInterval(3 * 86_400), detail: nil),
        ])
        let openRouter = provider("openrouter", "OpenRouter", facts: [.init(label: "Balance", value: "$25.00")])
        var computers = [UsageExportSnapshot.Computer(id: "home", name: "Home Hermes", providers: [claude, openRouter],
                                                      used: ["claude": UsageAmount(cost: 12.5, tokens: 2_000_000)])]
        if multiHost {
            computers.append(.init(id: "studio", name: "Studio Mac", providers: [claude]))
            computers.append(.init(id: "office", name: "Office Linux", providers: [],
                                   note: "Couldn't reach this computer."))
        }
        return UsageExportSnapshot(generatedAt: today, range: .month, metric: metric, summary: summary,
                                   computers: computers, namesComputers: multiHost, calendar: calendar)
    }

    /// BIGHELP_USAGE_EXPORT_EVIDENCE (TEST_RUNNER_…) keeps the files to look at.
    private static func keep(_ data: Data, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_USAGE_EXPORT_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }

    @Test func keepsEachFormatForReview() throws {
        for format in UsageExportFormat.allCases {
            let data = try UsageExporter.data(format, Self.snapshot(), appearance: .init(appearance: .system))
            Self.keep(data, "usage.\(format.fileExtension)")
            #expect(!data.isEmpty)
        }
    }

    // MARK: Names

    @Test func filesAreNamedForTheDay() {
        let snapshot = Self.snapshot()
        #expect(snapshot.baseFileName == "bighelp-usage-2026-10-03")
        #expect(UsageExportFormat.allCases.map(\.fileExtension) == ["pdf", "png", "html", "csv"])
        #expect(UsageExportFormat.allCases.map(\.title) == ["PDF", "Image (PNG)", "Web page (HTML)", "Spreadsheet (CSV)"])
        #expect(snapshot.dateRangeText == "Sep 4 – Oct 3, 2026")
    }

    // MARK: CSV

    private static func parse(_ csv: String) -> [[String]] {
        // A small RFC 4180 reader: quoted fields may hold commas, quotes and line breaks.
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var scalars = Array(csv.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            if quoted {
                if scalar == "\"" {
                    if scalars.first == "\"" { field.unicodeScalars.append(scalars.removeFirst()) } else { quoted = false }
                } else { field.unicodeScalars.append(scalar) }
            } else if scalar == "\"" { quoted = true
            } else if scalar == "," { row.append(field); field = ""
            } else if scalar == "\r" { continue
            } else if scalar == "\n" { row.append(field); rows.append(row); row = []; field = ""
            } else { field.unicodeScalars.append(scalar) }
        }
        return rows
    }

    @Test func csvIsOneTidyTableOfTheNumbers() throws {
        let snapshot = Self.snapshot()
        let csv = UsageExportCSV.make(snapshot)
        #expect(csv.hasSuffix("\r\n"))
        let table = Self.parse(csv)
        let header = try #require(table.first)
        #expect(header == UsageExportCSV.columns)
        #expect(table.allSatisfy { $0.count == header.count }, "Every row has every column")
        let records: [[String: String]] = table.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
        func section(_ name: String) -> [[String: String]] { records.filter { $0["section"] == name } }

        // One row per day of the range, adding up to the totals.
        let daily = section("daily")
        #expect(daily.count == snapshot.summary.points.count)
        #expect(daily.first?["date"] == "2026-09-04")
        #expect(daily.last?["date"] == "2026-10-03")
        let dailyCost: Double = daily.compactMap { Double($0["cost_usd"] ?? "") }.reduce(0, +)
        #expect(abs(dailyCost - snapshot.summary.totals.cost) < 0.001, "Full precision, not display rounding")
        let dailyTokens: Int = daily.compactMap { Int($0["tokens"] ?? "") }.reduce(0, +)
        #expect(dailyTokens == snapshot.summary.totals.processedTokens)
        #expect(!daily.contains { $0["cost_usd"]?.contains("$") == true })

        // Every model, agent and computer, not just the top five.
        #expect(section("model").count == snapshot.summary.models.count)
        let agents = section("agent")
        #expect(Set(agents.compactMap { $0["agent"] }) == ["Ada", "Rio Tanaka", "Sage Ortiz"])
        #expect(agents.first { $0["agent"] == "Sage Ortiz" }?["computer"] == "Studio Mac")
        let computers = section("computer")
        #expect(computers.compactMap { $0["computer"] } == ["Home Hermes", "Studio Mac", "Office Linux"])
        #expect(computers.last?["note"] == "Couldn't reach this computer.")
        // Office Linux couldn't be read, so it has no days to list.
        #expect(section("daily_by_computer").count == snapshot.summary.points.count * 2)
        #expect(!section("daily_by_model").isEmpty)

        // Plans and limits, with the computer they're on.
        let limits = section("limit")
        let studioWeek = limits.first { $0["computer"] == "Studio Mac" && $0["provider"] == "Claude" && $0["item"] == "Week" }
        #expect(studioWeek?["used_percent"] == "41")
        #expect(studioWeek?["left_percent"] == "59")
        #expect(limits.contains { $0["computer"] == "Office Linux" && $0["note"] == "Couldn't reach this computer." })
        #expect(section("balance").first?["value"] == "$25.00")
        #expect(section("agents_used").first?["cost_usd"] == "12.5")
        #expect(section("total").contains { $0["item"] == "Estimated cost" })
        #expect(section("report").contains { $0["item"] == "Range" && $0["value"] == "30 days" })
    }

    @Test func csvQuotesAndDefusesWhatHostsSend() throws {
        let csv = UsageExportCSV.make(Self.snapshot(agentName: "=HYPERLINK(\"https://example.com\",\"Ada, \"\"the\"\" bot\")\r\nnext"))
        let rows = Self.parse(csv)
        let agent = try #require(rows.first { $0.first == "agent" && $0[3].contains("HYPERLINK") })
        #expect(agent[3].hasPrefix("'="), "Spreadsheets show it as text instead of running it")
        #expect(agent[3].contains("\r\nnext"), "A line break stays inside its cell")
        #expect(UsageExportCSV.field("plain") == "plain")
        #expect(UsageExportCSV.field("a,b") == "\"a,b\"")
        #expect(UsageExportCSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(UsageExportCSV.field("@sum") == "'@sum")
        #expect(UsageExportCSV.field("+1") == "+1", "Numbers stay numbers")
        #expect(UsageExportCSV.money(0.000125) == "0.000125")
        #expect(UsageExportCSV.money(1234.5) == "1234.5")
    }

    // MARK: HTML

    @Test func htmlIsOneSelfContainedPageWithEverySection() {
        let html = UsageExportHTML.make(Self.snapshot(agentName: "<script>alert(1)</script>"))
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<style>"))
        #expect(html.components(separatedBy: "<html").count == 2, "One document")
        #expect(!html.lowercased().contains("<script"), "No scripts, and names are escaped")
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        for external in ["src=", "href=", "<link", "url(", "@import", "http://", "https://"] {
            #expect(!html.contains(external), "Nothing loaded from anywhere: \(external)")
        }
        for section in ["id=\"limits\"", "id=\"trend\"", "id=\"totals\"", "id=\"when\"", "id=\"by-model\"",
                        "id=\"by-agent\"", "id=\"by-computer\"", "<svg"] {
            #expect(html.contains(section), "Has \(section)")
        }
        // Each computer's plans under its own name.
        #expect(html.contains("<h3 class=\"computer\">Studio Mac</h3>"))
        #expect(html.contains("<h3 class=\"computer\">Office Linux</h3>"))
        #expect(html.contains("Sep 4 – Oct 3, 2026"))
        #expect(html.contains("Made "))

        let one = UsageExportHTML.make(Self.snapshot(multiHost: false))
        #expect(!one.contains("<h3 class=\"computer\">"), "One computer needs no names")
        #expect(!one.contains("id=\"by-computer\""))
    }

    // MARK: PNG and PDF

    @Test func pngIsTheWholePageAsOnePicture() throws {
        let data = try #require(UsageExportRenderer.png(Self.snapshot(), appearance: .init(appearance: .light)))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(data.count > 40_000, "A real picture: \(data.count) bytes")
        let image = try #require(UIImage(data: data))
        // Drawn at twice the size; a picture read back counts pixels.
        #expect(image.size.width == UsageExportRenderer.pageWidth * 2)
        #expect(image.size.height > 4_000, "Every section, top to bottom: \(image.size.height)")
    }

    @Test func pdfHasPagesOfThePage() throws {
        let data = try #require(UsageExportRenderer.pdf(Self.snapshot(), appearance: .init(appearance: .dark)))
        #expect(data.starts(with: Array("%PDF".utf8)))
        #expect(data.count > 20_000, "Drawn content: \(data.count) bytes")
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(document.numberOfPages >= 2, "Paginated: \(document.numberOfPages) pages")
        let page = try #require(document.page(at: 1))
        #expect(page.getBoxRect(.mediaBox).size == UsageExportRenderer.pageSize)
    }

    @Test func writesNamedFilesToTheTemporaryFolderAndClearsThem() throws {
        let snapshot = Self.snapshot()
        let csv = try UsageExporter.write(.csv, snapshot, appearance: .init(appearance: .light))
        #expect(csv.lastPathComponent == "bighelp-usage-2026-10-03.csv")
        #expect(csv.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let html = try UsageExporter.write(.html, snapshot, appearance: .init(appearance: .light))
        #expect(!FileManager.default.fileExists(atPath: csv.path), "Earlier exports go")
        #expect(FileManager.default.fileExists(atPath: html.path))
        UsageExporter.removeAll()
        #expect(!FileManager.default.fileExists(atPath: html.path))
    }
}
