import Foundation

/// One operation an agent's `iphone_*` tool can ask the phone for.
struct DeviceToolOperation: Equatable, Sendable {
    let capability: DeviceToolCapability
    /// A change to the person's data. The coordinator journals it before it runs, so a retried
    /// request returns the first outcome instead of changing anything twice.
    let journaled: Bool
    /// Result fields the agent gets now but the journal never keeps (the journal holds only
    /// `id`, `revision` and `deleted`). A retry of a finished request gets the result without them.
    let liveOnlyKeys: Set<String>
    /// Result fields the journal keeps beside `id`, `revision` and `deleted`: short, fixed words
    /// that hold none of the person's data, so a retry tells the agent how it went.
    let keptKeys: Set<String>

    init(_ capability: DeviceToolCapability, journaled: Bool, liveOnlyKeys: Set<String> = [],
         keptKeys: Set<String> = []) {
        self.capability = capability
        self.journaled = journaled
        self.liveOnlyKeys = liveOnlyKeys
        self.keptKeys = keptKeys
    }

    /// What the journal may store for this operation.
    var journalKeys: Set<String> { DeviceToolCatalog.durableKeys.union(keptKeys) }
}

/// Every operation the phone answers. docs/IPHONE_DEVICE_TOOLS.md describes each one; the
/// plugin checks the same names and arguments before a request reaches the phone.
enum DeviceToolCatalog {
    static let durableKeys: Set<String> = ["id", "revision", "deleted"]

    static let operations: [String: DeviceToolOperation] = {
        var all: [String: DeviceToolOperation] = [:]
        func reads(_ capability: DeviceToolCapability, _ names: String...) {
            for name in names { all["\(capability.rawValue).\(name)"] = DeviceToolOperation(capability, journaled: false) }
        }
        func writes(_ capability: DeviceToolCapability, _ names: String..., liveOnly: Set<String> = [],
                    kept: Set<String> = []) {
            for name in names {
                all["\(capability.rawValue).\(name)"] = DeviceToolOperation(
                    capability, journaled: true, liveOnlyKeys: liveOnly, keptKeys: kept)
            }
        }
        // Read only: bighelp never writes to Health.
        reads(.health, "read")
        reads(.calendar, "list"); writes(.calendar, "create", "update", "delete")
        reads(.reminders, "list"); writes(.reminders, "create", "update", "delete")
        reads(.contacts, "list"); writes(.contacts, "create", "update", "delete")
        reads(.photos, "list", "albums", "get")
        writes(.photos, "save", "update", "createAlbum")
        writes(.photos, "delete", liveOnly: ["count"])
        reads(.location, "current")
        reads(.geofences, "list"); writes(.geofences, "create", "delete")
        reads(.alarms, "list"); writes(.alarms, "create", "update", "delete")
        // Playing and pausing act on what's playing now: doing it twice is the same as once.
        reads(.music, "nowPlaying", "search", "library", "play", "control")
        writes(.music, "createPlaylist", "addToPlaylist", "addToLibrary")
        reads(.focus, "current")
        reads(.shortcuts, "list")
        // A shortcut can do anything, so a retry never runs it again; its output is the agent's only.
        // Its status (completed, cancelled, failed) is kept, so a retry reports how it went.
        writes(.shortcuts, "run", liveOnly: ["output", "truncated"], kept: ["status"])
        // Setting a look twice is the same as once, so there's nothing to reconcile.
        reads(.appearance, "get", "set")
        // Moves between pages and points; it never changes the person's data or a setting.
        reads(.navigation, "places", "open")
        return all
    }()

    static func capability(for operation: String) -> DeviceToolCapability? {
        operations[operation]?.capability
    }
}

/// Who asked: the request's own coordinates, for tools that act later (an arrival tells the chat
/// that set the place) or keep things per host.
struct DeviceToolCallContext: Equatable, Sendable {
    let requestID: String
    let hostID: String
    let agentID: String
    let sessionID: String
    let turnID: String

    init(requestID: String, hostID: String, agentID: String, sessionID: String, turnID: String) {
        self.requestID = requestID; self.hostID = hostID; self.agentID = agentID
        self.sessionID = sessionID; self.turnID = turnID
    }

    init(_ request: DeviceToolRequest) {
        self.init(requestID: request.requestId, hostID: request.hostId, agentID: request.agentId,
                  sessionID: request.sessionId, turnID: request.turnId)
    }
}

/// A phone tool with its own iOS permission: Contacts, Photos, Arriving and leaving, Alarms,
/// Music, Focus and Shortcuts. Apple Health, Calendar, Reminders and Location live in `AppleDeviceToolService`.
@MainActor
protocol DeviceCapabilityTool: AnyObject {
    var capability: DeviceToolCapability { get }
    /// iOS's current answer. Never asks.
    func status() async -> DeviceToolSystemAccess
    /// The Settings switch: asks iOS the first time, from the person's tap.
    func request() async -> DeviceToolSystemAccess
    /// Runs one operation from `DeviceToolCatalog`. Arguments arrive unchecked: a tool rejects
    /// unknown keys and bad values with `invalid_arguments` before it touches anything, and calls
    /// `authorize` again after every wait (a question from iOS, a fetch), before it changes anything.
    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        context: DeviceToolCallContext,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue]
}

/// Sends each request to the tool that owns its capability, after checking iOS still allows it.
@MainActor
final class DeviceToolRouter {
    private let apple: AppleDeviceToolService
    private let tools: [DeviceToolCapability: any DeviceCapabilityTool]

    init(apple: AppleDeviceToolService, tools: [any DeviceCapabilityTool]) {
        self.apple = apple
        self.tools = Dictionary(tools.map { ($0.capability, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func status(_ kind: DeviceToolCapability) async -> DeviceToolSystemAccess {
        guard kind.isOfferedOnThisPlatform else { return .unavailable }
        if let tool = tools[kind] { return await tool.status() }
        return await apple.status(kind)
    }

    func request(_ kind: DeviceToolCapability) async -> DeviceToolSystemAccess {
        guard kind.isOfferedOnThisPlatform else { return .unavailable }
        if let tool = tools[kind] { return await tool.request() }
        return await apple.request(kind)
    }

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        context: DeviceToolCallContext,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        guard let entry = DeviceToolCatalog.operations[operation] else {
            throw AppleDeviceToolError.unsupportedOperation
        }
        guard let tool = tools[entry.capability] else {
            return try await apple.execute(operation: operation, arguments: arguments, authorize: authorize)
        }
        guard entry.capability.isOfferedOnThisPlatform else { throw AppleDeviceToolError.unavailable }
        let guardedAuthorize: @MainActor () throws -> Void = {
            do { try authorize() } catch { throw AppleDeviceToolError.authorizationRequired }
        }
        do {
            try guardedAuthorize()
            switch await tool.status() {
            case .available: break
            case .unavailable: throw AppleDeviceToolError.unavailable
            case .notRequested, .denied: throw AppleDeviceToolError.authorizationRequired
            }
            try guardedAuthorize()
            let result = try await tool.execute(operation: operation, arguments: arguments,
                                                context: context, authorize: guardedAuthorize)
            try guardedAuthorize()
            return result
        } catch let error as any DeviceToolFailure {
            throw error
        } catch {
            throw AppleDeviceToolError.nativeFailure
        }
    }
}
