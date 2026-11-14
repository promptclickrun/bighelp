import Foundation
import SwiftUI

struct NativeSessionUsageView: View {
    let usage: DirectHermesSessionUsage

    var body: some View {
        DisclosureGroup("Usage") {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                value("Model", usage.model)
                value("Input tokens", usage.input.formatted())
                value("Output tokens", usage.output.formatted())
                value("Reasoning tokens", usage.reasoning.formatted())
                value("Prompt tokens", usage.prompt.formatted())
                value("Completion tokens", usage.completion.formatted())
                value("Total tokens", usage.total.formatted())
                value("Calls", usage.calls.formatted())
                optionalValue("Compressions", usage.compressions?.formatted())
                optionalValue("Context used", usage.contextUsed?.formatted())
                optionalValue("Context maximum", usage.contextMax?.formatted())
                optionalValue("Context percent", usage.contextPercent.map { "\($0)%" })
                optionalValue("Context source", usage.contextSource)
                optionalValue("Context estimate", usage.contextEstimated.map { $0 ? "Estimated" : "Measured" })
                optionalValue("Cache hit", usage.cacheHitPercent.map { "\($0)%" })
                optionalValue("Cache read", usage.cacheRead?.formatted())
                optionalValue("Cache write", usage.cacheWrite?.formatted())
                optionalValue("Average latency", usage.averageLatencySeconds.map { "\(decimal($0)) seconds" })
                optionalValue("Average speed", usage.averageTokensPerSecond.map { "\(decimal($0)) tokens/second" })
                optionalValue("Active subagents", usage.activeSubagents?.formatted())
                optionalValue("Developer credits spent", usage.developerCreditsSpentMicros.map { "\($0.formatted()) micros" })
                optionalValue("Cost (USD)", usage.costUSD.map(decimal))
                optionalValue("Cost status", usage.costStatus)
                if let lines = usage.creditLines {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        value("Credit \(index + 1)", line)
                    }
                }
            }
            .padding(.top, BighelpTokens.space8)
        }
    }

    private func value(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func optionalValue(_ label: String, _ value: String?) -> some View {
        if let value {
            self.value(label, value)
        }
    }

    private func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(1...12)))
    }
}

struct NativeSessionCompressionResultView: View {
    let result: DirectHermesCompressionResult

    var body: some View {
        DisclosureGroup("Last compression result") {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                optionalValue("Status", result.status)
                optionalValue("Removed", result.removed?.formatted())
                optionalValue("Messages before", result.beforeMessages?.formatted())
                optionalValue("Messages after", result.afterMessages?.formatted())
                optionalValue("Tokens before", result.beforeTokens?.formatted())
                optionalValue("Tokens after", result.afterTokens?.formatted())
                optionalValue("Compressed", result.compressed.map { $0 ? "Yes" : "No" })
                optionalValue("Message", result.message)
                LabeledContent("Readback", value: result.readback == nil ? "Unavailable" : "Received")
            }
            .padding(.top, BighelpTokens.space8)
        }
    }

    @ViewBuilder
    private func optionalValue(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label) {
                Text(value).textSelection(.enabled)
            }
        }
    }
}

struct NativeSessionControlSnapshotView: View {
    let snapshot: DirectHermesSessionControlSnapshot

    var body: some View {
        DisclosureGroup("Current control state") {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                LabeledContent("Revision", value: snapshot.revision)
                    .textSelection(.enabled)
                LabeledContent("Updated") {
                    Text(updatedText)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                component("Goal", snapshot.goal)
                component("Loop", snapshot.loop)
                component("Heartbeat", snapshot.heartbeat)
            }
            .padding(.top, BighelpTokens.space8)
        }
    }

