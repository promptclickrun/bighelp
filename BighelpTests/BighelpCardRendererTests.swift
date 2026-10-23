import Testing
@testable import Bighelp

struct BighelpCardRendererTests {
    @Test func rendererAndValidatorShareTheFiniteComponentCatalog() {
        #expect(BighelpCardRenderer.supportedTypes == Set([
            "card", "vstack", "hstack", "grid", "text", "metric", "badge",
            "progress", "chart", "table", "list", "divider", "spacer", "image",
            "contact", "place", "music",
        ]))
        #expect(BighelpCardValidator.supportedElementTypes == BighelpCardRenderer.supportedTypes)
    }
}
