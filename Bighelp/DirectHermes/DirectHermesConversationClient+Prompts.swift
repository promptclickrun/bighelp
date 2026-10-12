import Foundation

/// Negotiated server requests and native legacy-event approval/clarification compatibility.
extension DirectHermesConversationClient {
    func restoredLegacyPrompts(
        from snapshot: [String: BighelpJSONValue]
    ) throws -> [DirectHermesPrompt] {
        var restored: [DirectHermesPrompt] = []
        for (field, eventType) in [
            ("pending_approval", "approval.request"),
            ("pending_clarify", "clarify.request"),
        ] {
            guard let value = snapshot[field] else { continue }
            guard let payload = value.object else { throw DirectHermesError.invalidResponse }
            restored.append(try DirectHermesPrompt.legacy(
                eventType: eventType, payload: payload,
                hostIdentity: promptHostIdentity, profile: profile,
                runtimeSessionID: runtimeID, visibleSessionID: conversationID
            ))
        }
        return restored
    }

    func acceptLegacyPromptEvent(_ event: DirectHermesEvent) {
        do { try applyLegacyPromptEvent(event) }
        catch {
            // A malformed optional event is not authority to suspend a working
            // session. Authoritative recovery remains strict and will reject it.
        }
    }

    func applyLegacyPromptEvent(_ event: DirectHermesEvent) throws {
        guard promptContract == .legacyEvents,
              event.sessionID.map({ Data($0.utf8) == Data(runtimeID.utf8) }) ?? true else { return }
        switch event.type {
        case "approval.request", "clarify.request":
            let prompt = try DirectHermesPrompt.legacy(
                eventType: event.type, payload: event.payload,
                hostIdentity: promptHostIdentity, profile: profile,
                runtimeSessionID: runtimeID, visibleSessionID: conversationID
            )
            let key = DirectHermesLegacyPromptKey(wireID: prompt.wireID, method: prompt.method)
            if let previous = legacyPrompts[key] {
                let replacement = try DirectHermesPrompt.legacy(
                    eventType: event.type, payload: event.payload,
                    hostIdentity: promptHostIdentity, profile: profile,
                    runtimeSessionID: runtimeID, visibleSessionID: conversationID,
                    createdAt: previous.createdAt
                )
                legacyPrompts[key] = replacement
            } else {
                guard legacyPrompts.count < 64 else { throw DirectHermesError.invalidResponse }
                legacyPrompts[key] = prompt
            }
            try publishLegacyPrompts()
        case "clarify.expire":
            guard let wireID = event.payload["request_id"]?.string,
                  !wireID.isEmpty, wireID.utf8.count <= 4_096 else {
                throw DirectHermesError.invalidResponse
            }
            legacyPrompts.removeValue(forKey: DirectHermesLegacyPromptKey(
                wireID: wireID, method: "clarify"
            ))
            try publishLegacyPrompts()
        default:
            return
        }
    }

    func setPromptContract(
        _ contract: DirectHermesPromptContract,
        legacy prompts: [DirectHermesPrompt]
    ) throws {
        var indexed: [DirectHermesLegacyPromptKey: DirectHermesPrompt] = [:]
        for prompt in prompts {
            let key = DirectHermesLegacyPromptKey(wireID: prompt.wireID, method: prompt.method)
            guard indexed.updateValue(prompt, forKey: key) == nil else {
                throw DirectHermesError.invalidResponse
            }
        }
        try promptStore?.setContract(
            contract, legacy: prompts, hostIdentity: promptHostIdentity,
            profile: profile, runtimeID: runtimeID, visibleSessionID: conversationID
        )
        legacyPrompts = indexed
        promptContract = contract
    }

    private func publishLegacyPrompts() throws {
        guard promptContract == .legacyEvents else { return }
        try promptStore?.setContract(
            .legacyEvents, legacy: Array(legacyPrompts.values),
            hostIdentity: promptHostIdentity, profile: profile,
            runtimeID: runtimeID, visibleSessionID: conversationID
        )
    }

