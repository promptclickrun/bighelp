import Foundation

/// Demo mode's computer: two sample apps and the demo spaces' pages, answering the way the plugin does (docs/HTML_APPS.md ›
/// Routes), so UI tests and the demo need no host. Made-up numbers only.
@MainActor
final class DemoHTMLAppsClient: HTMLAppsClient {
    static let shared = DemoHTMLAppsClient()

    nonisolated static let tripBudgetID = "a_7b0c9d4e5f60718293a4b5c6d7e8f901"
    nonisolated static let gardenWatchID = "a_1f2e3d4c5b6a79880716253443526170"

    struct App {
        let title: String
        let description: String
        let sendsAnswers: Bool
        let html: String
        /// The app's data now, or nil for an app without data.
        let data: (@MainActor (Date) -> BighelpJSONValue)?
    }

    var apps: [String: App] = [
        tripBudgetID: App(title: "Trip budget",
                          description: "Split $2,400 across travel, food and fun, then send your pick.",
                          sendsAnswers: true, html: DemoHTMLApps.tripBudget, data: nil),
        gardenWatchID: App(title: "Garden watch",
                           description: "Soil, temperature and the last watering, from the sensors.",
                           sendsAnswers: false, html: DemoHTMLApps.gardenWatch, data: DemoHTMLApps.gardenData),
        // The demo spaces' pages (`DemoSpacesClient`): a panel on Today opens one.
        DemoSpacesClient.commutePageID: App(title: "Commute", description: "Drive time to work, from live traffic.",
                                            sendsAnswers: false, html: DemoSpacePages.commute,
                                            data: DemoSpacePages.commuteData),
        DemoSpacesClient.gardenPageID: App(title: "Garden", description: "Soil, temperature and the last watering.",
                                           sendsAnswers: false, html: DemoSpacePages.garden,
                                           data: DemoSpacePages.gardenData),
        DemoSpacesClient.workoutsPageID: App(title: "Workouts",
                                             description: "This week's training, read from the log each evening.",
                                             sendsAnswers: false, html: DemoSpacePages.workouts,
                                             data: DemoSpacePages.workoutsData),
        DemoSpacesClient.spendingPageID: App(title: "Spending", description: "This month's spending against the budget.",
                                             sendsAnswers: false, html: DemoSpacePages.spending,
                                             data: DemoSpacePages.spendingData),
    ]
    /// Small, so demo mode and its UI tests load every page in several pieces, as a big page does.
    var pieceBytes = 1_024
    private let clock: () -> Date
    /// Every call, for tests.
    private(set) var calls: [(operation: HTMLAppsOperation, payload: [String: BighelpJSONValue])] = []

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// `html-apps/get` as the plugin answers it: the app, then one piece of its page from `offset`
    /// (nothing when the phone has this page), and a later piece of a page that changed is refused.
    static func pageReply(info: [String: BighelpJSONValue], page: Data, payload: [String: BighelpJSONValue],
                          pieceBytes: Int) throws -> [String: BighelpJSONValue] {
        let hash = HTMLAppHash.sha256(page)
        if let revision = payload["htmlSha256"]?.string, revision != hash {
            throw WorkspaceClientError.rejected(code: "app_changed")
        }
        var app = info
        app["htmlSha256"] = .string(hash)
        app["htmlBytes"] = .integer(page.count)
        let offset = payload["offset"]?.integer ?? 0
        if offset == 0, payload["knownSha256"]?.string == hash { return ["app": .object(app)] }
        guard offset >= 0, offset < page.count else { throw WorkspaceClientError.rejected(code: "invalid_request") }
        let end = min(offset + pieceBytes, page.count)
        return ["app": .object(app), "offset": .integer(offset),
                "html": .string(page.subdata(in: offset..<end).base64EncodedString()),
                "nextOffset": end < page.count ? .integer(end) : .null]
    }

