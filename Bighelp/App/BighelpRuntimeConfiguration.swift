import Foundation

enum BighelpRuntimeConfiguration {
    static func nativeAcceptanceStorageID(
        arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UUID? {
        #if DEBUG && targetEnvironment(simulator)
        guard arguments.contains("-native-workspace-acceptance"),
              let value = environment["BIGHELP_UI_TEST_RUN_ID"] else { return nil }
        return UUID(uuidString: value)
        #else
        return nil
        #endif
    }
}
