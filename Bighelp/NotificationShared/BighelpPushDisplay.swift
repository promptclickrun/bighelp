import Foundation
import UserNotifications

/// The categories the notification service extension registers. A seam for tests;
/// `UNUserNotificationCenter` is the real one.
protocol BighelpNotificationCategoryStore: Sendable {
    func categories() async -> Set<UNNotificationCategory>
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

extension UNUserNotificationCenter: BighelpNotificationCategoryStore {
    func categories() async -> Set<UNNotificationCategory> { await notificationCategories() }
    func setCategories(_ categories: Set<UNNotificationCategory>) { setNotificationCategories(categories) }
}

/// What a push asks the notification service extension to add before it shows: its action
/// buttons (`bk.category`, `bk.actions`) and its picture (`bk.image`).
///
/// Pushes the notification service sends through BuzzKit and pushes it sends straight to
/// Apple carry the same `bk` object (CONTRACTS §2), so both show the same way. The only
/// difference is that a direct push has no `bk.messageId`, so it gets no BuzzKit delivered
/// receipt (`BighelpNotificationProcessor` sends that for pushes that have one).
struct BighelpPushDisplay: Equatable, Sendable {
    struct Action: Equatable, Sendable {
        let id: String
        let title: String
        let destructive: Bool
        let foreground: Bool
        let input: Bool
        let placeholder: String?

        fileprivate init?(raw: [String: Any]) {
            guard let id = raw["id"] as? String, let title = raw["title"] as? String else { return nil }
            self.id = id
            self.title = title
            destructive = raw["destructive"] as? Bool ?? false
            foreground = raw["foreground"] as? Bool ?? false
            input = raw["input"] as? Bool ?? false
            placeholder = raw["placeholder"] as? String
        }
    }

    /// The most a picture may weigh. iOS refuses larger image attachments anyway.
    static let maximumImageBytes = 10 * 1024 * 1024
    static let imageIdentifier = "bk.image"

    let categoryID: String?
    let actions: [Action]
    let imageURL: URL?

    /// Nil for a push with neither a `bk` object nor a top-level `messageId`: it has nothing to add.
    /// Other top-level keys, such as `bighelp_meta`, are ignored.
    init?(userInfo: [AnyHashable: Any]) {
        let bk = userInfo["bk"] as? [String: Any] ?? [:]
        guard !bk.isEmpty || userInfo["messageId"] is String else { return nil }
        categoryID = bk["category"] as? String
        actions = (bk["actions"] as? [[String: Any]])?.compactMap(Action.init(raw:)) ?? []
        let image = bk["image"] as? String ?? userInfo["imageUrl"] as? String
        imageURL = image.flatMap(URL.init(string:))
    }

    typealias Download = @Sendable (URL) async throws -> (URL, URLResponse)

    /// The picture's download, with a short timeout: the extension has about 30 seconds in all.
    static let download: Download = download(using: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return configuration
    }())

    /// Reads the answer's head first and gives up at once on a picture that says it is too big, then
    /// writes what arrives to a file in the pieces the system hands over, and cancels the moment it has
    /// more than the cap, instead of downloading all of it to find out.
    static func download(using configuration: URLSessionConfiguration, maximumBytes: Int = maximumImageBytes) -> Download {
        { url in
            let loader = PictureLoader(maximumBytes: maximumBytes)
            let session = URLSession(configuration: configuration, delegate: loader, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    loader.start(session.dataTask(with: url), continuation)
                }
            } onCancel: {
                loader.cancel()
            }
        }
    }

    /// Registers the action buttons and attaches the picture. Anything that fails leaves the
    /// notification as it is.
    func apply(to content: UNMutableNotificationContent,
               categories: any BighelpNotificationCategoryStore = UNUserNotificationCenter.current(),
               download: Download = BighelpPushDisplay.download) async {
        await registerActions(on: content, categories: categories)
        await attachImage(to: content, download: download)
    }

    func registerActions(on content: UNMutableNotificationContent,
                         categories store: any BighelpNotificationCategoryStore) async {
        guard !actions.isEmpty, let categoryID else { return }
        let existing = await store.categories()
        content.categoryIdentifier = categoryID
        guard !existing.contains(where: { $0.identifier == categoryID }) else { return }
        let buttons = actions.map { action -> UNNotificationAction in
            var options: UNNotificationActionOptions = []
            if action.destructive { options.insert(.destructive) }
            if action.foreground { options.insert(.foreground) }
            if action.input {
                return UNTextInputNotificationAction(
                    identifier: action.id, title: action.title, options: options,
                    textInputButtonTitle: action.title, textInputPlaceholder: action.placeholder ?? "")
            }
            return UNNotificationAction(identifier: action.id, title: action.title, options: options)
        }
        let category = UNNotificationCategory(identifier: categoryID, actions: buttons, intentIdentifiers: [],
                                              options: [.customDismissAction])
        store.setCategories(existing.union([category]))
    }

    func attachImage(to content: UNMutableNotificationContent, download: Download) async {
        guard let url = imageURL, url.scheme?.lowercased() == "https" else { return }
        do {
            let (location, response) = try await download(url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  response.expectedContentLength <= Int64(Self.maximumImageBytes),
                  let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maximumImageBytes else {
                try? FileManager.default.removeItem(at: location)
                return
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension.isEmpty ? "png" : url.pathExtension)
            try FileManager.default.moveItem(at: location, to: destination)
            do {
                content.attachments = [try UNNotificationAttachment(identifier: Self.imageIdentifier, url: destination)]
            } catch {
                try? FileManager.default.removeItem(at: destination)
            }
        } catch {
            return
        }
    }
}

/// One picture's download: checks the head, writes the pieces to a file, stops past the cap.
private final class PictureLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var file: URL?
    private var handle: FileHandle?
    private var response: HTTPURLResponse?
    private var total = 0
    private var failure: (any Error)?

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        if FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) {
            lock.withLock { self.file = file; self.handle = handle; self.task = task; self.continuation = continuation }
            task.resume()
        } else {
            continuation.resume(throwing: URLError(.cannotCreateFile))
        }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDataTask? in
            failure = failure ?? CancellationError()
            return self.task
        }
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            lock.withLock { failure = URLError(.badServerResponse) }
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            lock.withLock { failure = URLError(.dataLengthExceedsMaximum) }
            completionHandler(.cancel)
            return
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooMuch: Bool = lock.withLock {
            total += data.count
            guard total <= maximumBytes else { failure = URLError(.dataLengthExceedsMaximum); return true }
            do { try handle?.write(contentsOf: data) } catch { failure = error; return true }
            return false
        }
        if tooMuch { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, file, response, failure) = lock.withLock { () -> (CheckedContinuation<(URL, URLResponse), Error>?, URL?, HTTPURLResponse?, (any Error)?) in
            try? handle?.close()
            handle = nil
            defer { self.continuation = nil }
            return (self.continuation, self.file, self.response, self.failure ?? error)
        }
        guard let file else { continuation?.resume(throwing: failure ?? URLError(.unknown)); return }
        if let failure {
            try? FileManager.default.removeItem(at: file)
            continuation?.resume(throwing: failure)
        } else if let response {
            continuation?.resume(returning: (file, response))
        } else {
            try? FileManager.default.removeItem(at: file)
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }
}