    func perform(_ operation: HTMLAppsOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        calls.append((operation, payload))
        guard payload["agentId"]?.string?.isEmpty == false, let appID = payload["appId"]?.string else {
            throw WorkspaceClientError.rejected(code: "invalid_request")
        }
        guard let app = apps[appID] else { throw WorkspaceClientError.rejected(code: "app_not_found") }
        let now = clock()
        switch operation {
        case .get:
            let info: [String: BighelpJSONValue] = [
                "appId": .string(appID), "title": .string(app.title), "description": .string(app.description),
                "sendsAnswers": .boolean(app.sendsAnswers), "live": .boolean(app.data != nil), "revision": .integer(1),
                "updatedAt": .string("2026-11-07T12:00:00Z"),
            ]
            return try Self.pageReply(info: info, page: Data(app.html.utf8), payload: payload, pieceBytes: pieceBytes)
        case .data:
            let data = app.data?(now)
            return ["appId": .string(appID), "data": data ?? .null,
                    "updatedAt": data == nil ? .null : .string(ISO8601DateFormatter().string(from: now)),
                    "dataSha256": .null, "problem": .null]
        }
    }
}

/// The sample apps' pages, as an agent might write them: one self-contained page each that follows
/// the phone's light or dark look and uses `window.bighelp`.
enum DemoHTMLApps {
    /// The garden sensors drift a little every few seconds, so the open app shows live data.
    static func gardenData(_ now: Date) -> BighelpJSONValue {
        let tick = Int(now.timeIntervalSince1970 / 5)
        return .object([
            "zone": .string("Zone 2 · Back beds"),
            "moisture": .integer(38 + tick % 6),
            "temperature": .number(18 + Double(tick % 5) / 10),
            "light": .integer(12_000 + (tick % 7) * 150),
            "lastWatered": .string("Tuesday, 7:10 AM"),
        ])
    }

