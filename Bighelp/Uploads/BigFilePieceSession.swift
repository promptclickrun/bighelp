import Foundation

/// A `URLSession` for the pieces of big files. There are two, and `BigFilePieceSender` picks:
/// - `inFront` is an ordinary session, as fast as the link. Its tasks stop when iOS suspends Bighelp.
/// - `background` hands each piece to iOS, which sends it outside the app at a pace iOS sets (far
///   under the link's), so a piece on its way keeps going while Bighelp is in the background or
///   suspended. Pieces that finish then are recorded on the host; when Bighelp comes back,
///   `uploads/status` says which arrived, and only the rest go again.
/// Like the app's own sessions, both keep no cookies or credentials, refuse redirects and answer no
/// sign-in challenge by themselves.
final class BigFilePieceSession: NSObject, BigFileChunkSending, URLSessionDataDelegate, @unchecked Sendable {
    static let backgroundIdentifier = "app.loopdy.mobile.big-file-uploads"
    static let background = BigFilePieceSession(runsInBackground: true)
    static let inFront = BigFilePieceSession(runsInBackground: false)
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
    /// Made once, with the object. Three pieces start at the same moment: made on first use, each of
    /// them made a session of its own, their tasks shared numbers, and two of three answers were lost.
    private var session: URLSession!

    private init(runsInBackground: Bool) {
        super.init()
        let configuration: URLSessionConfiguration
        if runsInBackground {
            configuration = .background(withIdentifier: Self.backgroundIdentifier)
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
            // A piece waits for the network while the phone is offline, up to a day.
            configuration.timeoutIntervalForResource = 24 * 60 * 60
        } else {
            configuration = .ephemeral
            configuration.waitsForConnectivity = false
            // One piece, on the slowest link worth waiting for. A drop costs only this piece.
            configuration.timeoutIntervalForResource = 10 * 60
        }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// iOS woke Bighelp because the background session's tasks finished while it was away.
    func handleEvents(completion: @escaping @Sendable () -> Void) {
        lock.withLock { finishEvents = completion }
    }

    func send(_ request: URLRequest, fromFile file: URL,
              onSent: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let task = session.uploadTask(with: request, fromFile: file)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending[task.taskIdentifier] = Pending(continuation: continuation, onSent: onSent) }
                guard Task.isCancelled else { return task.resume() }
                // Cancelled before it started: its end may have come before it was listed above,
                // and then nothing else would end this wait.
                task.cancel()
                lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }?
                    .continuation.resume(throwing: CancellationError())
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

    /// How a finished piece ends. The background session never asks about the response before the body
    /// (`didReceive response` is for ordinary sessions), so the task's own response stands in for it:
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
