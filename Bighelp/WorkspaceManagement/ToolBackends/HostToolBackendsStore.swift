import Foundation
import Observation

enum HostToolBackendsSupport: Equatable, Sendable {
    case unknown
    case available
    case unavailable(String)
}

@MainActor
@Observable
final class HostToolBackendsStore {
    enum Review: Identifiable, Equatable {
        case selectBackend(HermesTerminalBackend)
        case requestComputerUsePermissions(HermesComputerUseStatus)

        var id: String {
            switch self {
            case .selectBackend(let backend): "terminal\u{1f}\(backend.id)"
            case .requestComputerUsePermissions(let status):
                "computer-use\u{1f}\(status.hostPlatform)\u{1f}\(status.version ?? "unknown")"
            }
        }

        var title: String {
            switch self {
            case .selectBackend: "Change the host terminal backend?"
            case .requestComputerUsePermissions: "Open macOS permission controls on the host?"
            }
        }

        var buttonTitle: String {
            switch self {
            case .selectBackend(let backend): "Use \(backend.label)"
            case .requestComputerUsePermissions: "Request on Host Mac"
            }
        }

        var message: String {
            switch self {
            case .selectBackend(let backend):
                let readiness = backend.status == .ready
                    ? "Hermes currently reports this backend ready."
                    : "Hermes reports that this backend still needs setup: \(backend.detail)"
                return "Hermes will persist \(backend.label) as the terminal execution backend for the selected profile. \(readiness) Existing terminal sessions are not migrated by this selection."
            case .requestComputerUsePermissions:
                return "Hermes will launch CuaDriver’s permission flow on the selected host Mac. You must approve Accessibility and Screen Recording in macOS on that host. \(BighelpPlatform.isMac ? "Bighelp" : "This iPhone or iPad") cannot grant Mac permissions."
            }
        }
    }

    let hostName: String
    let profileID: String

    private(set) var support: HostToolBackendsSupport = .unknown
    private(set) var terminal: HermesTerminalBackends?
    private(set) var computerUse: HermesComputerUseStatus?
    private(set) var grantReceipt: HermesComputerUseGrantReceipt?
    private(set) var grantStatus: HermesComputerUseGrantStatus?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var isRetired = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    var review: Review?

    @ObservationIgnored private let client: any HermesHostToolBackendsManaging
    @ObservationIgnored private let isCurrent: @MainActor () -> Bool
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var grantPollingTask: Task<Void, Never>?

    init(
        hostName: String,
        profileID: String,
        client: any HermesHostToolBackendsManaging,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
        self.isCurrent = isCurrent
    }

    var ownsScope: Bool { !isRetired && isCurrent() }
    var canAct: Bool { ownsScope && support == .available && !isLoading && !isMutating }

    func load() async {
        guard ownsScope, !isMutating else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == token { isLoading = false } }

        do {
            let next = try await client.terminalBackends(profileID: profileID)
            guard accepts(token) else { return }
            terminal = next
            support = .available
        } catch HermesHostToolBackendsError.unavailable {
            guard accepts(token) else { return }
            support = .unavailable("This Hermes host does not expose terminal backend and Computer Use management.")
            terminal = nil
            computerUse = nil
            return
        } catch {
            publish(error, token: token)
            return
        }