    static let tripBudget = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Trip budget</title>
    <style>
      :root { color-scheme: light dark; --page: #F4F5FB; --card: #FFFFFF; --ink: #1C2140; --muted: #4B5270; --track: #E4E7F5; --accent: #4F6BED; }
      @media (prefers-color-scheme: dark) { :root { --page: #12142A; --card: #1E2140; --ink: #F1F2FA; --muted: #B5B9D6; --track: #34385C; --accent: #8EA0FF; } }
      body { margin: 0; padding: 22px 18px; background: var(--page); color: var(--ink); font: 16px -apple-system, system-ui, sans-serif; }
      .total { font-size: 32px; font-weight: 700; margin: 2px 0; }
      .muted { color: var(--muted); font-size: 14px; }
      .card { background: var(--card); border-radius: 16px; padding: 16px; margin: 18px 0; display: grid; gap: 18px; }
      label { display: flex; justify-content: space-between; font-size: 15px; }
      input[type=range] { width: 100%; accent-color: var(--accent); }
      button { width: 100%; height: 50px; border: 0; border-radius: 14px; background: var(--accent); color: #fff; font: 600 16px -apple-system, system-ui, sans-serif; }
      button:disabled { opacity: 0.5; }
    </style>
    </head>
    <body>
      <div class="muted">Weekend in the mountains</div>
      <div class="total">$2,400</div>
      <div class="muted" id="left">All of it is planned</div>
      <div class="card" id="parts"></div>
      <button id="send">Send my pick</button>
      <p class="muted" id="note"></p>
    <script>
      const total = 2400;
      const parts = [["Travel", 1100], ["Food", 800], ["Fun", 500]];
      const money = (n) => "$" + n.toLocaleString("en-US");
      const holder = document.getElementById("parts");
      parts.forEach(([name, value], index) => {
        const row = document.createElement("div");
        row.innerHTML = `<label><span>${name}</span><b id="v${index}"></b></label>
          <input type="range" min="0" max="${total}" step="50" value="${value}" id="r${index}" aria-label="${name}">`;
        holder.appendChild(row);
        row.querySelector("input").addEventListener("input", (event) => { parts[index][1] = Number(event.target.value); draw(); });
      });
      function draw() {
        parts.forEach(([, value], index) => { document.getElementById("v" + index).textContent = money(value); });
        const left = total - parts.reduce((sum, [, value]) => sum + value, 0);
        document.getElementById("left").textContent =
          left === 0 ? "All of it is planned" : left > 0 ? money(left) + " left to plan" : money(-left) + " over the budget";
      }
      draw();
      document.getElementById("send").addEventListener("click", async () => {
        const button = document.getElementById("send");
        button.disabled = true;
        const sent = await window.bighelp.sendAnswer(Object.fromEntries(parts.map(([name, value]) => [name, money(value)])));
        document.getElementById("note").textContent = sent ? "Sent. You can change it and send again." : "";
        button.disabled = false;
      });
    </script>
    </body>
    </html>
    """#

    static let gardenWatch = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Garden watch</title>
    <style>
      :root { color-scheme: light dark; --page: #F3F7F2; --card: #FFFFFF; --ink: #1E3A28; --muted: #4A5E50; --track: #E3ECE5; --accent: #2F7D4E; }
      @media (prefers-color-scheme: dark) { :root { --page: #0F1A13; --card: #18281D; --ink: #E4F2E8; --muted: #A9C2B1; --track: #2A3F31; --accent: #5CC489; } }
      body { margin: 0; padding: 20px 16px; background: var(--page); color: var(--ink); font: 16px -apple-system, system-ui, sans-serif; }
      .zone { font-size: 13px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
      h1 { font-size: 26px; margin: 2px 0 14px; }
      .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
      .card { background: var(--card); border-radius: 16px; padding: 14px; display: grid; gap: 6px; }
      .label, .small { font-size: 13px; color: var(--muted); }
      .value { font-size: 28px; font-weight: 700; }
      .bar { height: 6px; border-radius: 3px; background: var(--track); overflow: hidden; }
      .bar span { display: block; height: 100%; background: var(--accent); }
      svg { width: 100%; height: 90px; }
      .wide { margin-top: 12px; }
    </style>
    </head>
    <body>
      <div class="zone" id="zone">Waiting for the sensors</div>
      <h1 id="headline">Garden watch</h1>
      <div class="grid">
        <div class="card"><span class="label">Soil moisture</span><span class="value" id="moisture">–</span><div class="bar"><span id="moistureBar" style="width: 0%"></span></div></div>
        <div class="card"><span class="label">Temperature</span><span class="value" id="temperature">–</span></div>
        <div class="card"><span class="label">Light</span><span class="value" id="light">–</span><span class="small">lux</span></div>
        <div class="card"><span class="label">Last watered</span><span class="value" id="watered" style="font-size: 18px">–</span></div>
      </div>
      <div class="card wide"><span class="label">Moisture while this is open</span><svg viewBox="0 0 300 90" preserveAspectRatio="none"><polyline id="line" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"></polyline></svg></div>
    <script>
      const readings = [];
      window.bighelp.onData((data) => {
        if (!data) return;
        document.getElementById("zone").textContent = data.zone;
        document.getElementById("headline").textContent = data.moisture < 40 ? "Water soon" : "All good for today";
        document.getElementById("moisture").textContent = data.moisture + "%";
        document.getElementById("moistureBar").style.width = data.moisture + "%";
        document.getElementById("temperature").textContent = data.temperature.toFixed(1) + "°C";
        document.getElementById("light").textContent = (data.light / 1000).toFixed(1) + "k";
        document.getElementById("watered").textContent = data.lastWatered;
        readings.push(data.moisture);
        if (readings.length > 30) readings.shift();
        const step = readings.length > 1 ? 300 / (readings.length - 1) : 0;
        document.getElementById("line").setAttribute("points",
          readings.map((value, index) => `${index * step},${90 - (value - 30) * 4}`).join(" "));
        document.getElementById("line").style.color = getComputedStyle(document.documentElement).getPropertyValue("--accent");
      });
    </script>
    </body>
    </html>
    """#
}
