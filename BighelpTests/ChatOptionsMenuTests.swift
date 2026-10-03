import Testing
@testable import Bighelp

/// The chat ⋯ menu's model group. The context window left the rail above the
/// message box for this menu, between the model and provider usage.
struct ChatOptionsMenuTests {
    @Test func theContextWindowSitsBetweenModelAndProviderUsage() {
        #expect(ChatOptionsModelMenuItem.items(hasModelControls: true, showsContextWindow: true,
                                               showsProviderUsage: true)
            == [.modelAndReasoning, .contextWindow, .providerUsage])
    }

    @Test func missingPartsLeaveOnlyTheirOwnItemOut() {
        #expect(ChatOptionsModelMenuItem.items(hasModelControls: true, showsContextWindow: false,
                                               showsProviderUsage: true)
            == [.modelAndReasoning, .providerUsage])
        #expect(ChatOptionsModelMenuItem.items(hasModelControls: false, showsContextWindow: true,
                                               showsProviderUsage: false)
            == [.contextWindow])
        #expect(ChatOptionsModelMenuItem.items(hasModelControls: false, showsContextWindow: false,
                                               showsProviderUsage: false).isEmpty)
    }
}
