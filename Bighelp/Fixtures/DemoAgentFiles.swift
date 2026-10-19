import CryptoKit
import Foundation
import UIKit

/// The demo computer's folders: each bot has its own, as each Hermes agent works in its own folder.
/// Every file is made up. Bots without any show the empty state.
@MainActor
final class SimpleBotDemoFiles: SimpleBotFilesSource {
    static let root = "/home/hermes/workspace"
    static let travelRoot = "/home/hermes/.hermes/profiles/travel/workspace"
    static let homeRoot = "/home/hermes/.hermes/profiles/home/workspace"

    /// The default agent works in Hermes' workspace folder; the others in their profiles' own.
    static func root(for agentID: String) -> String {
        switch agentID {
        case "finance": root
        case "travel": travelRoot
        case "home": homeRoot
        default: "/home/hermes/.hermes/profiles/\(agentID)/workspace"
        }
    }

    private enum Entry {
        case folder(String)
        case file(String, mimeType: String, daysAgo: Double, data: @MainActor () -> Data)
    }

    private let now = Date()

    var downloadLimit: Int { DirectHermesManagedFilesClient.maximumNativeTransferBytes }

    func list(agentID: String, path: String?) async throws -> HermesManagedFileDirectory {
        let root = Self.root(for: agentID)
        let path = path ?? root
        guard path == root || path.hasPrefix(root + "/") else { throw DirectHermesManagedFilesError.invalidPath }
        guard let entries = Self.tree[path] ?? (path == root ? [] : nil) else {
            throw DirectHermesManagedFilesError.invalidPath
        }
        return .init(path: path, parent: path == root ? nil : (path as NSString).deletingLastPathComponent,
                     files: entries.map { file($0, in: path) })
    }

    func download(agentID: String, file: HermesManagedFile) async throws -> HermesManagedFileContents {
        guard file.path.hasPrefix(Self.root(for: agentID) + "/") else { throw DirectHermesManagedFilesError.invalidPath }
        let folder = (file.path as NSString).deletingLastPathComponent
        guard let entry = Self.tree[folder]?.first(where: { Self.name(of: $0) == file.name }),
              case .file(_, _, _, let data) = entry else { throw DirectHermesManagedFilesError.invalidPath }
        let bytes = data()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(file: file, bytes: bytes, sha256: digest)
    }

    /// The demo has no host to stream from; videos download and play in the preview.
    func canStream(agentID: String, file: HermesManagedFile) -> Bool { false }
    func playback(agentID: String, file: HermesManagedFile) -> DirectHermesManagedMediaPlayback? { nil }

    private func file(_ entry: Entry, in folder: String) -> HermesManagedFile {
        let path = folder + "/" + Self.name(of: entry)
        switch entry {
        case .folder(let name):
            return .init(path: path, name: name, isDirectory: true, byteCount: nil,
                         modifiedAt: now.addingTimeInterval(-86_400), mimeType: nil)
        case .file(let name, let mimeType, let daysAgo, let data):
            return .init(path: path, name: name, isDirectory: false, byteCount: data().count,
                         modifiedAt: now.addingTimeInterval(-daysAgo * 86_400), mimeType: mimeType)
        }
    }

    private static func name(of entry: Entry) -> String {
        switch entry {
        case .folder(let name), .file(let name, _, _, _): name
        }
    }