    @ViewBuilder
    private func component(_ title: String, _ component: DirectHermesSessionControlComponent?) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text(title)
                .font(.bighelp(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
            if let component {
                NativeSessionControlFieldsView(fields: component.fields)
            } else {
                Text("Not set")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var updatedText: String {
        let raw = snapshot.updatedAt.formatted(.number.precision(.significantDigits(1...15)))
        let date = Date(timeIntervalSince1970: snapshot.updatedAt)
        return "\(date.formatted(date: .abbreviated, time: .standard)) · \(raw)"
    }
}

struct NativeSessionControlFieldsView: View {
    let fields: [String: BighelpJSONValue]

    var body: some View {
        if fields.isEmpty {
            Text("No fields")
                .foregroundStyle(.secondary)
        } else {
            ForEach(fields.keys.sorted(), id: \.self) { key in
                if let value = fields[key] {
                    LabeledContent(key.replacingOccurrences(of: "_", with: " ").capitalized) {
                        Text(NativeSessionReadOnlyFormatting.text(value))
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct NativeSessionControlDispatchView: View {
    let dispatch: DirectHermesSessionControlDispatch

    var body: some View {
        DisclosureGroup("Last control dispatch") {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                optionalValue("Type", dispatch.type)
                optionalValue("Display", dispatch.display)
                optionalValue("Message", dispatch.message)
                optionalValue("Notice", dispatch.notice)
                optionalValue("Output", dispatch.output)
                if dispatch.continuation != .notRequired {
                    LabeledContent("Continuation", value: dispatch.continuation.label)
                }
            }
            .padding(.top, BighelpTokens.space8)
        }
    }

    @ViewBuilder
    private func optionalValue(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }
}

struct NativeSessionRollbackCheckpointRow: View {
    let checkpoint: DirectHermesRollbackCheckpoint

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(checkpoint.message.isEmpty ? "Rollback checkpoint" : checkpoint.message)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !checkpoint.timestamp.isEmpty {
                    Text(checkpoint.timestamp)
                        .font(.bighelp(.caption))
                        .foregroundStyle(.secondary)
                }
                Text(checkpoint.hash)
                    .font(.bighelp(.caption).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: BighelpTokens.space8)
            Image(systemName: "chevron.right")
                .font(.bighelp(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(checkpoint.message.isEmpty ? "Rollback checkpoint" : checkpoint.message)
        .accessibilityValue([checkpoint.timestamp, checkpoint.hash].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

struct NativeSessionRollbackRestoreResultView: View {
    let result: DirectHermesRollbackRestoreResult

    var body: some View {
        DisclosureGroup("Last restore result") {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                LabeledContent("Success", value: result.success ? "Yes" : "No")
                optionalValue("Restored to", result.restoredTo)
                optionalValue("Reason", result.reason)
                optionalValue("Directory", result.directory)
                optionalValue("File", result.file)
                optionalValue("History removed", result.historyRemoved?.formatted())
                optionalValue("Error", result.error)
                stringList("Restored files", result.restoredFiles)
                stringList("Skipped user edits", result.skippedUserEdits)
                stringList("Skipped oversized files", result.skippedOversize)
                stringList("Failed deletes", result.failedDeletes)
                LabeledContent("Readback", value: result.readback == nil ? "Unavailable" : "Received")
            }
            .padding(.top, BighelpTokens.space8)
        }
    }

    @ViewBuilder
    private func optionalValue(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label) { Text(value).textSelection(.enabled) }
        }
    }

    @ViewBuilder
    private func stringList(_ title: String, _ values: [String]?) -> some View {
        if let values {
            DisclosureGroup("\(title) (\(values.count))") {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .font(.bighelp(.caption).monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct NativeSessionDelegationRow: View {
    let delegation: DirectHermesActiveDelegation

    var body: some View {
        DisclosureGroup(delegation.goal ?? delegation.id) {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                value("Subagent ID", delegation.id)
                optionalValue("Parent ID", delegation.parentID)
                optionalValue("Child chat ID", delegation.childSessionID)
                optionalValue("Delegation ID", delegation.delegationID)
                optionalValue("Depth", delegation.depth?.formatted())
                optionalValue("Goal", delegation.goal)
                optionalValue("Model", delegation.model)
                optionalValue("Status", delegation.status)
            }
            .padding(.top, BighelpTokens.space8)
        }
    }

    private func value(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).textSelection(.enabled) }
    }

    @ViewBuilder
    private func optionalValue(_ label: String, _ value: String?) -> some View {
        if let value { self.value(label, value) }
    }
}

struct NativeSessionSpawnTreeRow: View {
    let entry: DirectHermesSpawnTreeEntry

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(entry.label.isEmpty ? "Spawn tree" : entry.label)
                    .foregroundStyle(.primary)
                Text("\(entry.count.formatted()) helpers")
                    .font(.bighelp(.caption))
                    .foregroundStyle(.secondary)
                Text(entry.path)
                    .font(.bighelp(.caption).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: BighelpTokens.space8)
            Image(systemName: "chevron.right")
                .font(.bighelp(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct NativeSessionVerificationStatusView: View {
    let status: DirectHermesVerificationStatus

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            LabeledContent("Status", value: status.status)
            optionalValue("Root", status.root)
            optionalValue("Chat ID", status.sessionID)
            if let paths = status.changedPaths {
                DisclosureGroup("Changed paths (\(paths.count))") {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                            Text(path)
                                .font(.bighelp(.caption).monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, BighelpTokens.space4)
                }
            }
            if let evidence = status.evidence {
                DisclosureGroup("Evidence") {
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        optionalValue("ID", evidence.id?.formatted())
                        optionalValue("Created", evidence.createdAt)
                        optionalValue("Chat ID", evidence.sessionID)
                        optionalValue("Working directory", evidence.workingDirectory)
                        optionalValue("Root", evidence.root)
                        optionalValue("Command", evidence.command)
                        optionalValue("Canonical command", evidence.canonicalCommand)
                        optionalValue("Kind", evidence.kind)
                        optionalValue("Scope", evidence.scope)
                        optionalValue("Status", evidence.status)
                        optionalValue("Exit code", evidence.exitCode?.formatted())
                        optionalValue("Output summary", evidence.outputSummary)
                    }
                    .padding(.top, BighelpTokens.space8)
                }
            }
        }
    }

    @ViewBuilder
    private func optionalValue(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }
}

enum NativeSessionReadOnlyFormatting {
    static func text(_ value: BighelpJSONValue) -> String {
        if let display = value.displayText { return display }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "Unavailable"
        }
        return text
    }

    static func timestamp(_ value: Double?) -> String? {
        guard let value else { return nil }
        let raw = value.formatted(.number.precision(.significantDigits(1...15)))
        return "\(Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .standard)) · \(raw)"
    }
}
