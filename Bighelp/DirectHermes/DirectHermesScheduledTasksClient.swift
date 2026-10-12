import Foundation

@MainActor
final class DirectHermesScheduledTasksClient: ScheduledTasksClient {
    private let scope: DirectHermesCoreRequestScope
    private let servingProfileID: String?
    private let http: (any DirectHermesAuthenticatedHTTP)?
    private var blueprintCatalog: [String: ScheduledTaskBlueprint] = [:]

    init(
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        servingProfileID: String? = nil,
        http: (any DirectHermesAuthenticatedHTTP)? = nil
    ) {
        scope = .init(workspace: workspace, owner: owner, currentOwner: currentOwner)
        self.servingProfileID = servingProfileID
        self.http = http
    }

    func list(agentID: String?) async throws -> [ScheduledTask] {
        if let agentID { return try await listProfile(DirectHermesCoreRequestScope.profile(agentID)) }
        let catalog = try await scope.perform(.profilesList, ["include_sessions": .boolean(false)])
        let names = try WorkspaceManagementDecoder.rows(catalog["profiles"], maximum: 128).map {
            try DirectHermesCoreRequestScope.profile(WorkspaceManagementDecoder.text(
                WorkspaceManagementDecoder.object($0)["name"], maximum: 128
            ))
        }
        guard Set(names).count == names.count else { throw WorkspaceClientError.invalidResponse }
        var tasks: [ScheduledTask] = []
        // The native "all" endpoint suppresses individual profile failures. Separate reads
        // preserve an honest all-or-error catalog with this client's existing return type.
        for profile in names {
            tasks += try await listProfile(profile)
            guard tasks.count <= 500 else { throw WorkspaceClientError.capacityExceeded }
        }
        guard Set(tasks.map(\.identity)).count == tasks.count else { throw ScheduledTasksError.invalidCatalog }
        return tasks
    }

    func detail(id: String, agentID: String) async throws -> ScheduledTask {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let id = try DirectHermesCoreRequestScope.identifier(id)
        try scope.require(.schedulesRead, profile: profile)
        let response = try await request(.init(
            path: "/api/cron/jobs/\(Self.pathComponent(id))",
            method: .get,
            query: [.init(name: "profile", value: profile)],
            maximumResponseBytes: 524_288
        ))
        let row = try WorkspaceManagementDecoder.object(response)
        var task = try DirectHermesScheduledTaskCodec.task(response, profile: profile)
        guard task.id.utf8.elementsEqual(id.utf8) else { throw WorkspaceClientError.invalidResponse }
        task.lastRun = try DirectHermesScheduledTaskCodec.date(row["last_run_at"])
        task.lastError = try WorkspaceManagementDecoder.optionalText(row["last_error"], maximum: 8_192)
        task.model = try WorkspaceManagementDecoder.optionalText(row["model"], maximum: 512)
        task.provider = try WorkspaceManagementDecoder.optionalText(row["provider"], maximum: 256)
        return task
    }

    func runs(id: String, agentID: String, limit: Int = 20) async throws -> [ScheduledTaskRun] {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let id = try DirectHermesCoreRequestScope.identifier(id)
        guard (1...100).contains(limit) else { throw WorkspaceClientError.invalidRequest }
        try scope.require(.schedulesRead, profile: profile)
        let response = try await request(.init(
            path: "/api/cron/jobs/\(Self.pathComponent(id))/runs",
            method: .get,
            query: [
                .init(name: "profile", value: profile),
                .init(name: "limit", value: String(limit)),
            ],
            maximumResponseBytes: 1_048_576
        ))
        return try Self.runs(response, jobID: id, profile: profile, requestedLimit: limit)
    }

    func blueprints() async throws -> [ScheduledTaskBlueprint] {
        let response = try await request(.init(
            path: "/api/cron/blueprints",
            method: .get,
            maximumResponseBytes: 1_048_576
        ))
        let blueprints = try Self.blueprints(response)
        blueprintCatalog = Dictionary(uniqueKeysWithValues: blueprints.map { ($0.key, $0) })
        return blueprints
    }

