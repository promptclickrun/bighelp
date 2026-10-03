#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftUI

/// `-test-models-page`: the Models page against a synthetic host, so UI tests can
/// check the profile default, auxiliary task and Mixture of Agents pickers.
enum ModelAdministrationFixture {
    static let launchArgument = "-test-models-page"

    @MainActor
    static func rootView() -> some View {
        let owner = WorkspaceOwner(
            authority: try! .direct(endpointIdentity: "https://models.example", providerID: "basic", userID: "person"),
            authenticationGeneration: UUID(),
            connectionGeneration: UUID()
        )
        let transport = DemoModelsTransport(answersReadiness: false)
        let client = DirectHermesModelAdministrationClient(
            rpc: transport, http: transport, owner: owner, currentOwner: { owner }
        )
        return NavigationStack {
            ModelAdministrationView(hostName: "Demo host", profileID: "default", client: client)
        }
        .environment(\.bighelpUIV3Enabled, true)
    }
}
#endif
