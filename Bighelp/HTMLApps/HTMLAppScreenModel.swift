import Foundation
import Observation

/// The computer in use for agents' apps: its cache scope and its `html-apps` routes. Set up by the
/// app with the computer in use (`BighelpApp`); nil while there is none.
@MainActor
enum HTMLAppHost {
    static var connection: @MainActor () -> (scope: String, api: HTMLAppsAPI)? = { nil }
}

/// The last HTML each app had on this phone (Caches), so a reopened app opens at once and the
/// plugin sends the page again only when it changed. The least recently opened go first.
struct HTMLAppCache: Sendable {
    static let maximumApps = 40

    let folder: URL

    init(folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BighelpHTMLApps", isDirectory: true)) {
        self.folder = folder
    }

    func html(scope: String, agentID: String, appID: String) -> (html: String, sha256: String)? {
        let file = url(scope: scope, agentID: agentID, appID: appID)
        guard let data = try? Data(contentsOf: file), let html = String(data: data, encoding: .utf8) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return (html, HTMLAppHash.sha256(data))
    }

    func store(_ html: String, scope: String, agentID: String, appID: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(html.utf8).write(to: url(scope: scope, agentID: agentID, appID: appID), options: .atomic)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        guard files.count > Self.maximumApps else { return }
        let oldestFirst = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return lhs < rhs
        }
        for file in oldestFirst.prefix(files.count - Self.maximumApps) { try? manager.removeItem(at: file) }
    }

    func eraseAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func url(scope: String, agentID: String, appID: String) -> URL {
        folder.appendingPathComponent(HTMLAppHash.sha256(Data("\(scope)\n\(agentID)\n\(appID)".utf8)) + ".html")
    }
}

/// One open app: its page (from the phone's copy when the plugin says it hasn't changed), its data
/// while it's open, and the answer waiting for the person's Send.
@MainActor
@Observable
final class HTMLAppScreenModel {
    enum Phase: Equatable {
        case opening
        case open(html: String)
        case failed(HTMLAppsError)
    }

    struct PendingAnswer: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    /// How often an open live app reads its data.
    static let dataInterval: Duration = .seconds(5)

    let app: HTMLAppCard
    let agentID: String
    private(set) var phase: Phase = .opening
    private(set) var info: HTMLAppInfo?
    private(set) var dataJSON: String?
    private(set) var dataUpdatedAt: Date?
    private(set) var dataProblem: HTMLAppData.Problem?
    /// Changes on Reload, so the page starts again.
    private(set) var loadID = 0
    /// The answer the page asked to send: the person sees the exact message before it goes.
    private(set) var pendingAnswer: PendingAnswer?
    private(set) var sendFailure: String?

    @ObservationIgnored private let connection: @MainActor () -> (scope: String, api: HTMLAppsAPI)?
    @ObservationIgnored private let cache: HTMLAppCache
    @ObservationIgnored private var answerContinuation: CheckedContinuation<Bool, Never>?

    init(app: HTMLAppCard, agentID: String,
         connection: @escaping @MainActor () -> (scope: String, api: HTMLAppsAPI)? = HTMLAppHost.connection,
         cache: HTMLAppCache = HTMLAppCache()) {
        self.app = app
        self.agentID = agentID
        self.connection = connection
        self.cache = cache
    }

    var title: String { info?.title ?? app.title }
    var isLive: Bool { info?.isLive ?? app.isLive }
    /// A card that says no is final (a space's never sends): the plugin's `info` can only narrow a yes.
    var sendsAnswers: Bool { app.sendsAnswers && (info?.sendsAnswers ?? true) }

    func open() async {
        guard let connection = connection() else {
            phase = .failed(.noConnection)
            return
        }
        let cached = cache.html(scope: connection.scope, agentID: agentID, appID: app.appID)
        do {
            let page = try await connection.api.app(agentID: agentID, appID: app.appID, knownSHA256: cached?.sha256)
            info = page.info
            if let html = page.html {
                cache.store(html, scope: connection.scope, agentID: agentID, appID: app.appID)
                phase = .open(html: html)
            } else if let cached {
                phase = .open(html: cached.html)
            } else {
                phase = .failed(.failed)
            }
        } catch {
            // Away from the computer, the copy on the phone still opens; its data waits.
            if error == .noConnection, let cached { phase = .open(html: cached.html) } else { phase = .failed(error) }
        }
    }

    func reload() async {
        cancelAnswer()
        phase = .opening
        loadID += 1
        await open()
    }

    /// Reads a live app's data now and every few seconds until cancelled.
    func watchData() async {
        guard isLive else { return }
        while !Task.isCancelled {
            if let connection = connection(),
               let data = try? await connection.api.data(agentID: agentID, appID: app.appID) {
                dataJSON = data.json
                dataUpdatedAt = data.updatedAt
                dataProblem = data.problem
            }
            try? await Task.sleep(for: Self.dataInterval)
        }
    }

    /// The page's `sendAnswer`: true once the person sends it, false when they don't. One at a time.
    func requestAnswer(_ answer: HTMLAppAnswer) async -> Bool {
        guard answerContinuation == nil else { return false }
        pendingAnswer = PendingAnswer(message: answer.message(title: title))
        sendFailure = nil
        return await withCheckedContinuation { answerContinuation = $0 }
    }

    /// Sends the waiting answer through the chat's own send path. When the chat can't send now,
    /// the panel stays with the reason.
    func confirmAnswer(_ send: (String) throws -> Void) {
        guard let pendingAnswer else { return }
        do {
            try send(pendingAnswer.message)
        } catch {
            sendFailure = (error as? LocalizedError)?.errorDescription ?? "This chat can't send right now. Try again in a moment."
            return
        }
        finishAnswer(sent: true)
    }

    func cancelAnswer() {
        finishAnswer(sent: false)
    }

    private func finishAnswer(sent: Bool) {
        pendingAnswer = nil
        sendFailure = nil
        answerContinuation?.resume(returning: sent)
        answerContinuation = nil
    }
}