        do {
            let next = try await client.computerUseStatus(profileID: profileID)
            guard accepts(token) else { return }
            computerUse = next
        } catch HermesHostToolBackendsError.unavailable {
            guard accepts(token) else { return }
            computerUse = nil
            errorMessage = "Terminal backends are available, but this host does not expose Computer Use status."
        } catch {
            guard accepts(token) else { return }
            errorMessage = "Terminal backends loaded, but Computer Use status could not be refreshed."
        }
    }

    func prepareBackend(_ backend: HermesTerminalBackend) {
        guard canAct, !backend.isActive else { return }
        review = .selectBackend(backend)
    }

    func prepareComputerUsePermissionRequest() {
        guard canAct, let status = computerUse, status.requiresMacHostInteraction,
              status.isInstalled else { return }
        review = .requestComputerUsePermissions(status)
    }

    func confirm(_ expected: Review) async {
        guard canAct, review == expected else {
            review = nil
            return
        }
        review = nil
        let token = beginMutation()
        defer { finishMutation(token) }
        do {
            switch expected {
            case .selectBackend(let backend):
                let readback = try await client.selectTerminalBackend(reviewed: backend, profileID: profileID)
                guard accepts(token) else { return }
                terminal = readback
                let selected = readback.backends.first { $0.id == backend.id }
                successMessage = selected?.status == .ready
                    ? "Host readback confirms \(backend.label) is the selected terminal backend."
                    : "Host readback confirms \(backend.label) is selected, but it still needs host setup before use."
            case .requestComputerUsePermissions(let status):
                let receipt = try await client.requestComputerUsePermissionGrant(
                    reviewed: status, profileID: profileID
                )
                guard accepts(token) else { return }
                grantReceipt = receipt
                grantStatus = .init(
                    phase: .waitingForHostInteraction,
                    processID: receipt.processID,
                    actionID: receipt.actionID
                )
                successMessage = "Hermes opened the CuaDriver flow on the host Mac. Approve Accessibility and Screen Recording there; this device cannot grant them."
                startGrantPolling(receipt)
            }
        } catch HermesHostToolBackendsError.outcomeUnknown {
            await reconcileUnknownMutation(expected, token: token)
        } catch { publish(error, token: token) }
    }

    func refreshComputerUse() async {
        guard ownsScope else { return }
        do {
            let next = try await client.computerUseStatus(profileID: profileID)
            guard ownsScope else { return }
            computerUse = next
            if next.isReady == true {
                successMessage = "The host now reports Computer Use ready. This status came from the host OS and CuaDriver."
            }
        } catch { publish(error) }
    }

    func refreshGrantStatus() async {
        guard ownsScope, let receipt = grantReceipt else { return }
        do {
            let next = try await client.permissionGrantStatus(for: receipt)
            guard ownsScope else { return }
            grantStatus = next
            if case .waitingForHostInteraction = next.phase {
                successMessage = "CuaDriver is still waiting for approval on the host Mac."
            } else {
                await refreshComputerUseAfterGrant()
            }
        } catch { publishGrantError(error) }
    }

    func dismissGrantReceipt() {
        grantPollingTask?.cancel()
        grantPollingTask = nil
        grantReceipt = nil
        grantStatus = nil
    }

    func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }

    func retire() {
        isRetired = true
        generation = UUID()
        grantPollingTask?.cancel()
        grantPollingTask = nil
        support = .unknown
        terminal = nil
        computerUse = nil
        grantReceipt = nil
        grantStatus = nil
        review = nil
        isLoading = false
        isMutating = false
        errorMessage = nil
        successMessage = nil
    }

    private func startGrantPolling(_ receipt: HermesComputerUseGrantReceipt) {
        grantPollingTask?.cancel()
        grantPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<150 {
                if attempt > 0 {
                    do { try await Task.sleep(nanoseconds: 1_500_000_000) }
                    catch { return }
                }
                guard self.ownsScope, !Task.isCancelled,
                      self.grantReceipt?.id == receipt.id else { return }
                do {
                    let next = try await self.client.permissionGrantStatus(for: receipt)
                    guard self.ownsScope, self.grantReceipt?.id == receipt.id else { return }
                    self.grantStatus = next
                    if case .waitingForHostInteraction = next.phase { continue }
                    self.grantPollingTask = nil
                    await self.refreshComputerUseAfterGrant()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard self.ownsScope else { return }
                    self.grantPollingTask = nil
                    self.publishGrantError(error)
                    return
                }
            }
            guard self.ownsScope, self.grantReceipt?.id == receipt.id else { return }
            self.grantPollingTask = nil
            self.successMessage = "CuaDriver is still waiting on the host Mac. Complete the macOS dialogs there, then refresh status."
        }
    }

    private func refreshComputerUseAfterGrant() async {
        guard ownsScope else { return }
        do {
            let readback = try await client.computerUseStatus(profileID: profileID)
            guard ownsScope else { return }
            computerUse = readback
            if readback.isReady == true {
                successMessage = "The host reports that CuaDriver now has the required OS permissions and Computer Use is ready."
            } else {
                errorMessage = "The host permission process ended, but Computer Use is not ready. Check Accessibility and Screen Recording on the host Mac; \(BighelpPlatform.isMac ? "Bighelp" : "the phone") did not grant either permission."
            }
        } catch {
            guard ownsScope else { return }
            errorMessage = "The host permission process ended, but readiness could not be read back. Check the host Mac before requesting again."
        }
    }

    private func reconcileUnknownMutation(_ review: Review, token: UUID) async {
        do {
            let nextTerminal = try await client.terminalBackends(profileID: profileID)
            let nextComputer = try await client.computerUseStatus(profileID: profileID)
            guard accepts(token) else { return }
            terminal = nextTerminal
            computerUse = nextComputer
            switch review {
            case .selectBackend(let backend) where nextTerminal.activeBackendID == backend.id:
                successMessage = "Host readback confirms \(backend.label) is selected."
            case .requestComputerUsePermissions where nextComputer.isReady == true:
                successMessage = "The host now reports Computer Use ready. This status came from the host OS; \(BighelpPlatform.isMac ? "Bighelp" : "the phone") did not grant Mac permissions."
            case .requestComputerUsePermissions:
                errorMessage = "The launch outcome is unknown. Check the host Mac for CuaDriver or macOS dialogs, then refresh; Bighelp did not repeat the request."
            case .selectBackend:
                errorMessage = "The selection outcome is unknown and host readback does not confirm it. Bighelp did not repeat the request."
            }
        } catch {
            guard accepts(token) else { return }
            errorMessage = "The request outcome is unknown and host backend readback failed. Check the host before trying again."
        }
    }

    private func beginMutation() -> UUID {
        let token = UUID()
        generation = token
        isLoading = false
        isMutating = true
        errorMessage = nil
        successMessage = nil
        return token
    }

    private func finishMutation(_ token: UUID) {
        if generation == token { isMutating = false }
    }

    private func accepts(_ token: UUID) -> Bool {
        ownsScope && generation == token && !Task.isCancelled
    }

    private func publish(_ error: any Error, token: UUID? = nil) {
        if let token, !accepts(token) { return }
        guard ownsScope else { return }
        if error is CancellationError { return }
        if let error = error as? HermesHostToolBackendsError { errorMessage = error.localizedDescription }
        else if let error = error as? DirectHermesError { errorMessage = error.localizedDescription }
        else { errorMessage = "Hermes could not complete this Tool Backends request. Refresh host status before trying again." }
    }

    private func publishGrantError(_ error: any Error) {
        guard ownsScope, !(error is CancellationError) else { return }
        errorMessage = "Bighelp could not confirm the host permission process. Check the host Mac and refresh Computer Use status; do not assume \(BighelpPlatform.isMac ? "Bighelp" : "the phone") granted permission."
    }
}