    private func removeLegacyPrompt(_ prompt: DirectHermesPrompt) {
        guard prompt.origin == .legacyEvent else { return }
        legacyPrompts.removeValue(forKey: DirectHermesLegacyPromptKey(
            wireID: prompt.wireID, method: prompt.method
        ))
        try? publishLegacyPrompts()
    }

    func clearConfirmedLegacyPrompts() {
        guard promptContract == .legacyEvents else { return }
        legacyPrompts.removeAll(keepingCapacity: true)
        try? publishLegacyPrompts()
    }

    func resetPromptContract() {
        legacyPrompts.removeAll(keepingCapacity: false)
        legacyMutations.removeAll(keepingCapacity: false)
        promptContract = .unknown
        try? promptStore?.setContract(
            .unknown, legacy: [], hostIdentity: promptHostIdentity,
            profile: profile, runtimeID: runtimeID, visibleSessionID: conversationID
        )
    }

    func respond(to prompt: DirectHermesPrompt, decision: ApprovalDecision) async throws {
        try validate(conversationID)
        let current = try currentPrompt(matching: prompt)
        guard current.kind == .approval,
              current.approval?.choices.contains(decision) == true else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        switch current.origin {
        case .serverRequest:
            guard let promptStore else { throw DirectHermesWorkspaceError.expiredPrompt }
            try promptStore.answerApproval(current, decision: decision)
        case .legacyEvent:
            try await respondToLegacyApproval(current, decision: decision)
        }
    }

    func respond(to prompt: DirectHermesPrompt, value: String) async throws {
        try validate(conversationID)
        let current = try currentPrompt(matching: prompt)
        switch current.kind {
        case .approval:
            guard let decision = ApprovalDecision(rawValue: value) else {
                throw DirectHermesWorkspaceError.expiredPrompt
            }
            try await respond(to: current, decision: decision)
        case .clarification:
            switch current.origin {
            case .serverRequest:
                guard let promptStore else { throw DirectHermesWorkspaceError.expiredPrompt }
                try promptStore.answerClarification(current, answer: value)
            case .legacyEvent:
                try await respondToLegacyClarification(current, answer: value)
            }
        }
    }

    func respond(
        to prompt: DirectHermesPrompt,
        response: DashboardClarificationResponse
    ) async throws {
        try validate(conversationID)
        let current = try currentPrompt(matching: prompt)
        guard current.kind == .clarification,
              let clarification = current.clarification,
              response.answers.count == clarification.questions.count else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        var answers: [String: String] = [:]
        for question in clarification.questions {
            let matches = response.answers.filter {
                Data($0.questionID.utf8) == Data(question.id.utf8)
            }
            guard matches.count == 1, let answer = matches.first?.value,
                  answers.updateValue(answer, forKey: question.id) == nil else {
                throw DirectHermesWorkspaceError.expiredPrompt
            }
        }
        if clarification.isBatch {
            try await respond(to: current, answers: answers)
        } else if let question = clarification.questions.first,
                  let answer = answers[question.id] {
            try await respond(to: current, value: answer)
        } else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
    }

    func respond(to prompt: DirectHermesPrompt, answers: [String: String]) async throws {
        try validate(conversationID)
        let current = try currentPrompt(matching: prompt)
        guard current.kind == .clarification else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        switch current.origin {
        case .serverRequest:
            guard let promptStore else { throw DirectHermesWorkspaceError.expiredPrompt }
            try promptStore.answerClarification(current, answers: answers)
        case .legacyEvent:
            try await respondToLegacyClarification(current, answers: answers)
        }
    }

    func cancel(_ prompt: DirectHermesPrompt) async throws {
        try validate(conversationID)
        let current = try currentPrompt(matching: prompt)
        switch current.origin {
        case .serverRequest:
            guard let promptStore else { throw DirectHermesWorkspaceError.expiredPrompt }
            try promptStore.cancel(current)
        case .legacyEvent:
            try await cancelLegacyPrompt(current)
        }
    }

