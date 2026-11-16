#if DEBUG && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import CryptoKit
import UIKit

/// `-test-island-moment command|approval|question|done|failed` (with the demo data): a card whose one
/// chat has news, and the alert that opens the Dynamic Island for it, for screenshots and for a look
/// on a phone. The real alert comes in a push from the notification service, which a simulator can't
/// receive; ActivityKit's own alert opens the island the same way. The update goes a few seconds
/// after launch, so there is time to leave the app: iOS hides an app's own card while it is in front.
@MainActor
enum IslandMomentPreview {
    static let launchArgument = "-test-island-moment"

    private static let details: [String: (phase: LoopdySessionActivityAttributes.ContentState.Phase, detail: String, alert: String)] = [
        "command": (.waiting, #""q":"rm -rf build/cache","a":"c""#, "A chat needs you."),
        "approval": (.waiting, #""q":"Deletes the old builds and their caches from three folders","a":"a""#, "A chat needs you."),
        "question": (.waiting, #""q":"Can I delete the 14 old drafts in Notes, Archive?","a":"q""#, "A chat needs you."),
        "done": (.completed, #""p":"Booked the 7:40 train to Leeds and put it in your calendar. The return is open until Friday.""#, "A chat finished."),
        "failed": (.failed, #""p":"The airline site asked for a sign-in I don't have. Your search is saved.""#, "A chat could not finish."),
    ]

    static func runIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("-use-demo-fixtures"), let index = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(index + 1), let moment = details[arguments[index + 1]] else { return }
        let rowID = "native-" + String(repeating: "ab", count: 32)
        let started = Int(Date.now.timeIntervalSince1970)
        var attributes = LoopdySessionActivityAttributes(sessionID: rowID, sessionTitle: "Active chat",
                                                         agentID: "scout", agentName: "Scout")
        BighelpActivitySessionInfo.save([rowID: .init(attributes: attributes, title: "Weekend trip")])
        attributes.cardKey = BighelpActivityCardKey.attributeKey()
        let background = UIApplication.shared.beginBackgroundTask(withName: "Island moment preview")
        let phase = moment.phase, detail = moment.detail, alert = moment.alert
        Task.detached {
            await play(rowID: rowID, started: started, attributes: attributes, phase: phase, detail: detail, alert: alert)
            await MainActor.run { UIApplication.shared.endBackgroundTask(background) }
        }
    }

    /// Off the main actor: an `Activity` isn't sendable, so one task makes it and changes it.
    nonisolated private static func play(rowID: String, started: Int, attributes: LoopdySessionActivityAttributes,
                                         phase: LoopdySessionActivityAttributes.ContentState.Phase,
                                         detail: String, alert: String) async {
        let working = BighelpActivitySession.aggregate([.init(id: rowID, phase: .usingTool, timestamp: started)], timestamp: started)
        guard let activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: working, staleDate: Date(timeIntervalSince1970: TimeInterval(started + 120))),
            pushType: nil) else { return }
        try? await Task.sleep(for: .seconds(7))
        let timestamp = Int(Date.now.timeIntervalSince1970)
        var row = BighelpActivitySession(id: rowID, phase: phase, timestamp: timestamp)
        if let master = BighelpActivityCardKey.master(create: true),
           let box = try? AES.GCM.seal(Data(#"{"v":1,"b":\#(started - 240),"s":9,\#(detail)}"#.utf8),
                                       using: BighelpActivityCardKey.rowKey(rowID, master: master),
                                       authenticating: Data("bighelp-card-v1|\(timestamp)".utf8)),
           let combined = box.combined {
            row.sealed = BighelpActivityDetail.encode(combined)
        }
        var state = BighelpActivitySession.aggregate([row], timestamp: timestamp)
        state.sessions = [row]
        state.lead = rowID
        await activity.update(
            ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: TimeInterval(timestamp + 120))),
            alertConfiguration: AlertConfiguration(title: "Bighelp", body: LocalizedStringResource(stringLiteral: alert), sound: .default))
        try? await Task.sleep(for: .seconds(40))
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
#endif
