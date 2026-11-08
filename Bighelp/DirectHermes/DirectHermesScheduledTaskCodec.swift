import Foundation

enum DirectHermesScheduledTaskCodec {
    typealias D = WorkspaceManagementDecoder
    typealias Object = [String: BighelpJSONValue]

    static func task(_ value: BighelpJSONValue, profile expectedProfile: String) throws -> ScheduledTask {
        let row = try D.object(value)
        let profile = try D.text(row["profile"], maximum: 128)
        guard profile.utf8.elementsEqual(expectedProfile.utf8), let enabled = row["enabled"]?.boolean else {
            throw WorkspaceClientError.invalidResponse
        }
        let state = try D.text(row["state"], maximum: 64)
        let status: ScheduledTaskStatus
        switch state {
        case "completed": status = .completed
        case "error": status = .failed
        case "scheduled", "running", "paused": status = enabled ? .active : .paused
        default: throw WorkspaceClientError.invalidResponse
        }
        let request = try schedule(row["schedule"])
        let display = try D.optionalText(row["schedule_display"], maximum: 2_048) ?? request
        let script = try D.optionalText(row["script"], maximum: 4_096)
        let skills = try row["skills"].map { try D.rows($0, maximum: 100) } ?? []
        if let noAgent = row["no_agent"], noAgent.boolean == nil { throw WorkspaceClientError.invalidResponse }
        let execution = hostExecution(script: script, skills: skills, noAgent: row["no_agent"]?.boolean == true)
        return try ScheduledTask(
            id: DirectHermesCoreRequestScope.identifier(D.text(row["id"], maximum: 160)),
            agentID: profile,
            name: D.text(row["name"], maximum: 240),
            instructions: D.text(row["prompt"], maximum: 256_000, empty: true),
            schedule: .hermes(request: request, display: ScheduleRequestBuilder.display(forHermesRequest: display),
                timeZoneID: TimeZone.current.identifier),
            deliveryTarget: D.text(row["deliver"], maximum: 512),
            scheduleDescription: ScheduleRequestBuilder.display(forHermesRequest: display),
            nextRun: date(row["next_run_at"]),
            status: status,
            lastResult: D.optionalText(row["last_status"], maximum: 512),
            hostExecution: execution
        )
    }

    /// Only the script's file name leaves the reader: its path is the computer's own business.
    /// A skill that isn't a short name is left out rather than failing the whole list.
    static func hostExecution(script: String?, skills: [BighelpJSONValue], noAgent: Bool) -> ScheduledTaskHostExecution? {
        let scriptName = script?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        let names = skills.compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { (1...128).contains($0.count) }
        guard scriptName != nil || !names.isEmpty || noAgent else { return nil }
        return ScheduledTaskHostExecution(scriptName: scriptName, skills: names, runsWithoutAgent: noAgent)
    }

    static func tasks(_ payload: Object, profile: String) throws -> [ScheduledTask] {
        try D.unique(D.rows(payload["jobs"], maximum: 500).map { try task($0, profile: profile) })
    }

    static func schedule(_ value: BighelpJSONValue?) throws -> String {
        if let raw = value?.string { return try D.text(.string(raw), maximum: 2_048) }
        guard let row = value?.object else { throw WorkspaceClientError.invalidResponse }
        switch row["kind"]?.string {
        case "cron":
            return try D.text(row["expr"], maximum: 2_048)
        case "once":
            let text = try D.text(row["run_at"], maximum: 128)
            guard try date(.string(text)) != nil else { throw WorkspaceClientError.invalidResponse }
            return text
        case "interval":
            guard let minutes = row["minutes"]?.number, minutes.isFinite, minutes > 0 else {
                throw WorkspaceClientError.invalidResponse
            }
            let text = row["minutes"]?.integer.map(String.init) ?? String(minutes)
            return "every \(text)m"
        default: throw WorkspaceClientError.invalidResponse
        }
    }

    static func date(_ value: BighelpJSONValue?) throws -> Date? {
        guard let value, value != .null else { return nil }
        if let seconds = value.number, seconds >= 0, seconds <= 253_402_300_799 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = value.string, text.utf8.count <= 128 {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: text) { return date }
        }
        throw WorkspaceClientError.invalidResponse
    }

    static func matches(_ task: ScheduledTask, request: String) -> Bool {
        guard case .hermes(let saved, _, _) = task.schedule else { return false }
        if saved == request { return true }
        let formatter = ISO8601DateFormatter()
        if let savedDate = formatter.date(from: saved), let requestedDate = formatter.date(from: request) {
            return savedDate == requestedDate
        }
        return false
    }

    static func deliveryTargets(_ payload: Object) throws -> [ScheduledTaskDeliveryTarget] {
        try D.unique(D.rows(payload["targets"], maximum: 64).map {
            let row = try D.object($0)
            guard let home = row["home_target_set"]?.boolean else { throw WorkspaceClientError.invalidResponse }
            return try .init(id: D.text(row["id"], maximum: 512),
                name: D.text(row["name"], maximum: 160), homeTargetSet: home)
        })
    }
}