    func instantiate(
        _ blueprint: ScheduledTaskBlueprint,
        values: [String: String],
        agentID: String
    ) async throws -> ScheduledTask {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let key = try DirectHermesCoreRequestScope.identifier(blueprint.key, maximum: 160)
        guard blueprintCatalog[key] == blueprint,
              Set(blueprint.fields.map(\.name)).count == blueprint.fields.count else {
            throw ScheduledTasksError.invalidBlueprint
        }
        let values = try blueprint.validatedValues(values)
        let encodedValues = values.mapValues(BighelpJSONValue.string)
        guard try JSONEncoder().encode(encodedValues).count <= 65_536 else {
            throw WorkspaceClientError.capacityExceeded
        }
        try scope.require(.schedulesEdit, profile: profile)
        let receiptValue = try await request(.init(
            path: "/api/cron/blueprints/instantiate",
            method: .post,
            query: [.init(name: "profile", value: profile)],
            body: ["blueprint": .string(key), "values": .object(encodedValues)],
            maximumResponseBytes: 524_288
        ))
        let receipt = try DirectHermesScheduledTaskCodec.task(receiptValue, profile: profile)
        try scope.check()
        let readback = try await detail(id: receipt.id, agentID: profile)
        guard readback.identity == receipt.identity else { throw WorkspaceClientError.outcomeUnknown }
        return readback
    }

    func deliveryTargets() async throws -> [ScheduledTaskDeliveryTarget] {
        try DirectHermesScheduledTaskCodec.deliveryTargets(await scope.perform(.scheduledTaskDeliveryTargets, [:]))
    }

    func create(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask {
        let profile = try DirectHermesCoreRequestScope.profile(draft.agentID)
        try scope.require(.schedulesEdit, profile: profile)
        let fields = try await fields(name: draft.name, instructions: draft.instructions,
            schedule: draft.schedule, delivery: draft.deliveryTarget, profile: profile)
        try scope.require(.schedulesEdit, profile: profile)
        let response = try await scope.perform(.scheduledTaskCreate, fields.merging(["profile": .string(profile)]) { _, new in new })
        return try confirmed(response, profile: profile, id: nil, fields: fields)
    }

    func update(id: String, agentID: String, changes: ScheduledTaskChanges) async throws -> ScheduledTask {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let id = try DirectHermesCoreRequestScope.identifier(id)
        try scope.require(.schedulesEdit, profile: profile)
        let fields = try await fields(name: changes.name, instructions: changes.instructions,
            schedule: changes.schedule, delivery: changes.deliveryTarget, profile: profile)
        try scope.require(.schedulesEdit, profile: profile)
        let response = try await scope.perform(.scheduledTaskUpdate, [
            "profile": .string(profile), "id": .string(id), "updates": .object(fields)
        ])
        return try confirmed(response, profile: profile, id: id, fields: fields)
    }

    func setPaused(_ paused: Bool, id: String, agentID: String) async throws -> ScheduledTask {
        let task = try await mutate(paused ? .scheduledTaskPause : .scheduledTaskResume, id: id, profile: agentID, capability: .schedulesEdit)
        guard task.status == (paused ? .paused : .active) else { throw WorkspaceClientError.outcomeUnknown }
        return task
    }

    func runNow(id: String, agentID: String) async throws -> ScheduledTask {
        // Hermes may atomically resume a paused task. Return its actual current/terminal
        // state; a run request does not synthesize a successful final result.
        try await mutate(.scheduledTaskRun, id: id, profile: agentID, capability: .schedulesRun)
    }

    func delete(id: String, agentID: String) async throws {
        let profile = try DirectHermesCoreRequestScope.profile(agentID)
        let id = try DirectHermesCoreRequestScope.identifier(id)
        try scope.require(.schedulesEdit, profile: profile)
        let result = try await scope.perform(.scheduledTaskDelete, ["profile": .string(profile), "id": .string(id)])
        guard result["ok"]?.boolean == true else { throw WorkspaceClientError.outcomeUnknown }
        let remaining = try await listProfile(profile)
        guard !remaining.contains(where: { $0.id.utf8.elementsEqual(id.utf8) }) else { throw WorkspaceClientError.outcomeUnknown }
    }

    private func listProfile(_ profile: String) async throws -> [ScheduledTask] {
        try DirectHermesScheduledTaskCodec.tasks(
            await scope.perform(.scheduledTasksList, ["profile": .string(profile)]), profile: profile
        )
    }

    private func fields(name: String, instructions: String, schedule: ScheduleInput,
                        delivery: String, profile: String) async throws -> [String: BighelpJSONValue] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try WorkspaceManagementDecoder.text(.string(name), maximum: 240)
        _ = try WorkspaceManagementDecoder.text(.string(instructions), maximum: 256_000)
        let request = try ScheduleRequestBuilder.hermesRequest(for: schedule)
        _ = try WorkspaceManagementDecoder.text(.string(request), maximum: 2_048)
        let targets = try await deliveryTargets()
        let target = try ScheduledTaskDeliverySelection.resolve(
            selectedID: delivery.contains(":") ? ScheduledTaskDeliverySelection.manualID : delivery,
            manualValue: delivery, targets: targets
        )
        if target != "local", !target.contains(":"), servingProfileID != profile {
            throw WorkspaceClientError.unavailable(.identityContextUnavailable)
        }
        return ["name": .string(name), "prompt": .string(instructions), "schedule": .string(request), "deliver": .string(target)]
    }