    private static let tree: [String: [Entry]] = [
        root: [
            .folder("Budget"),
            .folder("Recordings"),
            .folder("Reports"),
            .file("Notes.md", mimeType: "text/markdown", daysAgo: 0.1) { Data(notes.utf8) },
            .file("Shopping list.txt", mimeType: "text/plain", daysAgo: 2) { Data(shopping.utf8) },
        ],
        root + "/Budget": [
            .file("October budget.md", mimeType: "text/markdown", daysAgo: 1) { Data(budget.utf8) },
            .file("Bills.csv", mimeType: "text/csv", daysAgo: 6) { Data(bills.utf8) },
        ],
        root + "/Recordings": [
            .file("Budget walkthrough.mp4", mimeType: "video/mp4", daysAgo: 3) { DemoAgentMedia.video },
        ],
        root + "/Reports": [
            .file(DemoBoardFiles.chartName, mimeType: "image/png", daysAgo: 0.5) { DemoBoardFiles.chart },
            .file(DemoBoardFiles.planName, mimeType: "application/pdf", daysAgo: 0.5) { DemoBoardFiles.plan },
            .file("savings-goal.png", mimeType: "image/png", daysAgo: 4) { DemoAgentMedia.savings },
        ],
        travelRoot: [
            .folder("Lisbon trip"),
            .file("Flights.csv", mimeType: "text/csv", daysAgo: 1) { Data(flights.utf8) },
            .file("Ideas.md", mimeType: "text/markdown", daysAgo: 5) { Data(tripIdeas.utf8) },
        ],
        travelRoot + "/Lisbon trip": [
            .file("Itinerary.md", mimeType: "text/markdown", daysAgo: 0.2) { Data(itinerary.utf8) },
            .file("Packing list.md", mimeType: "text/markdown", daysAgo: 0.4) { Data(packing.utf8) },
            .file("lisbon-evening.png", mimeType: "image/png", daysAgo: 0.1) { DemoAgentMedia.sunset },
            .file(DemoBoardFiles.chartName, mimeType: "image/png", daysAgo: 1) { DemoBoardFiles.chart },
            .file("trip-preview.mp4", mimeType: "video/mp4", daysAgo: 2) { DemoAgentMedia.video },
        ],
        homeRoot: [
            .folder("House"),
            .file("Grocery list.txt", mimeType: "text/plain", daysAgo: 0.3) { Data(shopping.utf8) },
        ],
        homeRoot + "/House": [
            .file("Chores.md", mimeType: "text/markdown", daysAgo: 0.5) { Data(chores.utf8) },
            .file("Repairs.csv", mimeType: "text/csv", daysAgo: 3) { Data(repairs.utf8) },
        ],
    ]

    private static let flights = """
    flight,departs,price
    TAP 202,Oct 9 18:40,$389
    United 64,Oct 9 21:15,$412
    Delta 248,Oct 10 07:05,$436
    """

    private static let tripIdeas = """
    # Trip ideas

    - Lisbon in October: mild days, fewer crowds.
    - Porto by train for one night.
    - Kyoto in spring, next year.
    """

    private static let itinerary = """
    # Lisbon, October 9–16

    1. **Thu:** land at 7:30 AM, check in, walk Alfama.
    2. **Fri:** tram 28, then the Gulbenkian.
    3. **Sat:** day trip to Sintra; book trains a day ahead.
    4. **Sun:** fado dinner in Alfama.
    """

    private static let packing = """
    # Packing list

    - [x] Passport
    - [x] Travel adapter (Type F)
    - [ ] Comfortable walking shoes
    - [ ] Light rain jacket
    - [ ] Sunglasses and sunscreen
    """

    private static let chores = """
    # Chores this week

    - Water the plants on Tuesday and Friday.
    - Change the air filter (size 16×25).
    - Take the recycling out on Wednesday night.
    """

    private static let repairs = """
    repair,who,when
    Kitchen faucet drip,Plumber,Oct 22
    Squeaky hallway door,Me,This weekend
    """

    private static let notes = """
    # Notes

    - Rent goes out on the 1st; the reminder is set for the 28th.
    - Lisbon fund: **$1,340** of $2,000 saved.
    - Ask about the cheaper phone plan before the 15th.

    ## This week
    1. Move $120 to savings on Friday.
    2. Cancel the streaming trial before it renews.
    """

    private static let shopping = """
    Oat milk
    Eggs
    Spinach
    Coffee beans
    Dish soap
    """

    private static let budget = """
    # October budget

    | What | Planned | Spent |
    | --- | ---: | ---: |
    | Rent | $1,450 | $1,450 |
    | Groceries | $420 | $268 |
    | Transport | $110 | $64 |
    | Fun | $150 | $92 |

    On track: **$296 left** for the rest of the month.
    """

    private static let bills = """
    bill,amount,due
    Electricity,64.20,Oct 21
    Internet,55.00,Oct 24
    Phone,38.00,Oct 27
    """
}

/// The demo bots' photos and videos from their chats, drawn on the phone from made-up numbers.
@MainActor
final class DemoAgentMediaClient: AgentMediaClient {
    static let shared = DemoAgentMediaClient()

    func recent(agentID: String) async throws -> [AgentMediaItem] {
        DemoAgentMedia.items(for: agentID).map(\.item)
    }

    func data(agentID: String, item: AgentMediaItem) async throws -> Data {
        guard let entry = DemoAgentMedia.items(for: agentID).first(where: { $0.item.id == item.id }) else {
            throw WorkspaceClientError.invalidResponse
        }
        return entry.data()
    }
}