    private func currentPrompt(matching candidate: DirectHermesPrompt) throws -> DirectHermesPrompt {
        let candidateID = Data(candidate.id.utf8)
        let matches = prompts.filter { prompt in
            Data(prompt.id.utf8) == candidateID
                && prompt.origin == candidate.origin
                && Data(prompt.wireID.utf8) == Data(candidate.wireID.utf8)
                && prompt.method == candidate.method
                && Data(prompt.hostIdentity.utf8) == Data(promptHostIdentity.utf8)
                && Data(prompt.profile.utf8) == Data(profile.utf8)
                && Data(prompt.runtimeSessionID.utf8) == Data(runtimeID.utf8)
                && Data(prompt.visibleSessionID.utf8) == Data(conversationID.utf8)
        }
        guard matches.count == 1, let current = matches.first else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        if current.origin == .legacyEvent, needsRecovery {
            throw DirectHermesWorkspaceError.reviewRequired
        }
        return current
    }

    private func respondToLegacyApproval(
        _ prompt: DirectHermesPrompt,
        decision: ApprovalDecision
    ) async throws {
        var params = sessionParams
        params["request_id"] = .string(prompt.wireID)
        params["choice"] = .string(decision.rawValue)
        params["all"] = .boolean(false)
        let result = try await requestLegacyMutation("approval.respond", params: params, prompt: prompt)
        guard let resolved = result.object?["resolved"]?.integer, resolved >= 0 else {
            markLegacyMutationUnknown()
            throw DirectHermesError.invalidResponse
        }
        guard resolved > 0 else {
            removeLegacyPrompt(prompt)
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        removeLegacyPrompt(prompt)
    }

    private func respondToLegacyClarification(
        _ prompt: DirectHermesPrompt,
        answer: String
    ) async throws {
        guard let clarification = prompt.clarification,
              !clarification.isBatch,
              let question = clarification.questions.first else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        let validated = try DirectHermesPromptStore.validatedAnswer(answer, for: question)
        var params = sessionParams
        params["request_id"] = .string(prompt.wireID)
        params["answer"] = .string(validated)
        let result = try await requestLegacyMutation("clarify.respond", params: params, prompt: prompt)
        try finishLegacyClarification(prompt, result: result)
    }

    private func respondToLegacyClarification(
        _ prompt: DirectHermesPrompt,
        answers: [String: String]
    ) async throws {
        guard let clarification = prompt.clarification, clarification.isBatch,
              answers.count == clarification.questions.count else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        var unlocked: [(DirectHermesPrompt.Question, String)] = []
        for question in clarification.questions {
            let exactAnswers = answers.filter { Data($0.key.utf8) == Data(question.id.utf8) }
            guard exactAnswers.count == 1, let answer = exactAnswers.first?.value else {
                throw DirectHermesWorkspaceError.expiredPrompt
            }
            if let locked = question.lockedAnswer {
                guard Data(answer.utf8) == Data(locked.utf8) else {
                    throw DirectHermesWorkspaceError.expiredPrompt
                }
            } else {
                unlocked.append((question, try DirectHermesPromptStore.validatedAnswer(answer, for: question)))
            }
        }
        if unlocked.isEmpty {
            removeLegacyPrompt(prompt)
            return
        }
        for (offset, entry) in unlocked.enumerated() {
            let current = try currentPrompt(matching: prompt)
            var params = sessionParams
            params["request_id"] = .string(current.wireID)
            params["question_id"] = .string(entry.0.id)
            params["answer"] = .string(entry.1)
            let result = try await requestLegacyMutation("clarify.respond", params: params, prompt: current)
            guard result.object?["status"]?.string == "ok" else {
                if result.object?["status"]?.string == "expired" {
                    removeLegacyPrompt(current)
                    throw DirectHermesWorkspaceError.expiredPrompt
                }
                markLegacyMutationUnknown()
                throw DirectHermesError.invalidResponse
            }
            try lockLegacyAnswer(entry.1, questionID: entry.0.id, prompt: current)
            guard let remaining = result.object?["remaining"]?.array,
                  remaining.allSatisfy({ $0.string != nil }) else {
                markLegacyMutationUnknown()
                throw DirectHermesError.invalidResponse
            }
            let expected = unlocked.dropFirst(offset + 1).map { Data($0.0.id.utf8) }
            let returned = remaining.compactMap { $0.string.map { Data($0.utf8) } }
            guard returned == expected else {
                markLegacyMutationUnknown()
                throw DirectHermesError.invalidResponse
            }
        }
        removeLegacyPrompt(prompt)
    }

    private func cancelLegacyPrompt(_ prompt: DirectHermesPrompt) async throws {
        switch prompt.kind {
        case .approval:
            try await respondToLegacyApproval(prompt, decision: .deny)
        case .clarification:
            var params = sessionParams
            params["request_id"] = .string(prompt.wireID)
            params["answer"] = .string("")
            let result = try await requestLegacyMutation("clarify.respond", params: params, prompt: prompt)
            try finishLegacyClarification(prompt, result: result)
        }
    }

    private func finishLegacyClarification(
        _ prompt: DirectHermesPrompt,
        result: BighelpJSONValue
    ) throws {
        switch result.object?["status"]?.string {
        case "ok":
            removeLegacyPrompt(prompt)
        case "expired":
            removeLegacyPrompt(prompt)
            throw DirectHermesWorkspaceError.expiredPrompt
        default:
            markLegacyMutationUnknown()
            throw DirectHermesError.invalidResponse
        }
    }

    private func requestLegacyMutation(
        _ method: String,
        params: [String: BighelpJSONValue],
        prompt: DirectHermesPrompt
    ) async throws -> BighelpJSONValue {
        try Task.checkCancellation()
        let key = DirectHermesLegacyPromptKey(wireID: prompt.wireID, method: prompt.method)
        guard legacyMutations[key] == nil else { throw DirectHermesWorkspaceError.reviewRequired }
        let mutation = UUID()
        legacyMutations[key] = mutation
        defer {
            if legacyMutations[key] == mutation { legacyMutations[key] = nil }
        }
        let owner = generation
        do {
            let result = try await rpc.request(method, params: params)
            guard connected, generation == owner else {
                throw DirectHermesError.disconnected(outcomeUnknown: true)
            }
            return result
        } catch {
            guard generation == owner else { throw error }
            if let direct = error as? DirectHermesError,
               case .rpcRejected(let code, _) = direct, code == 4009 {
                removeLegacyPrompt(prompt)
                throw DirectHermesWorkspaceError.expiredPrompt
            }
            markLegacyMutationUnknown()
            throw error
        }
    }

    private func markLegacyMutationUnknown() {
        needsRecovery = true
        status = "Hermes may have received that response. Reopen to reconcile it; nothing was resent."
    }

    private func lockLegacyAnswer(
        _ answer: String,
        questionID: String,
        prompt: DirectHermesPrompt
    ) throws {
        var payload = prompt.payload
        var locked = payload["answers"]?.object ?? [:]
        locked[questionID] = .string(answer)
        payload["answers"] = .object(locked)
        payload["request_id"] = .string(prompt.wireID)
        let replacement = try DirectHermesPrompt.legacy(
            eventType: "clarify.request", payload: payload,
            hostIdentity: promptHostIdentity, profile: profile,
            runtimeSessionID: runtimeID, visibleSessionID: conversationID,
            createdAt: prompt.createdAt
        )
        legacyPrompts[DirectHermesLegacyPromptKey(wireID: prompt.wireID, method: prompt.method)] = replacement
        try publishLegacyPrompts()
    }
}