    private func mutate(_ operation: WorkspaceOperation, id: String, profile: String,
                        capability: WorkspaceCapability) async throws -> ScheduledTask {
        let profile = try DirectHermesCoreRequestScope.profile(profile)
        let id = try DirectHermesCoreRequestScope.identifier(id)
        try scope.require(capability, profile: profile)
        let result = try await scope.perform(operation, ["profile": .string(profile), "id": .string(id)])
        let task = try DirectHermesScheduledTaskCodec.task(.object(result), profile: profile)
        guard task.id.utf8.elementsEqual(id.utf8) else { throw WorkspaceClientError.outcomeUnknown }
        return task
    }

    private func confirmed(_ response: [String: BighelpJSONValue], profile: String, id: String?,
                           fields: [String: BighelpJSONValue]) throws -> ScheduledTask {
        let task = try DirectHermesScheduledTaskCodec.task(.object(response), profile: profile)
        if let id, !task.id.utf8.elementsEqual(id.utf8) { throw WorkspaceClientError.outcomeUnknown }
        guard let name = fields["name"]?.string, task.name.utf8.elementsEqual(name.utf8),
              let prompt = fields["prompt"]?.string, task.instructions.utf8.elementsEqual(prompt.utf8),
              let deliver = fields["deliver"]?.string, task.deliveryTarget.utf8.elementsEqual(deliver.utf8),
              let request = fields["schedule"]?.string,
              DirectHermesScheduledTaskCodec.matches(task, request: request) else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return task
    }

