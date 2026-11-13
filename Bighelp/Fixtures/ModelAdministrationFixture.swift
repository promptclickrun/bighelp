#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftUI

/// `-test-models-page`: Settings › Models' Default model against made-up bots, so UI tests can open a
/// bot's row and check its Default Model page.
enum ModelAdministrationFixture {
    static let launchArgument = "-test-models-page"
    @MainActor private static let sharedDefaults = FixtureAgentRuntimeDefaultsClient()

    @MainActor
    static func rootView() -> some View {
        Root()
    }

    /// Held in state: the app's body runs again at launch.
    private struct Root: View {
        // Kept for the run so a second visit shows what was saved.
        @State private var defaults = ModelsBotDefaults(
            agents: [.init(id: "default", name: "Avery Park", imageURL: nil),
                     .init(id: "travel", name: "Mina Shah", imageURL: nil)],
            client: ModelAdministrationFixture.sharedDefaults)

        var body: some View {
            NavigationStack {
                Form { ModelsDefaultModelSection(defaults: defaults) }
                    .bighelpFormSurface()
                    .navigationTitle("Models")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .environment(\.bighelpUIV3Enabled, true)
        }
    }
}
#endif
