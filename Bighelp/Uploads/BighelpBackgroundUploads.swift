import Foundation

/// A background `URLSession` for the pieces of big files. iOS sends its tasks
/// itself, so a video keeps going while bighelp is in the background or
/// suspended. Pieces that finish then are recorded on the host; when bighelp
/// comes back, `uploads/status` says which arrived, and only the rest go again.
/// Like the app's own sessions, it keeps no cookies or credentials, refuses
/// redirects and answers no sign-in challenge by itself.
final class BighelpBackgroundUploads: NSObject, BigFileChunkSending, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "app.loopdy.mobile.big-file-uploads"
    static let shared = BighelpBackgroundUploads()
    /// The host's answer to a piece is a few hundred bytes of JSON.
    static let maximumResponseBytes = 65_536

    private struct Pending {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
        let onSent: @Sendable (Int64) -> Void
        var response: HTTPURLResponse?
        var received = Data()
        var failure: (any Error)?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var finishEvents: (@Sendable () -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        // A piece waits for the network while the phone is offline, up to a day.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// iOS woke bighelp because this session's tasks finished while it was away.
    func handleEvents(completion: @escaping @Sendable () -> Void) {
        lock.withLock { finishEvents = completion }
        _ = session
    }

    func send(_ request: URLRequest, fromFile file: URL,
              onSent: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let task = session.uploadTask(with: request, fromFile: file)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending[task.taskIdentifier] = Pending(continuation: continuation, onSent: onSent) }
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let report = lock.withLock { pending[task.taskIdentifier]?.onSent }
        report?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust: completionHandler(.performDefaultHandling, nil)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault:
            completionHandler(.rejectProtectionSpace, nil)
        default: completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let allow = lock.withLock { () -> Bool in
            guard var value = pending[dataTask.taskIdentifier] else { return true }
            guard let http = response as? HTTPURLResponse,
                  http.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                value.failure = DirectHermesError.messageTooLarge
                pending[dataTask.taskIdentifier] = value
                return false
            }
            value.response = http
            pending[dataTask.taskIdentifier] = value
            return true
        }
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock { () -> Bool in
            guard var value = pending[dataTask.taskIdentifier], value.failure == nil else { return false }
            guard value.received.count + data.count <= Self.maximumResponseBytes else {
                value.failure = DirectHermesError.messageTooLarge
                pending[dataTask.taskIdentifier] = value
                return true
            }
            value.received.append(data)
            pending[dataTask.taskIdentifier] = value
            return false
        }
        if overflow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let value = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        value.continuation.resume(with: Self.outcome(failure: value.failure ?? error, captured: value.response,
                                                     taskResponse: task.response, requested: task.originalRequest?.url,
                                                     body: value.received))
    }

    /// How a finished piece ends. A background session never asks about the response before the body
    /// (`didReceive response` is for foreground sessions), so the task's own response stands in for it:
    /// without it every piece that reached the host came back as a refusal.
    static func outcome(failure: (any Error)?, captured: HTTPURLResponse?, taskResponse: URLResponse?,
                        requested: URL?, body: Data) -> Result<(Data, HTTPURLResponse), any Error> {
        if let failure {
            return .failure((failure as? URLError)?.code == .cancelled ? CancellationError() : failure)
        }
        guard let response = captured ?? (taskResponse as? HTTPURLResponse) else {
            return .failure(DirectHermesError.invalidResponse)
        }
        guard requested == nil || response.url == requested else { return .failure(DirectHermesError.redirectRefused) }
        guard body.count <= maximumResponseBytes else { return .failure(DirectHermesError.messageTooLarge) }
        return .success((body, response))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { finishEvents = nil }
            return finishEvents
        }
        guard let completion else { return }
        DispatchQueue.main.async(execute: completion)
    }
}