@MainActor
enum DemoAgentMedia {
    struct Entry {
        let item: AgentMediaItem
        let data: @MainActor () -> Data
    }

    /// Newest first, like the plugin's list. Bots without any show the empty state.
    static func items(for agentID: String) -> [Entry] {
        let now = Date()
        func entry(_ id: String, _ name: String, _ mime: String, hoursAgo: Double,
                   _ data: @escaping @MainActor () -> Data) -> Entry {
            Entry(item: AgentMediaItem(id: "demo-media-\(agentID)-\(id)", fileName: name, mimeType: mime,
                                       byteCount: data().count, createdAt: now.addingTimeInterval(-hoursAgo * 3_600)),
                  data: data)
        }
        switch agentID {
        case "finance":
            return [
                entry("savings", "savings-goal.png", "image/png", hoursAgo: 3) { savings },
                entry("fares", DemoBoardFiles.chartName, "image/png", hoursAgo: 20) { DemoBoardFiles.chart },
                entry("walkthrough", "budget-walkthrough.mp4", "video/mp4", hoursAgo: 52) { video },
                entry("sunset", "lisbon-evening.png", "image/png", hoursAgo: 75) { sunset },
            ]
        case "travel":
            return [
                entry("sunset", "lisbon-evening.png", "image/png", hoursAgo: 2) { sunset },
                entry("fares", DemoBoardFiles.chartName, "image/png", hoursAgo: 26) { DemoBoardFiles.chart },
                entry("preview", "trip-preview.mp4", "video/mp4", hoursAgo: 49) { video },
            ]
        default:
            return []
        }
    }

    /// A short clip that ships with the app's demo data.
    static let video: Data = {
        guard let url = Bundle.main.url(forResource: "generation-preview", withExtension: "mp4"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }()

    static let savings: Data = {
        let months: [(String, CGFloat)] = [("Jun", 420), ("Jul", 610), ("Aug", 820), ("Sep", 1_090), ("Oct", 1_340)]
        let size = CGSize(width: 1_000, height: 1_000)
        return render(size) { context in
            UIColor(red: 0.93, green: 0.96, blue: 0.93, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            draw("Lisbon fund", at: CGPoint(x: 70, y: 70), size: 64, weight: .bold, color: UIColor(white: 0.15, alpha: 1))
            draw("$1,340 of $2,000", at: CGPoint(x: 70, y: 160), size: 40, weight: .medium,
                 color: UIColor(white: 0.35, alpha: 1))
            for (index, month) in months.enumerated() {
                let height = month.1 / 2_000 * 560
                let bar = CGRect(x: 80 + CGFloat(index) * 175, y: 860 - height, width: 120, height: height)
                (index == months.count - 1 ? UIColor.systemGreen : UIColor(white: 0.75, alpha: 1)).setFill()
                UIBezierPath(roundedRect: bar, cornerRadius: 20).fill()
                draw(month.0, at: CGPoint(x: bar.minX + 22, y: 880), size: 34, weight: .semibold,
                     color: UIColor(white: 0.3, alpha: 1))
            }
        }
    }()

    static let sunset: Data = {
        let size = CGSize(width: 1_000, height: 1_000)
        return render(size) { context in
            let colors = [UIColor(red: 0.98, green: 0.62, blue: 0.38, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.33, blue: 0.62, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                         locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height),
                                                     options: [])
            }
            UIColor(red: 1, green: 0.88, blue: 0.55, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 330, y: 380, width: 340, height: 340)).fill()
            UIColor(red: 0.2, green: 0.17, blue: 0.3, alpha: 1).setFill()
            let skyline = UIBezierPath()
            skyline.move(to: CGPoint(x: 0, y: 1_000))
            for (x, y) in [(0, 700), (120, 700), (120, 640), (260, 640), (260, 720), (420, 720), (420, 600),
                           (520, 560), (620, 600), (620, 690), (780, 690), (780, 630), (900, 630), (900, 710),
                           (1_000, 710)] {
                skyline.addLine(to: CGPoint(x: x, y: y))
            }
            skyline.addLine(to: CGPoint(x: 1_000, y: 1_000))
            skyline.close()
            skyline.fill()
        }
    }()

    private static func render(_ size: CGSize, _ drawing: (UIGraphicsImageRendererContext) -> Void) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData(actions: drawing)
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight, color: UIColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight),
                                                            .foregroundColor: color])
    }
}