    private func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        guard let http else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
        try scope.check()
        if let body = request.body,
           try JSONEncoder().encode(BighelpJSONValue.object(body)).count > 524_288 {
            throw WorkspaceClientError.capacityExceeded
        }
        do {
            let response = try await http.request(request)
            try scope.check()
            guard try JSONEncoder().encode(response).count <= request.maximumResponseBytes else {
                throw WorkspaceClientError.capacityExceeded
            }
            return response
        } catch {
            do { try scope.check() } catch { throw error }
            throw Self.safeError(error)
        }
    }

    private static func runs(
        _ value: BighelpJSONValue,
        jobID: String,
        profile: String,
        requestedLimit: Int
    ) throws -> [ScheduledTaskRun] {
        typealias D = WorkspaceManagementDecoder
        let payload = try D.object(value)
        guard payload["limit"]?.integer == requestedLimit else { throw WorkspaceClientError.invalidResponse }
        let rows = try D.rows(payload["runs"], maximum: requestedLimit)
        var ids = Set<String>()
        return try rows.map { value in
            let row = try D.object(value)
            let id = try D.text(row["id"], maximum: 240)
            let rowProfile = try D.text(row["profile"], maximum: 128)
            guard rowProfile.utf8.elementsEqual(profile.utf8),
                  row["source"]?.string == "cron",
                  id.hasPrefix("cron_\(jobID)_"),
                  ids.insert(id).inserted,
                  let startedAt = try DirectHermesScheduledTaskCodec.date(row["started_at"]),
                  let lastActiveAt = try DirectHermesScheduledTaskCodec.date(row["last_active"]),
                  let isActive = row["is_active"]?.boolean,
                  let archived = row["archived"]?.boolean,
                  let messageCount = row["message_count"]?.integer, messageCount >= 0,
                  let toolCallCount = row["tool_call_count"]?.integer, toolCallCount >= 0 else {
                throw WorkspaceClientError.invalidResponse
            }
            return ScheduledTaskRun(
                id: id,
                agentID: rowProfile,
                title: try D.optionalText(row["title"], maximum: 240),
                preview: try D.optionalText(row["preview"], maximum: 8_192),
                startedAt: startedAt,
                lastActiveAt: lastActiveAt,
                endedAt: try DirectHermesScheduledTaskCodec.date(row["ended_at"]),
                isActive: isActive,
                isArchived: archived,
                model: try D.optionalText(row["model"], maximum: 512),
                messageCount: messageCount,
                toolCallCount: toolCallCount
            )
        }
    }

    private static func blueprints(_ value: BighelpJSONValue) throws -> [ScheduledTaskBlueprint] {
        typealias D = WorkspaceManagementDecoder
        let payload = try D.object(value)
        let rows = try D.rows(payload["blueprints"], maximum: 128)
        var keys = Set<String>()
        return try rows.map { value in
            let row = try D.object(value)
            let key = try DirectHermesCoreRequestScope.identifier(D.text(row["key"], maximum: 160))
            guard keys.insert(key).inserted else { throw WorkspaceClientError.invalidResponse }
            let fieldRows = try D.rows(row["fields"], maximum: 64)
            var fieldNames = Set<String>()
            let fields = try fieldRows.map { fieldValue in
                let field = try D.object(fieldValue)
                let name = try DirectHermesCoreRequestScope.identifier(D.text(field["name"], maximum: 160))
                guard fieldNames.insert(name).inserted,
                      let rawKind = field["type"]?.string,
                      let kind = ScheduledTaskBlueprintFieldKind(rawValue: rawKind),
                      let isOptional = field["optional"]?.boolean,
                      let isStrict = field["strict"]?.boolean else {
                    throw WorkspaceClientError.invalidResponse
                }
                let optionRows = try D.rows(field["options"], maximum: 128)
                let options = try optionRows.map { try D.text($0, maximum: 1_024) }
                guard Set(options).count == options.count else { throw WorkspaceClientError.invalidResponse }
                return ScheduledTaskBlueprintField(
                    name: name,
                    kind: kind,
                    label: try D.text(field["label"], maximum: 240),
                    defaultValue: try D.optionalText(field["default"], maximum: 8_192),
                    options: options,
                    isOptional: isOptional,
                    isStrict: isStrict,
                    help: try D.text(field["help"], maximum: 2_048, empty: true)
                )
            }
            let tags = try D.rows(row["tags"], maximum: 64).map { try D.text($0, maximum: 160) }
            guard Set(tags).count == tags.count else { throw WorkspaceClientError.invalidResponse }
            return ScheduledTaskBlueprint(
                key: key,
                title: try D.text(row["title"], maximum: 240),
                summary: try D.text(row["description"], maximum: 4_096, empty: true),
                category: try D.text(row["category"], maximum: 160),
                tags: tags,
                fields: fields,
                scheduleDescription: try D.text(row["scheduleHuman"], maximum: 512)
            )
        }
    }

    private static func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func safeError(_ error: any Error) -> any Error {
        if error is CancellationError || error is WorkspaceClientError || error is ScheduledTasksError {
            return error
        }
        guard let direct = error as? DirectHermesError else { return WorkspaceClientError.transportUnavailable }
        if direct.outcomeIsUnknown { return WorkspaceClientError.outcomeUnknown }
        switch direct {
        case .invalidCredentials, .authenticationRequired: return WorkspaceClientError.authenticationRequired
        case .rpcRejected(let code, _) where code == -32601: return WorkspaceClientError.unavailable(.unsupportedOperation)
        case .rpcRejected(_, let message): return WorkspaceClientError.rejected(code: nil, message: message)
        case .invalidResponse: return WorkspaceClientError.invalidResponse
        case .messageTooLarge, .tooManyRequests: return WorkspaceClientError.capacityExceeded
        default: return WorkspaceClientError.transportUnavailable
        }
    }
}
