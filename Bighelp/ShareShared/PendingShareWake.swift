#if canImport(Darwin)
import Foundation

/// How the share sheet tells bighelp that a share waits for the default bot (#1069).
///
/// A share extension can't open its app, and bighelp may not be running. The one thing iOS offers is a
/// background `URLSession`: when a request the extension started ends and the extension is gone, iOS
/// starts the app in the background to take the result (`handleEventsForBackgroundURLSession`). So the
/// sheet starts one small request, and bighelp, once started, sends the share itself
/// (`PendingShareSender`). The request carries nothing about the share and its answer isn't read.
/// iOS decides when it runs; a share iOS never wakes bighelp for goes when bighelp next opens.
enum PendingShareWake {
    /// The extension's own session: a background session belongs to one process at a time, and
    /// bighelp takes this one over only when iOS starts it for the result.
    static let sessionIdentifier = "app.loopdy.mobile.share-wake"
    /// Posted (a Darwin notification, no content) for a bighelp that is running already.
    static let notificationName = "app.loopdy.mobile.share.saved"
    /// The provider logo list on bighelp's own site, which the app reads anyway. Asked for with HEAD.
    static let url = URL(string: "https://logos.loopdy.app/provider-logos/v1/manifest.json")!
    /// Long enough for the sheet to close and its process to end first (`ShareViewController.finish`):
    /// while the sheet's process is connected, iOS hands the result to it and starts nothing.
    static let delay: TimeInterval = 2

    static func configuration(appGroup: String = PendingShareInbox.appGroup) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sharedContainerIdentifier = appGroup
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // Offline, the request ends by itself and bighelp still starts, to say the share didn't go.
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    static func request() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// Called by the share sheet once a share is saved, with its one session for this identifier.
    static func signal(on session: URLSession, now: Date = Date()) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(notificationName as CFString), nil, nil, true)
        let task = session.downloadTask(with: request())
        task.earliestBeginDate = now.addingTimeInterval(delay)
        task.resume()
    }
}

/// The default bot's name, for the share sheet to say who gets a share. The app writes it for its
/// widgets (`BighelpWidgetSnapshot`, in the app group); the sheet reads only this one field.
enum PendingShareDefaultBot {
    /// `BighelpWidgetSnapshot.fileName`: that type isn't built into the share sheet.
    static let fileName = "loopdy-widget-snapshot-v1.json"
    static let maximumBytes = 262_144

    private struct Snapshot: Decodable {
        let defaultAgentName: String?
    }

    static func name(appGroup: String = PendingShareInbox.appGroup) -> String? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .flatMap { name(in: $0.appending(path: fileName)) }
    }

    static func name(in file: URL) -> String? {
        guard let data = PendingShareInbox.read(file, limit: maximumBytes),
              let name = (try? JSONDecoder().decode(Snapshot.self, from: data))?.defaultAgentName?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return String(name.prefix(60))
    }
}
#endif
